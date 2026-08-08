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

@Test @MainActor func helperLifecycleRegistersReplacementWhenOldStateRemainsEnabled() async throws {
  let service = FakeHelperService(
    registrationState: .enabled,
    stateAfterUnregistration: .enabled
  )

  let response = try await HelperLifecycle.replace(
    service: service,
    registrationTimeout: .milliseconds(100),
    startupTimeout: .milliseconds(100),
    pollInterval: .milliseconds(5)
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
  let response = try await HelperLifecycle.enable(
    service: service,
    timeout: .milliseconds(100),
    pollInterval: .milliseconds(5)
  ) {
    HelperResponse(success: true, coreRunning: false, message: "ready")
  }

  #expect(service.registrationCount == 1)
  #expect(service.registrationState == .enabled)
  #expect(response.success)
}

@Test @MainActor func helperLifecycleDoesNotRegisterAlreadyEnabledHelper() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  _ = try await HelperLifecycle.enable(
    service: service,
    timeout: .milliseconds(100),
    pollInterval: .milliseconds(5)
  ) {
    HelperResponse(success: true, coreRunning: false, message: "ready")
  }

  #expect(service.registrationCount == 0)
}

@Test @MainActor func helperLifecycleRetriesProbeUntilHelperIsReady() async throws {
  let service = FakeHelperService(registrationState: .notRegistered)
  let attemptCounter = ProbeAttemptCounter()

  let response = try await HelperLifecycle.enable(
    service: service,
    timeout: .milliseconds(200),
    pollInterval: .milliseconds(5)
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

@Test @MainActor func helperLifecycleStopsImmediatelyWhenApprovalIsRequired() async {
  let service = FakeHelperService(registrationState: .requiresApproval)

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.enable(
      service: service,
      timeout: .milliseconds(100),
      pollInterval: .milliseconds(5)
    ) {
      HelperResponse(success: true, coreRunning: false, message: "ready")
    }
  }
  #expect(service.registrationCount == 0)
}

@Test @MainActor func helperLifecycleUsesBoundedStartupTimeout() async {
  let service = FakeHelperService(registrationState: .enabled)
  let clock = ContinuousClock()
  let started = clock.now

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.enable(
      service: service,
      timeout: .milliseconds(40),
      pollInterval: .milliseconds(5)
    ) {
      throw CocoaError(.fileReadNoSuchFile)
    }
  }

  #expect(started.duration(to: clock.now) < .seconds(1))
}

@Test @MainActor func helperLifecycleRetriesTransientReplacementRace() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  service.transientRegistrationFailures = 3
  var waitingCount = 0

  let response = try await HelperLifecycle.replace(
    service: service,
    registrationTimeout: .milliseconds(250),
    pollInterval: .milliseconds(5),
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

@Test @MainActor func helperLifecycleRetriesStartupTimeoutDuringReplacement() async throws {
  let service = FakeHelperService(registrationState: .enabled)
  let attemptCounter = ProbeAttemptCounter()
  var waitingCount = 0

  let response = try await HelperLifecycle.replace(
    service: service,
    registrationTimeout: .milliseconds(800),
    startupTimeout: .milliseconds(100),
    pollInterval: .milliseconds(5),
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

  await #expect(throws: CocoaError.self) {
    _ = try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .milliseconds(100),
      pollInterval: .milliseconds(5)
    ) {
      throw CocoaError(.fileReadCorruptFile)
    }
  }

  #expect(service.unregistrationCount == 1)
  #expect(service.registrationCount == 1)
}

@Test @MainActor func helperLifecycleReplacementUsesOneBoundedStartupWindow() async {
  let service = FakeHelperService(registrationState: .enabled)
  let clock = ContinuousClock()
  let started = clock.now

  await #expect(throws: HelperLifecycleFailure.self) {
    _ = try await HelperLifecycle.replace(
      service: service,
      registrationTimeout: .milliseconds(100),
      startupTimeout: .milliseconds(40),
      pollInterval: .milliseconds(5)
    ) {
      throw CocoaError(.fileReadNoSuchFile)
    }
  }

  #expect(started.duration(to: clock.now) < .seconds(1))
  #expect(service.unregistrationCount == 1)
  #expect(service.registrationCount == 1)
}
