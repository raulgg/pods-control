import Darwin
import Foundation

private let allowOffCacheLegacyMigrationMarkerBytes = Data("1\n".utf8)
private let allowOffCacheLegacyMigrationLockName = "allow-off-v1.migration.lock"

struct AllowOffCacheLegacyMigration {
  var fileURL: URL
  var markExcludedFromBackup: (URL) throws -> Void
  var legacyMigrationCreatedObserver: () -> Void
  var lockRetryObserver: () -> Void

  private var directoryURL: URL {
    fileURL.deletingLastPathComponent()
  }

  private var legacyDirectoryURL: URL {
    directoryURL
      .deletingLastPathComponent()
      .appendingPathComponent(
        allowOffCacheLegacyDirectoryName,
        isDirectory: true
      )
  }

  // Copies a trusted legacy cache once. The copy-or-stamp decision holds the
  // legacy migration lock. The new directory is a rename of a private
  // directory, so it appears only with the cache file and every deny marker.
  // The marker is written after that rename, and a failed marker write removes
  // the directory. A file the reader would reject stays where it is, and a
  // path this call did not create is never chmod'd. After the new directory
  // or the marker exists, a missing file stays missing so a purge or deletion
  // cannot restore stale evidence. A check that cannot tell whether the
  // marker exists does not create the new directory. A directory that
  // already exists stays usable.
  func importIfNeeded() -> Bool {
    guard directoryURL.lastPathComponent == allowOffCacheDirectoryName,
          fileURL.lastPathComponent == allowOffCacheFileName
    else { return true }
    if pathIsAbsent(legacyDirectoryURL) { return true }
    switch legacyMigrationMarkerPresence() {
    case .present:
      return true
    case .unreadable:
      return existingDirectoryStaysUsable()
    case .absent:
      return importWhileLocked()
    }
  }

  private func importWhileLocked() -> Bool {
    // lockf does not block other threads in this process. Poll so a
    // same-process waiter can report the legacy-lock wait.
    allowOffCacheAcquireProcessMutationLock(
      reportingWaits: true,
      lockRetryObserver: lockRetryObserver
    )
    defer { allowOffCacheReleaseProcessMutationLock() }
    let legacyDirectory: Int32
    switch openLegacyDirectory(legacyDirectoryURL) {
    case .absent, .untrusted:
      return true
    case .unreadable:
      return existingDirectoryStaysUsable()
    case .opened(let descriptor):
      legacyDirectory = descriptor
    }
    defer { Darwin.close(legacyDirectory) }
    guard let lockDescriptor = openMigrationLock(dirfd: legacyDirectory) else {
      return false
    }
    defer { Darwin.close(lockDescriptor) }
    guard acquireAllowOffCacheFileLock(
      lockDescriptor,
      lockRetryObserver: lockRetryObserver
    ) else { return false }
    defer { _ = Darwin.lockf(lockDescriptor, F_ULOCK, 0) }

    switch legacyMigrationMarkerPresence(dirfd: legacyDirectory) {
    case .present:
      return true
    case .unreadable:
      return existingDirectoryStaysUsable()
    case .absent:
      break
    }
    if !pathIsAbsent(directoryURL) {
      return stampExistingDirectoryIfTrusted(legacyDirectory: legacyDirectory)
    }
    switch readTrustedLegacyCache(dirfd: legacyDirectory) {
    case .absent:
      return true
    case .rejected:
      // Leave the new directory unpublished so a later read can retry.
      return false
    case .value(let legacy):
      return publishLegacyCache(legacy, legacyDirectory: legacyDirectory)
    }
  }

  /// One result for a final path that already exists: stamp a trusted
  /// `0700` directory and do not copy. A file, symlink, or other mode stays
  /// untouched and unstamped so a later attempt can still migrate.
  private func stampExistingDirectoryIfTrusted(legacyDirectory: Int32) -> Bool {
    guard let currentDirectory = openTrustedDirectory(directoryURL) else {
      return true
    }
    Darwin.close(currentDirectory)
    return recordLegacyMigrationMarker(dirfd: legacyDirectory)
  }

  private func publishLegacyCache(
    _ legacy: LegacyAllowOffCacheSnapshot,
    legacyDirectory: Int32
  ) -> Bool {
    let stagingURL = stagingDirectoryURL()
    guard createStagingDirectory(stagingURL) else { return false }
    var published = false
    defer {
      if !published {
        removeDirectoryTree(stagingURL)
      }
    }
    guard let staging = openTrustedDirectory(stagingURL) else { return false }
    defer { Darwin.close(staging) }

    // Tests observe the window after the private directory exists and before
    // the cache file is installed. The final directory is still absent.
    legacyMigrationCreatedObserver()

    guard installLegacySnapshot(
      legacy,
      dirfd: staging,
      parentURL: stagingURL
    ),
      excludeVerifiedDirectoryFromBackup(dirfd: staging, url: stagingURL),
      fsyncDirectory(staging)
    else { return false }

    switch renameExclusive(from: stagingURL, to: directoryURL) {
    case .failed:
      return false
    case .destinationExists:
      return stampExistingDirectoryIfTrusted(legacyDirectory: legacyDirectory)
    case .renamed:
      break
    }

    guard fsyncParentDirectory(directoryURL.deletingLastPathComponent()),
          excludeVerifiedDirectoryFromBackup(dirfd: staging, url: directoryURL),
          recordLegacyMigrationMarker(dirfd: legacyDirectory)
    else {
      removeDirectoryTree(directoryURL)
      return false
    }
    published = true
    return true
  }

  private func installLegacySnapshot(
    _ legacy: LegacyAllowOffCacheSnapshot,
    dirfd: Int32,
    parentURL: URL
  ) -> Bool {
    switch installExclusiveSibling(
      dirfd: dirfd,
      parentURL: parentURL,
      name: allowOffCacheFileName,
      bytes: legacy.document,
      maximumByteCount: AllowOffCachePolicy.maximumByteCount
    ) {
    case .failed:
      return false
    case .adopted, .created:
      break
    }
    for marker in legacy.markers {
      switch installExclusiveSibling(
        dirfd: dirfd,
        parentURL: parentURL,
        name: marker.name,
        bytes: marker.bytes,
        maximumByteCount: allowOffCacheDenyMarkerMaximumByteCount
      ) {
      case .failed:
        return false
      case .adopted, .created:
        break
      }
    }
    return true
  }

  private func legacyMigrationMarkerPresence() -> MigrationMarkerPresence {
    switch openLegacyDirectory(legacyDirectoryURL) {
    case .opened(let descriptor):
      defer { Darwin.close(descriptor) }
      return legacyMigrationMarkerPresence(dirfd: descriptor)
    case .absent:
      return .absent
    case .untrusted:
      return .present
    case .unreadable:
      return .unreadable
    }
  }

  private func openMigrationLock(dirfd: Int32) -> Int32? {
    let descriptor = allowOffCacheLegacyMigrationLockName.withCString { name in
      Darwin.openat(
        dirfd,
        name,
        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
        allowOffCacheFilePermissions
      )
    }
    guard descriptor >= 0 else { return nil }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedUnsharedRegularFile(value),
          restrictAndSync(descriptor)
    else {
      Darwin.close(descriptor)
      return nil
    }
    do {
      try markExcludedFromBackup(
        legacyDirectoryURL.appendingPathComponent(
          allowOffCacheLegacyMigrationLockName,
          isDirectory: false
        )
      )
    } catch {
      Darwin.close(descriptor)
      return nil
    }
    return descriptor
  }

  private func legacyMigrationMarkerPresence(
    dirfd: Int32
  ) -> MigrationMarkerPresence {
    switch readSibling(
      dirfd: dirfd,
      name: allowOffCacheLegacyMigrationMarkerName,
      maximumByteCount: allowOffCacheLegacyMigrationMarkerBytes.count
    ) {
    case .absent:
      return .absent
    // A symlink, wrong mode, or oversized file is present. Treating it as
    // finished keeps a purged cache from copying the legacy file again.
    case .rejected, .value:
      return .present
    case .unreadable:
      return .unreadable
    }
  }

  private func recordLegacyMigrationMarker(dirfd: Int32) -> Bool {
    switch installExclusiveSibling(
      dirfd: dirfd,
      parentURL: legacyDirectoryURL,
      name: allowOffCacheLegacyMigrationMarkerName,
      bytes: allowOffCacheLegacyMigrationMarkerBytes,
      maximumByteCount: allowOffCacheLegacyMigrationMarkerBytes.count
    ) {
    case .created, .adopted:
      return true
    case .failed:
      return legacyMigrationMarkerPresence(dirfd: dirfd) == .present
    }
  }

  private struct AllowOffCacheFileIdentity: Equatable {
    var device: dev_t
    var inode: ino_t
  }

  private struct LegacyDenyMarker {
    var name: String
    var bytes: Data
  }

  private struct LegacyAllowOffCacheSnapshot {
    var document: Data
    var markers: [LegacyDenyMarker]
  }

  private enum SiblingBytes {
    case absent
    case rejected
    case unreadable
    case value(Data, AllowOffCacheFileIdentity)
  }

  private enum MigrationMarkerPresence {
    case absent
    case present
    case unreadable
  }

  private enum LegacyDirectoryOpen {
    case opened(Int32)
    case absent
    case untrusted
    case unreadable
  }

  private enum ExclusiveInstall {
    case created(AllowOffCacheFileIdentity)
    case adopted(AllowOffCacheFileIdentity)
    case failed
  }

  private enum LegacySnapshotRead {
    case absent
    case rejected
    case value(LegacyAllowOffCacheSnapshot)
  }

  private func readTrustedLegacyCache(dirfd: Int32) -> LegacySnapshotRead {
    switch readSibling(
      dirfd: dirfd,
      name: allowOffCacheFileName,
      maximumByteCount: AllowOffCachePolicy.maximumByteCount
    ) {
    case .absent:
      return .absent
    case .rejected, .unreadable:
      return .rejected
    case .value(let document, _):
      guard let names = directoryEntryNames(dirfd: dirfd) else { return .rejected }
      var markers: [LegacyDenyMarker] = []
      for name in names where isLegacyDenyMarkerName(name) {
        guard case .value(let bytes, _) = readSibling(
          dirfd: dirfd,
          name: name,
          maximumByteCount: allowOffCacheDenyMarkerMaximumByteCount
        ) else { return .rejected }
        markers.append(LegacyDenyMarker(name: name, bytes: bytes))
      }
      return .value(
        LegacyAllowOffCacheSnapshot(document: document, markers: markers)
      )
    }
  }

  private func isLegacyDenyMarkerName(_ name: String) -> Bool {
    guard name.hasPrefix(allowOffCacheDenyMarkerPrefix),
          name.hasSuffix(allowOffCacheDenyMarkerSuffix)
    else { return false }
    return name.count
      > allowOffCacheDenyMarkerPrefix.count + allowOffCacheDenyMarkerSuffix.count
  }

  private func stagingDirectoryURL() -> URL {
    directoryURL
      .deletingLastPathComponent()
      .appendingPathComponent(
        ".allow-off-v1.\(UUID().uuidString).migrating",
        isDirectory: true
      )
  }

  private func createStagingDirectory(_ url: URL) -> Bool {
    let created = url.withUnsafeFileSystemRepresentation { path -> Bool in
      guard let path else { return false }
      return Darwin.mkdir(path, allowOffCacheDirectoryPermissions) == 0
    }
    guard created else { return false }
    let descriptor = openFile(
      url,
      flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      removeDirectoryTree(url)
      return false
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fchmod(descriptor, allowOffCacheDirectoryPermissions) == 0 else {
      removeDirectoryTree(url)
      return false
    }
    return true
  }

  private enum ExclusiveRename {
    case renamed
    case destinationExists
    case failed
  }

  private func renameExclusive(from source: URL, to destination: URL) -> ExclusiveRename {
    var renameError = Int32(0)
    let renamed = source.withUnsafeFileSystemRepresentation { sourcePath -> Bool in
      destination.withUnsafeFileSystemRepresentation { destinationPath -> Bool in
        guard let sourcePath, let destinationPath else {
          renameError = EINVAL
          return false
        }
        if Darwin.renamex_np(
          sourcePath,
          destinationPath,
          UInt32(RENAME_EXCL)
        ) == 0 { return true }
        renameError = errno
        return false
      }
    }
    if renamed { return .renamed }
    return renameError == EEXIST || renameError == ENOTEMPTY
      ? .destinationExists
      : .failed
  }

  private func installExclusiveSibling(
    dirfd: Int32,
    parentURL: URL,
    name: String,
    bytes: Data,
    maximumByteCount: Int
  ) -> ExclusiveInstall {
    switch readSibling(
      dirfd: dirfd,
      name: name,
      maximumByteCount: maximumByteCount
    ) {
    case .rejected, .unreadable:
      return .failed
    case .value(let existing, let identity):
      return existing == bytes ? .adopted(identity) : .failed
    case .absent:
      break
    }

    let temporaryName = ".allow-off-v1.\(UUID().uuidString).tmp"
    let descriptor = temporaryName.withCString { temporary in
      Darwin.openat(
        dirfd,
        temporary,
        O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
        allowOffCacheFilePermissions
      )
    }
    guard descriptor >= 0 else { return .failed }
    guard writeAll(bytes, to: descriptor), restrictAndSync(descriptor) else {
      Darwin.close(descriptor)
      unlinkSibling(dirfd: dirfd, name: temporaryName)
      return .failed
    }
    var written = stat()
    guard Darwin.fstat(descriptor, &written) == 0 else {
      Darwin.close(descriptor)
      unlinkSibling(dirfd: dirfd, name: temporaryName)
      return .failed
    }
    let identity = AllowOffCacheFileIdentity(
      device: written.st_dev,
      inode: written.st_ino
    )
    Darwin.close(descriptor)

    var renameError = Int32(0)
    let renamed = temporaryName.withCString { temporary in
      name.withCString { final -> Bool in
        if Darwin.renameatx_np(
          dirfd,
          temporary,
          dirfd,
          final,
          UInt32(RENAME_EXCL)
        ) == 0 { return true }
        renameError = errno
        return false
      }
    }
    if !renamed {
      unlinkSibling(dirfd: dirfd, name: temporaryName)
      guard renameError == EEXIST,
            case .value(let existing, let existingIdentity) = readSibling(
              dirfd: dirfd,
              name: name,
              maximumByteCount: maximumByteCount
            ),
            existing == bytes
      else { return .failed }
      return .adopted(existingIdentity)
    }

    guard case .value(let installed, let installedIdentity) = readSibling(
      dirfd: dirfd,
      name: name,
      maximumByteCount: maximumByteCount
    ),
      installed == bytes,
      installedIdentity == identity,
      excludeBackupIfUnchanged(
        parentURL.appendingPathComponent(name, isDirectory: false),
        dirfd: dirfd,
        name: name,
        identity: identity
      )
    else {
      removeIfIdentityMatches(dirfd: dirfd, name: name, identity: identity)
      return .failed
    }
    return .created(identity)
  }

  private func readSibling(
    dirfd: Int32,
    name: String,
    maximumByteCount: Int
  ) -> SiblingBytes {
    var openError = Int32(0)
    let descriptor = name.withCString { cName -> Int32 in
      while true {
        let opened = Darwin.openat(
          dirfd,
          cName,
          O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if opened >= 0 { return opened }
        let error = errno
        if error == EINTR { continue }
        openError = error
        return opened
      }
    }
    if descriptor < 0 {
      switch openError {
      case ENOENT:
        return .absent
      case ELOOP:
        return .rejected
      default:
        return .unreadable
      }
    }
    defer { Darwin.close(descriptor) }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else { return .unreadable }
    guard isTrustedOwnedUnsharedRegularFile(value),
          value.st_size >= 0,
          value.st_size <= off_t(maximumByteCount),
          permissionBits(value) == allowOffCacheFilePermissions
    else { return .rejected }
    guard let bytes = readExact(
      descriptor: descriptor,
      size: Int(value.st_size)
    ) else { return .unreadable }
    return .value(
      bytes,
      AllowOffCacheFileIdentity(device: value.st_dev, inode: value.st_ino)
    )
  }

  private func excludeBackupIfUnchanged(
    _ url: URL,
    dirfd: Int32,
    name: String,
    identity: AllowOffCacheFileIdentity
  ) -> Bool {
    guard siblingIdentity(dirfd: dirfd, name: name) == identity else {
      return false
    }
    do {
      try markExcludedFromBackup(url)
      return true
    } catch {
      return false
    }
  }

  private func excludeVerifiedDirectoryFromBackup(
    dirfd: Int32,
    url: URL
  ) -> Bool {
    var descriptorStatus = stat()
    guard Darwin.fstat(dirfd, &descriptorStatus) == 0,
          let pathStatus = status(of: url),
          pathStatus.st_dev == descriptorStatus.st_dev,
          pathStatus.st_ino == descriptorStatus.st_ino,
          isTrustedOwnedDirectory(pathStatus),
          permissionBits(pathStatus) == allowOffCacheDirectoryPermissions
    else { return false }
    do {
      try markExcludedFromBackup(url)
      return true
    } catch {
      return false
    }
  }

  private func siblingIdentity(
    dirfd: Int32,
    name: String
  ) -> AllowOffCacheFileIdentity? {
    let descriptor = name.withCString { cName in
      Darwin.openat(dirfd, cName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedUnsharedRegularFile(value)
    else { return nil }
    return AllowOffCacheFileIdentity(device: value.st_dev, inode: value.st_ino)
  }

  private func removeIfIdentityMatches(
    dirfd: Int32,
    name: String,
    identity: AllowOffCacheFileIdentity
  ) {
    guard siblingIdentity(dirfd: dirfd, name: name) == identity else { return }
    unlinkSibling(dirfd: dirfd, name: name)
  }

  private func unlinkSibling(dirfd: Int32, name: String) {
    _ = name.withCString { cName in
      Darwin.unlinkat(dirfd, cName, 0)
    }
  }

  private func openLegacyDirectory(_ url: URL) -> LegacyDirectoryOpen {
    var openError = Int32(0)
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else {
        openError = EINVAL
        return -1
      }
      while true {
        let opened = Darwin.open(
          path,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if opened >= 0 { return opened }
        let error = errno
        if error == EINTR { continue }
        openError = error
        return -1
      }
    }
    if descriptor < 0 {
      switch openError {
      case ENOENT:
        return .absent
      case ELOOP, ENOTDIR:
        return .untrusted
      default:
        return .unreadable
      }
    }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else {
      Darwin.close(descriptor)
      return .unreadable
    }
    guard isTrustedOwnedDirectory(value),
          permissionBits(value) == allowOffCacheDirectoryPermissions
    else {
      Darwin.close(descriptor)
      return .untrusted
    }
    return .opened(descriptor)
  }

  private func openTrustedDirectory(_ url: URL) -> Int32? {
    let descriptor = openFile(
      url,
      flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return nil }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedDirectory(value),
          permissionBits(value) == allowOffCacheDirectoryPermissions
    else {
      Darwin.close(descriptor)
      return nil
    }
    return descriptor
  }

  private func fsyncDirectory(_ descriptor: Int32) -> Bool {
    Darwin.fsync(descriptor) == 0
  }

  /// The parent of the cache directory may itself be a symlink. `mkdir` and
  /// `rename` follow that link. `O_NOFOLLOW` would fail the open, and the
  /// caller would delete the directory it had just published.
  private func fsyncParentDirectory(_ url: URL) -> Bool {
    let descriptor = openFile(
      url,
      flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC
    )
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedDirectory(value)
    else { return false }
    return Darwin.fsync(descriptor) == 0
  }

  private func removeDirectoryTree(_ url: URL) {
    let descriptor = openFile(
      url,
      flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedDirectory(value),
          permissionBits(value) == allowOffCacheDirectoryPermissions
    else {
      Darwin.close(descriptor)
      return
    }
    if let names = directoryEntryNames(dirfd: descriptor) {
      for name in names {
        unlinkSibling(dirfd: descriptor, name: name)
      }
    }
    Darwin.close(descriptor)
    url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return }
      _ = Darwin.rmdir(path)
    }
  }

  private func existingDirectoryStaysUsable() -> Bool {
    !pathIsAbsent(directoryURL)
  }

  private func pathIsAbsent(_ url: URL) -> Bool {
    var absent = false
    url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return }
      var value = stat()
      absent = Darwin.lstat(path, &value) != 0 && errno == ENOENT
    }
    return absent
  }
}

private func directoryEntryNames(dirfd: Int32) -> [String]? {
  let duplicate = Darwin.dup(dirfd)
  guard duplicate >= 0 else { return nil }
  guard let directory = Darwin.fdopendir(duplicate) else {
    Darwin.close(duplicate)
    return nil
  }
  defer { Darwin.closedir(directory) }
  var names: [String] = []
  while true {
    errno = 0
    guard let entry = Darwin.readdir(directory) else {
      return errno == 0 ? names : nil
    }
    let name = directoryEntryName(entry)
    if name != "." && name != ".." {
      names.append(name)
    }
  }
}

private func directoryEntryName(
  _ entry: UnsafeMutablePointer<dirent>
) -> String {
  let length = Int(entry.pointee.d_namlen)
  return withUnsafeBytes(of: entry.pointee.d_name) { bytes in
    let end = min(max(length, 0), bytes.count)
    return String(decoding: bytes.prefix(end), as: UTF8.self)
  }
}

private func readExact(descriptor: Int32, size: Int) -> Data? {
  guard size >= 0 else { return nil }
  var data = Data()
  data.reserveCapacity(size)
  var remaining = size
  var buffer = [UInt8](
    repeating: 0,
    count: min(max(size, 1), allowOffCacheReadBufferByteCount)
  )
  while remaining > 0 {
    let count = buffer.withUnsafeMutableBytes { bytes in
      Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
    }
    if count < 0 {
      if errno == EINTR { continue }
      return nil
    }
    if count == 0 { return nil }
    data.append(buffer, count: count)
    remaining -= count
  }
  return data
}

