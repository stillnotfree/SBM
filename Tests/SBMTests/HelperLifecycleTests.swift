import Foundation
import SBMShared
import Testing

@testable import SBM

@MainActor
private final class FakeHelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState
  var stateAfterRegistration: HelperRegistrationState
  private(set) var registrationCount = 0
  private(set) var openedSettingsCount = 0

  init(
    registrationState: HelperRegistrationState,
    stateAfterRegistration: HelperRegistrationState = .enabled
  ) {
    self.registrationState = registrationState
    self.stateAfterRegistration = stateAfterRegistration
  }

  func register() throws {
    registrationCount += 1
    registrationState = stateAfterRegistration
  }

  func unregister() async throws {
    registrationState = .notRegistered
  }

  func openSystemSettings() {
    openedSettingsCount += 1
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
