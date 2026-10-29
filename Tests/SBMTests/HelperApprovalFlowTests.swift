import Foundation
import SBMShared
import Testing

@testable import SBM

@MainActor
private final class ApprovalFlowHelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState
  var legacyRegistrationState: HelperRegistrationState = .notRegistered
  var stateAfterRegistration: HelperRegistrationState
  var stateAfterUnregistration: HelperRegistrationState
  var registrationError: (any Error)?
  var stateAfterRegistrationError: HelperRegistrationState?
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
    if let registrationError {
      if let stateAfterRegistrationError { registrationState = stateAfterRegistrationError }
      throw registrationError
    }
    registrationState = stateAfterRegistration
  }

  func unregister() async throws {
    unregistrationCount += 1
    registrationState = stateAfterUnregistration
  }

  func unregisterLegacy() async throws {
    legacyRegistrationState = .notRegistered
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
  private var statusRevisions: [Int] = []

  init(responses: [HelperResponse]) {
    self.responses = responses
  }

  func send(_ request: HelperRequest, timeout _: Int) throws -> HelperResponse {
    actions.append(request.action)
    guard !responses.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
    let response = responses.count == 1 ? responses[0] : responses.removeFirst()
    if request.action == .status {
      statusRevisions.append(response.helperRevision)
    }
    return response
  }

  func recordedActions() -> [HelperAction] {
    actions
  }

  func recordedStatusRevisions() -> [Int] {
    statusRevisions
  }
}

private actor ApprovalFlowRuntime {
  private struct Pending {
    let request: HelperRequest
    let continuation: CheckedContinuation<HelperResponse, any Error>
  }

  private var pending: [Pending] = []
  private var announced: [HelperRequest] = []
  private var waiters: [CheckedContinuation<HelperRequest, Never>] = []
  private var requests: [HelperRequest] = []

  func send(_ request: HelperRequest) async throws -> HelperResponse {
    requests.append(request)
    if waiters.isEmpty {
      announced.append(request)
    } else {
      waiters.removeFirst().resume(returning: request)
    }
    return try await withCheckedThrowingContinuation { continuation in
      pending.append(Pending(request: request, continuation: continuation))
    }
  }

  func nextRequest() async -> HelperRequest {
    if !announced.isEmpty { return announced.removeFirst() }
    return await withCheckedContinuation { waiters.append($0) }
  }

  func completeNext(_ response: HelperResponse) {
    pending.removeFirst().continuation.resume(returning: response)
  }

  func recordedRequests() -> [HelperRequest] { requests }
}

private func helperResponse(
  revision: Int = HelperConstants.helperRevision,
  legacyRetired: Bool? = true
) throws -> HelperResponse {
  let response = HelperResponse(
    success: true,
    coreRunning: false,
    legacy1115Retired: legacyRetired,
    message: "ready"
  )
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

private func approvalFlowProfile(_ server: String) -> CoreProfile {
  .compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          displayName: server,
          outbound: .shadowsocks(
            ShadowsocksProfile(server: server, port: 443, method: "aes-256-gcm", password: "test")
          )
        )
      ]
    )
  )
}

@MainActor
private func makeApprovalFlowModel(
  service: ApprovalFlowHelperService,
  transport: ApprovalFlowTransport,
  library: ProfileLibrary = .empty,
  userDefaults: UserDefaults = IsolatedTestUserDefaults(),
  runtimeSender: @escaping @Sendable (HelperRequest) async throws -> HelperResponse = { _ in
    HelperResponse(success: true, coreRunning: false, message: "runtime")
  },
  pollDuration: Duration = .milliseconds(80)
) -> AppModel {
  AppModel(
    helperService: service,
    helperLifecycleSender: { request, timeout in
      try await transport.send(request, timeout: timeout)
    },
    helperApprovalPollDuration: pollDuration,
    helperApprovalPollInterval: .milliseconds(5),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    runtimeSender: runtimeSender,
    profileLibraryLoader: { library },
    profileLibrarySaver: { _ in },
    userDefaults: userDefaults,
    performStartup: false
  )
}

@MainActor
private func waitUntil(
  timeout: Duration = .seconds(1),
  _ condition: @escaping () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !(await condition()), clock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(await condition())
}

@Test @MainActor func approvalFlowContinuesFreshRegistrationWithoutRepeatedAction() async throws {
  let service = ApprovalFlowHelperService(
    registrationState: .notRegistered,
    stateAfterRegistration: .requiresApproval
  )
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(
    service: service,
    transport: transport,
    pollDuration: .seconds(2)
  )

  model.enableHelper()
  try await waitUntil { model.helperApprovalPending }
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

@Test @MainActor func approvalFlowDetectsApprovalGrantedBeforeSetupTaskFinishes() async throws {
  let service = ApprovalFlowHelperService(
    registrationState: .notRegistered,
    stateAfterRegistration: .requiresApproval
  )
  service.stateWhenOpeningSettings = .enabled
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport)

  model.enableHelper()
  try await waitUntil { model.helperReachable && !model.helperApprovalPending }

  #expect(service.registrationCount == 1)
  #expect(service.openedSettingsCount == 1)
  #expect(await transport.recordedActions() == [.status])
}

@Test @MainActor func approvalFlowUsesBoundedWaitingWithoutRegistrationLoop() async throws {
  let service = ApprovalFlowHelperService(registrationState: .requiresApproval)
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(
    service: service,
    transport: transport,
    pollDuration: .milliseconds(30)
  )

  model.enableHelper()
  try await waitUntil { model.helperApprovalPending && !model.helperApprovalPolling }

  #expect(service.registrationCount == 0)
  #expect(service.unregistrationCount == 0)
  #expect(service.openedSettingsCount == 1)
  #expect(await transport.recordedActions().isEmpty)
}

@Test @MainActor func approvalRequiredStateComesFromCurrentServiceStatus() async throws {
  let service = ApprovalFlowHelperService(registrationState: .requiresApproval)
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport)

  model.applicationDidBecomeActive()
  #expect(model.helperRequiresApproval)
  #expect(!model.helperApprovalPending)
  #expect(await transport.recordedActions().isEmpty)
}

@Test @MainActor func registerFailureThatRequiresApprovalStartsApprovalFlow() async throws {
  let service = ApprovalFlowHelperService(registrationState: .notRegistered)
  service.registrationError = NSError(domain: NSPOSIXErrorDomain, code: 1)
  service.stateAfterRegistrationError = .requiresApproval
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport)

  model.enableHelper()
  try await waitUntil { model.helperRequiresApproval }

  #expect(model.helperApprovalPending)
  #expect(service.openedSettingsCount == 1)
  #expect(service.registrationCount == 1)
}

@Test @MainActor func staleApprovalFlagDoesNotOverrideCurrentEnabledServiceStatus() async throws {
  let service = ApprovalFlowHelperService(registrationState: .enabled)
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport)
  model.helperRequiresApproval = true

  model.enableHelper()
  try await waitUntil { model.helperReachable && !model.helperApprovalPending }

  #expect(service.openedSettingsCount == 0)
  #expect(service.registrationCount == 0)
  #expect(await transport.recordedActions() == [.status])
}

@Test @MainActor func repairUsesCurrentEnabledServiceStatusWhenApprovalFlagIsStale() async throws {
  let service = ApprovalFlowHelperService(registrationState: .enabled)
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport)
  model.helperEnabled = true
  model.helperRequiresApproval = true

  model.repairHelper()
  try await waitUntil { model.helperReachable && !model.helperSetupInProgress }

  #expect(service.openedSettingsCount == 0)
  #expect(service.registrationCount == 0)
  #expect(service.unregistrationCount == 0)
  #expect(await transport.recordedActions() == [.status])
}

@Test @MainActor func approvalRevocationIsReportedWithoutStartingPendingFlow() async throws {
  let service = ApprovalFlowHelperService(registrationState: .enabled)
  let transport = ApprovalFlowTransport(responses: [try helperResponse()])
  let model = makeApprovalFlowModel(service: service, transport: transport)

  model.applicationDidBecomeActive()
  try await waitUntil { model.helperReachable }
  service.registrationState = .requiresApproval
  model.applicationDidBecomeActive()

  #expect(model.helperRequiresApproval)
  #expect(!model.helperApprovalPending)
}
