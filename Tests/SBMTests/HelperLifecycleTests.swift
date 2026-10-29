import Foundation
import SBMShared
import ServiceManagement
import Testing

@testable import SBM

@MainActor
private final class FakeHelperService: HelperServiceManaging {
  private var storedRegistrationState: HelperRegistrationState
  private(set) var registrationStateReadCount = 0
  var onRegistrationStateRead: ((Int) -> Void)?
  var registrationState: HelperRegistrationState {
    get {
      registrationStateReadCount += 1
      onRegistrationStateRead?(registrationStateReadCount)
      return storedRegistrationState
    }
    set { storedRegistrationState = newValue }
  }
  var legacyRegistrationState: HelperRegistrationState = .notRegistered
  var stateAfterRegistration: HelperRegistrationState
  var stateAfterUnregistration: HelperRegistrationState
  private(set) var registrationCount = 0
  private(set) var unregistrationCount = 0
  private(set) var legacyUnregistrationCount = 0
  private(set) var openedSettingsCount = 0
  var transientRegistrationFailures = 0
  var permanentRegistrationError: (any Error)?
  var unregisterGate: SuspendedProbeGate?
  var legacyUnregisterGate: SuspendedProbeGate?
  var legacyUnregisterError: (any Error)?
  var onLegacyUnregister: (() -> Void)?

  init(
    registrationState: HelperRegistrationState,
    stateAfterRegistration: HelperRegistrationState = .enabled,
    stateAfterUnregistration: HelperRegistrationState = .notRegistered
  ) {
    self.storedRegistrationState = registrationState
    self.stateAfterRegistration = stateAfterRegistration
    self.stateAfterUnregistration = stateAfterUnregistration
  }

  func register() throws {
    registrationCount += 1
    if let permanentRegistrationError {
      throw permanentRegistrationError
    }
    if transientRegistrationFailures > 0 {
      transientRegistrationFailures -= 1
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(POSIXErrorCode.EPERM.rawValue)
      )
    }
    registrationState = stateAfterRegistration
  }

  func unregister() async throws {
    unregistrationCount += 1
    if let unregisterGate { await unregisterGate.pause() }
    registrationState = stateAfterUnregistration
  }

  func unregisterLegacy() async throws {
    legacyUnregistrationCount += 1
    onLegacyUnregister?()
    if let legacyUnregisterGate { await legacyUnregisterGate.pause() }
    if let legacyUnregisterError { throw legacyUnregisterError }
    legacyRegistrationState = .notRegistered
  }

  func openSystemSettings() {
    openedSettingsCount += 1
  }
}

@Test @MainActor func helperReplaceChecksCancellationImmediatelyBeforeRegister() async {
  let service = FakeHelperService(registrationState: .notRegistered)
  let task = Task {
    try await HelperLifecycle.replace(service: service) {
      HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  }
  service.onRegistrationStateRead = { readCount in
    if readCount == 2 {
      task.cancel()
    }
  }

  await #expect(throws: CancellationError.self) { _ = try await task.value }
  #expect(service.registrationCount == 0)
  #expect(service.unregistrationCount == 0)
}

@Test @MainActor func helperReplaceDoesNotDelayWhenNativeUnregisterIsUnneeded() async throws {
  for initialState in [HelperRegistrationState.notRegistered, .notFound] {
    let service = FakeHelperService(registrationState: initialState)
    let timing = ManualHelperLifecycleTiming()

    let response = try await HelperLifecycle.replace(
      service: service,
      timing: timing,
      probe: {
        HelperResponse(success: true, coreRunning: false, message: "ready")
      }
    )

    #expect(response.success)
    #expect(service.unregistrationCount == 0)
    #expect(service.registrationCount == 1)
    #expect(timing.elapsed == .zero)
  }
}

@MainActor
private final class ManualHelperLifecycleTiming: HelperLifecycleTiming {
  private let origin = ContinuousClock().now
  private(set) var elapsed = Duration.zero
  var onSleep: (() -> Void)?

  var now: ContinuousClock.Instant {
    origin.advanced(by: elapsed)
  }

  func sleep(for duration: Duration) async throws {
    elapsed = elapsed + duration
    onSleep?()
    try Task.checkCancellation()
  }
}

@MainActor
private func expectReplacementRegistrationFailureToFailFast(_ registrationError: NSError) async {
  let service = FakeHelperService(registrationState: .notRegistered)
  service.permanentRegistrationError = registrationError
  let timing = ManualHelperLifecycleTiming()

  do {
    _ = try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .milliseconds(100),
      pollInterval: .milliseconds(5),
      timing: timing,
      probe: {
        HelperResponse(success: true, coreRunning: false, message: "ready")
      }
    )
    Issue.record("Expected the original registration error to be thrown.")
  } catch {
    let thrownError = error as NSError
    #expect(thrownError.domain == registrationError.domain)
    #expect(thrownError.code == registrationError.code)
  }

  #expect(service.unregistrationCount == 0)
  #expect(service.registrationCount == 1)
  #expect(timing.elapsed == .zero)
}

@MainActor
private final class CancellationTrigger {
  var action: (() -> Void)?

  func fire() {
    action?()
    action = nil
  }
}

@Test @MainActor func helperLifecycleRequiresColdOffProofBeforeUnregistering() async {
  let service = FakeHelperService(
    registrationState: .enabled,
    stateAfterUnregistration: .enabled
  )
  do {
    _ = try await HelperLifecycle.replace(service: service) {
      HelperResponse(success: true, coreRunning: false, message: "ready")
    }
    Issue.record("Expected replacement without a Cold OFF claim to fail.")
  } catch HelperLifecycleFailure.coldOffProofRequired {
    // The native service remains untouched without a verified claim.
  } catch {
    Issue.record("Unexpected replacement error: \(error.localizedDescription)")
  }
  #expect(service.unregistrationCount == 0)
  #expect(service.registrationCount == 0)
}

private actor ProbeAttemptCounter {
  private var count = 0

  func next() -> Int {
    count += 1
    return count
  }

  func value() -> Int {
    count
  }
}

private actor SuspendedProbeGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var enteredWaiter: CheckedContinuation<Void, Never>?
  private var hasEntered = false

  func pause() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      hasEntered = true
      enteredWaiter?.resume()
      enteredWaiter = nil
    }
  }

  func waitUntilEntered() async {
    if hasEntered { return }
    await withCheckedContinuation { enteredWaiter = $0 }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

@Test @MainActor func helperEnableCancellationBeforeRegisterHasNoSideEffect() async {
  let service = FakeHelperService(registrationState: .notRegistered)
  let task = Task {
    try await HelperLifecycle.enable(service: service) {
      HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  }
  task.cancel()

  await #expect(throws: CancellationError.self) { _ = try await task.value }
  #expect(service.registrationCount == 0)
}

@Test @MainActor func helperReplaceCancellationBeforeUnregisterHasNoSideEffect() async {
  let service = FakeHelperService(registrationState: .enabled)
  let task = Task {
    try await HelperLifecycle.replace(service: service) {
      HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  }
  task.cancel()

  await #expect(throws: CancellationError.self) { _ = try await task.value }
  #expect(service.unregistrationCount == 0)
  #expect(service.registrationCount == 0)
}

@Test @MainActor func helperLifecycleRegistersMissingHelperAndWaitsForReadyProbe() async throws {
  let service = FakeHelperService(registrationState: .notRegistered)
  let timing = ManualHelperLifecycleTiming()
  let response = try await HelperLifecycle.enable(
    service: service,
    timeout: .milliseconds(100),
    pollInterval: .milliseconds(5),
    timing: timing
  ) {
    HelperResponse(success: true, coreRunning: false, message: "ready")
  }

  #expect(service.registrationCount == 1)
  #expect(service.registrationState == .enabled)
  #expect(response.success)
}

@Test @MainActor func helperLifecycleDoesNotRegisterAlreadyEnabledHelper() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  let timing = ManualHelperLifecycleTiming()
  _ = try await HelperLifecycle.enable(
    service: service,
    timeout: .milliseconds(100),
    pollInterval: .milliseconds(5),
    timing: timing
  ) {
    HelperResponse(success: true, coreRunning: false, message: "ready")
  }

  #expect(service.registrationCount == 0)
}

@Test @MainActor func helperEnableRechecksRegistrationAfterSuspendedProbe() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  let timing = ManualHelperLifecycleTiming()
  let gate = SuspendedProbeGate()
  let task = Task {
    try await HelperLifecycle.enable(
      service: service,
      timeout: .milliseconds(10),
      pollInterval: .milliseconds(1),
      timing: timing
    ) {
      await gate.pause()
      return HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  }

  await gate.waitUntilEntered()
  service.registrationState = .unknown
  await gate.resume()
  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await task.value
  }
  #expect(timing.elapsed == .milliseconds(10))
}

@Test @MainActor func helperReplaceRechecksRegistrationAfterSuspendedProbe() async throws {
  let service = FakeHelperService(registrationState: .notRegistered)
  let timing = ManualHelperLifecycleTiming()
  let gate = SuspendedProbeGate()
  let task = Task {
    try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .milliseconds(10),
      startupTimeout: .milliseconds(10),
      pollInterval: .milliseconds(1),
      timing: timing
    ) {
      await gate.pause()
      return HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  }

  await gate.waitUntilEntered()
  service.registrationState = .notRegistered
  await gate.resume()
  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await task.value
  }
  #expect(timing.elapsed >= .milliseconds(10))
}

@Test @MainActor func helperLifecycleRejectsPreviousProtocolAndRevisionBeforeReady() async throws {
  let current = HelperResponse(success: true, coreRunning: false, message: "ready")
  for revision in [HelperConstants.helperRevision, HelperConstants.helperRevision - 1] {
    let service = FakeHelperService(registrationState: .enabled)
    let timing = ManualHelperLifecycleTiming()
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
    )
    object["protocolVersion"] = HelperConstants.protocolVersion - 1
    object["helperRevision"] = revision
    let oldResponse = try JSONDecoder().decode(
      HelperResponse.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    await #expect(throws: HelperLifecycleFailure.self) {
      _ = try await HelperLifecycle.enable(
        service: service,
        timeout: .milliseconds(25),
        pollInterval: .milliseconds(1),
        timing: timing
      ) {
        oldResponse
      }
    }
  }
}

@Test @MainActor func helperLifecycleRetriesProbeUntilHelperIsReady() async throws {
  let service = FakeHelperService(registrationState: .notRegistered)
  let attemptCounter = ProbeAttemptCounter()
  let timing = ManualHelperLifecycleTiming()

  let response = try await HelperLifecycle.enable(
    service: service,
    timeout: .milliseconds(200),
    pollInterval: .milliseconds(5),
    timing: timing
  ) {
    let attempt = await attemptCounter.next()
    if attempt < 3 {
      throw CocoaError(.fileReadNoSuchFile)
    }
    return HelperResponse(success: true, coreRunning: false, message: "ready")
  }

  let attemptCount = await attemptCounter.value()
  #expect(attemptCount == 3)
  #expect(response.success)
}

@Test @MainActor func helperLifecycleRejectsPreviousRevisionBeforeReady() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  let timing = ManualHelperLifecycleTiming()
  let current = HelperResponse(success: true, coreRunning: false, message: "ready")
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
  )
  object["helperRevision"] = HelperConstants.helperRevision - 1
  let oldResponse = try JSONDecoder().decode(
    HelperResponse.self,
    from: JSONSerialization.data(withJSONObject: object)
  )
  #expect(oldResponse.helperRevision == HelperConstants.helperRevision - 1)

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.enable(
      service: service,
      timeout: .milliseconds(25),
      pollInterval: .milliseconds(1),
      timing: timing
    ) {
      oldResponse
    }
  }

  #expect(timing.elapsed == .milliseconds(25))
}

@Test @MainActor func helperLifecycleStopsImmediatelyWhenApprovalIsRequired() async {
  let service = FakeHelperService(registrationState: .requiresApproval)
  let timing = ManualHelperLifecycleTiming()

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.enable(
      service: service,
      timeout: .milliseconds(100),
      pollInterval: .milliseconds(5),
      timing: timing
    ) {
      HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  }
  #expect(service.registrationCount == 0)
}

@Test @MainActor func helperLifecycleUsesBoundedStartupTimeout() async {
  let service = FakeHelperService(registrationState: .enabled)
  let timing = ManualHelperLifecycleTiming()

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.enable(
      service: service,
      timeout: .milliseconds(40),
      pollInterval: .milliseconds(5),
      timing: timing
    ) {
      throw CocoaError(.fileReadNoSuchFile)
    }
  }

  #expect(timing.elapsed == .milliseconds(40))
}

@Test @MainActor func helperLifecycleRetriesTransientReplacementRace() async throws {
  let service = FakeHelperService(registrationState: .notRegistered)
  service.transientRegistrationFailures = 3
  let timing = ManualHelperLifecycleTiming()

  let response = try await HelperLifecycle.replace(
    service: service,
    registrationTimeout: .milliseconds(250),
    pollInterval: .milliseconds(5),
    timing: timing,
    probe: {
      HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  )

  #expect(service.unregistrationCount == 0)
  #expect(service.registrationCount == 4)
  #expect(timing.elapsed == .milliseconds(15))
  #expect(response.success)
}

@Test @MainActor
func helperLifecycleRegistrationTimeoutAfterTransientErrorsIsDeterministic() async {
  let service = FakeHelperService(registrationState: .notRegistered)
  service.transientRegistrationFailures = 100
  let timing = ManualHelperLifecycleTiming()

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .milliseconds(20),
      pollInterval: .milliseconds(5),
      timing: timing,
      probe: {
        HelperResponse(success: true, coreRunning: false, message: "ready")
      }
    )
  }

  #expect(service.registrationCount == 4)
  #expect(timing.elapsed == .milliseconds(20))
}

@Test @MainActor func helperLifecycleRetriesStartupTimeoutDuringReplacement() async throws {
  let service = FakeHelperService(registrationState: .notRegistered)
  let attemptCounter = ProbeAttemptCounter()
  let timing = ManualHelperLifecycleTiming()

  let response = try await HelperLifecycle.replace(
    service: service,
    registrationTimeout: .milliseconds(800),
    startupTimeout: .milliseconds(100),
    pollInterval: .milliseconds(5),
    timing: timing,
    probe: {
      let attempt = await attemptCounter.next()
      if attempt == 1 {
        throw CocoaError(.fileReadNoSuchFile)
      }
      return HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  )

  #expect(service.unregistrationCount == 0)
  #expect(await attemptCounter.value() == 2)
  #expect(timing.elapsed == .milliseconds(5))
  #expect(response.success)
}

@Test @MainActor func helperLifecycleDoesNotRetryPermanentReplacementFailure() async {
  let service = FakeHelperService(registrationState: .notRegistered)
  service.permanentRegistrationError = CocoaError(.fileReadCorruptFile)
  let timing = ManualHelperLifecycleTiming()

  await #expect(throws: CocoaError.self) {
    _ = try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .milliseconds(100),
      pollInterval: .milliseconds(5),
      timing: timing
    ) {
      throw CocoaError(.fileReadCorruptFile)
    }
  }

  #expect(service.unregistrationCount == 0)
  #expect(service.registrationCount == 1)
}

@Test @MainActor func helperLifecycleDoesNotRetryUnrelatedDomainEPERM() async {
  await expectReplacementRegistrationFailureToFailFast(
    NSError(domain: "Audit.PermanentError", code: Int(POSIXErrorCode.EPERM.rawValue))
  )
}

@Test @MainActor func helperLifecycleDoesNotInferSMAppServiceEPERMAsTransient() async {
  await expectReplacementRegistrationFailureToFailFast(
    NSError(domain: SMAppServiceErrorDomain, code: Int(POSIXErrorCode.EPERM.rawValue))
  )
}

@Test @MainActor func helperLifecycleDoesNotRetryPOSIXNonEPERM() async {
  await expectReplacementRegistrationFailureToFailFast(
    NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue))
  )
}

@Test @MainActor func helperLifecycleReplacementUsesOneBoundedStartupWindow() async {
  let service = FakeHelperService(registrationState: .notRegistered)
  let timing = ManualHelperLifecycleTiming()

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .milliseconds(100),
      startupTimeout: .milliseconds(40),
      pollInterval: .milliseconds(5),
      timing: timing
    ) {
      throw CocoaError(.fileReadNoSuchFile)
    }
  }

  #expect(timing.elapsed == .milliseconds(40))
  #expect(service.unregistrationCount == 0)
  #expect(service.registrationCount == 1)
}

@Test @MainActor
func helperLifecyclePreservesDifferentReadinessDeadlineFailures() async {
  let enableService = FakeHelperService(registrationState: .enabled)
  let enableTiming = ManualHelperLifecycleTiming()
  enableTiming.onSleep = { enableService.registrationState = .notRegistered }

  do {
    _ = try await HelperLifecycle.enable(
      service: enableService,
      timeout: .milliseconds(2),
      pollInterval: .milliseconds(1),
      timing: enableTiming
    ) {
      throw CocoaError(.fileReadNoSuchFile)
    }
    Issue.record("Expected enable readiness to fail as registrationDidNotFinish.")
  } catch let failure as HelperLifecycleFailure {
    if case .registrationDidNotFinish = failure {
    } else {
      Issue.record("Expected registrationDidNotFinish, got \(failure.localizedDescription).")
    }
  } catch {
    Issue.record("Expected HelperLifecycleFailure, got \(error.localizedDescription).")
  }
  #expect(enableTiming.elapsed == .milliseconds(2))

  let replacementService = FakeHelperService(registrationState: .notRegistered)
  let replacementTiming = ManualHelperLifecycleTiming()
  replacementTiming.onSleep = { replacementService.registrationState = .notRegistered }
  let replacementProbeAttempts = ProbeAttemptCounter()

  do {
    _ = try await HelperLifecycle.replace(
      service: replacementService,
      registrationTimeout: .milliseconds(10),
      startupTimeout: .milliseconds(2),
      pollInterval: .milliseconds(1),
      timing: replacementTiming,
      probe: {
        _ = await replacementProbeAttempts.next()
        throw CocoaError(.fileReadNoSuchFile)
      }
    )
    Issue.record("Expected replacement readiness to fail as startupTimedOut.")
  } catch let failure as HelperLifecycleFailure {
    if case .startupTimedOut = failure {
    } else {
      Issue.record("Expected startupTimedOut, got \(failure.localizedDescription).")
    }
  } catch {
    Issue.record("Expected HelperLifecycleFailure, got \(error.localizedDescription).")
  }
  #expect(replacementTiming.elapsed == .milliseconds(2))
  #expect(replacementService.registrationCount == 1)
  #expect(await replacementProbeAttempts.value() == 1)
}

@Test @MainActor
func helperLifecycleReplacementApprovalDuringReadinessDoesNotWait() async {
  let service = FakeHelperService(registrationState: .notRegistered)
  let timing = ManualHelperLifecycleTiming()
  let probeAttempts = ProbeAttemptCounter()

  do {
    _ = try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .milliseconds(100),
      startupTimeout: .milliseconds(100),
      pollInterval: .milliseconds(5),
      timing: timing,
      probe: {
        _ = await probeAttempts.next()
        await MainActor.run { service.registrationState = .requiresApproval }
        return HelperResponse(success: true, coreRunning: false, message: "ready")
      }
    )
    Issue.record("Expected replacement readiness to fail as approvalRequired.")
  } catch let failure as HelperLifecycleFailure {
    if case .approvalRequired = failure {
    } else {
      Issue.record("Expected approvalRequired, got \(failure.localizedDescription).")
    }
  } catch {
    Issue.record("Expected HelperLifecycleFailure, got \(error.localizedDescription).")
  }

  #expect(await probeAttempts.value() == 1)
  #expect(timing.elapsed == .zero)
}

@Test @MainActor func helperLifecycleRegistrationWaitCancellationPropagates() async {
  let service = FakeHelperService(registrationState: .notRegistered)
  service.transientRegistrationFailures = 100
  let timing = ManualHelperLifecycleTiming()
  let trigger = CancellationTrigger()
  timing.onSleep = { trigger.fire() }

  let task = Task { @MainActor in
    try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .seconds(1),
      pollInterval: .milliseconds(5),
      timing: timing
    ) {
      HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  }
  trigger.action = { task.cancel() }

  await #expect(throws: CancellationError.self) {
    _ = try await task.value
  }
  #expect(service.registrationCount == 1)
  #expect(timing.elapsed == .milliseconds(5))
}

@Test @MainActor func helperLifecycleStartupWaitCancellationPropagates() async {
  let service = FakeHelperService(registrationState: .notRegistered)
  let timing = ManualHelperLifecycleTiming()
  let trigger = CancellationTrigger()
  timing.onSleep = { trigger.fire() }

  let task = Task { @MainActor in
    try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .seconds(1),
      startupTimeout: .seconds(1),
      pollInterval: .milliseconds(5),
      timing: timing
    ) {
      throw CocoaError(.fileReadNoSuchFile)
    }
  }
  trigger.action = { task.cancel() }

  await #expect(throws: CancellationError.self) {
    _ = try await task.value
  }
  #expect(service.registrationCount == 1)
  #expect(timing.elapsed == .milliseconds(5))
}

private func legacyUpgradeBundle(valid: Bool = true) throws -> URL {
  let bundle = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent("SBM-LegacyUpgrade-\(UUID().uuidString).app", isDirectory: true)
  let directory = bundle.appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let marker = valid ? HelperConstants.legacyServiceLabel : "com.example.invalid"
  let sockets = valid ? "" : "<key>Sockets</key><dict/>"
  let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>\(HelperConstants.legacyServiceLabel)</string>
      <key>BundleProgram</key><string>Contents/Resources/SBMHelper</string>
      <key>EnvironmentVariables</key><dict>
        <key>SBM_HELPER_SERVICE_LABEL</key><string>\(marker)</string>
      </dict>
      \(sockets)
    </dict></plist>
    """
  try plist.write(
    to: directory.appendingPathComponent(HelperConstants.legacyDaemonPlistName),
    atomically: true,
    encoding: .utf8
  )
  return bundle
}

private func inertLegacyUpgradeResponse() -> HelperResponse {
  HelperResponse(
    success: true,
    coreRunning: false,
    legacy1115Retired: false,
    message: "inert current helper"
  )
}

private func retiredLegacyUpgradeResponse() -> HelperResponse {
  HelperResponse(
    success: true,
    coreRunning: false,
    legacy1115Retired: true,
    message: "retired"
  )
}

@MainActor
private final class LegacyUpgradeRecorder {
  var events: [String] = []
  var finishCount = 0
}

@Test @MainActor func legacyUpgradeAuthenticatesCurrentHelperBeforeNativeWithdrawalAndFinish()
  async throws
{
  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()
  service.onLegacyUnregister = { recorder.events.append("unregister-legacy") }

  let upgrade = try await HelperLifecycle.upgradeLegacy1115(
    service: service,
    bundleURL: bundle,
    probe: {
      await MainActor.run { recorder.events.append("authenticated-inert-status") }
      return inertLegacyUpgradeResponse()
    },
    finish: {
      await MainActor.run {
        recorder.events.append("finish")
        recorder.finishCount += 1
      }
      return retiredLegacyUpgradeResponse()
    }
  )

  let response = upgrade.response
  #expect(recorder.events == ["authenticated-inert-status", "unregister-legacy", "finish"])
  #expect(upgrade.newlyRetired)
  #expect(service.legacyUnregistrationCount == 1)
  #expect(recorder.finishCount == 1)
  #expect(response.legacy1115Retired == true)
  #expect(!response.coreRunning)
}

@Test @MainActor func legacyUpgradeAcceptsNotFoundWithoutRepeatingWithdrawal() async throws {
  let service = FakeHelperService(registrationState: .notFound)
  service.legacyRegistrationState = .notFound
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()

  let upgrade = try await HelperLifecycle.upgradeLegacy1115(
    service: service,
    bundleURL: bundle,
    probe: { inertLegacyUpgradeResponse() },
    finish: {
      await MainActor.run { recorder.finishCount += 1 }
      return retiredLegacyUpgradeResponse()
    }
  )

  #expect(service.registrationCount == 1)
  #expect(service.legacyUnregistrationCount == 0)
  #expect(recorder.finishCount == 1)
  #expect(upgrade.newlyRetired)
  let response = upgrade.response
  #expect(response.legacy1115Retired == true)
}

@Test @MainActor func completedReceiptDoesNotConflateRetirementWithRuntimeHealth() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .notRegistered
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()

  let upgrade = try await HelperLifecycle.upgradeLegacy1115(
    service: service,
    bundleURL: bundle,
    probe: {
      HelperResponse(
        success: false,
        coreRunning: true,
        legacy1115Retired: true,
        message: "current runtime reports an independent failure"
      )
    },
    finish: {
      await MainActor.run { recorder.finishCount += 1 }
      return retiredLegacyUpgradeResponse()
    }
  )

  let response = upgrade.response
  #expect(!upgrade.newlyRetired)
  #expect(!response.success)
  #expect(response.coreRunning)
  #expect(response.legacy1115Retired == true)
  #expect(service.legacyUnregistrationCount == 0)
  #expect(recorder.finishCount == 0)
  #expect(recorder.events.isEmpty)
}

@Test(arguments: [
  HelperRegistrationState.enabled,
  .unknown,
  .requiresApproval,
])
@MainActor func completedReceiptConflictingWithLegacyRegistrationRefusesUpgrade(
  _ legacyState: HelperRegistrationState
) async throws {
  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = legacyState
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.upgradeLegacy1115(
      service: service,
      bundleURL: bundle,
      probe: { retiredLegacyUpgradeResponse() },
      finish: {
        await MainActor.run { recorder.finishCount += 1 }
        return retiredLegacyUpgradeResponse()
      }
    )
  }

  #expect(service.registrationCount == 0)
  #expect(service.unregistrationCount == 0)
  #expect(service.legacyUnregistrationCount == 0)
  #expect(service.legacyRegistrationState == legacyState)
  #expect(recorder.finishCount == 0)
}

@Test @MainActor func legacyUpgradeRefusesInvalidTombstoneBeforeWithdrawal() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let bundle = try legacyUpgradeBundle(valid: false)
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.upgradeLegacy1115(
      service: service,
      bundleURL: bundle,
      probe: { inertLegacyUpgradeResponse() },
      finish: {
        await MainActor.run { recorder.finishCount += 1 }
        return retiredLegacyUpgradeResponse()
      }
    )
  }

  #expect(service.legacyUnregistrationCount == 0)
  #expect(service.legacyRegistrationState == .enabled)
  #expect(recorder.finishCount == 0)
}

@Test @MainActor func legacyUpgradeWithdrawalFailureDoesNotCallFinishOrClaimAbsence() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  service.legacyUnregisterError = CocoaError(.fileWriteNoPermission)
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()

  await #expect(throws: CocoaError.self) {
    _ = try await HelperLifecycle.upgradeLegacy1115(
      service: service,
      bundleURL: bundle,
      probe: { inertLegacyUpgradeResponse() },
      finish: {
        await MainActor.run { recorder.finishCount += 1 }
        return retiredLegacyUpgradeResponse()
      }
    )
  }

  #expect(service.legacyRegistrationState == .enabled)
  #expect(recorder.finishCount == 0)
}

@Test @MainActor func legacyUpgradeFinishFailurePreservesMessageAfterOnePostWithdrawalCall()
  async throws
{
  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()
  service.onLegacyUnregister = { recorder.events.append("unregister-legacy") }
  let finishMessage = "legacy launcher fence did not clear: pid 951 remains alive"

  do {
    _ = try await HelperLifecycle.upgradeLegacy1115(
      service: service,
      bundleURL: bundle,
      probe: {
        await MainActor.run { recorder.events.append("authenticated-inert-status") }
        return inertLegacyUpgradeResponse()
      },
      finish: {
        await MainActor.run {
          recorder.events.append("finish")
          recorder.finishCount += 1
        }
        return HelperResponse(
          success: false,
          coreRunning: false,
          legacy1115Retired: false,
          message: finishMessage
        )
      }
    )
    Issue.record("Expected Finish failure to be reported.")
  } catch let failure as HelperLifecycleFailure {
    guard case .startupTimedOut(let detail) = failure else {
      Issue.record("Expected startupTimedOut, got \(failure).")
      return
    }
    #expect(detail == finishMessage)
    #expect(failure.localizedDescription.contains(finishMessage))
  } catch {
    Issue.record("Expected HelperLifecycleFailure, got \(error).")
  }

  #expect(recorder.events == ["authenticated-inert-status", "unregister-legacy", "finish"])
  #expect(recorder.finishCount == 1)
  #expect(service.legacyRegistrationState == .notRegistered)
}

@Test @MainActor func legacyUpgradeFinishFailureUsesFallbackForEmptyMessage() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()

  do {
    _ = try await HelperLifecycle.upgradeLegacy1115(
      service: service,
      bundleURL: bundle,
      probe: { inertLegacyUpgradeResponse() },
      finish: {
        await MainActor.run { recorder.finishCount += 1 }
        return HelperResponse(
          success: false,
          coreRunning: false,
          legacy1115Retired: false,
          message: " \n"
        )
      }
    )
    Issue.record("Expected Finish failure to be reported.")
  } catch let failure as HelperLifecycleFailure {
    guard case .startupTimedOut(let detail) = failure else {
      Issue.record("Expected startupTimedOut, got \(failure).")
      return
    }
    #expect(detail == "The helper reported a Finish failure without details.")
  }

  #expect(recorder.finishCount == 1)
  #expect(service.legacyRegistrationState == .notRegistered)
}

@Test @MainActor func legacyUpgradeFinishTupleMismatchDoesNotExposeResponseMessage() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let untrustedMessage = "message from mismatched helper tuple"
  let validResponse = HelperResponse(
    success: false,
    coreRunning: false,
    legacy1115Retired: false,
    message: untrustedMessage
  )
  var responseObject = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(validResponse)) as? [String: Any]
  )
  responseObject["helperRevision"] = HelperConstants.helperRevision - 1
  let mismatchedResponse = try JSONDecoder().decode(
    HelperResponse.self,
    from: JSONSerialization.data(withJSONObject: responseObject)
  )

  do {
    _ = try await HelperLifecycle.upgradeLegacy1115(
      service: service,
      bundleURL: bundle,
      probe: { inertLegacyUpgradeResponse() },
      finish: { mismatchedResponse }
    )
    Issue.record("Expected mismatched Finish tuple to be rejected.")
  } catch let failure as HelperLifecycleFailure {
    guard case .startupTimedOut(let detail) = failure else {
      Issue.record("Expected startupTimedOut, got \(failure).")
      return
    }
    #expect(detail == "The helper tuple changed during legacy retirement.")
    #expect(!failure.localizedDescription.contains(untrustedMessage))
  }
}

@Test @MainActor func legacyUpgradeFinishTransportTimeoutRemainsDistinct() async throws {
  struct FinishTimeout: Error, Equatable {}

  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()
  service.onLegacyUnregister = { recorder.events.append("unregister-legacy") }

  await #expect(throws: FinishTimeout.self) {
    _ = try await HelperLifecycle.upgradeLegacy1115(
      service: service,
      bundleURL: bundle,
      probe: { inertLegacyUpgradeResponse() },
      finish: {
        await MainActor.run {
          recorder.events.append("finish")
          recorder.finishCount += 1
        }
        throw FinishTimeout()
      }
    )
  }

  #expect(recorder.events == ["unregister-legacy", "finish"])
  #expect(recorder.finishCount == 1)
  #expect(service.legacyRegistrationState == .notRegistered)
}

@Test @MainActor func legacyUpgradeCompletesAcceptedFenceAfterCallerCancellation() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let gate = SuspendedProbeGate()
  service.legacyUnregisterGate = gate
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()
  let task = Task { @MainActor in
    try await HelperLifecycle.upgradeLegacy1115(
      service: service,
      bundleURL: bundle,
      probe: { inertLegacyUpgradeResponse() },
      finish: {
        await MainActor.run { recorder.finishCount += 1 }
        return retiredLegacyUpgradeResponse()
      }
    )
  }

  await gate.waitUntilEntered()
  task.cancel()
  await gate.resume()
  let upgrade = try await task.value
  let response = upgrade.response

  #expect(upgrade.newlyRetired)
  #expect(response.legacy1115Retired == true)
  #expect(recorder.finishCount == 1)
}

@Test @MainActor func legacyUpgradeCancellationBeforeWithdrawalLeavesLegacyServiceRegistered()
  async throws
{
  let service = FakeHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let probeGate = SuspendedProbeGate()
  let bundle = try legacyUpgradeBundle()
  defer { try? FileManager.default.removeItem(at: bundle) }
  let recorder = LegacyUpgradeRecorder()
  let task = Task { @MainActor in
    try await HelperLifecycle.upgradeLegacy1115(
      service: service,
      bundleURL: bundle,
      probe: {
        await probeGate.pause()
        return inertLegacyUpgradeResponse()
      },
      finish: {
        await MainActor.run { recorder.finishCount += 1 }
        return retiredLegacyUpgradeResponse()
      }
    )
  }

  await probeGate.waitUntilEntered()
  task.cancel()
  await probeGate.resume()
  await #expect(throws: CancellationError.self) { _ = try await task.value }

  #expect(service.legacyUnregistrationCount == 0)
  #expect(service.legacyRegistrationState == .enabled)
  #expect(recorder.finishCount == 0)
}

@Test @MainActor func legacyUpgradeRejectsMissingOrFalseTerminalReceipt() async throws {
  let incompleteReceipts: [(receipt: Bool?, coreRunning: Bool)] = [
    (nil, false),
    (false, false),
    (true, true),
  ]
  for (receipt, coreRunning) in incompleteReceipts {
    let service = FakeHelperService(registrationState: .enabled)
    let bundle = try legacyUpgradeBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }
    let recorder = LegacyUpgradeRecorder()

    await #expect(throws: HelperLifecycleFailure.self) {
      _ = try await HelperLifecycle.upgradeLegacy1115(
        service: service,
        bundleURL: bundle,
        probe: { inertLegacyUpgradeResponse() },
        finish: {
          await MainActor.run { recorder.finishCount += 1 }
          return HelperResponse(
            success: true,
            coreRunning: coreRunning,
            legacy1115Retired: receipt,
            message: "unproven"
          )
        }
      )
    }
    #expect(recorder.finishCount == 1)
  }
}

@Test func helperResponseRetirementReceiptRemainsOptionalOnTheWire() throws {
  for receipt in [Bool?.none, false, true] {
    let encoded = try JSONEncoder().encode(
      HelperResponse(
        success: true,
        coreRunning: false,
        legacy1115Retired: receipt,
        message: "receipt"
      )
    )
    let decoded = try JSONDecoder().decode(HelperResponse.self, from: encoded)
    #expect(decoded.legacy1115Retired == receipt)
  }

  var previousWire = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(
        HelperResponse(success: true, coreRunning: false, legacy1115Retired: nil, message: "old")
      )
    ) as? [String: Any]
  )
  previousWire.removeValue(forKey: "legacy1115Retired")
  let decodedPreviousWire = try JSONDecoder().decode(
    HelperResponse.self,
    from: JSONSerialization.data(withJSONObject: previousWire)
  )
  #expect(decodedPreviousWire.legacy1115Retired == nil)
}
