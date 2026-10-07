import Darwin
import Dispatch
import Foundation
import Testing

@testable import AirPodsControlCore


private final class AllowOffCacheTestClock {
  var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func read() -> Date {
    value
  }
}

private enum AllowOffCacheTestError: Error {
  case unavailable
}

private let allowOffCacheTestSalt = Data(0..<32)

private func withTemporaryAllowOffCache(
  cleanupIf: () -> Bool = { true },
  _ body: (URL) -> Void
) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pods-control-allow-off-cache-tests-\(UUID().uuidString)",
    isDirectory: true
  )
  do {
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
  } catch {
    Issue.record("allow-off cache test creates its temporary root")
    return
  }
  defer {
    // Preserve the directory when a timed-out worker may still access it.
    if cleanupIf() {
      try? FileManager.default.removeItem(at: root)
    }
  }
  body(
    root
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent("allow-off-v1.json", isDirectory: false)
  )
}

private func withAllowOffCacheRenameFixture(
  cleanupIf: () -> Bool = { true },
  _ body: (_ legacyFileURL: URL, _ newFileURL: URL) -> Void
) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pods-control-allow-off-migration-\(UUID().uuidString)",
    isDirectory: true
  )
  do {
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
  } catch {
    Issue.record("allow-off cache migration test creates its temporary root")
    return
  }
  defer {
    // Preserve the directory when a timed-out worker may still access it.
    if cleanupIf() {
      try? FileManager.default.removeItem(at: root)
    }
  }
  body(
    root
      .appendingPathComponent(
        allowOffCacheLegacyDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(allowOffCacheFileName, isDirectory: false),
    root
      .appendingPathComponent(
        allowOffCacheDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(allowOffCacheFileName, isDirectory: false)
  )
}

private func allowOffRecord(
  from lookup: AllowOffCacheLookup
) -> AllowOffCacheRecord? {
  guard case .allowed(let record) = lookup else { return nil }
  return record
}

private func allowOffDenialRecord(
  from lookup: AllowOffCacheLookup
) -> AllowOffCacheRecord? {
  guard case .denied(let record) = lookup else { return nil }
  return record
}

private func allowOffCacheJSON(
  at fileURL: URL
) -> [String: Any]? {
  guard let data = try? Data(contentsOf: fileURL),
        let value = try? JSONSerialization.jsonObject(with: data),
        let object = value as? [String: Any]
  else { return nil }
  return object
}

private func allowOffCacheLstat(_ url: URL) -> stat? {
  var value = stat()
  let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return -1 }
    return Darwin.lstat(path, &value)
  }
  return result == 0 ? value : nil
}

private func allowOffCacheIsSymbolicLink(_ url: URL) -> Bool {
  guard let value = allowOffCacheLstat(url) else { return false }
  return value.st_mode & S_IFMT == S_IFLNK
}

private func allowOffCachePermissions(at url: URL) -> Int? {
  guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let permissions = attributes[.posixPermissions] as? NSNumber
  else { return nil }
  return permissions.intValue
}

private func withHeldAllowOffCacheFileLock(
  fileURL: URL,
  _ body: () -> Void
) {
  let lockURL = fileURL.deletingLastPathComponent()
    .appendingPathComponent("allow-off-v1.lock")
  let lockfURL = URL(fileURLWithPath: "/usr/bin/lockf")
  guard FileManager.default.isExecutableFile(atPath: lockfURL.path) else {
    Issue.record("lock contention test resolves the system lockf executable")
    return
  }

  let process = Process()
  let releasePipe = Pipe()
  let readyPipe = Pipe()
  let exited = DispatchSemaphore(value: 0)
  defer {
    try? releasePipe.fileHandleForReading.close()
    try? releasePipe.fileHandleForWriting.close()
    try? readyPipe.fileHandleForReading.close()
    try? readyPipe.fileHandleForWriting.close()
  }
  process.executableURL = lockfURL
  process.arguments = ["-k", "-t", "1", lockURL.path, "/bin/cat"]
  process.standardInput = releasePipe
  process.standardOutput = readyPipe
  process.terminationHandler = { _ in exited.signal() }
  do {
    // Queue the byte before launch so an early lockf failure cannot cause SIGPIPE.
    try releasePipe.fileHandleForWriting.write(contentsOf: Data([1]))
    try process.run()
  } catch {
    Issue.record("lock contention test starts lockf: \(error)")
    return
  }
  defer {
    // EOF lets cat exit and lockf reap it before releasing the preserved lock file.
    try? releasePipe.fileHandleForWriting.close()
    if exited.wait(timeout: .now() + 2) == .timedOut {
      Issue.record("lock contention holder did not exit within two seconds of EOF")
      let pid = process.processIdentifier
      // On failure, stop the isolated Process group, including cat.
      if process.isRunning, Darwin.getpgid(pid) == pid {
        _ = Darwin.kill(-pid, SIGKILL)
      }
      if exited.wait(timeout: .now() + 2) == .timedOut {
        Issue.record("lock contention holder could not be reaped")
      }
    }
    if !process.isRunning {
      process.waitUntilExit()
      #expect(
        process.terminationReason == .exit && process.terminationStatus == 0,
        "lock contention holder exits normally after release"
      )
    }
  }

  // Only cat can echo the byte, and lockf starts it only after acquiring the lock.
  try? releasePipe.fileHandleForReading.close()
  try? readyPipe.fileHandleForWriting.close()
  var readiness = pollfd(
    fd: readyPipe.fileHandleForReading.fileDescriptor,
    events: Int16(POLLIN),
    revents: 0
  )
  let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
  var pollResult: Int32
  repeat {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now < deadline else {
      Issue.record("lock contention holder did not become ready within two seconds")
      return
    }
    let remainingMilliseconds = Int32((deadline - now + 999_999) / 1_000_000)
    pollResult = Darwin.poll(&readiness, 1, remainingMilliseconds)
  } while pollResult < 0 && errno == EINTR
  guard pollResult > 0, readiness.revents & Int16(POLLIN) != 0 else {
    Issue.record("lock contention holder failed or timed out before becoming ready")
    return
  }
  do {
    guard try readyPipe.fileHandleForReading.read(upToCount: 1) == Data([1]) else {
      Issue.record("lock contention holder did not echo its readiness byte")
      return
    }
  } catch {
    Issue.record("lock contention test reads readiness: \(error)")
    return
  }
  body()
}

@Suite("Persistent Allow Off cache")
struct PersistentListeningModeAllowOffCacheTests {
  @Test("Uses the versioned user Caches path and a side-effect-free factory")
  func allowOffCacheUsesVersionedCachesPathAndFactory() {
    do {
      let expectedSuffix =
        "/Library/Caches/io.github.raulgg.pods-control/allow-off-v1.json"
      let defaultURL = try? PersistentListeningModeAllowOffCache.defaultFileURL()
      #expect(
        defaultURL?.path.hasSuffix(expectedSuffix) == true,
        "allow-off cache uses the versioned user Caches path"
      )
      #expect(
        PersistentListeningModeAllowOffCache.systemDefault() != nil,
        "allow-off cache has a side-effect-free system-default factory"
      )
    }
  }

  @Test("Copies a legacy Allow Off cache on miss and keeps the old file")
  func allowOffCacheCopiesLegacyFileOnMiss() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_000))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "AppleHDAEngineOutput:AirPods:CaseSensitive-UID"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "legacy Allow Off evidence is stored"
      )
      guard let legacyData = try? Data(contentsOf: legacyURL) else {
        Issue.record("legacy Allow Off cache was written")
        return
      }
      let legacyDirectory = legacyURL.deletingLastPathComponent()
      let marker = legacyDirectory.appendingPathComponent(
        "allow-off-v1-deny-abc.jsonl"
      )
      let lock = legacyDirectory.appendingPathComponent("allow-off-v1.lock")
      do {
        try Data("deny\n".utf8).write(to: marker)
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o600)],
          ofItemAtPath: marker.path
        )
        try Data("lock".utf8).write(to: lock)
      } catch {
        Issue.record("legacy Allow Off cache side files were seeded")
        return
      }

      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { Data(repeating: 9, count: 32) }
      )
      guard let record = allowOffRecord(
        from: migrated.lookup(rawDeviceUID: rawUID)
      ) else {
        Issue.record("legacy Allow Off evidence is visible at the new path")
        return
      }
      #expect(
        record.evidence.observedAt == clock.value,
        "copied Allow Off evidence keeps its timestamp"
      )
      #expect(
        (try? Data(contentsOf: newURL)) == legacyData,
        "the new cache file is a byte copy"
      )
      #expect(
        (try? Data(contentsOf: legacyURL)) == legacyData,
        "migration does not delete or rewrite the legacy cache"
      )
      let newDirectory = newURL.deletingLastPathComponent()
      #expect(
        FileManager.default.fileExists(
          atPath: newDirectory.appendingPathComponent(
            "allow-off-v1-deny-abc.jsonl"
          ).path
        ),
        "migration copies deny markers"
      )
      #expect(
        !FileManager.default.fileExists(
          atPath: newDirectory.appendingPathComponent("allow-off-v1.lock").path
        ),
        "migration does not copy the lock file"
      )
      try? FileManager.default.removeItem(at: legacyURL)
      #expect(
        allowOffRecord(from: migrated.lookup(rawDeviceUID: rawUID)) != nil,
        "later reads use the copied file"
      )
    }
  }

  @Test("Publishes a legacy Allow Off copy only as a complete directory")
  func allowOffCachePublishesCompleteDirectory() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_005))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "complete-publication-uid"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "legacy Allow Off evidence exists before publication"
      )
      let legacyDirectory = legacyURL.deletingLastPathComponent()
      let denyName = "allow-off-v1-deny-abc.jsonl"
      let denyMarker = legacyDirectory.appendingPathComponent(denyName)
      do {
        try Data("deny\n".utf8).write(to: denyMarker)
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o600)],
          ofItemAtPath: denyMarker.path
        )
      } catch {
        Issue.record("complete publication test seeds a deny marker")
        return
      }

      let newDirectory = newURL.deletingLastPathComponent()
      var publishedEarly = false
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { Data(repeating: 9, count: 32) },
        legacyMigrationCreatedObserver: {
          if allowOffCacheLstat(newDirectory) != nil {
            publishedEarly = true
          }
        }
      )
      guard allowOffRecord(from: migrated.lookup(rawDeviceUID: rawUID)) != nil else {
        Issue.record("the published copy keeps the legacy Allow Off record")
        return
      }
      #expect(!publishedEarly, "the final directory is absent until the copy is complete")
      #expect(
        FileManager.default.fileExists(
          atPath: newDirectory.appendingPathComponent(denyName).path
        ),
        "the published directory includes the deny marker"
      )
      let parent = newDirectory.deletingLastPathComponent()
      let names = (
        try? FileManager.default.contentsOfDirectory(atPath: parent.path)
      ) ?? []
      #expect(
        names.contains { $0.hasSuffix(".migrating") } == false,
        "a finished copy leaves no private directory behind"
      )
    }
  }

  @Test("Does not copy a legacy Allow Off cache again after the new one is removed")
  func allowOffCacheRemovalDoesNotRestoreLegacyEvidence() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_010))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "removed-new-cache-uid"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "legacy Allow Off evidence exists before removal"
      )
      guard let legacyData = try? Data(contentsOf: legacyURL) else {
        Issue.record("legacy Allow Off cache was written")
        return
      }
      let legacyMode = allowOffCachePermissions(at: legacyURL)
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { Data(repeating: 9, count: 32) }
      )
      guard allowOffRecord(from: migrated.lookup(rawDeviceUID: rawUID)) != nil else {
        Issue.record("legacy Allow Off evidence is copied before removal")
        return
      }
      let markerURL = legacyURL
        .deletingLastPathComponent()
        .appendingPathComponent(allowOffCacheLegacyMigrationMarkerName)
      #expect(
        allowOffCachePermissions(at: markerURL) == 0o600,
        "migration records a private marker beside the legacy cache"
      )
      #expect(
        allowOffCachePermissions(at: legacyURL) == legacyMode,
        "migration does not chmod the legacy cache"
      )

      try? FileManager.default.removeItem(at: newURL)
      #expect(
        migrated.lookup(rawDeviceUID: rawUID) == .miss,
        "deleting the new cache file stays a miss"
      )
      #expect(
        allowOffCacheLstat(newURL) == nil,
        "deleting the new cache file does not copy the legacy cache back"
      )
      #expect(
        (try? Data(contentsOf: legacyURL)) == legacyData,
        "deleting the new cache leaves the legacy bytes unchanged"
      )

      try? FileManager.default.removeItem(at: newURL.deletingLastPathComponent())
      #expect(
        migrated.lookup(rawDeviceUID: rawUID) == .miss,
        "deleting the new cache directory stays a miss"
      )
      #expect(
        allowOffCacheLstat(newURL) == nil,
        "deleting the new cache directory does not copy the legacy cache back"
      )
      #expect(
        (try? Data(contentsOf: markerURL)) == Data("1\n".utf8),
        "the migration marker remains after the new directory is deleted"
      )
    }
  }

  @Test("Does not restore legacy Allow Off evidence when a negative write purges the new cache")
  func allowOffCachePurgeDoesNotRestoreLegacyEvidence() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_020))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "purged-new-cache-uid"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "legacy positive Allow Off evidence exists before the purge"
      )
      guard let legacyData = try? Data(contentsOf: legacyURL) else {
        Issue.record("legacy Allow Off cache was written")
        return
      }
      var failTemporaryBackup = false
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt },
        markExcludedFromBackup: { url in
          if failTemporaryBackup && url.pathExtension == "tmp" {
            throw AllowOffCacheTestError.unavailable
          }
          try excludeAllowOffCacheURLFromBackup(url)
        }
      )
      guard allowOffRecord(from: migrated.lookup(rawDeviceUID: rawUID)) != nil else {
        Issue.record("legacy positive evidence is copied before the purge")
        return
      }
      failTemporaryBackup = true
      #expect(
        migrated.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: clock.value
        ) == .applied,
        "a failed negative write purges the new cache"
      )
      #expect(
        migrated.lookup(rawDeviceUID: rawUID) == .miss,
        "the purge does not expose the legacy positive evidence"
      )
      #expect(
        allowOffCacheLstat(newURL) == nil,
        "the purge does not copy the legacy cache back"
      )
      #expect(
        (try? Data(contentsOf: legacyURL)) == legacyData,
        "the purge leaves the legacy cache unchanged"
      )
    }
  }

  @Test("Migrates legacy Allow Off evidence on the first cache write")
  func allowOffCacheWriteMigratesLegacyEvidence() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_030))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let originalUID = "legacy-write-migration-original"
      let addedUID = "legacy-write-migration-added"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: originalUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "legacy Allow Off evidence exists before the first new write"
      )
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { Data(repeating: 9, count: 32) }
      )
      #expect(
        migrated.applyObservation(
          rawDeviceUID: addedUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "the first write stores its own Allow Off evidence"
      )
      #expect(
        allowOffRecord(from: migrated.lookup(rawDeviceUID: originalUID))?
          .evidence.observedAt == clock.value,
        "the first write keeps the legacy Allow Off evidence"
      )
    }
  }

  @Test("Does not restore legacy Allow Off evidence on a write after the new cache directory is deleted")
  func allowOffCacheWriteAfterDirectoryRemovalDoesNotRestoreLegacyEvidence() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_040))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let originalUID = "legacy-write-after-removal-original"
      let addedUID = "legacy-write-after-removal-added"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: originalUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "legacy Allow Off evidence exists before the new cache directory is deleted"
      )
      guard let legacyData = try? Data(contentsOf: legacyURL) else {
        Issue.record("legacy Allow Off cache was written")
        return
      }
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { Data(repeating: 9, count: 32) }
      )
      guard allowOffRecord(from: migrated.lookup(rawDeviceUID: originalUID)) != nil else {
        Issue.record("legacy Allow Off evidence is copied before removal")
        return
      }

      try? FileManager.default.removeItem(at: newURL.deletingLastPathComponent())
      #expect(
        migrated.applyObservation(
          rawDeviceUID: addedUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "a write recreates the new cache directory"
      )
      #expect(
        allowOffRecord(from: migrated.lookup(rawDeviceUID: addedUID)) != nil,
        "the write after removal stores its own Allow Off evidence"
      )
      #expect(
        migrated.lookup(rawDeviceUID: originalUID) == .miss,
        "recreating the new cache directory does not copy the legacy cache back"
      )
      #expect(
        (try? Data(contentsOf: legacyURL)) == legacyData,
        "recreating the new cache directory leaves the legacy bytes unchanged"
      )
    }
  }

  @Test(
    "Keeps legacy Allow Off evidence when another lookup starts during the copy"
  )
  func allowOffCacheSecondLookupDuringCopyKeepsLegacyEvidence() {
    var secondDidFinish = false
    withAllowOffCacheRenameFixture(cleanupIf: { secondDidFinish }) { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_050))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "concurrent-legacy-migration-uid"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "legacy Allow Off evidence exists before the concurrent copy"
      )
      guard let legacyData = try? Data(contentsOf: legacyURL) else {
        Issue.record("legacy Allow Off cache was written")
        return
      }

      let migrationLockObserved = DispatchSemaphore(value: 0)
      let secondFinished = DispatchSemaphore(value: 0)
      let resultLock = NSLock()
      var secondLookup: AllowOffCacheLookup?
      let second = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { Data(repeating: 7, count: 32) },
        lockRetryObserver: { migrationLockObserved.signal() }
      )
      var secondLookupThread: Thread?
      let first = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { Data(repeating: 9, count: 32) },
        legacyMigrationCreatedObserver: {
          secondLookupThread?.start()
          #expect(
            migrationLockObserved.wait(timeout: .now() + 2) == .success,
            "a second lookup waits on the legacy migration lock"
          )
        }
      )
      secondLookupThread = Thread {
        let lookup = second.lookup(rawDeviceUID: rawUID)
        resultLock.lock()
        secondLookup = lookup
        resultLock.unlock()
        secondFinished.signal()
      }

      let firstRecord = allowOffRecord(from: first.lookup(rawDeviceUID: rawUID))
      secondDidFinish = secondFinished.wait(timeout: .now() + 2) == .success
      #expect(secondDidFinish, "the waiting lookup finishes after the copy")
      guard firstRecord != nil else {
        Issue.record("the copying lookup keeps the legacy Allow Off record")
        return
      }
      guard secondDidFinish else { return }
      resultLock.lock()
      let lookup = secondLookup
      resultLock.unlock()
      #expect(
        allowOffRecord(from: lookup ?? .miss)?.evidence.observedAt == clock.value,
        "the waiting lookup still sees the legacy Allow Off record"
      )
      #expect(
        (try? Data(contentsOf: legacyURL)) == legacyData,
        "the waiting lookup leaves the legacy bytes unchanged"
      )
      #expect(
        (try? Data(contentsOf: newURL)) == legacyData,
        "the waiting lookup does not replace the copied cache"
      )
      let legacyDirectory = legacyURL.deletingLastPathComponent()
      let markerName = allowOffCacheLegacyMigrationMarkerName
      let names = (
        try? FileManager.default.contentsOfDirectory(atPath: legacyDirectory.path)
      ) ?? []
      #expect(
        names.filter { $0 == markerName }.count == 1,
        "the migration marker is written once"
      )
      #expect(
        (try? Data(
          contentsOf: legacyDirectory.appendingPathComponent(markerName)
        )) == Data("1\n".utf8),
        "the migration marker records one completed copy"
      )
    }
  }

  @Test("Treats a failed legacy Allow Off copy as a cache miss")
  func allowOffCacheCopyFailureIsAMiss() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_000))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "AppleHDAEngineOutput:AirPods:CaseSensitive-UID"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "legacy Allow Off evidence exists before the failed copy"
      )
      let blocker = newURL.deletingLastPathComponent()
      do {
        try Data("nope".utf8).write(to: blocker)
      } catch {
        Issue.record("copy-failure fixture blocks the new cache directory")
        return
      }
      let blockerMode = allowOffCachePermissions(at: blocker)
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      #expect(
        migrated.lookup(rawDeviceUID: rawUID) == .miss,
        "a failed legacy copy is a cache miss"
      )
      #expect(
        FileManager.default.fileExists(atPath: legacyURL.path),
        "a failed copy leaves the legacy cache in place"
      )
      #expect(
        (try? Data(contentsOf: blocker)) == Data("nope".utf8),
        "a failed copy does not replace the blocked path"
      )
      #expect(
        allowOffCachePermissions(at: blocker) == blockerMode,
        "a failed copy does not chmod the blocked path"
      )
    }
  }

  @Test("Does not adopt a legacy Allow Off cache the reader would reject")
  func allowOffCacheLeavesUntrustedLegacyFileUntouched() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_100))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "untrusted-legacy-cache-uid"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "untrusted legacy cache test seeds evidence"
      )
      do {
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o644)],
          ofItemAtPath: legacyURL.path
        )
      } catch {
        Issue.record("untrusted legacy cache test loosens the file mode")
        return
      }
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      #expect(
        migrated.lookup(rawDeviceUID: rawUID) == .miss,
        "an untrusted legacy cache is a miss"
      )
      #expect(
        allowOffCacheLstat(newURL) == nil,
        "an untrusted legacy cache is not copied"
      )
      #expect(
        allowOffCachePermissions(at: legacyURL) == 0o644,
        "an untrusted legacy cache keeps its mode"
      )
    }
  }

  @Test("Does not adopt a hard-linked legacy Allow Off cache")
  func allowOffCacheLeavesHardLinkedLegacyFileUntouched() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_150))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "hard-linked-legacy-cache-uid"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "hard-linked legacy cache test seeds evidence"
      )
      let linkURL = legacyURL
        .deletingLastPathComponent()
        .appendingPathComponent("legacy-hard-link.json")
      do {
        try FileManager.default.linkItem(at: legacyURL, to: linkURL)
      } catch {
        Issue.record("hard-linked legacy cache test creates the extra link")
        return
      }
      guard let legacyData = try? Data(contentsOf: legacyURL) else {
        Issue.record("hard-linked legacy cache test reads the seeded file")
        return
      }
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      #expect(
        migrated.lookup(rawDeviceUID: rawUID) == .miss,
        "a hard-linked legacy cache is a miss"
      )
      #expect(
        allowOffCacheLstat(newURL) == nil,
        "a hard-linked legacy cache is not copied"
      )
      #expect(
        (try? Data(contentsOf: linkURL)) == legacyData,
        "a hard-linked legacy cache leaves the extra link unchanged"
      )
      #expect(
        allowOffCacheLstat(legacyURL)?.st_nlink == 2,
        "a hard-linked legacy cache keeps both names"
      )
    }
  }

  @Test("Does not follow a symlinked legacy Allow Off cache")
  func allowOffCacheLeavesSymlinkedLegacyTargetUntouched() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_200))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "symlinked-legacy-cache-uid"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "symlinked legacy cache test seeds a trusted directory"
      )
      let externalURL = legacyURL
        .deletingLastPathComponent()
        .appendingPathComponent("external-legacy-target.json")
      let externalData = Data("legacy-symlink-target".utf8)
      do {
        try externalData.write(to: externalURL)
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o644)],
          ofItemAtPath: externalURL.path
        )
        try FileManager.default.removeItem(at: legacyURL)
        try FileManager.default.createSymbolicLink(
          at: legacyURL,
          withDestinationURL: externalURL
        )
      } catch {
        Issue.record("symlinked legacy cache test prepares its target")
        return
      }
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      #expect(
        migrated.lookup(rawDeviceUID: rawUID) == .miss,
        "a symlinked legacy cache is a miss"
      )
      #expect(
        allowOffCacheLstat(newURL) == nil,
        "a symlinked legacy cache is not copied"
      )
      #expect(
        (try? Data(contentsOf: externalURL)) == externalData,
        "a symlinked legacy cache leaves the target bytes unchanged"
      )
      #expect(
        allowOffCachePermissions(at: externalURL) == 0o644,
        "a symlinked legacy cache leaves the target mode unchanged"
      )
    }
  }

  @Test("Does not follow a symlinked new Allow Off cache directory")
  func allowOffCacheLeavesSymlinkedDestinationDirectoryUntouched() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_300))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "symlinked-destination-directory-uid"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "symlinked destination test seeds trusted legacy evidence"
      )
      let externalDirectory = newURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("external-cache-directory", isDirectory: true)
      let newDirectory = newURL.deletingLastPathComponent()
      do {
        try FileManager.default.createDirectory(
          at: externalDirectory,
          withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
          at: newDirectory,
          withDestinationURL: externalDirectory
        )
      } catch {
        Issue.record("symlinked destination test prepares its target")
        return
      }
      guard let modeBefore = allowOffCachePermissions(at: externalDirectory) else {
        Issue.record("symlinked destination test records the target mode")
        return
      }
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      #expect(
        migrated.lookup(rawDeviceUID: rawUID) == .miss,
        "a symlinked destination directory is a miss"
      )
      #expect(
        allowOffCacheIsSymbolicLink(newDirectory),
        "a symlinked destination directory stays a symlink"
      )
      #expect(
        allowOffCachePermissions(at: externalDirectory) == modeBefore,
        "a symlinked destination directory leaves the target mode unchanged"
      )
      #expect(
        allowOffCacheLstat(externalDirectory.appendingPathComponent(allowOffCacheFileName))
          == nil,
        "a symlinked destination directory receives no cache file"
      )
    }
  }

  @Test("Retries a legacy Allow Off copy after an untrusted deny marker")
  func allowOffCacheRetriesAfterUntrustedDenyMarker() {
    withAllowOffCacheRenameFixture { legacyURL, newURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_400))
      let legacy = PersistentListeningModeAllowOffCache(
        fileURL: legacyURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "untrusted-deny-marker-uid"
      #expect(
        legacy.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "untrusted deny marker test seeds legacy evidence"
      )
      let legacyDirectory = legacyURL.deletingLastPathComponent()
      let marker = legacyDirectory.appendingPathComponent(
        "allow-off-v1-deny-abc.jsonl"
      )
      let externalURL = legacyDirectory.appendingPathComponent("external-deny-target")
      let externalData = Data("deny-marker-target".utf8)
      do {
        try externalData.write(to: externalURL)
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o755)],
          ofItemAtPath: externalURL.path
        )
        try FileManager.default.createSymbolicLink(
          at: marker,
          withDestinationURL: externalURL
        )
      } catch {
        Issue.record("untrusted deny marker test prepares a symlink")
        return
      }
      let migrated = PersistentListeningModeAllowOffCache(
        fileURL: newURL,
        now: clock.read,
        saltGenerator: { Data(repeating: 9, count: 32) }
      )
      #expect(
        migrated.lookup(rawDeviceUID: rawUID) == .miss,
        "an untrusted deny marker blocks the copy"
      )
      #expect(
        allowOffCacheLstat(newURL) == nil,
        "a blocked copy leaves the new cache absent"
      )
      #expect(
        allowOffCachePermissions(at: externalURL) == 0o755,
        "an untrusted deny marker leaves its target mode unchanged"
      )
      do {
        try FileManager.default.removeItem(at: marker)
        try Data("deny\n".utf8).write(to: marker)
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o600)],
          ofItemAtPath: marker.path
        )
      } catch {
        Issue.record("untrusted deny marker test replaces the marker")
        return
      }
      guard let record = allowOffRecord(
        from: migrated.lookup(rawDeviceUID: rawUID)
      ) else {
        Issue.record("a later trusted legacy cache is copied")
        return
      }
      #expect(
        record.evidence.observedAt == clock.value,
        "the retried copy keeps the legacy timestamp"
      )
      #expect(
        (try? Data(contentsOf: newURL.deletingLastPathComponent()
            .appendingPathComponent("allow-off-v1-deny-abc.jsonl")))
          == Data("deny\n".utf8),
        "the retried copy includes the trusted deny marker"
      )
    }
  }

  @Test("Stores positive evidence and expires it at the fixed TTL")
  func persistentCacheStoresAndExpiresPositiveEvidence() {
    withTemporaryAllowOffCache { fileURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_000))
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "AppleHDAEngineOutput:AirPods:CaseSensitive-UID"

      #expect(cache.lookup(rawDeviceUID: rawUID) == .miss, "missing cache is a miss")
      #expect(
        !FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path),
        "cache lookup does not create its directory"
      )
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "positive Allow Off evidence is stored"
      )

      guard let original = allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) else {
        Issue.record("stored Allow Off evidence is returned")
        return
      }
      #expect(
        original.evidence.observedAt == clock.value,
        "cache preserves the observation timestamp"
      )
      #expect(
        original.evidence.expiresAt
          == clock.value.addingTimeInterval(PersistentListeningModeAllowOffCache.defaultTTL),
        "cache reports the fixed seven-day expiry"
      )

      clock.value = clock.value.addingTimeInterval(123)
      guard let later = allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) else {
        Issue.record("unexpired Allow Off evidence remains a hit")
        return
      }
      #expect(
        later.evidence.observedAt == original.evidence.observedAt
          && later.evidence.expiresAt == original.evidence.expiresAt,
        "cache reads do not refresh TTL"
      )
      clock.value = original.evidence.expiresAt
      #expect(
        cache.lookup(rawDeviceUID: rawUID) == .miss,
        "Allow Off evidence expires at exactly seven days"
      )
    }
  }

  @Test("Persists a privacy-preserving document with safe permissions")
  func persistentCachePersistsPrivacyPreservingDocument() {
    withTemporaryAllowOffCache { fileURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_710_000_000))
      var excludedPaths = Set<String>()
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt },
        markExcludedFromBackup: { excludedPaths.insert($0.path) }
      )
      let rawUID = "UID-secret-material-A"
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "cache writes a privacy-preserving document"
      )

      let directoryURL = fileURL.deletingLastPathComponent()
      let lockURL = directoryURL.appendingPathComponent("allow-off-v1.lock")
      #expect(
        allowOffCachePermissions(at: directoryURL) == 0o700,
        "allow-off cache directory is mode 0700"
      )
      #expect(
        allowOffCachePermissions(at: fileURL) == 0o600,
        "allow-off cache file is mode 0600"
      )
      #expect(
        allowOffCachePermissions(at: lockURL) == 0o600,
        "allow-off cache lock file is mode 0600"
      )
      #expect(
        excludedPaths.contains(directoryURL.path),
        "allow-off cache marks its directory as excluded from backup"
      )
      #expect(
        excludedPaths.contains(fileURL.path),
        "allow-off cache marks its file as excluded from backup"
      )
      #expect(
        excludedPaths.contains(lockURL.path),
        "allow-off cache marks its lock file as excluded from backup"
      )

      guard let data = try? Data(contentsOf: fileURL),
            let text = String(data: data, encoding: .utf8),
            let object = allowOffCacheJSON(at: fileURL),
            let schemaVersion = object["schemaVersion"] as? NSNumber,
            let salt = object["salt"] as? String,
            let entries = object["positiveEvidence"] as? [String: Any]
      else {
        Issue.record("allow-off cache document is readable JSON")
        return
      }
      #expect(schemaVersion.intValue == 1, "allow-off cache persists schema version 1")
      #expect(Data(base64Encoded: salt)?.count == 32, "allow-off cache persists a 32-byte salt")
      #expect(!text.contains(rawUID), "allow-off cache never persists the raw device UID")
      #expect(entries.count == 1, "allow-off cache stores one positive evidence entry")
      if let key = entries.keys.first {
        #expect(
          key.utf8.count == 64
            && key.utf8.allSatisfy {
              ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            },
          "allow-off cache keys are full lowercase SHA-256 digests"
        )
      }
      let directoryNames =
        (try? FileManager.default.contentsOfDirectory(
          atPath: directoryURL.path
        )) ?? []
      #expect(
        !directoryNames.contains(where: { $0.hasSuffix(".tmp") }),
        "atomic cache replacement leaves no temporary file"
      )

      let reopened = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { throw AllowOffCacheTestError.unavailable }
      )
      #expect(
        allowOffRecord(from: reopened.lookup(rawDeviceUID: rawUID)) != nil,
        "persisted salt allows lookup after reopening without regenerating salt"
      )
      #expect(
        reopened.lookup(rawDeviceUID: rawUID.lowercased()) == .miss,
        "raw device UID hashing is exact and case-sensitive"
      )
    }
  }

  @Test("Uses opaque records for conditional eviction and preserves unrelated evidence")
  func persistentCacheUsesOpaqueRecordsAndPreservesUnrelatedEvidence() {
    withTemporaryAllowOffCache { fileURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_720_000_000))
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "conditional-eviction-uid"

      _ = cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: clock.value
      )
      guard let oldRecord = allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) else {
        Issue.record("conditional eviction obtains its original record")
        return
      }
      clock.value = clock.value.addingTimeInterval(5)
      _ = cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: clock.value
      )
      guard let refreshedRecord = allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) else {
        Issue.record("conditional eviction obtains its refreshed record")
        return
      }
      #expect(
        cache.remove(record: oldRecord) == .unchanged,
        "stale record cannot erase refreshed Allow Off evidence"
      )
      #expect(
        allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) == refreshedRecord,
        "refreshed Allow Off evidence survives stale eviction"
      )
      #expect(
        cache.remove(record: refreshedRecord) == .applied,
        "current opaque record evicts its exact evidence"
      )
      #expect(cache.lookup(rawDeviceUID: rawUID) == .miss, "record eviction removes evidence")

      _ = cache.applyObservation(
        rawDeviceUID: "first",
        allowsOff: true,
        observedAt: clock.value
      )
      _ = cache.applyObservation(
        rawDeviceUID: "second",
        allowsOff: true,
        observedAt: clock.value
      )
      #expect(
        cache.applyObservation(
          rawDeviceUID: "first",
          allowsOff: false,
          observedAt: clock.value
        ) == .applied,
        "raw UID removal deletes its positive evidence"
      )
      #expect(
        allowOffDenialRecord(from: cache.lookup(rawDeviceUID: "first")) != nil,
        "a negative raw UID observation remains available as denial evidence"
      )
      #expect(
        allowOffRecord(from: cache.lookup(rawDeviceUID: "second")) != nil,
        "raw UID removal preserves unrelated evidence"
      )
      #expect(
        cache.applyObservation(
          rawDeviceUID: "missing",
          allowsOff: false,
          observedAt: clock.value
        ) == .applied,
        "negative observations retain a tombstone even without positive evidence"
      )
    }
  }

  @Test("Preserves denial through omission and accepts newer positive evidence")
  func persistentCachePreservesDenialThroughOmissionAndAcceptsNewerPositive() {
    withTemporaryAllowOffCache { fileURL in
      let denialObservedAt = Date(timeIntervalSince1970: 1_730_100_000)
      let clock = AllowOffCacheTestClock(denialObservedAt)
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        ttl: 60,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "denial-omission-positive-uid"

      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: denialObservedAt
        ) == .applied,
        "persistent cache stores the initial denial"
      )
      guard let initialDenial = allowOffDenialRecord(
        from: cache.lookup(rawDeviceUID: rawUID)
      ) else {
        Issue.record("persistent cache returns the initial denial")
        return
      }

      let omissionObservedAt = denialObservedAt.addingTimeInterval(10)
      clock.value = omissionObservedAt
      #expect(
        cache.invalidatePositiveObservation(
          rawDeviceUID: rawUID,
          observedAt: omissionObservedAt
        ) == .unchanged,
        "an omission does not replace an unexpired denial tombstone"
      )
      guard let preservedDenial = allowOffDenialRecord(
        from: cache.lookup(rawDeviceUID: rawUID)
      ) else {
        Issue.record("an omission preserves denial evidence")
        return
      }
      #expect(
        preservedDenial.evidence.observedAt == initialDenial.evidence.observedAt
          && preservedDenial.evidence.expiresAt == initialDenial.evidence.expiresAt,
        "an omission does not extend the denial TTL"
      )

      let positiveObservedAt = denialObservedAt.addingTimeInterval(20)
      clock.value = positiveObservedAt
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: positiveObservedAt
        ) == .applied,
        "strictly newer positive evidence supersedes denial"
      )
      #expect(
        allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID))?.evidence.observedAt
          == positiveObservedAt,
        "newer positive evidence is returned after denial"
      )
    }
  }

  @Test("Recovers safely from corruption and unsafe file modes")
  func persistentCacheRecoversFromCorruptionAndUnsafeModes() {
    withTemporaryAllowOffCache { fileURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_730_000_000))
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "corruption-test-uid"
      _ = cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: clock.value
      )
      do {
        try Data("{not-json".utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o600)],
          ofItemAtPath: fileURL.path
        )
      } catch {
        Issue.record("corruption test prepares a malformed cache")
        return
      }
      #expect(cache.lookup(rawDeviceUID: rawUID) == .miss, "malformed cache is a safe miss")
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "positive observation replaces a malformed disposable cache"
      )
      #expect(
        allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) != nil,
        "rebuilt cache returns its positive evidence"
      )

      do {
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o644)],
          ofItemAtPath: fileURL.path
        )
      } catch {
        Issue.record("permissions test changes the cache mode")
        return
      }
      #expect(cache.lookup(rawDeviceUID: rawUID) == .miss, "unsafe file mode is a safe miss")
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: clock.value
        ) == .applied,
        "negative observation replaces a malformed disposable cache"
      )
      #expect(
        allowOffDenialRecord(from: cache.lookup(rawDeviceUID: rawUID)) != nil,
        "negative observation is returned as denial evidence"
      )
    }
  }

  @Test("Purges positive evidence when negative persistence fails")
  func persistentCachePurgesPositiveEvidenceWhenNegativePersistenceFails() {
    withTemporaryAllowOffCache { fileURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_731_000_000))
      var failTemporaryBackup = false
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt },
        markExcludedFromBackup: { url in
          if failTemporaryBackup && url.pathExtension == "tmp" {
            throw AllowOffCacheTestError.unavailable
          }
        }
      )
      let rawUID = "failed-negative-write-uid"
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "failed negative write test seeds positive evidence"
      )
      failTemporaryBackup = true
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: clock.value
        ) == .applied,
        "failed negative persistence purges stale positive evidence"
      )
      #expect(
        cache.lookup(rawDeviceUID: rawUID) == .miss,
        "failed primary persistence cannot expose stale positive evidence"
      )
    }
  }

  @Test("Rejects symlinked cache files without touching their targets")
  func persistentCacheRejectsSymlinkedCacheFiles() {
    withTemporaryAllowOffCache { fileURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_731_500_000))
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "untrusted-cache-file-uid"
      let directoryURL = fileURL.deletingLastPathComponent()
      let externalURL = directoryURL.appendingPathComponent("external.json")
      let externalData = Data("external-cache-target".utf8)

      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "untrusted-file test seeds positive evidence"
      )
      do {
        try externalData.write(to: externalURL)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(
          at: fileURL,
          withDestinationURL: externalURL
        )
      } catch {
        Issue.record("symlink test prepares an external cache target")
        return
      }
      #expect(
        cache.lookup(rawDeviceUID: rawUID) == .miss,
        "a cache symlink is treated as a miss"
      )
      #expect(
        (try? Data(contentsOf: externalURL)) == externalData,
        "a cache symlink never reads the external target as trusted evidence"
      )
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "a cache symlink can be replaced without following it"
      )
      #expect(
        (try? Data(contentsOf: externalURL)) == externalData,
        "rebuilding a symlinked cache leaves the external target unchanged"
      )
    }
  }

  @Test("Rejects hard-linked cache files without trusting them")
  func persistentCacheRejectsHardLinkedCacheFiles() {
    withTemporaryAllowOffCache { fileURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_731_600_000))
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "hard-linked-cache-file-uid"
      let directoryURL = fileURL.deletingLastPathComponent()
      let externalURL = directoryURL.appendingPathComponent("hard-link-target.json")
      let externalData = Data("hard-link-cache-target".utf8)

      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "hard-link test seeds positive evidence"
      )
      do {
        try externalData.write(to: externalURL)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.linkItem(atPath: externalURL.path, toPath: fileURL.path)
      } catch {
        Issue.record("hard-link test prepares an external cache target")
        return
      }
      #expect(
        cache.lookup(rawDeviceUID: rawUID) == .miss,
        "a cache hard link is treated as a miss"
      )
      #expect(
        (try? Data(contentsOf: externalURL)) == externalData,
        "a cache hard link never trusts a multiply-linked file"
      )
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "a hard-linked cache can be replaced safely"
      )
      #expect(
        (try? Data(contentsOf: externalURL)) == externalData,
        "rebuilding a hard-linked cache leaves the external target unchanged"
      )
    }
  }

  @Test("Treats oversized cache files as safe misses")
  func persistentCacheTreatsOversizedFilesAsSafeMisses() {
    withTemporaryAllowOffCache { fileURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_731_700_000))
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "oversized-cache-file-uid"
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "oversized-file test seeds positive evidence"
      )
      do {
        try Data(repeating: 0x78, count: 1_048_577).write(
          to: fileURL,
          options: .atomic
        )
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o600)],
          ofItemAtPath: fileURL.path
        )
      } catch {
        Issue.record("oversized-file test prepares a cache over the byte limit")
        return
      }
      #expect(
        cache.lookup(rawDeviceUID: rawUID) == .miss,
        "an oversized cache file is a safe miss"
      )
    }
  }

  @Test("Treats overfull cache files as safe misses")
  func persistentCacheTreatsOverfullFilesAsSafeMisses() {
    withTemporaryAllowOffCache { fileURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_731_800_000))
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "overfull-cache-file-uid"
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "overfull-file test seeds positive evidence"
      )
      var positiveEvidence: [String: Any] = [:]
      for index in 0...256 {
        let digits = String(index, radix: 16)
        let key = String(repeating: "0", count: 64 - digits.count) + digits
        positiveEvidence[key] = ["observedAt": clock.value.timeIntervalSince1970]
      }
      let document: [String: Any] = [
        "schemaVersion": 1,
        "salt": allowOffCacheTestSalt.base64EncodedString(),
        "positiveEvidence": positiveEvidence,
        "negativeEvidence": [:],
      ]
      do {
        let data = try JSONSerialization.data(
          withJSONObject: document,
          options: [.sortedKeys]
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o600)],
          ofItemAtPath: fileURL.path
        )
      } catch {
        Issue.record("overfull-file test prepares more than the entry limit")
        return
      }
      #expect(
        cache.lookup(rawDeviceUID: rawUID) == .miss,
        "a cache over the entry limit is a safe miss"
      )
    }
  }

  @Test("Writes denial evidence after lock contention")
  func persistentCacheWritesDenialAfterLockContention() {
    withTemporaryAllowOffCache { fileURL in
      let observedAt = Date(timeIntervalSince1970: 1_732_000_000)
      let clock = AllowOffCacheTestClock(observedAt)
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "contended-negative-uid"
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: observedAt
        ) == .applied,
        "lock-timeout test seeds positive evidence"
      )
      let negativeObservedAt = observedAt.addingTimeInterval(1)
      withHeldAllowOffCacheFileLock(fileURL: fileURL) {
        #expect(
          cache.applyObservation(
            rawDeviceUID: rawUID,
            allowsOff: false,
            observedAt: negativeObservedAt
          ) == .applied,
          "negative lock timeout writes a deny marker"
        )
      }
      clock.value = negativeObservedAt
      #expect(
        allowOffDenialRecord(from: cache.lookup(rawDeviceUID: rawUID)) != nil,
        "a deny marker exposes denial evidence after lock contention"
      )
      clock.value = negativeObservedAt.addingTimeInterval(1)
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "newer positive evidence can supersede a deny marker"
      )
      #expect(
        allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) != nil,
        "newer positive evidence remains usable after a denied write"
      )
    }
  }

  @Test("Gives fresh denial evidence its own expiry after positive evidence expires")
  func persistentCacheDenialExpiresFromItsOwnTimestamp() {
    withTemporaryAllowOffCache { fileURL in
      let observedAt = Date(timeIntervalSince1970: 1_732_100_000)
      let denialObservedAt = observedAt.addingTimeInterval(59)
      let clock = AllowOffCacheTestClock(observedAt)
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        ttl: 60,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "expired-positive-with-fresh-denial-uid"
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: observedAt
        ) == .applied,
        "fresh-denial test seeds positive evidence"
      )

      clock.value = denialObservedAt
      withHeldAllowOffCacheFileLock(fileURL: fileURL) {
        #expect(
          cache.applyObservation(
            rawDeviceUID: rawUID,
            allowsOff: false,
            observedAt: denialObservedAt
          ) == .applied,
          "fresh-denial test persists a marker during lock contention"
        )
      }

      clock.value = denialObservedAt.addingTimeInterval(1)
      guard let denial = allowOffDenialRecord(
        from: cache.lookup(rawDeviceUID: rawUID)
      ) else {
        Issue.record("a fresh denial remains usable after positive evidence expires")
        return
      }
      #expect(
        denial.evidence.observedAt == denialObservedAt,
        "denial evidence is anchored to the marker timestamp"
      )
      #expect(
        denial.evidence.expiresAt == denialObservedAt.addingTimeInterval(60),
        "denial evidence gets its own TTL"
      )
      clock.value = denialObservedAt.addingTimeInterval(60)
      #expect(
        cache.lookup(rawDeviceUID: rawUID) == .miss,
        "denial evidence expires from its own timestamp"
      )
    }
  }

  @Test("Does not resurrect an older denial after removing newer positive evidence")
  func persistentCacheDoesNotResurrectOrphanedDenial() {
    withTemporaryAllowOffCache { fileURL in
      let denialObservedAt = Date(timeIntervalSince1970: 1_732_200_000)
      let positiveObservedAt = denialObservedAt.addingTimeInterval(1)
      let clock = AllowOffCacheTestClock(denialObservedAt)
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        ttl: 60,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "orphan-denial-marker-uid"

      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: denialObservedAt
        ) == .applied,
        "stale-marker test seeds denial evidence"
      )
      clock.value = positiveObservedAt
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: positiveObservedAt
        ) == .applied,
        "stale-marker test stores newer positive evidence"
      )
      guard let positive = allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) else {
        Issue.record("stale-marker test reads newer positive evidence")
        return
      }
      #expect(
        cache.remove(record: positive) == .applied,
        "stale-marker test removes the newer positive record"
      )
      #expect(
        cache.lookup(rawDeviceUID: rawUID) == .miss,
        "an orphaned older denial marker cannot resurrect removed positive evidence"
      )
    }
  }

  @Test("Orders denial markers and omission tombstones by observation time")
  func persistentCacheOrdersDenialsAndTombstones() {
    withTemporaryAllowOffCache { fileURL in
      let denialObservedAt = Date(timeIntervalSince1970: 1_732_300_000)
      let tombstoneObservedAt = denialObservedAt.addingTimeInterval(60)
      let newerDenialObservedAt = tombstoneObservedAt.addingTimeInterval(1)
      let clock = AllowOffCacheTestClock(denialObservedAt)
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        ttl: 60,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "tombstone-denial-ordering-uid"

      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: denialObservedAt
        ) == .applied,
        "tombstone-ordering test seeds denial evidence"
      )
      clock.value = tombstoneObservedAt
      #expect(
        cache.invalidatePositiveObservation(
          rawDeviceUID: rawUID,
          observedAt: tombstoneObservedAt
        ) == .applied,
        "an expired denial can be replaced by a newer omission tombstone"
      )
      #expect(
        cache.lookup(rawDeviceUID: rawUID) == .miss,
        "an older denial marker cannot override a newer omission tombstone"
      )

      clock.value = newerDenialObservedAt
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: newerDenialObservedAt
        ) == .applied,
        "a newer definitive denial replaces the omission tombstone"
      )
      #expect(
        allowOffDenialRecord(from: cache.lookup(rawDeviceUID: rawUID))?.evidence.observedAt
          == newerDenialObservedAt,
        "the newer denial marker wins over the omission tombstone"
      )
    }
  }

  @Test("Rejects invalid raw device UIDs without filesystem effects")
  func persistentCacheRejectsInvalidRawDeviceUIDsWithoutFilesystemEffects() {
    withTemporaryAllowOffCache { fileURL in
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        saltGenerator: { allowOffCacheTestSalt }
      )
      #expect(
        cache.applyObservation(
          rawDeviceUID: "",
          allowsOff: true,
          observedAt: Date()
        ) == .unavailable,
        "empty raw device UID is rejected"
      )
      #expect(
        cache.applyObservation(
          rawDeviceUID: String(repeating: "x", count: 4_097),
          allowsOff: true,
          observedAt: Date()
        ) == .unavailable,
        "oversized raw device UID is rejected"
      )
      #expect(
        !FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path),
        "invalid raw device UID has no filesystem side effect"
      )
    }
  }

  @Test("Rejects invalid generated salts")
  func persistentCacheRejectsInvalidGeneratedSalt() {
    withTemporaryAllowOffCache { fileURL in
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        saltGenerator: { Data(repeating: 0, count: 31) }
      )
      #expect(
        cache.applyObservation(
          rawDeviceUID: "uid",
          allowsOff: true,
          observedAt: Date()
        ) == .unavailable,
        "invalid generated salt makes cache storage unavailable"
      )
      #expect(
        !FileManager.default.fileExists(atPath: fileURL.path),
        "invalid generated salt never writes a cache document"
      )
    }
  }

  @Test("Fails softly when cache mutation cannot acquire its lock")
  func persistentCacheFailsSoftOnLockContention() {
    withTemporaryAllowOffCache { fileURL in
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        saltGenerator: { allowOffCacheTestSalt }
      )
      _ = cache.applyObservation(
        rawDeviceUID: "existing",
        allowsOff: true,
        observedAt: Date()
      )

      withHeldAllowOffCacheFileLock(fileURL: fileURL) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let result = cache.applyObservation(
          rawDeviceUID: "contended",
          allowsOff: true,
          observedAt: Date()
        )
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        #expect(result == .unavailable, "contended cache mutation fails soft")
        #expect(
          elapsed < 1_000_000_000,
          "contended cache mutation stops waiting within a bounded time"
        )
      }
      #expect(
        allowOffRecord(from: cache.lookup(rawDeviceUID: "existing")) != nil,
        "lock contention preserves existing cache evidence"
      )
      #expect(
        cache.lookup(rawDeviceUID: "contended") == .miss,
        "failed-soft lock contention does not mutate the cache"
      )
    }
  }

  @Test("Waits through brief lock contention without losing the observation time")
  func persistentCacheWaitsThroughBriefLockContention() {
    var workerDidComplete = false
    withTemporaryAllowOffCache(cleanupIf: { workerDidComplete }) { fileURL in
      let observedAt = Date(timeIntervalSince1970: 1_734_000_000)
      let afterContention = observedAt.addingTimeInterval(10)
      let retryObserved = DispatchSemaphore(value: 0)
      let workerCompleted = DispatchSemaphore(value: 0)
      let resultLock = NSLock()
      var workerResult: AllowOffCacheMutation?
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: { afterContention },
        saltGenerator: { allowOffCacheTestSalt },
        lockRetryObserver: { retryObserved.signal() }
      )
      _ = cache.applyObservation(
        rawDeviceUID: "seed",
        allowsOff: true,
        observedAt: observedAt
      )

      let waiter = Thread {
        let result = cache.applyObservation(
          rawDeviceUID: "delayed",
          allowsOff: true,
          observedAt: observedAt
        )
        resultLock.lock()
        workerResult = result
        resultLock.unlock()
        workerCompleted.signal()
      }
      withHeldAllowOffCacheFileLock(fileURL: fileURL) {
        waiter.start()
        #expect(
          retryObserved.wait(timeout: .now() + 2) == .success,
          "worker reports a failed lock attempt before the lock is released"
        )
      }
      workerDidComplete =
        workerCompleted.wait(timeout: .now() + 2) == .success
      #expect(workerDidComplete, "worker completes before temporary cache cleanup")
      guard workerDidComplete else { return }
      resultLock.lock()
      let result = workerResult
      resultLock.unlock()
      #expect(
        result == .applied,
        "positive observation waits for brief lock contention"
      )
      #expect(
        allowOffRecord(from: cache.lookup(rawDeviceUID: "delayed"))?.evidence.observedAt
          == observedAt,
        "positive observation keeps the time captured before lock contention"
      )
    }
  }

  @Test("Orders observations by timestamp")
  func persistentCacheOrdersObservationsByTimestamp() {
    withTemporaryAllowOffCache { fileURL in
      let current = Date(timeIntervalSince1970: 1_736_000_020)
      let clock = AllowOffCacheTestClock(current)
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "ordered-observation-uid"
      let older = current.addingTimeInterval(-20)
      let newer = current.addingTimeInterval(-10)

      clock.value = newer
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: newer
        ) == .applied,
        "newer positive observation is stored"
      )
      clock.value = current
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: older
        ) == .unchanged,
        "older positive observation cannot replace newer evidence"
      )
      clock.value = current
      #expect(
        allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID))?.evidence.observedAt
          == newer,
        "newer evidence survives a delayed older positive observation"
      )
      clock.value = current
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: older
        ) == .unchanged,
        "older negative observation cannot remove newer evidence"
      )
      clock.value = current
      #expect(
        allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID))?.evidence.observedAt
          == newer,
        "newer evidence survives a delayed older negative observation"
      )
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: current
        ) == .applied,
        "newer negative observation removes older evidence"
      )

      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: current
        ) == .unchanged,
        "equal positive and negative observations fail closed"
      )
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: older
        ) == .unchanged,
        "an older positive observation cannot replace a newer negative tombstone"
      )
    }
  }

  @Test("Handles a clock rollback without reviving positive evidence")
  func persistentCacheHandlesClockRollback() {
    withTemporaryAllowOffCache { fileURL in
      let positiveObservedAt = Date(timeIntervalSince1970: 1_737_000_000)
      let clock = AllowOffCacheTestClock(positiveObservedAt)
      let cache = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { allowOffCacheTestSalt }
      )
      let rawUID = "clock-rollback-uid"
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: positiveObservedAt
        ) == .applied,
        "clock rollback test seeds positive evidence"
      )
      let rolledBack = positiveObservedAt.addingTimeInterval(-60)
      clock.value = rolledBack
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: rolledBack
        ) == .applied,
        "a fresh negative during clock rollback is recorded at the future positive time"
      )
      clock.value = positiveObservedAt
      #expect(
        allowOffDenialRecord(from: cache.lookup(rawDeviceUID: rawUID)) != nil,
        "clock rollback preserves superseding denial evidence"
      )
    }
  }

  @Test("Preserves concurrent atomic mutations")
  func persistentCachePreservesConcurrentAtomicMutations() {
    withTemporaryAllowOffCache { fileURL in
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_735_000_000))
      let group = DispatchGroup()
      for index in 0..<12 {
        group.enter()
        DispatchQueue.global().async {
          let cache = PersistentListeningModeAllowOffCache(
            fileURL: fileURL,
            now: clock.read,
            saltGenerator: { allowOffCacheTestSalt }
          )
          _ = cache.applyObservation(
            rawDeviceUID: "concurrent-uid-\(index)",
            allowsOff: true,
            observedAt: clock.value
          )
          group.leave()
        }
      }
      group.wait()

      let reopened = PersistentListeningModeAllowOffCache(
        fileURL: fileURL,
        now: clock.read,
        saltGenerator: { throw AllowOffCacheTestError.unavailable }
      )
      for index in 0..<12 {
        #expect(
          allowOffRecord(
            from: reopened.lookup(rawDeviceUID: "concurrent-uid-\(index)")
          ) != nil,
          "locked atomic mutations preserve concurrent entry \(index)"
        )
      }
    }
  }

  @Test("Stores and expires positive evidence in memory")
  func inMemoryCacheStoresAndExpiresPositiveEvidence() {
    do {
      let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_740_000_000))
      guard
        let cache = InMemoryListeningModeAllowOffCache(
          salt: allowOffCacheTestSalt,
          ttl: 60,
          now: clock.read
        )
      else {
        Issue.record("in-memory Allow Off cache accepts a valid salt")
        return
      }
      #expect(cache.lookup(rawDeviceUID: "uid") == .miss, "in-memory cache starts empty")
      #expect(
        cache.applyObservation(
          rawDeviceUID: "uid",
          allowsOff: true,
          observedAt: clock.value
        ) == .applied,
        "in-memory cache stores positive evidence"
      )
      guard let record = allowOffRecord(from: cache.lookup(rawDeviceUID: "uid")) else {
        Issue.record("in-memory cache returns an opaque record")
        return
      }
      clock.value = clock.value.addingTimeInterval(60)
      #expect(cache.lookup(rawDeviceUID: "uid") == .miss, "in-memory cache enforces TTL")
      #expect(
        cache.remove(record: record) == .applied,
        "in-memory cache supports exact record eviction after expiry"
      )
      #expect(
        InMemoryListeningModeAllowOffCache(salt: Data(repeating: 0, count: 31)) == nil,
        "in-memory cache rejects an invalid salt"
      )
    }
  }

  @Test("Preserves in-memory denial through omission and newer positive evidence")
  func inMemoryCachePreservesDenialThroughOmissionAndNewerPositive() {
    do {
      let denialObservedAt = Date(timeIntervalSince1970: 1_740_100_000)
      let clock = AllowOffCacheTestClock(denialObservedAt)
      guard
        let cache = InMemoryListeningModeAllowOffCache(
          salt: allowOffCacheTestSalt,
          ttl: 60,
          now: clock.read
        )
      else {
        Issue.record("in-memory denial ordering accepts a valid salt")
        return
      }
      let rawUID = "denial-omission-positive-uid"
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: denialObservedAt
        ) == .applied,
        "in-memory cache stores the initial denial"
      )
      guard let initialDenial = allowOffDenialRecord(
        from: cache.lookup(rawDeviceUID: rawUID)
      ) else {
        Issue.record("in-memory cache returns the initial denial")
        return
      }

      let omissionObservedAt = denialObservedAt.addingTimeInterval(10)
      clock.value = omissionObservedAt
      #expect(
        cache.invalidatePositiveObservation(
          rawDeviceUID: rawUID,
          observedAt: omissionObservedAt
        ) == .unchanged,
        "in-memory omission preserves an unexpired denial tombstone"
      )
      guard let preservedDenial = allowOffDenialRecord(
        from: cache.lookup(rawDeviceUID: rawUID)
      ) else {
        Issue.record("in-memory omission preserves denial evidence")
        return
      }
      #expect(
        preservedDenial.evidence.observedAt == initialDenial.evidence.observedAt
          && preservedDenial.evidence.expiresAt == initialDenial.evidence.expiresAt,
        "in-memory omission does not extend the denial TTL"
      )

      let positiveObservedAt = denialObservedAt.addingTimeInterval(20)
      clock.value = positiveObservedAt
      #expect(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: true,
          observedAt: positiveObservedAt
        ) == .applied,
        "in-memory newer positive evidence supersedes denial"
      )
      #expect(
        allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID))?.evidence.observedAt
          == positiveObservedAt,
        "in-memory newer positive evidence is returned after denial"
      )
    }
  }
}
