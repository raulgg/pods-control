import Testing

@testable import AirPodsControlCore

@Suite("CLI parsing")
struct CLIParsingTests {
  @Test(
    "Canonicalizes listening-mode aliases",
    arguments: [
      AliasCase("anc", expected: "noise-cancellation"),
      AliasCase("nc", expected: "noise-cancellation"),
      AliasCase("trans", expected: "transparency"),
      AliasCase("automatic", expected: "adaptive"),
      AliasCase("auto", expected: "adaptive"),
    ]
  )
  func canonicalizesListeningModeAlias(_ example: AliasCase) throws {
    let invocation = try parseInvocation(["lm", "set", example.token])
    let mode = try #require(listeningModeSet(from: invocation.command))

    #expect(mode.rawValue == example.expected)
  }

  @Test("Accepts global options anywhere")
  func acceptsGlobalOptionsAnywhere() throws {
    let invocation = try parseInvocation([
      "--debug", "lm", "--device", "RAUL’S AIRPODS PRO", "get", "--json",
    ])

    #expect(invocation.debugEnabled)
    #expect(invocation.jsonOutput)
    #expect(invocation.requestedDeviceName == "RAUL’S AIRPODS PRO")
  }

  @Test(
    "Rejects invalid global and set arguments",
    arguments: [
      InvalidInvocation("off has no alias", ["lm", "set", "normal"]),
      InvalidInvocation(
        "duplicate device",
        ["--device", "A", "--device", "B", "lm", "get"]
      ),
      InvalidInvocation("missing device name", ["lm", "get", "--device"]),
      InvalidInvocation(
        "option-like device name",
        ["lm", "get", "--device", "--modes"]
      ),
      InvalidInvocation(
        "duplicate debug",
        ["--debug", "--debug", "lm", "get"]
      ),
      InvalidInvocation(
        "device is invalid for version",
        ["--device", "AirPods", "version"]
      ),
    ]
  )
  func rejectsInvalidGlobalAndSetArguments(
    _ example: InvalidInvocation
  ) {
    #expect(throws: CLIParseError.self) {
      _ = try parseInvocation(example.arguments)
    }
  }

  @Test(
    "Rejects invalid support-report arguments",
    arguments: [
      InvalidInvocation(
        "mutually exclusive write-test flags",
        ["support-report", "--with-write-tests", "--no-write-tests"]
      ),
      InvalidInvocation(
        "duplicate consent flags",
        ["support-report", "--with-write-tests", "--with-write-tests"]
      ),
      InvalidInvocation(
        "consent flag on another command",
        ["lm", "get", "--with-write-tests"]
      ),
      InvalidInvocation(
        "positional argument",
        ["support-report", "extra"]
      ),
      InvalidInvocation("JSON output", ["support-report", "--json"]),
      InvalidInvocation(
        "raw-name device selection",
        ["--device", "AirPods", "support-report"]
      ),
    ]
  )
  func rejectsInvalidSupportReportArguments(
    _ example: InvalidInvocation
  ) {
    #expect(throws: CLIParseError.self) {
      _ = try parseInvocation(example.arguments)
    }
  }

  @Test(
    "Rejects invalid status arguments",
    arguments: [
      InvalidInvocation("positional argument", ["status", "extra"]),
      InvalidInvocation(
        "cycle modes",
        ["status", "--modes", "transparency,adaptive"]
      ),
    ]
  )
  func rejectsInvalidStatusArguments(_ example: InvalidInvocation) {
    #expect(throws: CLIParseError.self) {
      _ = try parseInvocation(example.arguments)
    }
  }

  @Test(
    "Rejects invalid cycle arguments",
    arguments: [
      InvalidInvocation("positional argument", ["lm", "cycle", "extra"]),
      InvalidInvocation("missing modes value", ["lm", "cycle", "--modes"]),
      InvalidInvocation(
        "one mode",
        ["lm", "cycle", "--modes", "transparency"]
      ),
      InvalidInvocation(
        "repeated alias",
        ["lm", "cycle", "--modes", "trans,transparency"]
      ),
      InvalidInvocation(
        "repeated mode",
        ["lm", "cycle", "--modes", "adaptive,transparency,adaptive"]
      ),
      InvalidInvocation(
        "unknown mode",
        ["lm", "cycle", "--modes", "transparency,normal"]
      ),
      InvalidInvocation(
        "empty mode",
        ["lm", "cycle", "--modes", ",transparency,adaptive"]
      ),
      InvalidInvocation(
        "duplicate modes flag",
        ["lm", "cycle", "--modes", "a,b", "--modes", "a,b"]
      ),
      InvalidInvocation(
        "modes on get",
        ["lm", "get", "--modes", "transparency,adaptive"]
      ),
      InvalidInvocation(
        "explicit order without modes",
        ["lm", "cycle", "--explicit-order"]
      ),
      InvalidInvocation(
        "explicit order on get",
        ["lm", "get", "--explicit-order"]
      ),
      InvalidInvocation(
        "duplicate explicit order",
        [
          "lm", "cycle", "--modes", "adaptive,transparency",
          "--explicit-order", "--explicit-order",
        ]
      ),
      InvalidInvocation(
        "explicit order repeated alias",
        ["lm", "cycle", "--modes", "trans,transparency", "--explicit-order"]
      ),
      InvalidInvocation(
        "explicit order repeated mode",
        [
          "lm", "cycle", "--modes",
          "off,transparency,noise-cancellation,adaptive,off,noise-cancellation",
          "--explicit-order",
        ]
      ),
    ]
  )
  func rejectsInvalidCycleArguments(_ example: InvalidInvocation) {
    #expect(throws: CLIParseError.self) {
      _ = try parseInvocation(example.arguments)
    }
  }

  @Test("Preserves explicit cycle order only when --explicit-order is set")
  func preservesListedCycleOrder() throws {
    let sorted = try parseInvocation([
      "lm", "cycle", "--modes", "adaptive,noise-cancellation,transparency",
    ])
    let sortedRequest = try #require(listeningModeCycleRequest(from: sorted.command))
    #expect(
      sortedRequest == .subset([.transparency, .adaptive, .noiseCancellation]),
      "--modes without --explicit-order sorts into cycle order"
    )

    let listed = try parseInvocation([
      "lm", "cycle", "--modes",
      "adaptive,noise-cancellation,transparency", "--explicit-order",
    ])
    let listedRequest = try #require(listeningModeCycleRequest(from: listed.command))
    #expect(
      listedRequest == .explicitOrder([.adaptive, .noiseCancellation, .transparency]),
      "--explicit-order keeps the written mode sequence"
    )

    let flagBeforeModes = try parseInvocation([
      "lm", "cycle", "--explicit-order", "--modes",
      "adaptive,noise-cancellation,transparency",
    ])
    let flagBeforeRequest = try #require(
      listeningModeCycleRequest(from: flagBeforeModes.command)
    )
    #expect(
      flagBeforeRequest == listedRequest,
      "the flag is also accepted before --modes"
    )

    let flagAfterModes = try parseInvocation([
      "lm", "cycle", "--modes", "anc,trans,adaptive", "--explicit-order",
    ])
    let flagAfterRequest = try #require(
      listeningModeCycleRequest(from: flagAfterModes.command)
    )
    #expect(
      flagAfterRequest == .explicitOrder([
        .noiseCancellation, .transparency, .adaptive,
      ]),
      "aliases canonicalize and the flag follows --modes"
    )

    let defaultCycle = try parseInvocation(["lm", "cycle"])
    let defaultRequest = try #require(
      listeningModeCycleRequest(from: defaultCycle.command)
    )
    #expect(defaultRequest == .defaultCycle, "cycle without --modes uses the default set")
  }
}

struct AliasCase: Sendable, CustomTestStringConvertible {
  let token: String
  let expected: String

  init(_ token: String, expected: String) {
    self.token = token
    self.expected = expected
  }

  var testDescription: String { token }
}

struct InvalidInvocation: Sendable, CustomTestStringConvertible {
  let name: String
  let arguments: [String]

  init(_ name: String, _ arguments: [String]) {
    self.name = name
    self.arguments = arguments
  }

  var testDescription: String { name }
}

private func listeningModeSet(from command: CLICommand) -> ListeningMode? {
  guard case let .listeningModeSet(mode) = command else { return nil }
  return mode
}

private func listeningModeCycleRequest(
  from command: CLICommand
) -> ListeningModeCycleRequest? {
  guard case let .listeningModeCycle(request) = command else { return nil }
  return request
}
