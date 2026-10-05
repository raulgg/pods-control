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

  @Test("Names a repeated cycle mode and a bad token")
  func namesRepeatedCycleModeAndBadToken() {
    expectExplainedParse(
      ["lm", "cycle", "--modes", "trans,transparency"],
      CLIParseError(reason: .repeatedMode(.transparency)),
      "listening mode \"transparency\" is repeated in --modes; list each mode once"
    )
    expectExplainedParse(
      ["lm", "cycle", "--modes", "trans,transparency", "--explicit-order"],
      CLIParseError(reason: .repeatedMode(.transparency)),
      "listening mode \"transparency\" is repeated in --modes; list each mode once"
    )
    expectExplainedParse(
      ["lm", "cycle", "--modes", "anc,anc"],
      CLIParseError(reason: .repeatedMode(.noiseCancellation)),
      "listening mode \"noise-cancellation\" is repeated in --modes; list each mode once"
    )
    expectExplainedParse(
      ["lm", "cycle", "--modes", "adaptive,transparency,adaptive"],
      CLIParseError(reason: .repeatedMode(.adaptive)),
      "listening mode \"adaptive\" is repeated in --modes; list each mode once"
    )
    expectExplainedParse(
      ["lm", "cycle", "--modes", "anc,anc,trans"],
      CLIParseError(reason: .repeatedMode(.noiseCancellation)),
      "listening mode \"noise-cancellation\" is repeated in --modes; list each mode once"
    )
    expectExplainedParse(
      ["lm", "cycle", "--modes", "transparency"],
      CLIParseError(reason: .singleCycleMode),
      "--modes lists one distinct mode; cycle needs at least two"
    )
    expectExplainedParse(
      ["lm", "cycle", "--explicit-order", "--modes", "transparency"],
      CLIParseError(reason: .singleCycleMode),
      "--modes lists one distinct mode; cycle needs at least two"
    )
    expectExplainedParse(
      ["lm", "cycle", "--modes", ",transparency,adaptive"],
      CLIParseError(reason: .emptyCycleToken),
      "empty listening-mode token in --modes"
    )
    expectExplainedParse(
      ["lm", "cycle", "--modes", ""],
      CLIParseError(reason: .emptyCycleToken),
      "empty listening-mode token in --modes"
    )
    expectExplainedParse(
      ["lm", "cycle", "--modes", "transparency,normal"],
      CLIParseError(reason: .unknownListeningMode(token: "normal")),
      "unknown listening mode \"normal\"; expected off, transparency, adaptive, noise-cancellation"
    )
    expectExplainedParse(
      ["lm", "cycle", "--modes", "transparency,normal,transparency"],
      CLIParseError(reason: .unknownListeningMode(token: "normal")),
      "unknown listening mode \"normal\"; expected off, transparency, adaptive, noise-cancellation"
    )
    expectExplainedParse(
      ["lm", "set", "normal"],
      CLIParseError(reason: .unknownListeningMode(token: "normal")),
      "unknown listening mode \"normal\"; expected off, transparency, adaptive, noise-cancellation"
    )
    expectExplainedParse(
      ["ca", "set", "maybe"],
      CLIParseError(reason: .unknownConversationAwarenessState(token: "maybe")),
      "unknown conversation-awareness state \"maybe\"; expected on or off"
    )
  }

  @Test("Leaves other malformed arguments unexplained")
  func leavesOtherMalformedArgumentsUnexplained() {
    #expect(CLIParseError().stderrLine == nil, "a reason-less parse error has no stderr line")
    expectUnexplainedParse(["lm", "cycle", "--modes"])
    expectUnexplainedParse(["lm", "set"])
    expectUnexplainedParse(["ca", "set"])
    expectUnexplainedParse(["lm", "cycle", "extra"])
  }

  @Test("Quotes a token that contains a quote or a line break")
  func quotesTokenWithQuoteOrLineBreak() {
    let mode = CLIParseError(reason: .unknownListeningMode(token: "a\"b\nc"))
    #expect(
      mode.stderrLine
        == "unknown listening mode \"a\\\"b\\nc\"; expected off, transparency, adaptive, noise-cancellation"
    )
    let crlf = CLIParseError(reason: .unknownListeningMode(token: "a\r\nb"))
    #expect(
      crlf.stderrLine
        == "unknown listening mode \"a\\r\\nb\"; expected off, transparency, adaptive, noise-cancellation"
    )
    let separator = CLIParseError(
      reason: .unknownListeningMode(token: "a\u{2028}b")
    )
    #expect(
      separator.stderrLine
        == "unknown listening mode \"a\\u{2028}b\"; expected off, transparency, adaptive, noise-cancellation"
    )
    let slash = CLIParseError(reason: .unknownListeningMode(token: "a\\b"))
    #expect(
      slash.stderrLine
        == "unknown listening mode \"a\\\\b\"; expected off, transparency, adaptive, noise-cancellation"
    )
    let state = CLIParseError(
      reason: .unknownConversationAwarenessState(token: "on\"off")
    )
    #expect(
      state.stderrLine
        == "unknown conversation-awareness state \"on\\\"off\"; expected on or off"
    )
  }

  @Test("Keeps bad-args plain and JSON output unchanged")
  func keepsBadArgsOutputUnchanged() {
    #expect(
      CLIOutputSerializer.plain("bad-args") == "bad-args\n",
      "plain bad-args stays the terminal-reason token"
    )
    #expect(
      CLIOutputSerializer.json(TerminalReason.badArgs.addingEnvelope(to: [:]))
        == "{\"error\":\"bad-args\",\"result\":\"error\"}\n",
      "JSON bad-args stays the existing error envelope"
    )
    let sentence =
      "listening mode \"adaptive\" is repeated in --modes; list each mode once"
    #expect(
      CLIOutputSerializer.json(
        TerminalReason.badArgs.addingEnvelope(to: ["reason": .string(sentence)])
      )
        == "{\"error\":\"bad-args\",\"reason\":\"listening mode \\\"adaptive\\\" is repeated in --modes; list each mode once\",\"result\":\"error\"}\n",
      "JSON bad-args includes the parse reason"
    )
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

private func expectExplainedParse(
  _ arguments: [String],
  _ expected: CLIParseError,
  _ stderr: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(throws: expected, sourceLocation: sourceLocation) {
    _ = try parseInvocation(arguments)
  }
  #expect(
    expected.stderrLine == stderr,
    "stderr names the parse mistake",
    sourceLocation: sourceLocation
  )
}

private func expectUnexplainedParse(
  _ arguments: [String],
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(throws: CLIParseError(), sourceLocation: sourceLocation) {
    _ = try parseInvocation(arguments)
  }
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
