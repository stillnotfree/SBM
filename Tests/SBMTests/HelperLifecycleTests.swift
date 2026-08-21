import Foundation
import SBMShared
import Testing

@testable import SBM

@MainActor
private final class FakeHelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState
  var stateAfterRegistration: HelperRegistrationState
  var stateAfterUnregistration: HelperRegistrationState
  private(set) var registrationCount = 0
  private(set) var unregistrationCount = 0
  private(set) var openedSettingsCount = 0
  var transientRegistrationFailures = 0
  var permanentRegistrationError: (any Error)?

  init(
    registrationState: HelperRegistrationState,
    stateAfterRegistration: HelperRegistrationState = .enabled,
    stateAfterUnregistration: HelperRegistrationState = .notRegistered
  ) {
    self.registrationState = registrationState
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
    registrationState = stateAfterUnregistration
  }

  func openSystemSettings() {
    openedSettingsCount += 1
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
private final class CancellationTrigger {
  var action: (() -> Void)?

  func fire() {
    action?()
    action = nil
  }
}

@Test @MainActor func helperLifecycleRegistersReplacementWhenOldStateRemainsEnabled() async throws {
  let service = FakeHelperService(
    registrationState: .enabled,
    stateAfterUnregistration: .enabled
  )
  let timing = ManualHelperLifecycleTiming()

  let response = try await HelperLifecycle.replace(
    service: service,
    registrationTimeout: .milliseconds(100),
    startupTimeout: .milliseconds(100),
    pollInterval: .milliseconds(5),
    timing: timing
  ) {
    HelperResponse(success: true, coreRunning: false, message: "ready")
  }

  #expect(service.unregistrationCount == 1)
  #expect(service.registrationCount == 1)
  #expect(response.success)
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

@Test @MainActor func helperLifecycleRejectsPreviousProtocolBeforeReady() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  let timing = ManualHelperLifecycleTiming()
  let current = HelperResponse(success: true, coreRunning: false, message: "ready")
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
  )
  object["protocolVersion"] = HelperConstants.protocolVersion - 1
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

@Test @MainActor func helperLifecycleRejectsPreviousHelperRevisionBeforeReady() async throws {
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
  let service = FakeHelperService(registrationState: .enabled)
  service.transientRegistrationFailures = 3
  let timing = ManualHelperLifecycleTiming()
  var waitingCount = 0

  let response = try await HelperLifecycle.replace(
    service: service,
    registrationTimeout: .milliseconds(250),
    pollInterval: .milliseconds(5),
    timing: timing,
    waiting: { waitingCount += 1 },
    probe: {
      HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  )

  #expect(service.unregistrationCount == 1)
  #expect(service.registrationCount == 4)
  #expect(waitingCount == 3)
  #expect(response.success)
}

@Test @MainActor
func helperLifecycleRegistrationTimeoutAfterTransientErrorsIsDeterministic() async {
  let service = FakeHelperService(registrationState: .enabled)
  service.transientRegistrationFailures = 100
  let timing = ManualHelperLifecycleTiming()
  var waitingCount = 0

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .milliseconds(20),
      pollInterval: .milliseconds(5),
      timing: timing,
      waiting: { waitingCount += 1 },
      probe: {
        HelperResponse(success: true, coreRunning: false, message: "ready")
      }
    )
  }

  #expect(service.registrationCount == 4)
  #expect(waitingCount == 4)
  #expect(timing.elapsed == .milliseconds(20))
}

@Test @MainActor func helperLifecycleRetriesStartupTimeoutDuringReplacement() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  let attemptCounter = ProbeAttemptCounter()
  let timing = ManualHelperLifecycleTiming()
  var waitingCount = 0

  let response = try await HelperLifecycle.replace(
    service: service,
    registrationTimeout: .milliseconds(800),
    startupTimeout: .milliseconds(100),
    pollInterval: .milliseconds(5),
    timing: timing,
    waiting: { waitingCount += 1 },
    probe: {
      let attempt = await attemptCounter.next()
      if attempt == 1 {
        throw CocoaError(.fileReadNoSuchFile)
      }
      return HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  )

  #expect(service.unregistrationCount == 1)
  #expect(waitingCount == 1)
  #expect(response.success)
}

@Test @MainActor func helperLifecycleDoesNotRetryPermanentReplacementFailure() async {
  let service = FakeHelperService(registrationState: .enabled)
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

  #expect(service.unregistrationCount == 1)
  #expect(service.registrationCount == 1)
}

@Test @MainActor func helperLifecycleReplacementUsesOneBoundedStartupWindow() async {
  let service = FakeHelperService(registrationState: .enabled)
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
  #expect(service.unregistrationCount == 1)
  #expect(service.registrationCount == 1)
}

@Test @MainActor func helperLifecycleRegistrationWaitCancellationPropagates() async {
  let service = FakeHelperService(registrationState: .enabled)
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
  let service = FakeHelperService(registrationState: .enabled)
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
