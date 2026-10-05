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
  // legacy migration lock; a directory this attempt created is removed unless
  // the marker is written. A file the reader would reject stays where it is,
  // and a path this call did not create is never chmod'd. After the new
  // directory or the marker exists, a missing file stays missing so a purge
  // or deletion cannot restore stale evidence.
  func importIfNeeded() -> Bool {
    guard directoryURL.lastPathComponent == allowOffCacheDirectoryName,
          fileURL.lastPathComponent == allowOffCacheFileName
    else { return true }
    if pathIsAbsent(legacyDirectoryURL) { return true }
    if legacyMigrationMarkerIsPresent() { return true }
    return importWhileLocked()
  }

  private func importWhileLocked() -> Bool {
    // lockf does not block other threads in this process. Poll so a
    // same-process waiter can report the legacy-lock wait.
    allowOffCacheAcquireProcessMutationLock(
      reportingWaits: true,
      lockRetryObserver: lockRetryObserver
    )
    defer { allowOffCacheReleaseProcessMutationLock() }
    guard let legacyDirectory = openTrustedDirectory(legacyDirectoryURL) else {
      return true
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

    if legacyMigrationMarkerIsPresent(dirfd: legacyDirectory) { return true }
    if !pathIsAbsent(directoryURL) {
      if let currentDirectory = openTrustedDirectory(directoryURL) {
        Darwin.close(currentDirectory)
        recordLegacyMigrationMarker(dirfd: legacyDirectory)
      }
      return true
    }
    guard let legacy = readTrustedLegacyCache(dirfd: legacyDirectory) else {
      return true
    }
    return copyLegacyCache(legacy, legacyDirectory: legacyDirectory)
  }

  private func copyLegacyCache(
    _ legacy: LegacyAllowOffCacheSnapshot,
    legacyDirectory: Int32
  ) -> Bool {
    guard let opened = openNewCacheDirectory() else { return false }
    let destination = opened.descriptor
    let creation = opened.creation
    var committed = false
    defer {
      Darwin.close(destination)
      if !committed {
        removeEmptyDirectoryIfCreated(creation)
      }
    }
    if creation == .exists {
      recordLegacyMigrationMarker(dirfd: legacyDirectory)
      committed = true
      return true
    }
    // Tests observe the window after mkdir and before the cache file is installed.
    legacyMigrationCreatedObserver()

    var created: [CreatedAllowOffCacheFile] = []
    switch installExclusiveSibling(
      dirfd: destination,
      parentURL: directoryURL,
      name: allowOffCacheFileName,
      bytes: legacy.document,
      maximumByteCount: AllowOffCachePolicy.maximumByteCount
    ) {
    case .failed:
      return false
    case .adopted:
      break
    case .created(let identity):
      created.append(
        CreatedAllowOffCacheFile(name: allowOffCacheFileName, identity: identity)
      )
    }
    for marker in legacy.markers {
      switch installExclusiveSibling(
        dirfd: destination,
        parentURL: directoryURL,
        name: marker.name,
        bytes: marker.bytes,
        maximumByteCount: allowOffCacheDenyMarkerMaximumByteCount
      ) {
      case .failed:
        removeCreatedFiles(dirfd: destination, created)
        return false
      case .adopted:
        break
      case .created(let identity):
        created.append(
          CreatedAllowOffCacheFile(name: marker.name, identity: identity)
        )
      }
    }
    guard excludeVerifiedDirectoryFromBackup(dirfd: destination) else {
      removeCreatedFiles(dirfd: destination, created)
      return false
    }
    recordLegacyMigrationMarker(dirfd: legacyDirectory)
    committed = true
    return true
  }

  private func legacyMigrationMarkerIsPresent() -> Bool {
    guard let descriptor = openTrustedDirectory(legacyDirectoryURL) else {
      return false
    }
    defer { Darwin.close(descriptor) }
    return legacyMigrationMarkerIsPresent(dirfd: descriptor)
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

  private func legacyMigrationMarkerIsPresent(dirfd: Int32) -> Bool {
    switch readSibling(
      dirfd: dirfd,
      name: allowOffCacheLegacyMigrationMarkerName,
      maximumByteCount: allowOffCacheLegacyMigrationMarkerBytes.count
    ) {
    case .absent:
      return false
    case .rejected, .value:
      return true
    }
  }

  private func recordLegacyMigrationMarker(dirfd: Int32) {
    _ = installExclusiveSibling(
      dirfd: dirfd,
      parentURL: legacyDirectoryURL,
      name: allowOffCacheLegacyMigrationMarkerName,
      bytes: allowOffCacheLegacyMigrationMarkerBytes,
      maximumByteCount: allowOffCacheLegacyMigrationMarkerBytes.count
    )
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

  private struct CreatedAllowOffCacheFile {
    var name: String
    var identity: AllowOffCacheFileIdentity
  }

  private enum SiblingBytes {
    case absent
    case rejected
    case value(Data, AllowOffCacheFileIdentity)
  }

  private enum ExclusiveInstall {
    case created(AllowOffCacheFileIdentity)
    case adopted(AllowOffCacheFileIdentity)
    case failed
  }

  private enum DirectoryCreation {
    case created
    case exists
    case failed
  }

  private func readTrustedLegacyCache(
    dirfd: Int32
  ) -> LegacyAllowOffCacheSnapshot? {
    guard case .value(let document, _) = readSibling(
      dirfd: dirfd,
      name: allowOffCacheFileName,
      maximumByteCount: AllowOffCachePolicy.maximumByteCount
    ) else { return nil }
    guard let names = directoryEntryNames(dirfd: dirfd) else { return nil }
    var markers: [LegacyDenyMarker] = []
    for name in names where isLegacyDenyMarkerName(name) {
      guard case .value(let bytes, _) = readSibling(
        dirfd: dirfd,
        name: name,
        maximumByteCount: allowOffCacheDenyMarkerMaximumByteCount
      ) else { return nil }
      markers.append(LegacyDenyMarker(name: name, bytes: bytes))
    }
    return LegacyAllowOffCacheSnapshot(document: document, markers: markers)
  }

  private func isLegacyDenyMarkerName(_ name: String) -> Bool {
    guard name.hasPrefix(allowOffCacheDenyMarkerPrefix),
          name.hasSuffix(allowOffCacheDenyMarkerSuffix)
    else { return false }
    return name.count
      > allowOffCacheDenyMarkerPrefix.count + allowOffCacheDenyMarkerSuffix.count
  }

  private func openNewCacheDirectory() -> (
    descriptor: Int32,
    creation: DirectoryCreation
  )? {
    let creation = makeCacheDirectory()
    guard creation != .failed else { return nil }
    let descriptor = openFile(
      directoryURL,
      flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      removeEmptyDirectoryIfCreated(creation)
      return nil
    }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedDirectory(value)
    else {
      Darwin.close(descriptor)
      removeEmptyDirectoryIfCreated(creation)
      return nil
    }
    if creation == .created {
      guard Darwin.fchmod(descriptor, allowOffCacheDirectoryPermissions) == 0 else {
        Darwin.close(descriptor)
        removeEmptyDirectoryIfCreated(creation)
        return nil
      }
    } else if permissionBits(value) != allowOffCacheDirectoryPermissions {
      Darwin.close(descriptor)
      return nil
    }
    return (descriptor, creation)
  }

  private func makeCacheDirectory() -> DirectoryCreation {
    var error = Int32(0)
    let created = directoryURL.withUnsafeFileSystemRepresentation { path -> Bool in
      guard let path else {
        error = EINVAL
        return false
      }
      if Darwin.mkdir(path, allowOffCacheDirectoryPermissions) == 0 {
        return true
      }
      error = errno
      return false
    }
    if created { return .created }
    return error == EEXIST ? .exists : .failed
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
    case .rejected:
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
      let opened = Darwin.openat(
        dirfd,
        cName,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
      )
      if opened < 0 { openError = errno }
      return opened
    }
    if descriptor < 0 {
      return openError == ENOENT ? .absent : .rejected
    }
    defer { Darwin.close(descriptor) }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedUnsharedRegularFile(value),
          value.st_size >= 0,
          value.st_size <= off_t(maximumByteCount),
          permissionBits(value) == allowOffCacheFilePermissions,
          let bytes = readExact(descriptor: descriptor, size: Int(value.st_size))
    else { return .rejected }
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

  private func excludeVerifiedDirectoryFromBackup(dirfd: Int32) -> Bool {
    var descriptorStatus = stat()
    guard Darwin.fstat(dirfd, &descriptorStatus) == 0,
          let pathStatus = status(of: directoryURL),
          pathStatus.st_dev == descriptorStatus.st_dev,
          pathStatus.st_ino == descriptorStatus.st_ino,
          isTrustedOwnedDirectory(pathStatus),
          permissionBits(pathStatus) == allowOffCacheDirectoryPermissions
    else { return false }
    do {
      try markExcludedFromBackup(directoryURL)
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

  private func removeCreatedFiles(
    dirfd: Int32,
    _ files: [CreatedAllowOffCacheFile]
  ) {
    for file in files {
      removeIfIdentityMatches(
        dirfd: dirfd,
        name: file.name,
        identity: file.identity
      )
    }
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

  private func removeEmptyDirectoryIfCreated(_ creation: DirectoryCreation) {
    guard creation == .created else { return }
    directoryURL.withUnsafeFileSystemRepresentation { path in
      guard let path else { return }
      _ = Darwin.rmdir(path)
    }
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

