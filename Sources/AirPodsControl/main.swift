// pods-control — control AirPods listening mode and Conversation Awareness
// from a scriptable command-line interface.
//
// Compiled with swiftc (no Xcode needed) + a tiny C bypass dylib. On launch it
// re-execs itself once with avbypass.dylib inserted so the in-process
// entitlement gate for the shared system audio context is satisfied — the same
// technique NoiseBuddy uses. The executable and companion dylib are ad-hoc
// signed.

import Darwin
import Foundation
import BypassProbe

func resolvedExecutablePath() -> String? {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  var size = UInt32(buffer.count)

  if _NSGetExecutablePath(&buffer, &size) != 0 {
    buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
  }

  let unresolved = String(cString: buffer)
  return URL(fileURLWithPath: unresolved)
    .resolvingSymlinksInPath()
    .standardizedFileURL.path
}

func ensureBypass(logger: DebugLogger) {
  if ProcessInfo.processInfo.environment["AIRPODS_CONTROL_BYPASSED"] != nil {
    if AirPodsControlBypassIsActive() {
      logger.debug("bypass.status", "active")
    } else {
      logger.warning("bypass.status", "inactive")
    }
    return
  }

  guard let executable = resolvedExecutablePath() else {
    logger.warning("bypass.status", "executable-path-unavailable")
    return
  }

  let dylib = (executable as NSString).deletingLastPathComponent + "/avbypass.dylib"
  guard FileManager.default.fileExists(atPath: dylib) else {
    logger.warning("bypass.status", "dylib-missing")
    logger.debug("bypass.dylib", dylib)
    return
  }

  setenv("DYLD_INSERT_LIBRARIES", dylib, 1)
  setenv("AIRPODS_CONTROL_BYPASSED", "1", 1)
  logger.info("bypass.status", "reexec")
  logger.debug("bypass.dylib", dylib)

  var cargs = CommandLine.arguments.map { strdup($0) }
  cargs.append(nil)
  execv(executable, &cargs)

  logger.warning("bypass.status", "reexec-failed")
  logger.debug("bypass.errno", errno)
}

func finish(
  plain: String,
  terminalReason: TerminalReason = .success,
  jsonOutput: Bool,
  data: [String: JSONValue] = [:]
) -> Never {
  let output = jsonOutput
    ? CLIOutputSerializer.json(terminalReason.addingEnvelope(to: data))
    : CLIOutputSerializer.plain(plain)
  print(output, terminator: "")
  exit(terminalReason.exitCode)
}

func finish(_ outcome: CommandOutcome, jsonOutput: Bool) -> Never {
  finish(
    plain: outcome.plain,
    terminalReason: outcome.terminalReason,
    jsonOutput: jsonOutput,
    data: outcome.data
  )
}

func accessPolicy(for command: CLICommand) -> PrivateAudioAccessPolicy {
  switch command {
  case .status:
    return .status
  case .supportReport:
    return .supportReport
  case .version, .listeningModeGet, .listeningModeList, .listeningModeSet,
       .listeningModeCycle, .conversationAwarenessGet, .conversationAwarenessSet:
    return .operational
  }
}

func bootstrapAndResolveAudioDevices(
  named requestedName: String?,
  policy: DeviceSelectionPolicy,
  logger: DebugLogger,
  accessPolicy: PrivateAudioAccessPolicy
) -> CommandDeviceResolution {
  ensureBypass(logger: logger)

  switch accessPolicy {
  case .operational:
    guard let endpoints = PrivateAudioDiscovery.systemOperationalEndpoints(
      logger: logger
    ) else { return .failed(.unavailable) }
    return .devices(
      from: PrivateAudioController(endpoints: endpoints, logger: logger)
        .resolveDevices(named: requestedName, policy: policy)
    )

  case .status:
    let activeOutputContext = PrivateAudioDiscovery.systemStatusOutputContext(
      logger: logger
    )
    let controllerResult = IOBluetoothStatusController.create(
      logger: logger,
      activeOutputContext: activeOutputContext
    )
    let controller: IOBluetoothStatusController
    switch controllerResult {
    case let .success(value): controller = value
    case .unavailable: return .failed(.unavailable)
    case .readError: return .failed(.readError)
    }
    return .statusDevices(
      from: controller.resolveDevices(named: requestedName, policy: policy)
    )

  case .supportReport:
    // Preserve the name-free, plural-only support-report discovery contract.
    // In particular, do not query outputDevice or private device identifiers.
    guard let devices = PrivateAudioDiscovery.systemOutputDevices(logger: logger) else {
      return .failed(.unavailable)
    }
    return .devices(
      from: PrivateAudioController(
        rawDevices: devices,
        logger: logger,
        includeDeviceNames: false
      ).resolveDevices(named: requestedName, policy: policy)
    )
  }
}

func bootstrapAndResolveListeningMode(
  command: ListeningModeCommand,
  invocation: CLIInvocation,
  logger: DebugLogger
) -> ListeningModeResolution {
  ensureBypass(logger: logger)

  let outputContext = PrivateAudioDiscovery.systemStatusOutputContext(logger: logger)
  let avDevices: [PrivateAudioDevice]
  if let outputContext {
    let endpoints = PrivateAudioDiscovery.contextEndpoints(
      from: outputContext,
      logger: logger
    )
    switch PrivateAudioController(endpoints: endpoints, logger: logger)
      .resolveDevices(named: nil, policy: .allOrExact)
    {
    case let .selected(devices): avDevices = devices
    case .noDevice, .ambiguousDevice: avDevices = []
    }
  } else {
    avDevices = []
  }

  return ListeningModeBootstrap.resolve(
    command: command,
    named: invocation.requestedDeviceName,
    avDevices: avDevices,
    logger: logger,
    chooseAmbiguous: { names in
      // Ineligible prompts and explicit declines both map to unavailable, which
      // resolve reports as ambiguous-device.
      let outcome = InteractiveDeviceChooser.choose(
        deviceNames: names,
        eligibility: .init(
          inputIsTerminal: isatty(STDIN_FILENO) == 1,
          errorIsTerminal: isatty(STDERR_FILENO) == 1,
          jsonOutput: invocation.jsonOutput
        ),
        readResponse: { readLine() },
        writeError: { text in
          fputs(text, stderr)
          fflush(stderr)
        }
      )
      switch outcome {
      case let .selected(index): return .selected(index: index)
      case .declined: return .unavailable
      }
    },
    loadHAL: {
      ListeningModeBootstrap.HALInventory(
        IOBluetoothStatusController.create(
          logger: logger,
          activeOutputContext: outputContext,
          readStatusListeningMode: false,
          readStatusInEarPlacement: false,
          allowOffCache: PersistentListeningModeAllowOffCache.systemDefault()
        )
      )
    }
  )
}

let rawArgs = Array(CommandLine.arguments.dropFirst())

if rawArgs.isEmpty {
  finish(plain: globalHelp, jsonOutput: false)
}
if let help = helpText(for: rawArgs) {
  finish(plain: help, jsonOutput: false)
}

let preliminaryJSON = rawArgs.contains("--json")
let preliminaryDebug = rawArgs.contains("--debug")
let preliminaryLogger = DebugLogger(enabled: preliminaryDebug)

let invocation: CLIInvocation
do {
  invocation = try parseInvocation(rawArgs)
} catch {
  let line = (error as? CLIParseError)?.stderrLine
  if let line {
    fputs(line + "\n", stderr)
    fflush(stderr)
  }
  preliminaryLogger.warning("cli.parse", "bad-args")
  finish(
    plain: "bad-args",
    terminalReason: .badArgs,
    jsonOutput: preliminaryJSON,
    data: line.map { ["reason": JSONValue.string($0)] } ?? [:]
  )
}

let supportReport = SupportReportCommand(
  requestWriteTestConsent: { plan in
    SupportReportInteraction.requestWriteTestConsent(plan: plan)
  },
  runWriteTests: { plan, device in
    let progress = SupportReportProgressDisplay(
      plan: plan,
      debugEnabled: invocation.debugEnabled
    )
    return SupportReportWriteTester.runInterruptibly(
      plan: plan,
      device: device,
      progress: { progress?.receive($0) }
    )
  }
)

let outcome: CommandOutcome
if ListeningModeCommand(invocation.command) != nil {
  outcome = CommandExecution.executeListeningMode(
    invocation,
    resolveSession: { command, _, logger in
      bootstrapAndResolveListeningMode(
        command: command,
        invocation: invocation,
        logger: logger
      )
    }
  )
} else {
  outcome = CommandExecution.execute(
    invocation,
    resolveDevices: { requestedName, policy, logger in
      bootstrapAndResolveAudioDevices(
        named: requestedName,
        policy: policy,
        logger: logger,
        accessPolicy: accessPolicy(for: invocation.command)
      )
    },
    supportReport: supportReport
  )
}
if case .supportReport = invocation.command {
  exit(SupportReportInteraction.present(outcome: outcome).exitCode)
}
finish(outcome, jsonOutput: invocation.jsonOutput)
