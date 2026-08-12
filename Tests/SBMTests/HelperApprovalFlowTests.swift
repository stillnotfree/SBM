import Foundation
import SBMShared
import Testing

@testable import SBM

@MainActor
private final class ApprovalFlowHelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState
  var stateAfterRegistration: HelperRegistrationState
  var stateAfterUnregistration: HelperRegistrationState
  var registrationError: (any Error)?
  var stateWhenOpeningSettings: HelperRegistrationState?
  private(set) var registrationCount = 0
  private(set) var unregistrationCount = 0
  private(set) var openedSettingsCount = 0

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
    if let registrationError { throw registrationError }
    registrationState = stateAfterRegistration
  }

  func unregister() async throws {
    unregistrationCount += 1
    registrationState = stateAfterUnregistration
  }

  func openSystemSettings() {
    openedSettingsCount += 1
    if let stateWhenOpeningSettings {
      registrationState = stateWhenOpeningSettings
    }
  }
}

private actor ApprovalFlowTransport {
  private var responses: [HelperResponse]
  private var actions: [HelperAction] = []

  init(responses: [HelperResponse]) {
    self.responses = responses
  }

  func send(_ request: HelperRequest, timeout _: Int) throws -> HelperResponse {
    actions.append(request.action)
    guard !responses.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
    if responses.count == 1 { return responses[0] }
    return responses.removeFirst()
  }

  func recordedActions() -> [HelperAction] {
    actions
  }
}

private func helperResponse(revision: Int = HelperConstants.helperRevision) throws -> HelperResponse
{
  let response = HelperResponse(success: true, coreRunning: false, message: "ready")
  let encoded = try JSONEncoder().encode(response)
  guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
    throw CocoaError(.coderInvalidValue)
  }
  object["helperRevision"] = revision
  return try JSONDecoder().decode(
    HelperResponse.self,
    from: JSONSerialization.data(withJSONObject: object)
  )
}

@MainActor
private func makeApprovalFlowModel(
  service: ApprovalFlowHelperService,
  transport: ApprovalFlowTransport,
  defaults: UserDefaults,
  pollDuration: Duration = .milliseconds(80)
) -> AppModel {
  AppModel(
    helperService: service,
    helperLifecycleSender: { request, timeout in
      try await transport.send(request, timeout: timeout)
    },
    helperApprovalDefaults: defaults,
    helperApprovalPollDuration: pollDuration,
    helperApprovalPollInterval: .milliseconds(5),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    profileLibraryLoader: { .empty },
    profileLibrarySaver: { _ in },
    performStartup: false
  )
}

@MainActor
private func waitUntil(
  timeout: Duration = .seconds(1),
  _ condition: @escaping () -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !condition(), clock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(condition())
}

private func isolatedDefaults() throws -> (UserDefaults, String) {
  let name = "HelperApprovalFlowTests.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: name) else {
    throw CocoaError(.fileWriteUnknown)
  }
  defaults.removePersistentDomain(forName: name)
  return (defaults, name)
}

@Test @MainActor func approvalFlowContinuesFreshRegistrationWithoutRepeatedAction() async throws {
  let (defaults, name) = try isolatedDefaults()
  defer { defaults.removePersistentDomain(forName: name) }
  let service = ApprovalFlowHelperService(
    registrationState: .notRegistered,
    stateAfterRegistration: .requiresApproval
  )
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport, defaults: defaults)

  model.enableHelper()
  try await waitUntil { model.helperApprovalPending }
  #expect(model.helperStatus == "Waiting for approval in System Settings…")
  #expect(service.registrationCount == 1)
  #expect(service.openedSettingsCount == 1)

  model.enableHelper()
  #expect(service.registrationCount == 1)
  #expect(service.openedSettingsCount == 1)

  service.registrationState = .enabled
  model.applicationDidBecomeActive()
  try await waitUntil { model.helperReachable && !model.helperApprovalPending }

  #expect(service.unregistrationCount == 0)
  #expect(await transport.recordedActions() == [.status])
}

@Test @MainActor func approvalFlowAutomaticallyReplacesMismatchedHelper() async throws {
  let (defaults, name) = try isolatedDefaults()
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set(true, forKey: HelperApprovalPersistence.pendingKey)
  let service = ApprovalFlowHelperService(registrationState: .enabled)
  let transport = ApprovalFlowTransport(
    responses: [
      try helperResponse(revision: HelperConstants.helperRevision - 1),
      try helperResponse(),
      try helperResponse(),
    ]
  )
  let model = makeApprovalFlowModel(service: service, transport: transport, defaults: defaults)

  model.applicationDidBecomeActive()
  try await waitUntil { model.helperReachable && !model.helperApprovalPending }

  #expect(service.unregistrationCount == 1)
  #expect(service.registrationCount == 1)
  #expect(await transport.recordedActions() == [.status, .stop, .status])
}

@Test @MainActor func approvalFlowDetectsApprovalGrantedBeforeSetupTaskFinishes() async throws {
  let (defaults, name) = try isolatedDefaults()
  defer { defaults.removePersistentDomain(forName: name) }
  let service = ApprovalFlowHelperService(
    registrationState: .notRegistered,
    stateAfterRegistration: .requiresApproval
  )
  service.stateWhenOpeningSettings = .enabled
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport, defaults: defaults)

  model.enableHelper()
  try await waitUntil { model.helperReachable && !model.helperApprovalPending }

  #expect(service.registrationCount == 1)
  #expect(service.openedSettingsCount == 1)
  #expect(await transport.recordedActions() == [.status])
}

@Test @MainActor func approvalFlowUsesBoundedWaitingWithoutRegistrationLoop() async throws {
  let (defaults, name) = try isolatedDefaults()
  defer { defaults.removePersistentDomain(forName: name) }
  let service = ApprovalFlowHelperService(registrationState: .requiresApproval)
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(
    service: service,
    transport: transport,
    defaults: defaults,
    pollDuration: .milliseconds(30)
  )

  model.enableHelper()
  try await waitUntil { model.helperApprovalPending && !model.helperApprovalPolling }

  #expect(service.registrationCount == 0)
  #expect(service.unregistrationCount == 0)
  #expect(service.openedSettingsCount == 1)
  #expect(await transport.recordedActions().isEmpty)
}

@Test @MainActor func approvalFlowResumesPersistedIntentAfterRestart() async throws {
  let (defaults, name) = try isolatedDefaults()
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set(true, forKey: HelperApprovalPersistence.pendingKey)
  let service = ApprovalFlowHelperService(registrationState: .enabled)
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport, defaults: defaults)

  #expect(model.helperApprovalPending)
  model.applicationDidBecomeActive()
  try await waitUntil { model.helperReachable && !model.helperApprovalPending }

  #expect(service.openedSettingsCount == 0)
  #expect(service.registrationCount == 0)
  #expect(service.unregistrationCount == 0)
  #expect(await transport.recordedActions() == [.status])
}

@Test @MainActor func approvalFlowResumesUnregisteredIntentOnceAfterRestart() async throws {
  let (defaults, name) = try isolatedDefaults()
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set(true, forKey: HelperApprovalPersistence.pendingKey)
  let service = ApprovalFlowHelperService(registrationState: .notRegistered)
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport, defaults: defaults)

  model.applicationDidBecomeActive()
  try await waitUntil { model.helperReachable && !model.helperApprovalPending }

  #expect(service.registrationCount == 1)
  #expect(service.unregistrationCount == 0)
  #expect(await transport.recordedActions() == [.status])
}

@Test @MainActor func restartedWaitingFlowCanReopenSystemSettings() async throws {
  let (defaults, name) = try isolatedDefaults()
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set(true, forKey: HelperApprovalPersistence.pendingKey)
  let service = ApprovalFlowHelperService(registrationState: .requiresApproval)
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport, defaults: defaults)

  model.applicationDidBecomeActive()
  model.enableHelper()

  #expect(service.openedSettingsCount == 1)
  #expect(model.helperApprovalPending)
}

@Test @MainActor func approvalRevocationIsReportedWithoutStartingPendingFlow() async throws {
  let (defaults, name) = try isolatedDefaults()
  defer { defaults.removePersistentDomain(forName: name) }
  let service = ApprovalFlowHelperService(registrationState: .enabled)
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport, defaults: defaults)

  model.applicationDidBecomeActive()
  try await waitUntil { model.helperReachable }
  service.registrationState = .requiresApproval
  model.applicationDidBecomeActive()

  #expect(model.helperRequiresApproval)
  #expect(!model.helperApprovalPending)
  #expect(model.helperStatus == "Approval required")
}

@Test @MainActor func approvalFlowReplacementFailureEndsWithOneRecoveryAction() async throws {
  let (defaults, name) = try isolatedDefaults()
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set(true, forKey: HelperApprovalPersistence.pendingKey)
  let service = ApprovalFlowHelperService(registrationState: .enabled)
  service.registrationError = CocoaError(.fileWriteNoPermission)
  let transport = ApprovalFlowTransport(
    responses: [
      try helperResponse(revision: HelperConstants.helperRevision - 1),
      try helperResponse(),
    ]
  )
  let model = makeApprovalFlowModel(service: service, transport: transport, defaults: defaults)

  model.applicationDidBecomeActive()
  try await waitUntil { model.lastError != nil && !model.helperApprovalPending }

  #expect(model.lastError?.contains("Background helper repair failed") == true)
  #expect(service.registrationCount == 1)
  #expect(service.unregistrationCount == 1)
}
