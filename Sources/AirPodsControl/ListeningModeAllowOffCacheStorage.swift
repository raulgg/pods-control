import Darwin
import Dispatch
import Foundation
import Security

let allowOffCacheDirectoryPermissions: mode_t = 0o700
let allowOffCacheFilePermissions: mode_t = 0o600
private let allowOffCacheProcessMutationLock = NSLock()
private let allowOffCacheLockTimeoutNanoseconds: UInt64 = 250_000_000
private let allowOffCacheLockRetryMicroseconds: useconds_t = 10_000
let allowOffCacheDirectoryName = "io.github.raulgg.pods-control"
let allowOffCacheLegacyDirectoryName = "io.github.raulgg.airpods-control"
let allowOffCacheFileName = "allow-off-v1.json"
let allowOffCacheLegacyMigrationMarkerName =
  "allow-off-v1.migrated-to-pods-control"
let allowOffCacheDenyMarkerPrefix = "allow-off-v1-deny-"
let allowOffCacheDenyMarkerSuffix = ".jsonl"
let allowOffCacheDenyMarkerMaximumByteCount = 4_096
let allowOffCacheReadBufferByteCount = 4_096

private enum AllowOffCacheStorageError: Error {
  case systemFailure
}

final class AllowOffCacheFileStorage {
  private let fileURL: URL
  private let saltGenerator: () throws -> Data
  private let markExcludedFromBackup: (URL) throws -> Void
  private let fileManager: FileManager
  private let legacyMigrationCreatedObserver: () -> Void
  private let lockRetryObserver: () -> Void

  init(
    fileURL: URL,
    saltGenerator: @escaping () throws -> Data,
    markExcludedFromBackup: @escaping (URL) throws -> Void,
    fileManager: FileManager,
    legacyMigrationCreatedObserver: @escaping () -> Void,
    lockRetryObserver: @escaping () -> Void
  ) {
    self.fileURL = fileURL
    self.saltGenerator = saltGenerator
    self.markExcludedFromBackup = markExcludedFromBackup
    self.fileManager = fileManager
    self.legacyMigrationCreatedObserver = legacyMigrationCreatedObserver
    self.lockRetryObserver = lockRetryObserver
  }

  func makeEmptyCache() -> PersistedAllowOffCache? {
    guard let salt = try? saltGenerator(),
          salt.count == AllowOffCachePolicy.saltByteCount
    else { return nil }
    return PersistedAllowOffCache(
      schemaVersion: AllowOffCachePolicy.schemaVersion,
      salt: salt,
      observations: [:]
    )
  }

  func readPersistedCache() -> PersistedAllowOffCacheRead {
    _ = importIfNeeded()
    return decodePersistedCache()
  }

  /// Decode only. Callers inside `withExclusiveMutationLock` use this so the
  /// process lock stays non-recursive. The locked section imports once first.
  func decodePersistedCache() -> PersistedAllowOffCacheRead {
    switch secureRead(fileURL) {
    case .missing:
      return .missing
    case .invalid:
      return .invalid
    case .value(let data):
      guard let document = try? AllowOffCacheCodec.makeDecoder().decode(
        PersistedAllowOffCache.self,
        from: data
      ),
        document.isValid
      else { return .invalid }
      return .value(document)
    }
  }

  func readDenyMarker(for key: String) -> AllowOffDenyMarkerRead {
    switch secureRead(denyMarkerURL(for: key)) {
    case .missing:
      return .missing
    case .invalid:
      return .invalid
    case .value(let data):
      var newest: Date?
      for line in data.split(separator: 0x0A) {
        guard let marker = try? AllowOffCacheCodec.makeDecoder().decode(
          PersistedAllowOffDenyMarker.self,
          from: Data(line)
        ),
          AllowOffCachePolicy.isFiniteObservationTime(marker.observedAt)
        else { return .invalid }
        if newest == nil || marker.observedAt > newest! {
          newest = marker.observedAt
        }
      }
      guard let newest else { return .invalid }
      return .value(newest)
    }
  }

  func appendDenyMarker(for key: String, observedAt: Date) -> Bool {
    guard let encoded = try? AllowOffCacheCodec.makeEncoder().encode(
      PersistedAllowOffDenyMarker(observedAt: observedAt)
    ) else { return false }
    var line = encoded
    line.append(0x0A)
    guard line.count <= allowOffCacheDenyMarkerMaximumByteCount else {
      return false
    }

    let url = denyMarkerURL(for: key)
    let descriptor = openFile(
      url,
      flags: O_CREAT | O_APPEND | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
      permissions: allowOffCacheFilePermissions
    )
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    var value = stat()
    guard fstat(descriptor, &value) == 0,
          isTrustedOwnedUnsharedRegularFile(value),
          value.st_size >= 0,
          UInt64(value.st_size) + UInt64(line.count)
          <= UInt64(allowOffCacheDenyMarkerMaximumByteCount),
          writeAll(line, to: descriptor),
          restrictAndSync(descriptor)
    else { return false }
    do {
      try markExcludedFromBackup(url)
      return true
    } catch {
      return false
    }
  }

  func write(_ document: PersistedAllowOffCache) -> Bool {
    guard let data = encodedDocument(document),
          let temporary = openExclusiveTemporaryFile()
    else { return false }

    var shouldRemoveTemporary = true
    defer {
      Darwin.close(temporary.descriptor)
      if shouldRemoveTemporary { _ = unlinkURL(temporary.url) }
    }

    guard writeAll(data, to: temporary.descriptor),
          restrictAndSync(temporary.descriptor)
    else { return false }
    return commitTemporaryFile(
      temporary.url,
      shouldRemoveTemporary: &shouldRemoveTemporary
    )
  }

  private func encodedDocument(_ document: PersistedAllowOffCache) -> Data? {
    guard document.isValid,
          let data = try? AllowOffCacheCodec.makeEncoder().encode(document),
          data.count <= AllowOffCachePolicy.maximumByteCount
    else { return nil }
    return data
  }

  private func openExclusiveTemporaryFile() -> (url: URL, descriptor: Int32)? {
    let temporaryURL = directoryURL.appendingPathComponent(
      ".allow-off-v1.\(UUID().uuidString).tmp",
      isDirectory: false
    )
    let descriptor = openFile(
      temporaryURL,
      flags: O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
      permissions: allowOffCacheFilePermissions
    )
    guard descriptor >= 0 else { return nil }
    return (temporaryURL, descriptor)
  }

  private func commitTemporaryFile(
    _ temporaryURL: URL,
    shouldRemoveTemporary: inout Bool
  ) -> Bool {
    do {
      try markExcludedFromBackup(temporaryURL)
      guard renameURL(temporaryURL, to: fileURL) else { return false }
      shouldRemoveTemporary = false
      guard chmodURL(fileURL, permissions: allowOffCacheFilePermissions) else {
        _ = unlinkURL(fileURL)
        return false
      }
      try markExcludedFromBackup(fileURL)
      try markExcludedFromBackup(directoryURL)
      return true
    } catch {
      if !shouldRemoveTemporary { _ = unlinkURL(fileURL) }
      return false
    }
  }

  func purgeCacheFile() -> Bool {
    if unlinkURL(fileURL) { return true }
    return errno == ENOENT
  }

  func withExclusiveMutationLock(
    body: () -> AllowOffCacheMutation,
    onLockUnavailable: () -> AllowOffCacheMutation = { .unavailable }
  ) -> AllowOffCacheMutation {
    guard importIfNeeded() else { return .unavailable }
    allowOffCacheAcquireProcessMutationLock()
    defer { allowOffCacheReleaseProcessMutationLock() }
    guard ensureCacheDirectory(), let descriptor = openLockFile() else {
      return .unavailable
    }
    defer { Darwin.close(descriptor) }
    guard acquireAllowOffCacheFileLock(
      descriptor,
      lockRetryObserver: lockRetryObserver
    ) else { return onLockUnavailable() }
    defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
    return body()
  }

  private var directoryURL: URL {
    fileURL.deletingLastPathComponent()
  }

  private var lockFileURL: URL {
    directoryURL.appendingPathComponent("allow-off-v1.lock", isDirectory: false)
  }

  private func denyMarkerURL(for key: String) -> URL {
    directoryURL.appendingPathComponent(
      "\(allowOffCacheDenyMarkerPrefix)\(key)\(allowOffCacheDenyMarkerSuffix)",
      isDirectory: false
    )
  }

  private func ensureCacheDirectory() -> Bool {
    let attributes: [FileAttributeKey: Any] = [
      .posixPermissions: NSNumber(value: allowOffCacheDirectoryPermissions)
    ]
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: attributes
      )
      guard let status = status(of: directoryURL),
            isTrustedOwnedDirectory(status),
            chmodURL(directoryURL, permissions: allowOffCacheDirectoryPermissions)
      else { return false }
      try markExcludedFromBackup(directoryURL)
      return true
    } catch {
      return false
    }
  }

  private func openLockFile() -> Int32? {
    let descriptor = openFile(
      lockFileURL,
      flags: O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      permissions: allowOffCacheFilePermissions
    )
    guard descriptor >= 0 else { return nil }
    var value = stat()
    guard fstat(descriptor, &value) == 0,
          isTrustedOwnedUnsharedRegularFile(value),
          restrictAndSync(descriptor)
    else {
      Darwin.close(descriptor)
      return nil
    }
    do {
      try markExcludedFromBackup(lockFileURL)
    } catch {
      Darwin.close(descriptor)
      _ = unlinkURL(lockFileURL)
      return nil
    }
    return descriptor
  }

  private enum SecureDataRead {
    case value(Data)
    case missing
    case invalid
  }

  private func secureRead(_ url: URL) -> SecureDataRead {
    if let failure = trustedDirectory() {
      return failure
    }
    return trustedFileContents(url)
  }

  private func trustedDirectory() -> SecureDataRead? {
    guard let directoryStatus = status(of: directoryURL) else {
      return errno == ENOENT ? .missing : .invalid
    }
    guard isTrustedOwnedDirectory(directoryStatus),
          permissionBits(directoryStatus) == allowOffCacheDirectoryPermissions
    else { return .invalid }
    return nil
  }

  private func trustedFileContents(_ url: URL) -> SecureDataRead {
    let descriptor = openFile(url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      return errno == ENOENT ? .missing : .invalid
    }
    defer { Darwin.close(descriptor) }

    var value = stat()
    guard fstat(descriptor, &value) == 0,
          isTrustedOwnedUnsharedRegularFile(value),
          value.st_size >= 0,
          UInt64(value.st_size) <= UInt64(AllowOffCachePolicy.maximumByteCount),
          permissionBits(value) == allowOffCacheFilePermissions
    else { return .invalid }
    return boundedContents(from: descriptor, size: value.st_size)
  }

  private func boundedContents(
    from descriptor: Int32,
    size: off_t
  ) -> SecureDataRead {
    var data = Data()
    data.reserveCapacity(Int(size))
    var buffer = [UInt8](repeating: 0, count: allowOffCacheReadBufferByteCount)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        return .invalid
      }
      guard data.count + count <= AllowOffCachePolicy.maximumByteCount else {
        return .invalid
      }
      data.append(buffer, count: count)
    }
    return .value(data)
  }

  private func importIfNeeded() -> Bool {
    AllowOffCacheLegacyMigration(
      fileURL: fileURL,
      markExcludedFromBackup: markExcludedFromBackup,
      legacyMigrationCreatedObserver: legacyMigrationCreatedObserver,
      lockRetryObserver: lockRetryObserver
    ).importIfNeeded()
  }
}

func secureAllowOffCacheSalt() throws -> Data {
  var bytes = [UInt8](repeating: 0, count: AllowOffCachePolicy.saltByteCount)
  let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
  guard status == errSecSuccess else { throw AllowOffCacheStorageError.systemFailure }
  return Data(bytes)
}

func excludeAllowOffCacheURLFromBackup(_ url: URL) throws {
  var mutableURL = url
  var values = URLResourceValues()
  values.isExcludedFromBackup = true
  try mutableURL.setResourceValues(values)
}

func allowOffCacheAcquireProcessMutationLock(
  reportingWaits: Bool = false,
  lockRetryObserver: () -> Void = {}
) {
  if reportingWaits {
    while !allowOffCacheProcessMutationLock.lock(
      before: Date(timeIntervalSinceNow: 0.01)
    ) {
      lockRetryObserver()
    }
  } else {
    allowOffCacheProcessMutationLock.lock()
  }
}

func allowOffCacheReleaseProcessMutationLock() {
  allowOffCacheProcessMutationLock.unlock()
}

func acquireAllowOffCacheFileLock(
  _ descriptor: Int32,
  lockRetryObserver: () -> Void
) -> Bool {
  let startedAt = DispatchTime.now().uptimeNanoseconds
  while true {
    if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 { return true }
    guard errno == EACCES || errno == EAGAIN || errno == EINTR else {
      return false
    }

    lockRetryObserver()
    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
    guard elapsed < allowOffCacheLockTimeoutNanoseconds else { return false }
    let remainingMicroseconds =
      (allowOffCacheLockTimeoutNanoseconds - elapsed) / 1_000
    _ = Darwin.usleep(
      useconds_t(
        min(UInt64(allowOffCacheLockRetryMicroseconds), remainingMicroseconds)
      )
    )
  }
}

func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
  data.withUnsafeBytes { bytes in
    guard let baseAddress = bytes.baseAddress else { return true }
    var written = 0
    while written < bytes.count {
      let count = Darwin.write(
        descriptor,
        baseAddress.advanced(by: written),
        bytes.count - written
      )
      if count < 0 {
        if errno == EINTR { continue }
        return false
      }
      guard count > 0 else { return false }
      written += count
    }
    return true
  }
}

func status(of url: URL) -> stat? {
  var value = stat()
  let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return Int32(-1) }
    return Darwin.lstat(path, &value)
  }
  return result == 0 ? value : nil
}

private func isDirectory(_ value: stat) -> Bool {
  value.st_mode & S_IFMT == S_IFDIR
}

private func isRegularFile(_ value: stat) -> Bool {
  value.st_mode & S_IFMT == S_IFREG
}

func isTrustedOwnedDirectory(_ value: stat) -> Bool {
  isDirectory(value) && value.st_uid == geteuid()
}

func isTrustedOwnedUnsharedRegularFile(_ value: stat) -> Bool {
  isRegularFile(value) && value.st_uid == geteuid() && value.st_nlink == 1
}

func restrictAndSync(_ descriptor: Int32) -> Bool {
  fchmod(descriptor, allowOffCacheFilePermissions) == 0
    && fsync(descriptor) == 0
}

func permissionBits(_ value: stat) -> mode_t {
  value.st_mode & mode_t(0o777)
}

func openFile(
  _ url: URL,
  flags: Int32,
  permissions: mode_t = 0
) -> Int32 {
  url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return -1 }
    if flags & O_CREAT != 0 {
      return Darwin.open(path, flags, permissions)
    }
    return Darwin.open(path, flags)
  }
}

private func chmodURL(_ url: URL, permissions: mode_t) -> Bool {
  url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return false }
    return Darwin.chmod(path, permissions) == 0
  }
}

private func unlinkURL(_ url: URL) -> Bool {
  url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return false }
    return Darwin.unlink(path) == 0
  }
}

private func renameURL(_ source: URL, to destination: URL) -> Bool {
  source.withUnsafeFileSystemRepresentation { sourcePath in
    destination.withUnsafeFileSystemRepresentation { destinationPath in
      guard let sourcePath, let destinationPath else { return false }
      return Darwin.rename(sourcePath, destinationPath) == 0
    }
  }
}
