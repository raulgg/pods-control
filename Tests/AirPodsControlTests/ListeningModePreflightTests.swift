import Testing

@testable import AirPodsControlCore

@Suite("Listening mode preflight policy")
struct ListeningModePreflightTests {

  @Test("Normalizes complete and partial availability and fails closed")
  func normalizesAvailability() {
    let advertised: [ListeningMode] = [.noiseCancellation, .off, .transparency]
    let expected: [ListeningMode] = [.off, .transparency, .noiseCancellation]

    #expect(
      ListeningModePreflightPolicy.normalizedModes(from: .value(advertised)) == expected,
      "complete availability uses canonical output order"
    )
    #expect(
      ListeningModePreflightPolicy.normalizedModes(from: .partial(advertised)) == expected,
      "partial availability retains recognized modes"
    )
    #expect(
      ListeningModePreflightPolicy.normalizedModes(from: .unavailable).isEmpty,
      "unavailable availability exposes no modes"
    )
    #expect(
      ListeningModePreflightPolicy.normalizedModes(from: .readError).isEmpty,
      "read errors expose no modes"
    )
  }

  @Test("Only complete AV omissions block cached Allow Off evidence")
  func cachedAllowOffBlocking() {
    let cases: [(
      name: String,
      observation: ListeningModeAvailabilityObservation,
      transportKind: ListeningModeTransportKind,
      command: ListeningModeCommand,
      expected: Bool
    )] = [
      (
        "AV complete omission",
        .value([.transparency, .adaptive]),
        .av,
        .list,
        true
      ),
      (
        "AV complete Off",
        .value([.off, .transparency]),
        .av,
        .list,
        false
      ),
      (
        "AV partial",
        .partial([.transparency, .adaptive]),
        .av,
        .list,
        false
      ),
      ("AV unavailable", .unavailable, .av, .list, false),
      ("AV read error", .readError, .av, .list, false),
      (
        "HAL complete",
        .value([.transparency, .adaptive]),
        .hal,
        .list,
        false
      ),
      (
        "AV non-Off set",
        .value([.transparency, .adaptive]),
        .av,
        .set(.adaptive),
        false
      ),
      (
        "AV Off set",
        .value([.transparency, .adaptive]),
        .av,
        .set(.off),
        true
      ),
      (
        "AV default cycle",
        .value([.transparency, .adaptive]),
        .av,
        .cycle(.defaultCycle),
        false
      ),
      (
        "AV explicit Off cycle",
        .value([.transparency, .adaptive]),
        .av,
        .cycle(.subset([.transparency, .off])),
        true
      ),
    ]

    for example in cases {
      #expect(
        ListeningModePreflightPolicy.availabilityBlocksCachedAllowOff(
          example.observation,
          transportKind: example.transportKind,
          command: example.command
        ) == example.expected,
        "\(example.name)"
      )
    }
  }

  @Test("Adds Off only when the preflight grants permission")
  func effectiveModesUseOffPermission() {
    let available: [ListeningMode] = [.transparency, .adaptive]
    let expected: [ListeningMode] = [.off, .transparency, .adaptive]

    #expect(
      ListeningModePreflightPolicy.effectiveModes(
        availableModes: available,
        offPermission: nil
      ) == available,
      "unknown Off permission leaves Off excluded"
    )
    #expect(
      ListeningModePreflightPolicy.effectiveModes(
        availableModes: available,
        offPermission: .probe
      ) == expected,
      "a probe permission adds Off"
    )
    #expect(
      ListeningModePreflightPolicy.effectiveModes(
        availableModes: available,
        offPermission: .authorized(.live(cache: nil, record: nil))
      ) == expected,
      "an authorization permission adds Off"
    )
    #expect(
      ListeningModePreflightPolicy.effectiveModes(
        availableModes: expected,
        offPermission: .probe
      ) == expected,
      "advertised Off is not duplicated or reordered"
    )
    #expect(
      ListeningModePreflightPolicy.effectiveModes(
        availableModes: [],
        offPermission: .authorized(.live(cache: nil, record: nil))
      ) == [.off],
      "a permission offers Off even when nothing else is advertised"
    )
  }

  @Test("Filters default and explicit cycles with their intended order")
  func filtersCycles() {
    let available = ListeningMode.allCases

    #expect(
      ListeningModeCyclePolicy.supportedModes(requested: nil, available: available)
        == [.transparency, .adaptive, .noiseCancellation],
      "the default cycle excludes Off and keeps cycle order"
    )
    #expect(
      ListeningModeCyclePolicy.supportedModes(
        requested: nil,
        available: [.off, .noiseCancellation, .transparency]
      ) == [.transparency, .noiseCancellation],
      "the default cycle skips Adaptive when the device lacks it"
    )
    #expect(
      ListeningModeCyclePolicy.supportedModes(
        requested: [.noiseCancellation, .off, .transparency],
        available: available
      ) == [.noiseCancellation, .off, .transparency],
      "an explicit cycle preserves its requested order"
    )
    #expect(
      ListeningModeCyclePolicy.supportedModes(
        requested: [.noiseCancellation, .off, .transparency],
        available: [.off, .transparency]
      ) == [.off, .transparency],
      "unsupported explicit modes are filtered in place"
    )
  }

  @Test("Only explicit Off operations opt into Allow Off policy")
  func offCommandPolicy() {
    #expect(
      !ListeningModePreflightPolicy.commandExplicitlyTargetsOff(.cycle(.defaultCycle)),
      "the default cycle does not target Off"
    )
    #expect(
      ListeningModePreflightPolicy.commandExplicitlyTargetsOff(
        .cycle(.subset([.transparency, .off]))
      ),
      "an explicit Off cycle targets Off"
    )
    #expect(
      ListeningModePreflightPolicy.commandExplicitlyTargetsOff(
        .cycle(.explicitOrder([.off, .transparency]))
      ),
      "an explicit-order Off cycle targets Off"
    )
    #expect(
      !ListeningModePreflightPolicy.commandMayUseAllowOffCache(.cycle(.defaultCycle)),
      "the default cycle does not use Allow Off cache evidence"
    )
    #expect(
      ListeningModePreflightPolicy.commandMayUseAllowOffCache(
        .cycle(.subset([.transparency, .off]))
      ),
      "an explicit Off cycle may use Allow Off cache evidence"
    )
    #expect(
      ListeningModePreflightPolicy.commandMayUseAllowOffCache(
        .cycle(.explicitOrder([.off, .transparency]))
      ),
      "an explicit-order Off cycle may use Allow Off cache evidence"
    )

    // The two predicates disagree for `list`: it surfaces cached Allow Off
    // evidence without opting into a probe.
    let cases: [(
      name: String,
      command: ListeningModeCommand,
      targetsOff: Bool,
      mayUseCache: Bool
    )] = [
      ("list", .list, false, true),
      ("Off set", .set(.off), true, true),
      ("non-Off set", .set(.adaptive), false, false),
      ("get", .get, false, false),
    ]

    for example in cases {
      #expect(
        ListeningModePreflightPolicy.commandExplicitlyTargetsOff(example.command)
          == example.targetsOff,
        "\(example.name) explicit Off targeting"
      )
      #expect(
        ListeningModePreflightPolicy.commandMayUseAllowOffCache(example.command)
          == example.mayUseCache,
        "\(example.name) Allow Off cache eligibility"
      )
    }
  }
}
