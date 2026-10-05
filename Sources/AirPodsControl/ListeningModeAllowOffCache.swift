import Foundation

final class PersistentListeningModeAllowOffCache: ListeningModeAllowOffCaching {
  static let defaultTTL: TimeInterval = 7 * 24 * 60 * 60

  let fileURL: URL

  private let ttl: TimeInterval
  private let now: () -> Date
  private let storage: AllowOffCacheFileStorage

  init(
    fileURL: URL,
    ttl: TimeInterval = PersistentListeningModeAllowOffCache.defaultTTL,
    now: @escaping () -> Date = Date.init,
    saltGenerator: @escaping () throws -> Data = secureAllowOffCacheSalt,
    markExcludedFromBackup: @escaping (URL) throws -> Void =
      excludeAllowOffCacheURLFromBackup,
    fileManager: FileManager = .default,
    legacyMigrationCreatedObserver: @escaping () -> Void = {},
    lockRetryObserver: @escaping () -> Void = {}
  ) {
    self.fileURL = fileURL
    self.ttl = ttl
    self.now = now
    self.storage = AllowOffCacheFileStorage(
      fileURL: fileURL,
      saltGenerator: saltGenerator,
      markExcludedFromBackup: markExcludedFromBackup,
      fileManager: fileManager,
      legacyMigrationCreatedObserver: legacyMigrationCreatedObserver,
      lockRetryObserver: lockRetryObserver
    )
  }

  static func defaultFileURL(
    fileManager: FileManager = .default
  ) throws -> URL {
    try fileManager.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    )
    .appendingPathComponent(allowOffCacheDirectoryName, isDirectory: true)
    .appendingPathComponent(allowOffCacheFileName, isDirectory: false)
  }

  static func systemDefault(
    fileManager: FileManager = .default
  ) -> PersistentListeningModeAllowOffCache? {
    guard let fileURL = try? defaultFileURL(fileManager: fileManager) else {
      return nil
    }
    return PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      fileManager: fileManager
    )
  }

  func lookup(rawDeviceUID: String) -> AllowOffCacheLookup {
    guard AllowOffCachePolicy.isValidTTL(ttl),
          case .value(let document) = storage.readPersistedCache(),
          let key = AllowOffCachePolicy.digestKey(
            salt: document.salt,
            rawDeviceUID: rawDeviceUID
          ),
          let observation = document.observations[key]
    else { return .miss }
    switch storage.readDenyMarker(for: key) {
    case let .value(deniedAt)
      where AllowOffCachePolicy.denyMarkerOutranksObservation(
        deniedAt: deniedAt,
        observedAt: observation.observedAt
      ):
      guard let deniedEvidence = AllowOffCachePolicy.usableEvidence(
        observedAt: deniedAt,
        ttl: ttl,
        now: now
      ) else {
        return .miss
      }
      return .denied(AllowOffCacheRecord(evidence: deniedEvidence, key: key))
    case .missing, .value:
      guard observation.allowsOff,
            let evidence = AllowOffCachePolicy.usableEvidence(
              observedAt: observation.observedAt,
              ttl: ttl,
              now: now
            )
      else { return .miss }
      let record = AllowOffCacheRecord(evidence: evidence, key: key)
      return .allowed(record)
    case .invalid:
      return .miss
    }
  }

  func applyObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    applyObservation(
      rawDeviceUID: rawDeviceUID,
      allowsOff: allowsOff,
      observedAt: observedAt,
      recordsDenial: !allowsOff
    )
  }

  func invalidatePositiveObservation(
    rawDeviceUID: String,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    applyObservation(
      rawDeviceUID: rawDeviceUID,
      allowsOff: false,
      observedAt: observedAt,
      recordsDenial: false
    )
  }

  private func applyObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date,
    recordsDenial: Bool
  ) -> AllowOffCacheMutation {
    guard AllowOffCachePolicy.isValidTTL(ttl),
          AllowOffCachePolicy.isValidRawDeviceUID(rawDeviceUID),
          AllowOffCachePolicy.isFiniteObservationTime(observedAt)
    else { return .unavailable }
    return storage.withExclusiveMutationLock(
      body: {
        applyLockedObservation(
          rawDeviceUID: rawDeviceUID,
          allowsOff: allowsOff,
          observedAt: observedAt,
          recordsDenial: recordsDenial
        )
      },
      onLockUnavailable: {
        lockTimeoutDenyMarkerFallback(
          rawDeviceUID: rawDeviceUID,
          allowsOff: allowsOff,
          recordsDenial: recordsDenial,
          observedAt: observedAt
        )
      }
    )
  }

  private func applyLockedObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date,
    recordsDenial: Bool
  ) -> AllowOffCacheMutation {
    guard let document = loadOrRecreateDocument() else { return .unavailable }
    guard let prepared = preparedCandidate(
      from: document,
      rawDeviceUID: rawDeviceUID,
      allowsOff: allowsOff,
      observedAt: observedAt
    ) else { return .unavailable }

    if let omission = omissionVersusDenial(
      key: prepared.key,
      observations: prepared.observations,
      recordsDenial: recordsDenial,
      allowsOff: allowsOff
    ) {
      return omission
    }
    if let positive = positiveVersusDenial(
      key: prepared.key,
      candidate: prepared.candidate
    ) {
      return positive
    }
    guard AllowOffCachePolicy.shouldReplaceObservation(
      existing: prepared.observations[prepared.key],
      with: prepared.candidate
    ) else {
      return appendUnchangedObservationDenial(
        key: prepared.key,
        candidate: prepared.candidate,
        existing: prepared.observations[prepared.key],
        recordsDenial: recordsDenial
      )
    }
    return persistObservation(
      document: document,
      key: prepared.key,
      observations: prepared.observations,
      candidate: prepared.candidate,
      allowsOff: allowsOff,
      recordsDenial: recordsDenial
    )
  }

  private func loadOrRecreateDocument() -> PersistedAllowOffCache? {
    switch storage.readPersistedCache() {
    case .value(let value):
      return value
    case .missing:
      return storage.makeEmptyCache()
    case .invalid:
      guard storage.purgeCacheFile() else { return nil }
      return storage.makeEmptyCache()
    }
  }

  private func preparedCandidate(
    from document: PersistedAllowOffCache,
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date
  ) -> (
    key: String,
    candidate: AllowOffObservation,
    observations: [String: AllowOffObservation]
  )? {
    guard let key = AllowOffCachePolicy.digestKey(
      salt: document.salt,
      rawDeviceUID: rawDeviceUID
    ) else { return nil }
    let observations = document.observations
    let candidate = AllowOffCachePolicy.effectiveObservation(
      AllowOffObservation(allowsOff: allowsOff, observedAt: observedAt),
      existing: observations[key],
      now: now
    )
    return (key, candidate, observations)
  }

  private func omissionVersusDenial(
    key: String,
    observations: [String: AllowOffObservation],
    recordsDenial: Bool,
    allowsOff: Bool
  ) -> AllowOffCacheMutation? {
    guard !recordsDenial, !allowsOff else { return nil }
    switch storage.readDenyMarker(for: key) {
    case .missing:
      return nil
    case .invalid:
      return .unavailable
    case .value(let deniedAt):
      guard AllowOffCachePolicy.usableEvidence(
        observedAt: deniedAt,
        ttl: ttl,
        now: now
      ) != nil else { return nil }
      guard let existing = observations[key],
            existing.allowsOff,
            AllowOffCachePolicy.observationOutranksDenyMarker(
              observedAt: existing.observedAt,
              deniedAt: deniedAt
            )
      else {
        return .unchanged
      }
      return nil
    }
  }

  private func positiveVersusDenial(
    key: String,
    candidate: AllowOffObservation
  ) -> AllowOffCacheMutation? {
    guard candidate.allowsOff else { return nil }
    switch storage.readDenyMarker(for: key) {
    case .missing:
      return nil
    case .invalid:
      return .unavailable
    case .value(let deniedAt):
      guard AllowOffCachePolicy.observationOutranksDenyMarker(
        observedAt: candidate.observedAt,
        deniedAt: deniedAt
      ) else {
        return .unchanged
      }
      return nil
    }
  }

  private func appendUnchangedObservationDenial(
    key: String,
    candidate: AllowOffObservation,
    existing: AllowOffObservation?,
    recordsDenial: Bool
  ) -> AllowOffCacheMutation {
    guard recordsDenial, !candidate.allowsOff,
          existing?.allowsOff == false
    else {
      return .unchanged
    }
    switch storage.readDenyMarker(for: key) {
    case .value(let deniedAt)
      where AllowOffCachePolicy.denyMarkerOutranksObservation(
        deniedAt: deniedAt,
        observedAt: candidate.observedAt
      ):
      return .unchanged
    case .missing, .value:
      return storage.appendDenyMarker(
        for: key,
        observedAt: candidate.observedAt
      ) ? .applied : .unavailable
    case .invalid:
      return .unavailable
    }
  }

  private func persistObservation(
    document: PersistedAllowOffCache,
    key: String,
    observations: [String: AllowOffObservation],
    candidate: AllowOffObservation,
    allowsOff: Bool,
    recordsDenial: Bool
  ) -> AllowOffCacheMutation {
    var observations = observations
    observations[key] = candidate
    let updated = PersistedAllowOffCache(
      schemaVersion: document.schemaVersion,
      salt: document.salt,
      observations: observations
    )
    guard storage.write(updated) else {
      guard !candidate.allowsOff else { return .unavailable }
      return storage.purgeCacheFile() ? .applied : .unavailable
    }
    if recordsDenial {
      guard !allowsOff,
            storage.appendDenyMarker(
              for: key,
              observedAt: candidate.observedAt
            )
      else { return .unavailable }
    }
    return .applied
  }

  private func lockTimeoutDenyMarkerFallback(
    rawDeviceUID: String,
    allowsOff: Bool,
    recordsDenial: Bool,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    guard recordsDenial, !allowsOff else { return .unavailable }
    return persistDenyMarker(
      rawDeviceUID: rawDeviceUID,
      observedAt: observedAt
    )
  }

  func remove(record: AllowOffCacheRecord) -> AllowOffCacheMutation {
    return storage.withExclusiveMutationLock {
      guard case .value(let document) = storage.readPersistedCache() else {
        return purgeInvalidCacheIfNeeded()
      }
      return remove(
        key: record.key,
        observedAt: record.evidence.observedAt,
        from: document
      )
    }
  }

  private func persistDenyMarker(
    rawDeviceUID: String,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    guard case .value(let document) = storage.readPersistedCache(),
          let key = AllowOffCachePolicy.digestKey(
            salt: document.salt,
            rawDeviceUID: rawDeviceUID
          )
    else { return .unavailable }
    let candidate = AllowOffCachePolicy.effectiveObservation(
      AllowOffObservation(allowsOff: false, observedAt: observedAt),
      existing: document.observations[key],
      now: now
    )
    switch storage.readDenyMarker(for: key) {
    case .invalid:
      return .unchanged
    case .value(let existing)
      where AllowOffCachePolicy.denyMarkerOutranksObservation(
        deniedAt: existing,
        observedAt: candidate.observedAt
      ):
      return .unchanged
    case .missing, .value:
      return storage.appendDenyMarker(for: key, observedAt: candidate.observedAt)
        ? .applied
        : .unavailable
    }
  }

  private func remove(
    key: String,
    observedAt: Date,
    from document: PersistedAllowOffCache
  ) -> AllowOffCacheMutation {
    guard let existing = document.observations[key],
          existing.allowsOff,
          existing.observedAt == observedAt
    else { return .unchanged }

    var observations = document.observations
    observations.removeValue(forKey: key)
    let updated = PersistedAllowOffCache(
      schemaVersion: document.schemaVersion,
      salt: document.salt,
      observations: observations
    )
    if storage.write(updated) { return .applied }

    // A failed invalidation must not leave stale positive evidence behind.
    return storage.purgeCacheFile() ? .applied : .unavailable
  }

  private func purgeInvalidCacheIfNeeded() -> AllowOffCacheMutation {
    switch storage.readPersistedCache() {
    case .missing:
      return .unchanged
    case .invalid:
      return storage.purgeCacheFile() ? .applied : .unavailable
    case .value:
      return .unchanged
    }
  }

}
