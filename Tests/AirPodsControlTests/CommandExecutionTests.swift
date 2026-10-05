import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("Command execution")
struct CommandExecutionTests {
  @Test("Keeps version device-free and reports typed no-device outcomes")
  func commandExecutionLifecycleAndNoDeviceOutcomes() throws {
    let versionInvocation = try parseInvocation(["version"])
    var resolverCallCount = 0
    let version = CommandExecution.execute(versionInvocation) { _, _ in
      resolverCallCount += 1
      return nil
    }
    #expect(resolverCallCount == 0, "version does not resolve a device")
    #expect(version.plain == BuildVersion.current, "version outcome has plain version")
    #expect(version.exitCode == 0, "version outcome succeeds")
    #expect(version.payload["version"] as? String == BuildVersion.current, "version payload has version")

    let namedInvocation = try parseInvocation(["--device", "Studio AirPods", "lm", "get"])
    var capturedName: String?
    var capturedLoggerEnabled = true
    resolverCallCount = 0
    let noDevice = CommandExecution.executeListeningMode(
      namedInvocation,
      resolveSession: { command, name, logger in
        resolverCallCount += 1
        capturedName = name
        capturedLoggerEnabled = logger.enabled
        guard case .get = command else {
          Issue.record("listening-mode execution must pass get")
          return .failed(.noDevice)
        }
        return .failed(.noDevice)
      }
    )
    #expect(resolverCallCount == 1, "resource command resolves a device exactly once")
    #expect(capturedName == "Studio AirPods", "execution forwards the requested device name")
    #expect(!capturedLoggerEnabled, "execution forwards its configured logger")
    #expect(noDevice.plain == "no-device", "missing device has plain no-device")
    #expect(noDevice.terminalReason == .noDevice)
    #expect(noDevice.exitCode == 1, "missing device exits one")
    #expect(noDevice.payload["device"] is NSNull, "missing device is JSON null")
    #expect(noDevice.payload["listeningMode"] is NSNull, "missing listening mode is JSON null")
    #expect(noDevice.payload["error"] as? String == "no-device", "missing device has error")

    let listInvocation = try parseInvocation(["lm", "list"])
    let noDeviceList = CommandExecution.executeListeningMode(listInvocation) { _, _, _ in
      .failed(.noDevice)
    }
    #expect(noDeviceList.plain == "no-device", "missing-device list has plain no-device")
    #expect(noDeviceList.exitCode == 1, "missing-device list exits one")
    #expect(
      payloadEquals(
        noDeviceList.payload,
        [
          "device": NSNull(),
          "error": "no-device",
          "listeningMode": NSNull(),
          "result": "error",
          "supportedListeningModes": [String](),
        ]
      ),
      "missing-device list preserves its complete JSON payload"
    )

    let awarenessInvocation = try parseInvocation(["ca", "get"])
    let noDeviceAwareness = CommandExecution.execute(awarenessInvocation) { _, _ in nil }
    #expect(
      noDeviceAwareness.payload["conversationAwareness"] is NSNull,
      "missing Conversation Awareness state is JSON null"
    )
    #expect(
      noDeviceAwareness.payload["listeningMode"] == nil,
      "Conversation Awareness payload omits listening mode"
    )

    let reportInvocation = try parseInvocation(["support-report"])
    let noDeviceReport = CommandExecution.execute(reportInvocation) { _, _ in nil }
    #expect(noDeviceReport.exitCode == 1, "missing support-report device exits one")
    #expect(
      noDeviceReport.plain.contains(
        "Connect exactly one compatible AirPods or Beats device"
      ),
      "support-report requires an unambiguous privacy-preserving target"
    )
    #expect(noDeviceReport.supportReport == nil, "missing device does not offer issue creation")
  }

  @Test
  func commandDeviceResolutionMapsDeviceSelection() {
    let device = FakeCompatibleAudioDevice(
      name: "Desk AirPods",
      listeningMode: .transparency
    )
    switch CommandDeviceResolution.devices(from: .selected([device])) {
    case let .devices(resolved):
      #expect(resolved.count == 1, "selected devices map to the devices case")
      #expect(resolved[0].name == "Desk AirPods", "mapped device keeps its name")
    case .statusDevices, .failed:
      Issue.record("selected compatible devices must map to .devices")
    }
    switch CommandDeviceResolution.devices(
      from: DeviceSelection<FakeCompatibleAudioDevice>.noDevice
    ) {
    case .failed(.noDevice):
      break
    case .devices, .statusDevices, .failed:
      Issue.record("no-device selection must map to failed no-device")
    }
    switch CommandDeviceResolution.statusDevices(
      from: DeviceSelection<FakeCompatibleAudioDevice>.ambiguousDevice
    ) {
    case .failed(.ambiguousDevice):
      break
    case .devices, .statusDevices, .failed:
      Issue.record("ambiguous selection must map to failed ambiguous-device")
    }
  }

  @Test("Preserves the named listening-mode setter no-device contract")
  func namedListeningModeSetterNoDeviceOutcome() throws {
    let missingName = "__missing_airpods__"
    let invocation = try parseInvocation([
      "--device", missingName, "lm", "set", "anc",
    ])
    var resolverCallCount = 0
    var capturedName: String?
    let outcome = CommandExecution.executeListeningMode(
      invocation,
      resolveSession: { command, name, _ in
        resolverCallCount += 1
        capturedName = name
        guard case let .set(target) = command, target == .noiseCancellation else {
          Issue.record("listening-mode execution must pass the requested set target")
          return .failed(.noDevice)
        }
        return .failed(.noDevice)
      }
    )

    #expect(resolverCallCount == 1, "named setter resolves exactly once")
    #expect(capturedName == missingName, "named setter forwards the requested device name")
    #expect(outcome.plain == "no-device", "missing device set has plain no-device")
    #expect(outcome.exitCode == 1, "missing device set exits one")
    #expect(
      payloadEquals(
        outcome.payload,
        [
          "device": NSNull(),
          "error": "no-device",
          "listeningMode": NSNull(),
          "result": "error",
        ]
      ),
      "missing device set preserves its complete JSON payload"
    )
  }

  @Test("Preserves unavailable Conversation Awareness discovery")
  func unavailableConversationAwarenessOutcome() throws {
    let invocation = try parseInvocation(["ca", "get", "--json"])
    let outcome = CommandExecution.execute(
      invocation,
      resolveDevices: { _, _, _ in .failed(.unavailable) }
    )

    #expect(outcome.plain == "unavailable", "unavailable awareness has plain token")
    #expect(outcome.exitCode == 6, "unavailable awareness exits six")
    #expect(
      payloadEquals(
        outcome.payload,
        [
          "conversationAwareness": NSNull(),
          "device": NSNull(),
          "error": "unavailable",
          "result": "error",
        ]
      ),
      "unavailable awareness preserves its complete JSON payload"
    )
  }

  @Test(
    "Preserves unavailable support-report discovery without side effects",
    arguments: [
      ["support-report"],
      ["support-report", "--with-write-tests"],
    ]
  )
  func unavailableSupportReportOutcome(arguments: [String]) throws {
    let invocation = try parseInvocation(arguments)
    var consentRequests = 0
    var writeRuns = 0
    let outcome = CommandExecution.execute(
      invocation,
      resolveDevices: { _, _, _ in .failed(.unavailable) },
      supportReport: SupportReportCommand(
        requestWriteTestConsent: { _ in
          consentRequests += 1
          Issue.record("unavailable discovery must not request write consent")
          return true
        },
        runWriteTests: { _, _ in
          writeRuns += 1
          Issue.record("unavailable discovery must not run write tests")
          return SupportReportWriteTestResults(
            listeningModes: .skipped(reason: "unexpected write callback"),
            conversationAwareness: .skipped(reason: "unexpected write callback"),
            interruptedBySignal: nil
          )
        }
      )
    )

    #expect(outcome.exitCode == 6, "unavailable support-report discovery exits six")
    #expect(
      outcome.plain == """
      AirPods or Beats report-device discovery is unavailable.
      Connect exactly one compatible AirPods or Beats device as a macOS output device,
      then run `pods-control support-report` again.
      Nothing was sent to GitHub.
      """,
      "support-report preserves unavailable discovery guidance"
    )
    #expect(
      payloadEquals(
        outcome.payload,
        ["error": "unavailable", "result": "error"]
      ),
      "unavailable support-report preserves its complete JSON payload"
    )
    #expect(outcome.supportReport == nil, "unavailable discovery has no report")

    var readResponses = 0
    var openedURLs = 0
    var output = [String]()
    var errors = [String]()
    let presentationReason = SupportReportInteraction.present(
      outcome: outcome,
      inputIsInteractive: true,
      readResponse: {
        readResponses += 1
        return "yes"
      },
      openURL: { _ in
        openedURLs += 1
        return true
      },
      writeOutput: { output.append($0) },
      writeError: { errors.append($0) }
    )
    #expect(presentationReason == .unavailable, "unavailable report preserves its reason")
    #expect(output == [outcome.plain], "unavailable report preserves plain stdout")
    #expect(errors.isEmpty, "unavailable report preserves empty stderr")
    #expect(consentRequests == 0, "unavailable discovery never requests write consent")
    #expect(writeRuns == 0, "unavailable discovery never runs writes")
    #expect(readResponses == 0, "unavailable report never requests issue confirmation")
    #expect(openedURLs == 0, "unavailable report never opens an issue form")
  }

  @Test("Renders listening-mode reads and verified, unsupported, or no-op writes")
  func listeningModeCommandExecution() throws {
    let knownDevice = FakeCompatibleAudioDevice(
      name: "Known AirPods",
      listeningMode: .transparency
    )
    let known = try commandOutcome(["lm", "get"], device: knownDevice)
    #expect(known.plain == "transparency", "listening-mode get returns the current mode")
    #expect(known.payload["device"] as? String == "Known AirPods", "get payload has device")
    #expect(
      known.payload["listeningMode"] as? String == "transparency",
      "get payload has current mode"
    )
    let unknown = try commandOutcome(
      ["lm", "get"],
      device: FakeCompatibleAudioDevice(name: "Future AirPods", listeningMode: nil)
    )
    #expect(unknown.plain == "unknown", "unknown listening mode has plain fallback")
    #expect(unknown.payload["listeningMode"] is NSNull, "unknown listening mode is JSON null")

    let listDevice = FakeCompatibleAudioDevice(
      name: "Subset AirPods",
      listeningModes: [.noiseCancellation, .transparency],
      listeningMode: .noiseCancellation
    )
    let list = try commandOutcome(["lm", "list"], device: listDevice)
    #expect(
      list.plain == "transparency,noise-cancellation",
      "listening-mode list uses canonical order"
    )
    #expect(
      list.payload["supportedListeningModes"] as? [String]
        == ["transparency", "noise-cancellation"],
      "list payload has supported modes"
    )
    #expect(
      list.payload["listeningMode"] as? String == "noise-cancellation",
      "list payload has current mode"
    )

    let unsupportedDevice = FakeCompatibleAudioDevice(
      name: "Limited AirPods",
      listeningModes: [.transparency],
      listeningMode: .transparency
    )
    let unsupported = try commandOutcome(["lm", "set", "adaptive"], device: unsupportedDevice)
    #expect(unsupported.plain == "unsupported", "unavailable listening mode is unsupported")
    #expect(unsupported.exitCode == 4, "unsupported listening mode exits four")
    #expect(unsupported.terminalReason == .unsupported)
    #expect(
      unsupported.payload["listeningMode"] as? String == "transparency",
      "unsupported set preserves current mode"
    )
    let currentDevice = FakeCompatibleAudioDevice(
      name: "Current AirPods",
      listeningMode: .adaptive
    )
    let current = try commandOutcome(["lm", "set", "adaptive"], device: currentDevice)
    #expect(current.plain == "ok", "setting the current mode succeeds")
    #expect(currentDevice.listeningModeSetCount == 0, "idempotent set skips the setter")

    let changedDevice = FakeCompatibleAudioDevice(
      name: "Changed AirPods",
      listeningMode: .transparency
    )
    let changed = try commandOutcome(["lm", "set", "adaptive"], device: changedDevice)
    #expect(changed.plain == "ok", "verified listening-mode change succeeds")
    #expect(
      changed.payload["listeningMode"] as? String == "adaptive",
      "verified change reports observed mode"
    )
    #expect(changedDevice.listeningMode == .adaptive, "verified change mutates the device")
    #expect(changedDevice.listeningModeSetCount == 1, "verified change invokes the setter once")

    let unchangedDevice = FakeCompatibleAudioDevice(
      name: "Unchanged AirPods",
      listeningMode: .transparency,
      appliesListeningModeWrite: false
    )
    let unchanged = try commandOutcome(["lm", "set", "adaptive"], device: unchangedDevice)
    #expect(unchanged.plain == "no-op", "unverified listening-mode change is a no-op")
    #expect(unchanged.exitCode == 3, "unverified listening-mode change exits three")
    #expect(unchanged.terminalReason == .noOp)
    #expect(
      unchanged.payload["result"] as? String == "no-op"
        && unchanged.payload["error"] == nil,
      "a no-op has its distinct JSON envelope"
    )
    #expect(
      unchanged.payload["listeningMode"] as? String == "transparency",
      "no-op payload has observed mode"
    )
  }

  @Test("Reports default and explicit cycles with unsupported and no-op outcomes")
  func listeningModeCycleCommandExecution() throws {
    let defaultDevice = FakeCompatibleAudioDevice(
      name: "Cycle AirPods",
      listeningMode: .transparency
    )
    let defaultCycle = try commandOutcome(["lm", "cycle"], device: defaultDevice)
    #expect(defaultCycle.plain == "adaptive", "default cycle advances to Adaptive")
    #expect(
      defaultCycle.payload["listeningMode"] as? String == "adaptive",
      "cycle payload has target mode"
    )
    #expect(defaultDevice.listeningMode == .adaptive, "cycle mutates the device")
    #expect(
      defaultCycle.payload["supportedListeningModes"] == nil,
      "cycle payload omits supported mode list"
    )

    let explicitDevice = FakeCompatibleAudioDevice(
      name: "Explicit Cycle AirPods",
      listeningMode: .adaptive
    )
    let explicitCycle = try commandOutcome(
      ["lm", "cycle", "--modes", "anc,trans"],
      device: explicitDevice
    )
    #expect(
      explicitCycle.plain == "noise-cancellation",
      "explicit aliases advance in cycle order from an excluded current mode"
    )
    #expect(
      explicitDevice.listeningMode == .noiseCancellation,
      "explicit cycle applies its target"
    )
    let wrappedCycle = try commandOutcome(
      ["lm", "cycle", "--modes", "anc,trans"],
      device: explicitDevice
    )
    #expect(
      wrappedCycle.plain == "transparency",
      "explicit cycle wraps after its last selected mode"
    )

    explicitDevice.listeningMode = .noiseCancellation
    let cycleThroughOff = try commandOutcome(
      ["lm", "cycle", "--modes", "noise-cancellation,off,transparency"],
      device: explicitDevice
    )
    #expect(cycleThroughOff.plain == "off", "an explicit cycle can wrap through Off")
    let cycleOutOfOff = try commandOutcome(["lm", "cycle"], device: explicitDevice)
    #expect(cycleOutOfOff.plain == "transparency", "the default cycle advances out of Off")

    let unknownDevice = FakeCompatibleAudioDevice(
      name: "Unknown Cycle AirPods",
      listeningMode: nil
    )
    let unknownCycle = try commandOutcome(["lm", "cycle"], device: unknownDevice)
    #expect(unknownCycle.plain == "transparency", "an unknown mode starts at the first mode")

    let unknownExplicitDevice = FakeCompatibleAudioDevice(
      name: "Unknown Explicit Cycle AirPods",
      listeningMode: nil
    )
    let unknownExplicitCycle = try commandOutcome(
      ["lm", "cycle", "--modes", "noise-cancellation,transparency"],
      device: unknownExplicitDevice
    )
    #expect(
      unknownExplicitCycle.plain == "transparency",
      "an unknown mode starts at the first mode in cycle order"
    )

    let noAdaptiveDevice = FakeCompatibleAudioDevice(
      name: "No Adaptive AirPods",
      listeningModes: [.noiseCancellation, .transparency],
      listeningMode: .noiseCancellation
    )
    let skippedAdaptive = try commandOutcome(["lm", "cycle"], device: noAdaptiveDevice)
    #expect(
      skippedAdaptive.plain == "transparency",
      "a device without Adaptive cycles from Noise cancellation to Transparency"
    )
    let wrappedWithoutAdaptive = try commandOutcome(["lm", "cycle"], device: noAdaptiveDevice)
    #expect(
      wrappedWithoutAdaptive.plain == "noise-cancellation",
      "Transparency wraps to Noise cancellation when Adaptive is absent"
    )

    let limitedDevice = FakeCompatibleAudioDevice(
      name: "Limited Cycle AirPods",
      listeningModes: [.transparency],
      listeningMode: .transparency
    )
    let unsupported = try commandOutcome(["lm", "cycle"], device: limitedDevice)
    #expect(unsupported.plain == "unsupported", "cycle with fewer than two modes is unsupported")
    #expect(
      unsupported.payload["listeningMode"] as? String == "transparency",
      "unsupported cycle preserves current mode"
    )
    let unchangedDevice = FakeCompatibleAudioDevice(
      name: "Unchanged Cycle AirPods",
      listeningMode: .transparency,
      appliesListeningModeWrite: false
    )
    let unchanged = try commandOutcome(["lm", "cycle"], device: unchangedDevice)
    #expect(unchanged.plain == "no-op", "unverified cycle is a no-op")
    #expect(
      unchanged.payload["listeningMode"] as? String == "transparency",
      "cycle no-op payload has observed mode"
    )
  }

  @Test("Cycles through --modes in the order written")
  func explicitOrderCycleCommand() throws {
    let listedDevice = FakeCompatibleAudioDevice(
      name: "Listed Order AirPods",
      listeningMode: .adaptive
    )
    let listed = try commandOutcome(
      [
        "lm", "cycle", "--modes",
        "adaptive,transparency,noise-cancellation", "--explicit-order",
      ],
      device: listedDevice
    )
    #expect(
      listed.plain == "transparency",
      "explicit order advances from Adaptive to Transparency"
    )
    #expect(
      listedDevice.listeningMode == .transparency,
      "explicit order applies its target"
    )

    let cycleOrderDevice = FakeCompatibleAudioDevice(
      name: "Cycle Order AirPods",
      listeningMode: .adaptive
    )
    let cycleOrder = try commandOutcome(
      [
        "lm", "cycle", "--modes",
        "adaptive,transparency,noise-cancellation",
      ],
      device: cycleOrderDevice
    )
    #expect(
      cycleOrder.plain == "noise-cancellation",
      "the same names without --explicit-order follow cycle order"
    )
  }

  @Test("Reports Conversation Awareness reads and write outcomes")
  func conversationAwarenessCommandExecution() throws {
    let offDevice = FakeCompatibleAudioDevice(
      name: "Awareness AirPods",
      conversationAwarenessEnabled: false
    )
    let get = try commandOutcome(["ca", "get"], device: offDevice)
    #expect(get.plain == "off", "Conversation Awareness get returns state")
    #expect(
      get.payload["conversationAwareness"] as? String == "off",
      "Conversation Awareness payload has state"
    )

    let unsupportedDevice = FakeCompatibleAudioDevice(
      name: "Unsupported Awareness AirPods",
      conversationAwarenessSupported: false
    )
    let unsupported = try commandOutcome(["ca", "get"], device: unsupportedDevice)
    #expect(unsupported.plain == "unsupported", "unsupported Conversation Awareness is reported")
    #expect(
      unsupported.payload["conversationAwareness"] is NSNull,
      "unsupported Conversation Awareness state is JSON null"
    )
    let unsupportedSet = try commandOutcome(["ca", "set", "on"], device: unsupportedDevice)
    #expect(
      unsupportedSet.plain == "unsupported",
      "unsupported Conversation Awareness set is reported"
    )
    let currentDevice = FakeCompatibleAudioDevice(
      name: "Current Awareness AirPods",
      conversationAwarenessEnabled: true
    )
    let current = try commandOutcome(["ca", "set", "on"], device: currentDevice)
    #expect(current.plain == "ok", "setting current Conversation Awareness state succeeds")
    #expect(
      currentDevice.conversationAwarenessSetCount == 0,
      "idempotent Conversation Awareness set skips the setter"
    )

    let changedDevice = FakeCompatibleAudioDevice(
      name: "Changed Awareness AirPods",
      conversationAwarenessEnabled: false
    )
    let changed = try commandOutcome(["ca", "set", "on"], device: changedDevice)
    #expect(changed.plain == "ok", "verified Conversation Awareness change succeeds")
    #expect(
      changed.payload["conversationAwareness"] as? String == "on",
      "verified Conversation Awareness change reports observed state"
    )
    #expect(changedDevice.conversationAwarenessEnabled == true, "Conversation Awareness mutates")
    #expect(
      changedDevice.conversationAwarenessSetCount == 1,
      "Conversation Awareness change invokes the setter once"
    )

    let unchangedDevice = FakeCompatibleAudioDevice(
      name: "Unchanged Awareness AirPods",
      conversationAwarenessEnabled: false,
      appliesConversationAwarenessWrite: false
    )
    let unchanged = try commandOutcome(["ca", "set", "on"], device: unchangedDevice)
    #expect(unchanged.plain == "no-op", "unverified Conversation Awareness change is a no-op")
    #expect(
      unchanged.payload["conversationAwareness"] as? String == "off",
      "Conversation Awareness no-op reports observed state"
    )
  }

  @Test(
    "Resolves one exact named target for Conversation Awareness get and set",
    arguments: [
      ["ca", "--device", "Studio AirPods", "get"],
      ["ca", "set", "on", "--device", "Studio AirPods"],
    ]
  )
  func conversationAwarenessUsesSharedNamedSelection(arguments: [String]) throws {
    let invocation = try parseInvocation(arguments)
    var resolverCallCount = 0
    var capturedName: String?
    var capturedPolicy: DeviceSelectionPolicy?
    let outcome = CommandExecution.execute(
      invocation,
      resolveDevices: { name, policy, _ in
        resolverCallCount += 1
        capturedName = name
        capturedPolicy = policy
        return .failed(.noDevice)
      }
    )
    #expect(resolverCallCount == 1, "\(arguments) resolves exactly once")
    #expect(capturedName == "Studio AirPods", "\(arguments) forwards its exact requested name")
    guard case .singleOrExact? = capturedPolicy else {
      Issue.record("\(arguments) requires one operational target")
      return
    }
    #expect(outcome.payload["conversationAwareness"] is NSNull, "\(arguments) nulls its canonical state")
    #expect(outcome.payload["device"] is NSNull, "\(arguments) has no selected device")
    #expect(outcome.payload["supportedListeningModes"] == nil, "Conversation Awareness omits supported modes")
  }
}

private func payloadEquals(
  _ actual: [String: Any],
  _ expected: [String: Any]
) -> Bool {
  NSDictionary(dictionary: actual).isEqual(to: expected)
}
