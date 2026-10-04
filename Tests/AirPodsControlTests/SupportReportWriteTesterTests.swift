import Darwin
import Foundation
import Testing

@testable import AirPodsControlCore


private func supportWriteTestSignalHandler(_: Int32) {}

// These tests share process-wide signal handlers and the C monitor singleton.
@Suite("Support report write tester", .serialized)
struct SupportReportWriteTesterTests {
  @Test("Drops only an already-current first probe from listening-mode targets")
  func listeningModeTargetsDropFirstOnlyWhenInitialIsFirst() {
    let cases: [(ListeningMode, [ListeningMode])] = [
      (.noiseCancellation, [.adaptive, .transparency, .off]),
      (.transparency, [.noiseCancellation, .adaptive, .transparency, .off]),
    ]
    for (initial, expected) in cases {
      let plan = SupportReportWriteTestPlan.make(
        device: FakeCompatibleAudioDevice(
          listeningModes: Array(ListeningMode.allCases),
          listeningMode: initial,
          conversationAwarenessSupported: false
        )
      )
      #expect(
        plan.listeningModeTargets == expected,
        "initial \(initial.rawValue) keeps later probes, including Transparency"
      )
      guard case .willTest = plan.listeningModes else {
        Issue.record("advertised modes with a setter plan as willTest")
        return
      }
    }
  }

  @Test
  func writeTestPlanEncodesSkipVersusTest() {
    let both = SupportReportWriteTestPlan.make(
      device: FakeCompatibleAudioDevice(
        listeningModes: Array(ListeningMode.allCases),
        listeningMode: .noiseCancellation,
        conversationAwarenessSupported: true,
        conversationAwarenessEnabled: false
      )
    )
    guard case .willTest = both.listeningModes else {
      Issue.record("full capabilities plan listening-mode tests")
      return
    }
    guard case .willTest = both.conversationAwareness else {
      Issue.record("supported Awareness plans a toggle")
      return
    }

    let noAwareness = SupportReportWriteTestPlan.make(
      device: FakeCompatibleAudioDevice(
        listeningModes: Array(ListeningMode.allCases),
        listeningMode: .transparency,
        conversationAwarenessSupported: false
      )
    )
    switch noAwareness.conversationAwareness {
    case let .skipped(reason):
      #expect(reason == "not supported", "unsupported Awareness is a skipped plan")
    case .willTest:
      Issue.record("unsupported Awareness must not plan a toggle")
    }
  }

  @Test("Verifies and restores all supported capabilities")
  func writeTesterVerifiesAndRestores() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false
    )
    let results = SupportReportWriteTester.run(device: device)
    let modeRun = results.listeningModes.testRun
    let awarenessRun = results.conversationAwareness.testRun

    #expect(
      modeRun?.tests.map(\.mode)
        == [.adaptive, .transparency, .off],
      "noninitial modes are tested strongest-first, with Off last"
    )
    #expect(
      modeRun?.tests.allSatisfy(\.write.verified) == true,
      "an applying device verifies every advertised mode"
    )
    #expect(
      modeRun?.restoration.attempted?.mode == .noiseCancellation
        && modeRun?.restoration.attempted?.write.verified == true,
      "the initial mode is verified separately during restoration"
    )
    #expect(modeRun?.restored == true, "the last test restores the mode")
    #expect(
      device.currentListeningMode() == .noiseCancellation,
      "the device ends in its initial listening mode"
    )
    #expect(
      awarenessRun?.toggle.verified == true
        && awarenessRun?.restoration.attempted?.verified == true,
      "the Conversation Awareness round trip verifies"
    )
    #expect(
      awarenessRun?.restored == true,
      "Conversation Awareness ends in its initial state"
    )
    #expect(
      device.conversationAwarenessState() == false,
      "the device ends with its initial Conversation Awareness value"
    )
    #expect(results.fullyRestored, "a fully applying device reports full restoration")
    #expect(device.listeningModeSetCount == 4, "each advertised mode is written once")
    #expect(
      device.conversationAwarenessSetCount == 2,
      "Conversation Awareness is written exactly twice"
    )
  }

  @Test("Continues after a no-op write")
  func writeTesterContinuesAfterNoOp() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false,
      appliesConversationAwarenessWrite: false
    )
    device.listeningModeWriteOverride = {
      $0 == .off ? .transparency : $0
    }
    let results = SupportReportWriteTester.run(device: device)
    let modeRun = results.listeningModes.testRun

    #expect(modeRun?.tests.count == 2, "a no-op does not skip later mode tests")
    let transparencyTest = modeRun?.tests.first { $0.mode == .transparency }
    #expect(
      transparencyTest?.write.verified == true
        && transparencyTest?.targetAlreadyCurrent == false,
      "Transparency is probed before Off, so the fallback does not hide it"
    )
    let offTest = modeRun?.tests.first { $0.mode == .off }
    #expect(offTest?.write.verified == false, "an unapplied off write is not verified")
    #expect(
      offTest?.write.observed == .transparency,
      "the Off no-op records the observed Transparency fallback"
    )
    #expect(
      modeRun?.tests.allSatisfy(\.write.setterAccepted) == true,
      "accepted no-op writes do not stop the test sequence"
    )
    #expect(
      modeRun?.restored == true,
      "later tests restore the initial listening mode"
    )
    #expect(
      modeRun?.restoration.attempted?.mode == .noiseCancellation,
      "restoration is recorded separately from exploratory tests"
    )
    #expect(
      device.settleIntervals.count == 3,
      "an accepted no-op is still held before testing the next mode"
    )
    #expect(
      results.conversationAwareness.testRun?.toggle.verified == false,
      "an unapplied Conversation Awareness toggle is not verified"
    )
    #expect(
      device.conversationAwarenessSetCount == 1,
      "an unchanged Conversation Awareness state needs no restore write"
    )
    #expect(
      results.conversationAwareness.testRun?.restored == true,
      "an unchanged Conversation Awareness state counts as restored"
    )
  }

  @Test("Restores after Off fallback when readback still reports the initial mode")
  func writeTesterRestoresAfterInferredOffFallbackMatchingInitial() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: false
    )
    // Hardware accepted Off and bounced to Transparency, but the settled
    // readback still reports the pre-Off Noise Cancellation mode. That is
    // the same mismatch resolveListeningModeWrite infers as Transparency.
    device.listeningModeWriteOverride = { target in
      target == .off ? .noiseCancellation : target
    }
    let results = SupportReportWriteTester.run(device: device)
    let modeRun = results.listeningModes.testRun
    let offTest = modeRun?.tests.first { $0.mode == .off }

    #expect(
      offTest?.inferredOffFallback == true
        && offTest?.write.observed == .transparency
        && modeRun?.restoration.attempted?.mode == .noiseCancellation
        && modeRun?.restoration.attempted?.write.verified == true,
      "inferred Transparency is not treated as already-restored Noise Cancellation"
    )
    #expect(
      device.currentListeningMode() == .noiseCancellation,
      "the device ends in its initial listening mode"
    )
  }

  @Test("Records targets that are already current")
  func writeTesterRecordsAlreadyCurrentTargets() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: false
    )
    // Adaptive is probed immediately before Transparency. This fixture is a
    // defensive already-current case, not an observed AirPods fallback: Off
    // now runs last, so a real Off→Transparency bounce has no successor probe.
    device.listeningModeWriteOverride = {
      $0 == .adaptive ? .transparency : $0
    }
    let results = SupportReportWriteTester.run(device: device)
    let modeRun = results.listeningModes.testRun

    let transparencyTest = modeRun?.tests.first { $0.mode == .transparency }
    #expect(
      transparencyTest?.targetAlreadyCurrent == true,
      "a target reached by an earlier fallback is recorded as already current"
    )
    #expect(
      transparencyTest?.write.verified == true,
      "the matching readback of an already-current target is still recorded"
    )
    #expect(
      modeRun?.tests.first { $0.mode == .off }?.targetAlreadyCurrent == false,
      "a genuine transition is not flagged as already current"
    )
    #expect(
      modeRun?.restoration.attempted?.targetAlreadyCurrent == false,
      "restoration only runs from a different state, so it is never flagged"
    )
  }

  @Test("Verifies Transparency before an Off fallback")
  func writeTesterVerifiesTransparencyWhenOffFallsBack() {
    let startedInTransparency = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
      listeningMode: .transparency,
      conversationAwarenessSupported: false
    )
    startedInTransparency.listeningModeWriteOverride = {
      $0 == .off ? .transparency : $0
    }
    let snapshot = SupportReportSnapshot.capture(device: startedInTransparency)
    let fromTransparency = SupportReportWriteTester.run(device: startedInTransparency)
    let fromTransparencyRun = fromTransparency.listeningModes.testRun

    #expect(
      fromTransparencyRun?.tests.map(\.mode)
        == [.noiseCancellation, .adaptive, .transparency, .off],
      "the initial mode stays in the probe list when it is not first"
    )
    let transparencyFromStart = fromTransparencyRun?.tests.first {
      $0.mode == .transparency
    }
    #expect(
      transparencyFromStart?.targetAlreadyCurrent == false
        && transparencyFromStart?.write.verified == true,
      "Transparency is probed from Adaptive before Off can bounce back to it"
    )
    #expect(
      fromTransparencyRun?.tests.first { $0.mode == .off }?.write.verified == false,
      "the disabled Off write remains a no-op"
    )
    #expect(
      fromTransparencyRun?.restoration.stateNeverChanged == true
        && fromTransparencyRun?.restored == true,
      "Off fallback returns to the captured initial mode without a restore write"
    )

    let document = SupportReportDocument.make(
      snapshot: snapshot,
      writeTests: fromTransparency
    )
    #expect(
      document.summary.inconclusive == 0 && document.summary.verified == 3,
      "Off fallback from Transparency does not yield an inconclusive verdict"
    )
    #expect(
      !document.terminalOutput.contains("INCONCLUSIVE"),
      "the terminal report does not present Transparency as inconclusive"
    )
    #expect(
      !document.githubIssueDraft.report.contains("captured initial mode"),
      "a demonstrated initial mode is not an unnamed skipped restoration row"
    )

    let startedInNoiseCancellation = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: false
    )
    startedInNoiseCancellation.listeningModeWriteOverride = {
      $0 == .off ? .transparency : $0
    }
    let ncSnapshot = SupportReportSnapshot.capture(device: startedInNoiseCancellation)
    let fromNoiseCancellation = SupportReportWriteTester.run(
      device: startedInNoiseCancellation
    )
    let fromNoiseCancellationRun = fromNoiseCancellation.listeningModes.testRun
    let transparencyAfterOff = fromNoiseCancellationRun?.tests.first {
      $0.mode == .transparency
    }
    #expect(
      fromNoiseCancellationRun?.tests.map(\.mode)
        == [.adaptive, .transparency, .off],
      "the already-current first probe is deferred to restoration"
    )
    #expect(
      transparencyAfterOff?.targetAlreadyCurrent == false
        && transparencyAfterOff?.write.verified == true,
      "Transparency is still a real transition when Off is last"
    )
    #expect(
      fromNoiseCancellationRun?.restoration.attempted?.mode == .noiseCancellation
        && fromNoiseCancellationRun?.restoration.attempted?.write.verified == true,
      "restoration still demonstrates the captured initial mode"
    )
    let ncDocument = SupportReportDocument.make(
      snapshot: ncSnapshot,
      writeTests: fromNoiseCancellation
    )
    #expect(
      ncDocument.githubIssueDraft.report.contains(
        "`listening-mode set noise-cancellation` (restore): verified"
      ),
      "restoration of the initial mode is labeled restore"
    )
    #expect(
      ncDocument.terminalOutput.contains("VERIFIED · restore"),
      "the terminal marks the restoration write"
    )
  }

  @Test("Labels restoration separately when the initial mode was also probed")
  func writeTesterLabelsRestoreWhenInitialModeWasAlsoProbed() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
      listeningMode: .transparency,
      conversationAwarenessSupported: false
    )
    let snapshot = SupportReportSnapshot.capture(device: device)
    let results = SupportReportWriteTester.run(device: device)
    let document = SupportReportDocument.make(snapshot: snapshot, writeTests: results)
    let issueReport = document.githubIssueDraft.report

    #expect(
      device.listeningModeSetCount == 5,
      "Off applying after a mid-sequence initial probe still restores that mode"
    )
    #expect(
      issueReport.contains("`listening-mode set transparency`: verified"),
      "the exploratory Transparency probe stays a named verified row"
    )
    #expect(
      issueReport.contains("`listening-mode set transparency` (restore): verified"),
      "the restoration write is labeled so it is not a second unlabeled probe"
    )
    #expect(
      document.terminalOutput.contains("VERIFIED · restore"),
      "the terminal distinguishes the restoration write"
    )
  }

  @Test("Avoids claiming the state never changed after completed transitions")
  func writeTesterDoesNotClaimStateNeverChangedAfterTransitions() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
      listeningMode: .transparency,
      conversationAwarenessSupported: false
    )
    device.listeningModeWriteOverride = { target in
      switch target {
      case .off: return .transparency
      case .transparency: return device.listeningMode
      default: return target
      }
    }
    let snapshot = SupportReportSnapshot.capture(device: device)
    let results = SupportReportWriteTester.run(device: device)
    let issueReport = SupportReportDocument.make(
      snapshot: snapshot,
      writeTests: results
    ).githubIssueDraft.report

    #expect(
      results.listeningModes.testRun?.restoration.stateNeverChanged == true,
      "Off fallback returns to Transparency without a restore write"
    )
    #expect(
      issueReport.contains("`listening-mode set noise-cancellation`: verified"),
      "earlier probes still record real transitions"
    )
    #expect(
      issueReport.contains(
        "skipped (already at initial mode; not demonstrated)"
      ),
      "the unnamed row does not claim the device never left the initial mode"
    )
  }

  @Test("Verifies settled transitions before returning")
  func writeTesterVerifiesSettledTransitions() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.transparency, .adaptive],
      listeningMode: .transparency,
      appliesListeningModeWrite: false,
      conversationAwarenessSupported: false
    )
    device.settleEffect = {
      device.listeningMode = device.lastListeningModeTarget
    }

    let results = SupportReportWriteTester.run(device: device)
    let modeRun = results.listeningModes.testRun

    #expect(
      modeRun?.tests.map(\.mode) == [.adaptive, .transparency]
        && modeRun?.tests.allSatisfy(\.write.verified) == true,
      "each mode is verified from its post-hold state"
    )
    #expect(
      modeRun?.restoration.stateNeverChanged == true,
      "the initial mode is already restored by its exploratory probe"
    )
    #expect(
      device.settleIntervals.count == 2,
      "the tester waits for both advertised-mode holds"
    )
    #expect(
      modeRun?.finalMode == .transparency,
      "results return only after the initial mode is restored"
    )
  }

  @Test("Stops after a setter error and restores the initial mode")
  func writeTesterStopsOnSetterErrorAndRestores() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.transparency, .adaptive, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: false
    )
    device.listeningModeSetterAccepted = { $0 != .transparency }

    let results = SupportReportWriteTester.run(device: device)
    let modeRun = results.listeningModes.testRun

    #expect(
      modeRun?.tests.map(\.mode) == [.adaptive, .transparency],
      "a setter error skips remaining exploratory writes"
    )
    #expect(
      modeRun?.stoppedAfterSetterError == true,
      "the exploratory setter error is recorded separately from restoration"
    )
    #expect(
      device.listeningModeSetCount == 3,
      "a setter error is followed only by one restoration attempt"
    )
    #expect(
      device.settleIntervals.count == 3,
      "the accepted test, rejected test, and restoration are all held"
    )
    #expect(
      modeRun?.restored == true,
      "the best-effort restoration returns to the initial mode"
    )
    #expect(
      modeRun?.restoration.attempted?.mode == .noiseCancellation,
      "restoration is recorded after the interrupted tests"
    )
  }

  @Test("Reports a Conversation Awareness restoration setter error")
  func writeTesterReportsAwarenessRestorationSetterError() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [],
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false
    )
    device.conversationAwarenessSetterAccepted = { target in target }

    let results = SupportReportWriteTester.run(device: device)

    #expect(
      results.conversationAwareness.testRun?.restored == false,
      "a rejected Conversation Awareness restoration is not treated as restored"
    )
    #expect(
      results.conversationAwareness.testRun?.toggle.verified == true,
      "a failed restoration does not erase the toggle that did verify"
    )
    #expect(
      results.conversationAwareness.testRun?.finalState == true
        && !results.fullyRestored,
      "the failed restoration retains the final state and fails the run"
    )
  }

  @Test("Skips unreadable and unexposed capabilities")
  func writeTesterSkipsUnreadableAndUnexposedCapabilities() {
    let unreadable = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency],
      listeningMode: nil,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: nil
    )
    let unreadableResults = SupportReportWriteTester.run(device: unreadable)
    #expect(
      unreadableResults.listeningModes.skipReason != nil,
      "an unreadable initial mode skips the mode tests"
    )
    #expect(
      unreadableResults.conversationAwareness.skipReason != nil,
      "an unreadable Conversation Awareness state skips its test"
    )
    #expect(unreadable.listeningModeSetCount == 0, "no mode write happens blind")
    #expect(
      unreadable.conversationAwarenessSetCount == 0,
      "no Conversation Awareness write happens blind"
    )
    #expect(
      unreadableResults.fullyRestored,
      "skipped capabilities never fail restoration"
    )

    let unexposed = FakeCompatibleAudioDevice(
      conversationAwarenessSupported: false
    )
    unexposed.exposesListeningModeSetter = false
    let unexposedResults = SupportReportWriteTester.run(device: unexposed)
    #expect(
      unexposedResults.listeningModes.skipReason != nil,
      "a missing mode setter skips the mode tests"
    )
    #expect(
      unexposedResults.conversationAwareness.skipReason != nil,
      "unsupported Conversation Awareness skips its test"
    )
    #expect(unexposed.listeningModeSetCount == 0, "no write reaches a missing setter")

    let unadvertised = FakeCompatibleAudioDevice(
      listeningModes: [.adaptive, .noiseCancellation],
      listeningMode: .transparency,
      conversationAwarenessSupported: false
    )
    let unadvertisedResults = SupportReportWriteTester.run(device: unadvertised)
    #expect(
      unadvertisedResults.listeningModes.skipReason != nil,
      "an unadvertised initial mode makes the write-test plan unsafe"
    )
    #expect(
      unadvertised.listeningModeSetCount == 0,
      "no mode is written when the initial mode cannot be restored safely"
    )
  }

  @Test("Reports a failed listening mode restoration")
  func writeTesterReportsFailedRestore() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.transparency, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false
    )
    // Every write lands on transparency, so the final restore write misses.
    device.listeningModeWriteOverride = { _ in .transparency }
    let results = SupportReportWriteTester.run(device: device)
    let modeRun = results.listeningModes.testRun

    #expect(
      modeRun?.restored == false,
      "a restore write that lands elsewhere reports a failed restoration"
    )
    #expect(
      modeRun?.finalMode == .transparency,
      "the final listening mode is recorded for the report"
    )
    #expect(!results.fullyRestored, "a failed mode restore fails full restoration")
    #expect(
      results.conversationAwareness.testRun?.restored == true,
      "the Conversation Awareness restore is judged independently"
    )
  }

  @Test("Restores after a real signal during a mode hold")
  func writeTesterRestoresAfterRealSignal() {
    supportReportSignalMonitorLock.lock()
    defer { supportReportSignalMonitorLock.unlock() }

    let device = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false
    )
    device.settleEffect = {
      if device.listeningModeSetCount == 1 {
        #expect(
          kill(getpid(), SIGINT) == 0,
          "the real signal can be delivered during the mode hold"
        )
      }
    }

    var notices: [String] = []
    let results = SupportReportWriteTester.runInterruptibly(
      plan: SupportReportWriteTestPlan.make(device: device),
      device: device,
      writeError: { notices.append($0) }
    )

    #expect(
      results.interruptedBySignal == SIGINT,
      "the production monitor propagates a real signal into the runner"
    )
    #expect(notices.count == 1, "the real-signal path announces the interruption exactly once")
    #expect(
      results.listeningModes.testRun?.tests.map(\.mode) == [.adaptive],
      "a real signal stops later exploratory mode writes"
    )
    #expect(
      results.listeningModes.testRun?.restoration.attempted?.mode == .noiseCancellation,
      "the real-signal path restores the captured listening mode"
    )
    #expect(
      device.listeningMode == .noiseCancellation,
      "the fake device is restored before the real-signal path returns"
    )
    #expect(
      device.conversationAwarenessSetCount == 0,
      "the real-signal path does not begin the later awareness test"
    )
  }

  @Test("Restores the complete prior signal action")
  func terminationMonitorRestoresCompleteSignalAction() {
    supportReportSignalMonitorLock.lock()
    defer { supportReportSignalMonitorLock.unlock() }

    var customAction = sigaction()
    customAction.__sigaction_u.__sa_handler = supportWriteTestSignalHandler
    sigemptyset(&customAction.sa_mask)
    sigaddset(&customAction.sa_mask, SIGUSR1)
    customAction.sa_flags = SA_NODEFER

    var originalAction = sigaction()
    #expect(
      sigaction(SIGTERM, &customAction, &originalAction) == 0,
      "the test can install a custom SIGTERM action"
    )
    defer {
      var action = originalAction
      _ = sigaction(SIGTERM, &action, nil)
    }

    guard let monitor = SupportReportTerminationMonitor() else {
      Issue.record("the production signal monitor installs over a custom action")
      return
    }
    _ = monitor.disarm()

    var restoredAction = sigaction()
    #expect(
      sigaction(SIGTERM, nil, &restoredAction) == 0,
      "the restored SIGTERM action can be inspected"
    )
    #expect(
      restoredAction.sa_flags == customAction.sa_flags,
      "the monitor restores the prior sigaction flags"
    )
    #expect(
      sigismember(&restoredAction.sa_mask, SIGUSR1) == 1,
      "the monitor restores the prior sigaction mask"
    )
  }

  @Test("Restores Conversation Awareness after interruption")
  func writeTesterRestoresAwarenessAfterInterruption() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [],
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false
    )
    var caughtSignal: Int32?
    device.conversationAwarenessSetterAccepted = { target in
      if target {
        caughtSignal = SIGTERM
      }
      return true
    }

    let results = SupportReportWriteTester.run(
      plan: SupportReportWriteTestPlan.make(device: device),
      device: device,
      interruptionSignal: { caughtSignal },
      writeError: { _ in }
    )

    #expect(
      results.interruptedBySignal == SIGTERM,
      "an interruption during the Conversation Awareness toggle is retained"
    )
    #expect(
      device.conversationAwarenessSetCount == 2,
      "Conversation Awareness restoration still runs after interruption"
    )
    #expect(
      device.conversationAwarenessState() == false,
      "Conversation Awareness returns to its captured initial state"
    )
    #expect(
      results.conversationAwareness.testRun?.restored == true,
      "the interrupted round trip reports successful restoration"
    )
  }

  @Test("Does not start Awareness after a boundary interruption")
  func writeTesterStopsBeforeAwarenessAfterBoundaryInterruption() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [],
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false
    )
    let plan = SupportReportWriteTestPlan.make(device: device)
    var caughtSignal: Int32?
    device.conversationAwarenessStateEffect = {
      caughtSignal = SIGINT
    }

    let results = SupportReportWriteTester.run(
      plan: plan,
      device: device,
      interruptionSignal: { caughtSignal },
      writeError: { _ in }
    )

    #expect(
      device.conversationAwarenessSetCount == 0,
      "an interruption observed at the CA boundary prevents a new toggle"
    )
    #expect(
      results.interruptedBySignal == SIGINT,
      "the CA-boundary interruption is retained"
    )
    #expect(
      results.conversationAwareness.skipReason != nil,
      "the interrupted CA test is reported as skipped"
    )
  }

  @Test("Announces interruption once before restoration")
  func writeTesterAnnouncesInterruptionOnceBeforeRestoration() {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false
    )
    var caughtSignal: Int32?
    var notices: [String] = []
    var noticesBeforeRestorationWrite: Int?
    device.settleEffect = {
      if device.listeningModeSetCount == 1 {
        caughtSignal = SIGINT
      }
    }
    // The initial mode is written only by the restoration attempt, so this
    // hook observes the notice count at the moment restoration begins.
    device.listeningModeSetterAccepted = { target in
      if target == .noiseCancellation {
        noticesBeforeRestorationWrite = notices.count
      }
      return true
    }

    let results = SupportReportWriteTester.run(
      plan: SupportReportWriteTestPlan.make(device: device),
      device: device,
      interruptionSignal: { caughtSignal },
      writeError: { notices.append($0) }
    )

    #expect(
      results.interruptedBySignal == SIGINT,
      "the announced interruption is also retained in the results"
    )
    #expect(
      notices.count == 1,
      "the interrupt notice is written exactly once"
    )
    #expect(
      noticesBeforeRestorationWrite == 1,
      "the interrupt notice is already written when the restoration write begins"
    )
    #expect(
      results.conversationAwareness.skipReason != nil,
      "later checkpoints observe the same interruption without repeating the notice"
    )
  }
}
