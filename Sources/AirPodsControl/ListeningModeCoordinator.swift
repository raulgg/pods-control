import Foundation

enum ListeningModeTransportKind: String {
  case av
  case hal
}

enum ListeningModeAvailabilityObservation {
  case value([ListeningMode])
  case partial([ListeningMode])
  case unavailable
  case readError
}

enum ListeningModeStateObservation {
  case value(ListeningMode)
  case unknown
  case unavailable
  case readError
}

extension ListeningModeStateObservation {
  var value: ListeningMode? {
    guard case let .value(mode) = self else { return nil }
    return mode
  }
}

protocol ListeningModeTransport: AnyObject {
  var name: String? { get }
  var listeningModeTransportKind: ListeningModeTransportKind { get }

  func availableListeningModes() -> [ListeningMode]
  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation
  func currentListeningMode() -> ListeningMode?
  func listeningModeStateObservation() -> ListeningModeStateObservation
  func canSetListeningMode() -> Bool
  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode>
  func settle(for interval: TimeInterval)
}

extension ListeningModeTransport {
  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation {
    .value(availableListeningModes())
  }

  func listeningModeStateObservation() -> ListeningModeStateObservation {
    currentListeningMode().map(ListeningModeStateObservation.value) ?? .unknown
  }

}

protocol ListeningModeAllowOffTransport: ListeningModeTransport {
  func setListeningModeAndReadBackAllowingOff(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode>
}

extension PrivateAudioDevice: ListeningModeTransport {
  var listeningModeTransportKind: ListeningModeTransportKind { .av }
}

enum ListeningModeCandidateRoute: Equatable {
  case selected
  case notSelected
  case unknown
}

enum ListeningModeCommand {
  case get
  case list
  case set(ListeningMode)
  case cycle(ListeningModeCycleRequest)

  init?(_ command: CLICommand) {
    switch command {
    case .listeningModeGet:
      self = .get
    case .listeningModeList:
      self = .list
    case .listeningModeSet(let target):
      self = .set(target)
    case .listeningModeCycle(let request):
      self = .cycle(request)
    case .version, .status, .supportReport,
         .conversationAwarenessGet, .conversationAwarenessSet:
      return nil
    }
  }
}

struct ListeningModeCandidate {
  let displayName: String
  let selectableNames: [String]
  let avTransport: (any ListeningModeTransport)?
  let halTransport: (any ListeningModeTransport)?
  let route: ListeningModeCandidateRoute
  let avJoinEvidence: ActiveFeatureEndpointJoinEvidence
  let allowOffCorrelation: ListeningModeAllowOffCorrelation?

  init(
    displayName: String,
    selectableNames: [String],
    avTransport: (any ListeningModeTransport)?,
    halTransport: (any ListeningModeTransport)?,
    route: ListeningModeCandidateRoute,
    avJoinEvidence: ActiveFeatureEndpointJoinEvidence? = nil,
    allowOffCorrelation: ListeningModeAllowOffCorrelation? = nil
  ) {
    self.displayName = displayName
    self.selectableNames = selectableNames
    self.avTransport = avTransport
    self.halTransport = halTransport
    self.route = route
    self.avJoinEvidence = avJoinEvidence
      ?? (avTransport == nil ? .unavailable : .matched)
    self.allowOffCorrelation = allowOffCorrelation
  }
}

enum ListeningModeAmbiguousChoice {
  case selected(index: Int)
  case unavailable
}

enum ListeningModeHALDiscovery: Equatable {
  // An empty candidate list is meaningful only when discovery succeeded.
  case available
  case unavailable
  case readError
}

struct ListeningModeSession {
  let name: String?
  let transport: any ListeningModeTransport
  let availableModes: [ListeningMode]
  let stateObservation: ListeningModeStateObservation
  let availabilityObservation: ListeningModeAvailabilityObservation?
  let writePlan: ListeningModeWritePlan?
  let offPermission: ListeningModeOffPermission?
  let blocksCachedAllowOff: Bool

  var currentMode: ListeningMode? {
    stateObservation.value
  }

  var allowOffAuthorization: ListeningModeAllowOffAuthorization? {
    switch offPermission {
    case let .authorized(authorization): return authorization
    case .probe, .none: return nil
    }
  }

  var cachedAllowOffEvidence: CachedAllowOffEvidence? {
    allowOffAuthorization?.cachedEvidence
  }
}

enum ListeningModeResolution {
  case session(ListeningModeSession)
  case failed(TerminalReason)
}

final class ListeningModeCoordinator {
  private let avCandidates: [ListeningModeCandidate]
  private let halCandidates: [ListeningModeCandidate]
  private let halDiscovery: ListeningModeHALDiscovery
  private let logger: DebugLogger

  init(
    avDevices: [PrivateAudioDevice],
    halCandidates: [ListeningModeCandidate],
    halDiscovery: ListeningModeHALDiscovery = .available,
    logger: DebugLogger
  ) {
    avCandidates = avDevices.compactMap { device in
      guard let name = device.name else { return nil }
      return ListeningModeCandidate(
        displayName: name,
        selectableNames: [name],
        avTransport: device,
        halTransport: nil,
        route: device.isActiveOperationalEndpoint ? .selected : .unknown,
        allowOffCorrelation: nil
      )
    }
    self.halCandidates = halCandidates
    self.halDiscovery = halDiscovery
    self.logger = logger
  }

  init(
    candidates: [ListeningModeCandidate],
    halDiscovery: ListeningModeHALDiscovery = .available,
    logger: DebugLogger
  ) {
    avCandidates = candidates.filter { $0.halTransport == nil }
    halCandidates = candidates.filter { $0.halTransport != nil }
    self.halDiscovery = halDiscovery
    self.logger = logger
  }

  // One selected AV candidate already ready for this command. Otherwise nil,
  // which means load HAL and call resolve(). Does not offer the chooser.
  func uniqueSelectedReadySession(
    command: ListeningModeCommand,
    named requestedName: String?
  ) -> ListeningModeSession? {
    let selectedCandidate: ListeningModeCandidate
    if let requestedName {
      let matches = matching(requestedName, in: avCandidates)
      guard matches.count == 1, let only = matches.first else { return nil }
      selectedCandidate = only
    } else {
      let candidates = logicalCandidates()
      guard candidates.count == 1, let only = candidates.first else { return nil }
      selectedCandidate = only
    }
    guard selectedCandidate.route == .selected else { return nil }
    guard let session = selectTransport(for: selectedCandidate, command: command),
          isReady(session, for: command)
    else { return nil }
    return session
  }

  func resolve(
    command: ListeningModeCommand,
    named requestedName: String?,
    chooseAmbiguous: ([String]) -> ListeningModeAmbiguousChoice
  ) -> ListeningModeResolution {
    let selectedCandidate: ListeningModeCandidate

    if let requestedName {
      let matches = namedMatches(requestedName)
      let matchCount = matches.count
      guard matchCount == 1 else {
        logger.warning(
          "device_selection",
          matchCount == 0 ? "no-exact-name-match" : "ambiguous-device-name"
        )
        return matchCount == 0
          ? discoveryFailureResolution(for: command) ?? .failed(.noDevice)
          : .failed(.ambiguousDevice)
      }
      selectedCandidate = matches[0]
    } else {
      let candidates = logicalCandidates()
      guard !candidates.isEmpty else {
        return discoveryFailureResolution(for: command) ?? .failed(.noDevice)
      }
      if candidates.count == 1, let only = candidates.first {
        selectedCandidate = only
      } else {
        switch chooseAmbiguous(candidates.map(\.displayName)) {
        case .selected(let index) where candidates.indices.contains(index):
          selectedCandidate = candidates[index]
        case .selected, .unavailable:
          return .failed(.ambiguousDevice)
        }
      }
    }

    guard let session = selectTransport(for: selectedCandidate, command: command) else {
      return discoveryFailureResolution(for: command) ?? .failed(.noDevice)
    }
    logger.info("listening_mode.transport", session.transport.listeningModeTransportKind.rawValue)
    return .session(session)
  }

  private func discoveryFailureResolution(
    for command: ListeningModeCommand
  ) -> ListeningModeResolution? {
    switch halDiscovery {
    case .available:
      return nil
    case .unavailable:
      return .failed(.unavailable)
    case .readError:
      switch command {
      case .get, .list:
        return .failed(.readError)
      case .set, .cycle:
        return .failed(.unavailable)
      }
    }
  }

  private func logicalCandidates() -> [ListeningModeCandidate] {
    assembledCandidates(hal: halCandidates, av: avCandidates)
  }

  // Exact --device matching uses pre-join selectable names, then attaches AV.
  private func namedMatches(_ requestedName: String) -> [ListeningModeCandidate] {
    assembledCandidates(
      hal: matching(requestedName, in: halCandidates),
      av: matching(requestedName, in: avCandidates)
    )
  }

  private func assembledCandidates(
    hal: [ListeningModeCandidate],
    av: [ListeningModeCandidate]
  ) -> [ListeningModeCandidate] {
    let joinedHAL = hal.map(attachUniqueActiveAV)
    let independentAV = av.filter { avCandidate in
      !joinedHAL.contains { representsJoinedAVTarget(avCandidate, in: $0) }
    }
    return joinedHAL + independentAV
  }

  private func matching(
    _ requestedName: String,
    in candidates: [ListeningModeCandidate]
  ) -> [ListeningModeCandidate] {
    candidates.filter { candidate in
      candidate.selectableNames.contains {
        $0.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
      }
    }
  }

  private func attachUniqueActiveAV(
    to candidate: ListeningModeCandidate
  ) -> ListeningModeCandidate {
    guard candidate.route == .selected, candidate.avTransport == nil else {
      return candidate
    }
    guard candidate.avJoinEvidence == .unavailable else { return candidate }
    let activeAV = avCandidates.filter { $0.route == .selected }
    guard activeAV.count == 1, let avCandidate = activeAV.first,
          let avTransport = avCandidate.avTransport
    else {
      return candidate
    }
    let names = (candidate.selectableNames + avCandidate.selectableNames)
      .reduce(into: [String]()) { result, name in
        guard !result.contains(where: {
          $0.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { return }
        result.append(name)
      }
    return ListeningModeCandidate(
      displayName: candidate.displayName,
      selectableNames: names,
      avTransport: avTransport,
      halTransport: candidate.halTransport,
      route: candidate.route,
      avJoinEvidence: .matched,
      allowOffCorrelation: candidate.allowOffCorrelation
    )
  }

  private func representsJoinedAVTarget(
    _ avCandidate: ListeningModeCandidate,
    in halCandidate: ListeningModeCandidate
  ) -> Bool {
    guard halCandidate.avJoinEvidence == .matched,
          let avTransport = avCandidate.avTransport,
          let joinedTransport = halCandidate.avTransport
    else { return false }
    if avTransport === joinedTransport { return true }

    guard let avDevice = avTransport as? PrivateAudioDevice,
          let joinedDevice = joinedTransport as? PrivateAudioDevice
    else { return false }
    if avDevice.object === joinedDevice.object { return true }

    guard let avIdentifier = PrivateAudioDiscovery.deviceIdentifier(for: avDevice.object),
          let joinedIdentifier = PrivateAudioDiscovery.deviceIdentifier(
            for: joinedDevice.object
          )
    else { return false }
    return avIdentifier == joinedIdentifier
  }

  private func selectTransport(
    for candidate: ListeningModeCandidate,
    command: ListeningModeCommand
  ) -> ListeningModeSession? {
    let avSession: ListeningModeSession?
    if candidate.route == .notSelected {
      avSession = nil
    } else {
      avSession = candidate.avTransport.map {
        session(for: $0, command: command, correlation: candidate.allowOffCorrelation)
      }
    }
    if let avSession, isReady(avSession, for: command) { return avSession }

    guard let hal = candidate.halTransport else { return avSession }
    let halSession = session(
      for: hal,
      command: command,
      correlation: candidate.allowOffCorrelation,
      allowOffFromAV: avSession
    )
    // The preferred provider preserves the established unknown/unsupported
    // result when the logical device exists but preflight cannot proceed.
    if avSession == nil || isReady(halSession, for: command) { return halSession }
    return avSession
  }

  private func session(
    for transport: any ListeningModeTransport,
    command: ListeningModeCommand,
    correlation: ListeningModeAllowOffCorrelation?,
    allowOffFromAV: ListeningModeSession? = nil
  ) -> ListeningModeSession {
    switch command {
    case .get:
      return getState(for: transport, correlation: correlation)
    case .list, .set, .cycle:
      return availability(
        for: transport,
        command: command,
        correlation: correlation,
        allowOffFromAV: allowOffFromAV
      )
    }
  }

  private func getState(
    for transport: any ListeningModeTransport,
    correlation: ListeningModeAllowOffCorrelation?
  ) -> ListeningModeSession {
    let currentObservedAt = transport.listeningModeTransportKind == .av
      ? correlation?.captureObservationTime()
      : nil
    let stateObservation = transport.listeningModeStateObservation()
    if stateObservation.value == .off, let correlation, let currentObservedAt {
      correlation.observeCurrentOff(observedAt: currentObservedAt)
    }
    return ListeningModeSession(
      name: transport.name,
      transport: transport,
      availableModes: [],
      stateObservation: stateObservation,
      availabilityObservation: nil,
      writePlan: nil,
      offPermission: nil,
      blocksCachedAllowOff: false
    )
  }

  private func availability(
    for transport: any ListeningModeTransport,
    command: ListeningModeCommand,
    correlation: ListeningModeAllowOffCorrelation?,
    allowOffFromAV: ListeningModeSession?
  ) -> ListeningModeSession {
    let preflight = availabilityPreflight(
      for: transport,
      command: command,
      correlation: correlation,
      allowOffFromAV: allowOffFromAV
    )
    let canSet: Bool
    switch command {
    case .set, .cycle:
      canSet = transport.canSetListeningMode()
    case .list:
      canSet = false
    case .get:
      canSet = false
    }
    return assemble(
      preflight,
      canSet: canSet,
      transport: transport,
      correlation: correlation
    )
  }

  private func assemble(
    _ preflight: ListeningModeAvailabilityPreflight,
    canSet: Bool,
    transport: any ListeningModeTransport,
    correlation: ListeningModeAllowOffCorrelation?
  ) -> ListeningModeSession {
    let effectiveModes = ListeningModePreflightPolicy.effectiveModes(
      availableModes: preflight.facts.availableModes,
      offPermission: preflight.offPermission
    )

    let stateIsSafe = transport.listeningModeTransportKind == .av
      || preflight.facts.stateObservation.value != nil
    let writePlan = canSet && stateIsSafe
      ? ListeningModeWritePlan(
        transport: transport,
        availableModes: effectiveModes,
        offPermission: preflight.offPermission,
        allowOffCorrelation: correlation
      )
      : nil

    return ListeningModeSession(
      name: transport.name,
      transport: transport,
      availableModes: effectiveModes,
      stateObservation: preflight.facts.stateObservation,
      availabilityObservation: preflight.facts.availabilityObservation,
      writePlan: writePlan,
      offPermission: preflight.offPermission,
      blocksCachedAllowOff: preflight.blocksCachedAllowOff
    )
  }

  private struct ListeningModeAvailabilityPreflight {
    let facts: ListeningModePreflightFacts
    let offPermission: ListeningModeOffPermission?
    let blocksCachedAllowOff: Bool
  }

  private func availabilityPreflight(
    for transport: any ListeningModeTransport,
    command: ListeningModeCommand,
    correlation: ListeningModeAllowOffCorrelation?,
    allowOffFromAV: ListeningModeSession?
  ) -> ListeningModeAvailabilityPreflight {
    let observedAt = transport.listeningModeTransportKind == .av
      ? correlation?.captureObservationTime()
      : nil
    let stateObservation = transport.listeningModeStateObservation()
    let availabilityObservation = transport.listeningModeAvailabilityObservation()
    let facts = ListeningModePreflightFacts(
      observedAt: observedAt,
      stateObservation: stateObservation,
      availabilityObservation: availabilityObservation
    )
    let freshAVBlocksCachedAllowOff = ListeningModePreflightPolicy
      .availabilityBlocksCachedAllowOff(
        facts.availabilityObservation,
        transportKind: transport.listeningModeTransportKind,
        command: command
      )
    let allowOffAuthorization = applyAllowOffPolicy(
      to: facts.availabilityObservation,
      transport: transport,
      command: command,
      correlation: correlation,
      allowOffFromAV: allowOffFromAV,
      observedAt: facts.observedAt
    )
    let offPermission: ListeningModeOffPermission?
    if let allowOffAuthorization {
      offPermission = .authorized(allowOffAuthorization)
    } else if shouldProbeAllowOff(
      availability: facts.availabilityObservation,
      transport: transport,
      command: command,
      correlation: correlation
    ) {
      offPermission = .probe
    } else {
      offPermission = nil
    }
    return ListeningModeAvailabilityPreflight(
      facts: facts,
      offPermission: offPermission,
      blocksCachedAllowOff: freshAVBlocksCachedAllowOff
    )
  }

  private func shouldProbeAllowOff(
    availability: ListeningModeAvailabilityObservation,
    transport: any ListeningModeTransport,
    command: ListeningModeCommand,
    correlation: ListeningModeAllowOffCorrelation?
  ) -> Bool {
    guard transport.listeningModeTransportKind == .hal,
          ListeningModePreflightPolicy.commandExplicitlyTargetsOff(command),
          case .value = availability
    else { return false }
    return correlation?.hasCachedDenial() != true
  }

  private func applyAllowOffPolicy(
    to availability: ListeningModeAvailabilityObservation,
    transport: any ListeningModeTransport,
    command: ListeningModeCommand,
    correlation: ListeningModeAllowOffCorrelation?,
    allowOffFromAV: ListeningModeSession?,
    observedAt: Date?
  ) -> ListeningModeAllowOffAuthorization? {
    guard ListeningModePreflightPolicy.commandMayUseAllowOffCache(command) else {
      return nil
    }
    switch transport.listeningModeTransportKind {
    case .av:
      if case .value(let modes) = availability, modes.contains(.off) {
        if let correlation, let observedAt {
          return correlation.observeAvailability(availability, observedAt: observedAt)
        }
        return .live(cache: nil, record: nil)
      }
      if let correlation, let observedAt {
        _ = correlation.observeAvailability(availability, observedAt: observedAt)
      }
      return nil
    case .hal:
      guard case .value = availability else { return nil }
      guard !(allowOffFromAV?.blocksCachedAllowOff ?? false) else { return nil }
      return allowOffFromAV?.allowOffAuthorization
        ?? correlation?.cachedAuthorization()
    }
  }

  private func isReady(
    _ session: ListeningModeSession,
    for command: ListeningModeCommand
  ) -> Bool {
    switch command {
    case .get:
      switch session.stateObservation {
      case .value, .unknown: return true
      case .unavailable, .readError: return false
      }
    case .list:
      switch session.availabilityObservation {
      case .value, .partial: return true
      case .unavailable, .readError, .none: return false
      }
    case .set(let target):
      return session.writePlan?.canWrite(target) == true
    case .cycle(let request):
      let supported = ListeningModeCyclePolicy.supportedModes(
        requested: request.modes,
        available: session.availableModes
      )
      // A requested Off that this transport cannot offer is not ready.
      // Selection can then try the other transport's probe or cached
      // Allow Off evidence. When neither transport can offer Off,
      // execution still skips it and cycles what remains.
      guard supported.count >= 2, session.writePlan != nil else { return false }
      guard ListeningModePreflightPolicy.commandExplicitlyTargetsOff(command) else {
        return true
      }
      return supported.contains(.off)
    }
  }
}
