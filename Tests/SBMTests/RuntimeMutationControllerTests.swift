import Foundation
import SBMShared
import Testing

@testable import SBM

@MainActor
private final class RegisteredRuntimeTestHelper: HelperServiceManaging {
  var registrationState: HelperRegistrationState = .enabled
  var legacyRegistrationState: HelperRegistrationState = .notRegistered

  func register() throws {}
  func unregister() async throws {}
  func unregisterLegacy() async throws {}
  func openSystemSettings() {}
}

private actor DelayedHelperSender {
  private var requests: [HelperRequest] = []
  private var continuations: [CheckedContinuation<HelperResponse, Never>] = []

  func send(_ request: HelperRequest) async -> HelperResponse {
    requests.append(request)
    return await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func requestCount() -> Int { requests.count }

  func recordedRequests() -> [HelperRequest] { requests }

  func completeNext(with response: HelperResponse) {
    continuations.removeFirst().resume(returning: response)
  }
}

private actor RoutingValidationGate {
  private var profiles: [CoreProfile] = []
  private var continuations: [CheckedContinuation<HelperResponse, Never>] = []

  func validate(_ profile: CoreProfile) async -> HelperResponse {
    profiles.append(profile)
    return await withCheckedContinuation { continuations.append($0) }
  }

  func submittedProfiles() -> [CoreProfile] { profiles }

  func count() -> Int { profiles.count }

  func completeNext() {
    continuations.removeFirst().resume(
      returning: HelperResponse(success: true, coreRunning: false, message: "valid")
    )
  }
}

private actor LatencyRequestRecorder {
  private var nodes: [ProxyNodeID?] = []

  func send(_ node: ProxyNodeID?) -> HelperResponse {
    nodes.append(node)
    return HelperResponse(
      success: true,
      coreRunning: true,
      delays: node.map { [NodeDelay(node: $0, milliseconds: 20)] } ?? [],
      message: "latency"
    )
  }

  func requestCount() -> Int { nodes.count }
}

private func waitForRequestCount(
  _ expected: Int,
  sender: DelayedHelperSender
) async {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(2))
  while clock.now < deadline {
    if await sender.requestCount() >= expected { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(
    await sender.requestCount() >= expected, "runtime request count did not reach \(expected)")
}

@Test @MainActor
func runtimeMutationCompletesInFlightBeforeStartingLatestPendingRequest() async {
  let sender = DelayedHelperSender()
  let controller = RuntimeMutationController { request in
    await sender.send(request)
  }
  var completedCurrentness: [Bool] = []

  controller.submit(HelperRequest(action: .stop, stopReason: .userDisconnect)) { outcome in
    if case .success = outcome.result { completedCurrentness.append(outcome.isCurrent) }
  }
  await waitForRequestCount(1, sender: sender)
  controller.submit(HelperRequest(action: .start)) { outcome in
    if case .success = outcome.result { completedCurrentness.append(outcome.isCurrent) }
  }

  #expect((await sender.recordedRequests()).map(\.action) == [.stop])
  await sender.completeNext(
    with: HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  await waitForRequestCount(2, sender: sender)
  #expect((await sender.recordedRequests()).map(\.action) == [.stop, .start])
  #expect(completedCurrentness == [false])

  await sender.completeNext(
    with: HelperResponse(success: true, coreRunning: true, message: "started")
  )
  await waitForModel { !(controller.isApplying) }
  #expect(completedCurrentness == [false, true])
}

@Test @MainActor
func runtimeMutationCoalescesPendingRequestsToLatest() async {
  let sender = DelayedHelperSender()
  let controller = RuntimeMutationController { request in
    await sender.send(request)
  }

  controller.submit(HelperRequest(action: .stop)) { _ in }
  await waitForRequestCount(1, sender: sender)
  controller.submit(HelperRequest(action: .setMode, mode: .global)) { _ in }
  controller.submit(
    HelperRequest(action: .setNode, node: ProxyNodeID(rawValue: "latest-node"))
  ) { _ in }

  await sender.completeNext(
    with: HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  await waitForRequestCount(2, sender: sender)
  let requests = await sender.recordedRequests()
  #expect(requests.map(\.action) == [.stop, .setNode])
  #expect(requests[1].node == ProxyNodeID(rawValue: "latest-node"))

  await sender.completeNext(
    with: HelperResponse(success: true, coreRunning: true, message: "latest applied")
  )
  await waitForModel { !(controller.isApplying) }
}

@Test @MainActor
func desiredRunningTracksExplicitConnectAndDisconnectIntent() {
  let controller = RuntimeMutationController { _ in
    HelperResponse(success: true, coreRunning: false, message: "unused")
  }

  #expect(controller.desiredRunning == nil)
  controller.desiredRunning = true
  #expect(controller.desiredRunning == true)
  controller.desiredRunning = false
  #expect(controller.desiredRunning == false)
}

@Test @MainActor
func staleRuntimeIPv6ReplyCannotOverwriteNewerDesiredPolicy() async {
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "IPv6 race",
    payload: .compatibility(
      VPNProfile(connections: [runtimeTestConnection(id: .auto, server: "active.example.test")])
    )
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profileID, ipv6Enabled: true
    ),
    sender: sender
  )

  model.setCoreEnabled(true)
  await waitForRequestCount(1, sender: sender)
  model.setIPv6Enabled(false)

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      activeIPv6Enabled: true,
      message: "stale active IPv6"
    )
  )
  await waitForRequestCount(2, sender: sender)
  #expect(model.activeIPv6Enabled == nil)
  #expect((await sender.recordedRequests())[1].ipv6Enabled == false)

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      activeIPv6Enabled: false,
      message: "latest active IPv6"
    )
  )
  await waitForModel { !(model.runtimeApplyStatus == .applying) }
  #expect(model.activeIPv6Enabled == false)
}

@Test @MainActor
func replacedPendingMutationReceivesSupersededCompletion() async {
  let sender = DelayedHelperSender()
  let controller = RuntimeMutationController { request in
    await sender.send(request)
  }
  var pendingWasSuperseded = false

  controller.submit(HelperRequest(action: .stop)) { _ in }
  await waitForRequestCount(1, sender: sender)
  controller.submit(HelperRequest(action: .setMode, mode: .global)) { outcome in
    if case .failure(let error) = outcome.result,
      error is RuntimeMutationControllerFailure
    {
      pendingWasSuperseded = !outcome.isCurrent
    }
  }
  controller.submit(
    HelperRequest(action: .setNode, node: ProxyNodeID(rawValue: "current-node"))
  ) { _ in }

  #expect(pendingWasSuperseded)
  await sender.completeNext(
    with: HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  await waitForRequestCount(2, sender: sender)
  #expect((await sender.recordedRequests()).map(\.action) == [.stop, .setNode])
  await sender.completeNext(
    with: HelperResponse(success: true, coreRunning: true, message: "current")
  )
  await waitForModel { !(controller.isApplying) }
}

@Test @MainActor func routingRemovalDuringDelayedStartIsAppliedAfterStart() async throws {
  let profileID = UUID()
  let policy = RoutingPolicy(
    configuration: Data(
      #"{"route":{"rules":[{"domain_suffix":[".ru"],"action":"route","outbound":"direct"}]}}"#
        .utf8
    )
  )
  let connection = ManagedConnection(
    id: ProxyNodeID(rawValue: "node-test"),
    outbound: .vless(
      VLESSProfile(
        server: "203.0.113.10",
        port: 443,
        uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
        serverName: "example.test",
        fingerprint: "chrome",
        publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
        shortID: "",
        displayName: "Test"
      )
    )
  )
  let profile = ManagedProfile(
    id: profileID,
    name: "Test",
    payload: .compatibility(
      VPNProfile(connections: [connection], routingPolicy: policy)
    )
  )
  let library = ProfileLibrary(profiles: [profile], selectedProfileID: profileID)
  let sender = DelayedHelperSender()
  var savedLibraries: [ProfileLibrary] = []
  let model = AppModel(
    runtimeSender: { request in await sender.send(request) },
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    profileLibraryLoader: { library },
    profileLibrarySaver: { savedLibraries.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision

  model.setCoreEnabled(true)
  await waitForRequestCount(1, sender: sender)
  model.clearRoutingPolicy()

  #expect(model.runtimeApplyStatus == .applying)
  await waitForModel { model.subscriptionStatus == "Routing policy applying" }
  #expect(savedLibraries.last?.profiles.first?.payload?.routingPolicyForTesting == nil)
  #expect(model.routingPolicyMutationStatus.state == .applying)

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      message: "active-a"
    )
  )
  await waitForRequestCount(2, sender: sender)
  #expect(await sender.requestCount() == 2)
  let requests = await sender.recordedRequests()
  #expect(requests.map(\.action) == [.start, .start])
  guard requests.count == 2 else { return }
  guard case .compatibility(let secondProfile) = requests[1].profile else {
    Issue.record("The converged request did not contain a compatibility profile.")
    return
  }
  #expect(secondProfile.routingPolicy == nil)

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      message: "active-b"
    )
  )
  await waitForModel { !(model.runtimeApplyStatus == .applying) }

  #expect(model.runtimeApplyStatus == .active)
  #expect(model.subscriptionStatus == "Routing policy removed and active")
}

@Test @MainActor func routingPolicyRemovalR1InvalidatesAndRefreshesInspector() async {
  let profileID = UUID()
  let policy = routingPolicyFixture()
  let profile = ManagedProfile(
    id: profileID,
    name: "Inspector",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(
            id: ProxyNodeID(rawValue: "node-inspector"), server: "inspector.example.test")
        ],
        routingPolicy: policy
      )
    )
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    sender: sender
  )
  model.routingInspectorInput = "8.8.8.8"
  model.inspectRouting()
  let oldSnapshot = model.routingInspectorState.snapshot

  #expect(oldSnapshot != nil)
  #expect(model.routingInspectorOutput.contains("DIRECT"))

  model.clearRoutingPolicy()

  #expect(model.routingInspectorState == .idle)
  #expect(model.routingInspectorState.snapshot == nil)
  await waitForRoutingModel { model.routingPolicyMutationStatus.state == .saved }
  #expect(model.profiles.first?.payload?.routingPolicyForTesting == nil)

  model.inspectRouting()
  #expect(model.routingInspectorOutput.contains("PROXY"))
  #expect(!model.routingInspectorOutput.contains("DIRECT"))
  #expect(await sender.requestCount() == 0)
}

@Test @MainActor func routingPolicyRemovalR2KeepsOtherFieldsAndUsesCommonCommit() async {
  let profileID = UUID()
  let nodeID = ProxyNodeID(rawValue: "node-preserved")
  let connection = runtimeTestConnection(id: nodeID, server: "preserved.example.test")
  let group = ProxyNodeGroup(id: "group-preserved", name: "Preserved", nodes: [nodeID])
  let applicationRule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .direct
  )
  let websiteRule = WebsiteRoutingRule(domain: "preserved.example.test", target: .reject)
  let originalDate = Date(timeIntervalSince1970: 1)
  let original = ManagedProfile(
    id: profileID,
    name: "Preserved fields",
    payload: .compatibility(
      VPNProfile(
        connections: [connection],
        routingPolicy: routingPolicyFixture(),
        nodeGroups: [group],
        applicationRoutingRules: [applicationRule],
        websiteRoutingRules: [websiteRule],
        autoExcludedNodeIDs: [nodeID]
      )
    ),
    updatedAt: originalDate
  )
  let library = ProfileLibrary(profiles: [original], selectedProfileID: profileID)
  let sender = DelayedHelperSender()
  var savedLibraries: [ProfileLibrary] = []
  let model = AppModel(
    helperService: RegisteredRuntimeTestHelper(),
    runtimeSender: { request in await sender.send(request) },
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    profileLibraryLoader: { library },
    profileLibrarySaver: { savedLibraries.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  prepareRoutingMutationHelper(model)

  model.clearRoutingPolicy()
  await waitForRoutingModel { model.routingPolicyMutationStatus.state == .saved }

  guard let updated = model.profiles.first,
    case .compatibility(let payload) = updated.payload
  else {
    Issue.record("The selected compatibility profile was not preserved.")
    return
  }
  #expect(payload.routingPolicy == nil)
  #expect(payload.connections == [connection])
  #expect(payload.nodeGroups == [group])
  #expect(payload.applicationRoutingRules == [applicationRule])
  #expect(payload.websiteRoutingRules == [websiteRule])
  #expect(payload.autoExcludedNodeIDs == [nodeID])
  #expect(updated.updatedAt.map { $0 > originalDate } == true)
  #expect(model.routingPolicyMutationStatus.message == "Routing policy removed")
  #expect(savedLibraries.last?.profiles.first == updated)
  #expect(await sender.requestCount() == 0)
}

@Test @MainActor func routingPolicyRemovalR3PersistenceFailurePreservesKnownGoodState() async {
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "Known good",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(
            id: ProxyNodeID(rawValue: "node-known"), server: "known.example.test")
        ],
        routingPolicy: routingPolicyFixture()
      )
    )
  )
  let library = ProfileLibrary(profiles: [profile], selectedProfileID: profileID)
  var durableLibrary = library
  let sender = DelayedHelperSender()
  let model = AppModel(
    helperService: RegisteredRuntimeTestHelper(),
    runtimeSender: { request in await sender.send(request) },
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    profileLibraryLoader: { library },
    profileLibrarySaver: { candidate in
      if candidate.profiles.first?.payload?.routingPolicyForTesting == nil {
        throw NSError(domain: "RoutingPersistenceTest", code: 1)
      }
      durableLibrary = candidate
    },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  prepareRoutingMutationHelper(model)
  model.coreRunning = true
  model.routingInspectorInput = "8.8.8.8"
  model.inspectRouting()
  #expect(model.routingInspectorOutput.contains("DIRECT"))

  model.clearRoutingPolicy()

  #expect(model.routingInspectorState == .idle)
  await waitForRoutingModel { model.routingPolicyMutationStatus.state == .failed }
  #expect(model.profiles.first?.payload?.routingPolicyForTesting == routingPolicyFixture())
  #expect(durableLibrary.profiles.first?.payload?.routingPolicyForTesting == routingPolicyFixture())
  #expect(model.routingInspectorState == .idle)
  #expect(await sender.requestCount() == 0)
}

@Test @MainActor func routingPolicyRemovalR4RuntimeFailureCompensatesCurrentProfile() async {
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "Runtime rollback",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(
            id: ProxyNodeID(rawValue: "node-rollback"), server: "rollback.example.test")
        ],
        routingPolicy: routingPolicyFixture()
      )
    )
  )
  let library = ProfileLibrary(profiles: [profile], selectedProfileID: profileID)
  var durableLibrary = library
  let sender = DelayedHelperSender()
  let model = AppModel(
    helperService: RegisteredRuntimeTestHelper(),
    runtimeSender: { request in await sender.send(request) },
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    profileLibraryLoader: { library },
    profileLibrarySaver: { durableLibrary = $0 },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  prepareRoutingMutationHelper(model)
  model.coreRunning = true

  model.clearRoutingPolicy()
  await waitForRequestCount(1, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profileID,
      message: "injected apply failure"
    )
  )
  await waitForRoutingModel { model.routingPolicyMutationStatus.state == .failed }

  #expect(model.profiles.first?.payload?.routingPolicyForTesting == routingPolicyFixture())
  #expect(durableLibrary.profiles.first?.payload?.routingPolicyForTesting == routingPolicyFixture())
  #expect(
    model.routingPolicyMutationStatus.message
      == "Apply failed — previous routing remains active"
  )
}

@Test @MainActor func routingPolicyRemovalR5RebasesBeforeLaterRoutingEdit() async {
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "Queued routes",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(
            id: ProxyNodeID(rawValue: "node-queued"), server: "queued.example.test")
        ],
        routingPolicy: routingPolicyFixture()
      )
    )
  )
  let library = ProfileLibrary(profiles: [profile], selectedProfileID: profileID)
  let validator = RoutingValidationGate()
  let sender = DelayedHelperSender()
  let model = AppModel(
    helperService: RegisteredRuntimeTestHelper(),
    runtimeSender: { request in await sender.send(request) },
    profileValidator: { candidate in await validator.validate(candidate) },
    profileLibraryLoader: { library },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  prepareRoutingMutationHelper(model)
  model.coreRunning = true

  model.clearRoutingPolicy()
  await waitForValidationCount(1, validator: validator)
  model.websiteRoutingInput = "queued.example.test"
  model.websiteRoutingTarget = .direct
  model.addWebsiteRoutingRule()
  #expect(model.websiteRoutingStatus.state == .applying)

  await validator.completeNext()
  await waitForValidationCount(2, validator: validator)
  let validated = await validator.submittedProfiles()
  guard validated.count == 2,
    case .compatibility(let first) = validated[0],
    case .compatibility(let second) = validated[1]
  else {
    Issue.record("Both queued routing candidates were not validated.")
    return
  }
  #expect(first.routingPolicy == nil)
  #expect(first.websiteRoutingRules.isEmpty)
  #expect(second.routingPolicy == nil)
  #expect(second.websiteRoutingRules.map(\.domain) == ["queued.example.test"])

  await validator.completeNext()
  await waitForRequestCount(1, sender: sender)
  var requests = await sender.recordedRequests()
  #expect(requests.map(\.action) == [.start])
  guard case .compatibility(let firstStart) = requests[0].profile else {
    Issue.record("The removal Start did not carry a compatibility profile.")
    return
  }
  #expect(firstStart.routingPolicy == nil)
  #expect(firstStart.websiteRoutingRules.isEmpty)

  await waitForRoutingModel {
    model.profiles.first?.payload?.websiteRoutingRules.first?.domain == "queued.example.test"
  }
  #expect(model.profiles.first?.payload?.routingPolicyForTesting == nil)
  await sender.completeNext(
    with: HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profileID,
      message: "superseded removal apply failed"
    )
  )
  await waitForRequestCount(2, sender: sender)
  requests = await sender.recordedRequests()
  #expect(requests.map(\.action) == [.start, .start])
  guard case .compatibility(let latestStart) = requests[1].profile else {
    Issue.record("The later routing Start did not carry a compatibility profile.")
    return
  }
  #expect(latestStart.routingPolicy == nil)
  #expect(latestStart.websiteRoutingRules.map(\.domain) == ["queued.example.test"])
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      message: "latest routes active"
    )
  )
  await waitForRoutingModel { model.runtimeApplyStatus == .active }
  #expect(model.profiles.first?.payload?.routingPolicyForTesting == nil)
  #expect(model.profiles.first?.payload?.websiteRoutingRules.first?.domain == "queued.example.test")
}

@Test @MainActor func routingEditR6R7DuringReconnectStartIsSavedAndRemainsPending() async {
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "Reconnect routing",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(
            id: ProxyNodeID(rawValue: "node-reconnect"), server: "reconnect.example.test")
        ]
      )
    )
  )
  let sender = DelayedHelperSender()
  let confirmed = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: profileID,
    activeIPv6Enabled: true,
    runtimeOutcome: .applied,
    message: "confirmed"
  )
  let model = AppModel(
    helperService: RegisteredRuntimeTestHelper(),
    runtimeSender: { request in await sender.send(request) },
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profileID)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    runtimeStateReader: { confirmed },
    performStartup: false
  )
  prepareRoutingMutationHelper(model)
  model.coreRunning = true

  model.setIPv6Enabled(true)
  await waitForRequestCount(1, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      activeIPv6Enabled: false,
      runtimeOutcome: .reconnectRequired,
      message: "deferred"
    )
  )
  await waitForRoutingModel { model.deferredRuntimeApplyPhase == .pending }

  model.reconnectToApply()
  await waitForRequestCount(2, sender: sender)
  #expect((await sender.recordedRequests()).map(\.action) == [.start, .stop])
  await sender.completeNext(
    with: HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  await waitForRequestCount(3, sender: sender)
  #expect(model.deferredRuntimeApplyPhase == .reconnecting)

  model.websiteRoutingInput = "after-basis.example.test"
  model.websiteRoutingTarget = .direct
  model.addWebsiteRoutingRule()
  await waitForRoutingModel { model.websiteRoutingStatus.state == .saved }

  #expect(
    model.profiles.first?.payload?.websiteRoutingRules.first?.domain == "after-basis.example.test")
  #expect(model.deferredRuntimeApplyPhase == .reconnecting)
  #expect(await sender.requestCount() == 3)

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      activeIPv6Enabled: true,
      runtimeOutcome: .applied,
      message: "reconnect start completed"
    )
  )
  await waitForRoutingModel { model.deferredRuntimeApplyPhase == .pending }

  #expect(model.runtimeApplyStatus == .reconnectRequired)
  #expect(model.deferredRuntimeApplyError == nil)
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")
  #expect(await sender.requestCount() == 3)
  #expect((await sender.recordedRequests()).map(\.action) == [.start, .stop, .start])
}

@Test @MainActor func ordinaryRoutingEditR8StillSubmitsOneStart() async {
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "Ordinary route",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(
            id: ProxyNodeID(rawValue: "node-ordinary"), server: "ordinary.example.test")
        ]
      )
    )
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    sender: sender
  )
  model.coreRunning = true
  model.websiteRoutingInput = "ordinary.example.test"
  model.websiteRoutingTarget = .reject
  model.addWebsiteRoutingRule()

  await waitForRequestCount(1, sender: sender)
  let request = await sender.recordedRequests()[0]
  #expect(request.action == .start)
  #expect(request.profile?.websiteRoutingRules.first?.target == .reject)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      message: "ordinary route active"
    )
  )
  await waitForRoutingModel { model.runtimeApplyStatus == .active }
  #expect(await sender.requestCount() == 1)
  #expect(model.websiteRoutingStatus.state == .saved)
}

@Test @MainActor func profileSwitchAndNodeSelectionConvergeAfterDelayedStart() async throws {
  let profileAID = UUID()
  let profileBID = UUID()
  let nodeA = ProxyNodeID(rawValue: "node-a")
  let nodeB = ProxyNodeID(rawValue: "node-b")
  let profileA = ManagedProfile(
    id: profileAID,
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [runtimeTestConnection(id: nodeA, server: "a.example.test")]))
  )
  let profileB = ManagedProfile(
    id: profileBID,
    name: "B",
    payload: .compatibility(
      VPNProfile(connections: [runtimeTestConnection(id: nodeB, server: "b.example.test")]))
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileAID),
    sender: sender
  )

  model.setCoreEnabled(true)
  await waitForRequestCount(1, sender: sender)
  model.selectProfile(profileBID)
  model.setSelectedNode(nodeB)

  await sender.completeNext(
    with: HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileAID, message: "stale-a"))
  await waitForRequestCount(2, sender: sender)
  var requests = await sender.recordedRequests()
  #expect(requests.map(\.action) == [.start, .start])
  #expect(requests[1].profileID == profileBID)
  #expect(requests[1].node == nodeB)

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      selectedNode: nodeB,
      activeProfileID: profileBID,
      message: "node-b"
    ))
  await waitForModel { !(model.runtimeApplyStatus == .applying) }
  #expect(model.selectedProfileID == profileBID)
  #expect(model.selectedNodeID == nodeB)

  // A profile switch without a later node change carries the complete new profile.
  model.selectProfile(profileAID)
  await waitForRequestCount(3, sender: sender)
  requests = await sender.recordedRequests()
  #expect(requests[2].action == .start)
  #expect(requests[2].profileID == profileAID)
  await sender.completeNext(
    with: HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileAID, message: "active-a"))
}

@Test @MainActor func routingImportDuringDelayedStartConvergesToImportedPolicy() async throws {
  let profileID = UUID()
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(
      profiles: [
        ManagedProfile(
          id: profileID,
          name: "Routing",
          payload: .compatibility(
            VPNProfile(connections: [
              runtimeTestConnection(
                id: ProxyNodeID(rawValue: "node-routing"), server: "routing.example.test")
            ]))
        )
      ],
      selectedProfileID: profileID
    ),
    sender: sender
  )
  let policyURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMRuntimeRouting-\(UUID().uuidString).json")
  try Data(
    #"{"route":{"rules":[{"domain_suffix":[".ru"],"action":"route","outbound":"direct"}]}}"#
      .utf8
  ).write(to: policyURL)
  defer { try? FileManager.default.removeItem(at: policyURL) }

  model.setCoreEnabled(true)
  await waitForRequestCount(1, sender: sender)
  model.importRoutingPolicy(from: policyURL)
  await waitForModel { model.subscriptionStatus == "Routing policy applying" }

  await sender.completeNext(
    with: HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileID, message: "stale"))
  await waitForRequestCount(2, sender: sender)
  let requests = await sender.recordedRequests()
  #expect(requests.map(\.action) == [.start, .start])
  #expect(requests[1].profile?.routingPolicyForTesting != nil)
  await sender.completeNext(
    with: HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileID, message: "active"))
}

@Test @MainActor func subscriptionRefreshDuringDelayedStartConvergesToFreshProfile() async throws {
  let profileID = UUID()
  let sourceID = UUID()
  let oldPayload = CoreProfile.compatibility(
    VPNProfile(connections: [
      runtimeTestConnection(id: ProxyNodeID(rawValue: "node-old"), server: "old.example.test")
    ]))
  let freshPayload = CoreProfile.compatibility(
    VPNProfile(connections: [
      runtimeTestConnection(id: ProxyNodeID(rawValue: "node-new"), server: "new.example.test")
    ]))
  let source = ManagedSource(
    id: sourceID,
    name: "Remote",
    value: "https://subscription.example.test/list",
    payload: oldPayload
  )
  let library = ProfileLibrary(
    profiles: [
      ManagedProfile(
        id: profileID,
        name: "Refresh",
        sources: [source],
        payload: oldPayload
      )
    ],
    selectedProfileID: profileID
  )
  let sender = DelayedHelperSender()
  let manager = SubscriptionManager { _, _ in
    SubscriptionFetchResult(profile: freshPayload, skippedTransports: [:])
  }
  let model = runtimeTestModel(library: library, sender: sender, manager: manager)

  model.setCoreEnabled(true)
  await waitForRequestCount(1, sender: sender)
  model.saveAndSyncSubscription()
  await waitForModel { model.subscriptionStatus == "Sources updated; applying" }

  await sender.completeNext(
    with: HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileID, message: "stale"))
  await waitForRequestCount(2, sender: sender)
  let requests = await sender.recordedRequests()
  guard case .compatibility(let fresh) = requests[1].profile else {
    Issue.record("Expected a fresh compatibility profile")
    return
  }
  #expect(fresh.connections.first?.outbound.serverForRuntimeTest == "new.example.test")
  await sender.completeNext(
    with: HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileID, message: "fresh"))
}

@Test @MainActor func rapidApplicationEditsRemovalAndExplainConvergeToLatest() async throws {
  let profileID = UUID()
  let applicationRule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(
      profiles: [
        ManagedProfile(
          id: profileID,
          name: "Applications",
          payload: .compatibility(
            VPNProfile(
              connections: [
                runtimeTestConnection(
                  id: ProxyNodeID(rawValue: "node-app"), server: "app.example.test")
              ],
              applicationRoutingRules: [applicationRule]
            ))
        )
      ],
      selectedProfileID: profileID
    ),
    sender: sender
  )
  model.coreRunning = true

  model.setApplicationRoutingTarget(applicationRule.id, target: .direct)
  await waitForRequestCount(1, sender: sender)
  model.routingInspectorApplicationID = applicationRule.id
  model.routingInspectorInput = "google.com"
  model.inspectRouting()
  #expect(await sender.requestCount() == 1)
  #expect(
    model.routingInspectorOutput == "IPv6: REJECT\nIPv4: DIRECT"
  )
  #expect(model.routingInspectorDetails.contains("Traffic from: Browser"))

  model.setApplicationRoutingTarget(applicationRule.id, target: .selectedProxy)
  model.removeApplicationRoutingRule(applicationRule.id)
  await waitForModel { model.applicationRoutingRules.isEmpty }

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      message: "stale-direct"
    ))
  await waitForRequestCount(2, sender: sender)
  let requests = await sender.recordedRequests()
  #expect(requests.map(\.action) == [.start, .start])
  #expect(requests[1].profile?.applicationRoutingRules.isEmpty == true)

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      message: "latest-without-application-rule"
    ))
  await waitForModel { !(model.runtimeApplyStatus == .applying) }
  #expect(model.applicationRoutingRules.isEmpty)
  #expect(model.runtimeApplyStatus == .active)
}

@Test @MainActor func failedApplyReportsPreviousRoutingAsActiveWarning() async {
  let profileID = UUID()
  let rule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let model = AppModel(
    runtimeSender: { _ in
      HelperResponse(
        success: false,
        coreRunning: true,
        activeProfileID: profileID,
        message: "candidate start failed; previous configuration restored"
      )
    },
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: true, message: "valid")
    },
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [
          ManagedProfile(
            id: profileID,
            name: "Applications",
            payload: .compatibility(
              VPNProfile(
                connections: [
                  runtimeTestConnection(
                    id: ProxyNodeID(rawValue: "node-app"), server: "app.example.test")
                ],
                applicationRoutingRules: [rule]
              ))
          )
        ],
        selectedProfileID: profileID
      )
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.coreRunning = true

  model.setApplicationRoutingTarget(rule.id, target: .direct)
  await waitForModel { model.runtimeApplyStatus == .failed }

  #expect(model.routingPolicyStatus == "Apply failed — previous routing remains active")
  #expect(model.safeCurrentError?.contains("candidate start failed") == true)
  #expect(model.applicationRoutingRules.first?.target == .selectedProxy)
}

@Test @MainActor func transportFailureReconcilesKnownGoodBeforeReportingApplicationFailure() async {
  let profileID = UUID()
  let rule = ApplicationRoutingRule(
    displayName: "Transmission",
    bundlePath: "/Applications/Transmission.app",
    executablePath: "/Applications/Transmission.app/Contents/MacOS/Transmission",
    target: .selectedProxy
  )
  let model = AppModel(
    runtimeSender: { _ in
      throw NSError(domain: "SBMTransportTest", code: 1)
    },
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: true, message: "valid")
    },
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [
          ManagedProfile(
            id: profileID,
            name: "Applications",
            payload: .compatibility(
              VPNProfile(
                connections: [
                  runtimeTestConnection(
                    id: ProxyNodeID(rawValue: "node-app"), server: "app.example.test")
                ],
                applicationRoutingRules: [rule]
              ))
          )
        ],
        selectedProfileID: profileID
      )
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    runtimeStateReader: {
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profileID,
        message: "known good still active"
      )
    },
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.coreRunning = true

  model.setApplicationRoutingTarget(rule.id, target: .direct)
  await waitForModel {
    model.routingPolicyStatus == "Apply failed — previous routing remains active"
  }

  #expect(model.routingPolicyStatus == "Apply failed — previous routing remains active")
  #expect(model.helperReachable)
  #expect(model.applicationRoutingRules.first?.target == .selectedProxy)
}

@Test @MainActor
func deferredApplicationRoutingKeepsKnownGoodRuntimeUntilExplicitReconnect() async {
  let profileID = UUID()
  let rule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let profile = ManagedProfile(
    id: profileID,
    name: "Applications",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(
            id: ProxyNodeID(rawValue: "node-deferred"), server: "deferred.example.test")
        ],
        applicationRoutingRules: [rule]
      )
    )
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profileID, ipv6Enabled: true
    ),
    sender: sender
  )
  model.coreRunning = true

  model.setApplicationRoutingTarget(rule.id, target: .direct)
  await waitForRequestCount(1, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  await waitForModel { model.runtimeApplyStatus == .reconnectRequired }

  #expect(model.coreRunning)
  #expect(model.applicationRoutingRules.first?.target == .direct)
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")
  #expect(model.applicationRoutingStatus.state == .reconnectRequired)
  #expect(model.applicationRoutingStatus.message == nil)
  #expect(model.subscriptionStatus != DeferredRuntimeApplyPresentation.changesReadyToApply)
  #expect(await sender.requestCount() == 1)

  model.setCoreEnabled(false)
  await waitForRequestCount(2, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: false,
      activeProfileID: profileID,
      message: "VPN disconnected"
    )
  )
  await waitForModel {
    model.observedCoreState == .stopped && model.runtimeApplyStatus != .applying
  }

  model.setCoreEnabled(true)
  await waitForRequestCount(3, sender: sender)
  let reconnectRequest = await sender.recordedRequests()[2]
  #expect(reconnectRequest.action == .start)
  #expect(reconnectRequest.profile?.applicationRoutingRules.first?.target == .direct)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      message: "VPN connected"
    )
  )
  await waitForModel { model.runtimeApplyStatus == .active }
  #expect(model.coreRunning)
  #expect(model.deferredRuntimeApplyPresentation == nil)
  #expect(model.applicationRoutingStatus.state == .saved)
  #expect(model.applicationRoutingStatus.message == nil)
  #expect(model.subscriptionStatus != DeferredRuntimeApplyPresentation.changesReadyToApply)
}

@Test @MainActor
func deferredRuntimePresentationSurvivesASecondApplyAttempt() async {
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "Modes",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(id: ProxyNodeID(rawValue: "node-mode"), server: "mode.example.test")
        ]
      )
    )
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    sender: sender
  )
  model.coreRunning = true

  model.setRoutingMode(.global)
  await waitForRequestCount(1, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  await waitForModel { model.runtimeApplyStatus == .reconnectRequired }

  model.setRoutingMode(.direct)
  await waitForRequestCount(2, sender: sender)
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Applying…")
  #expect(model.deferredRuntimeApplyPresentation?.phase == .applying)
  #expect(model.deferredRuntimeApplyPresentation?.actionEnabled == false)

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  await waitForModel { model.runtimeApplyStatus == .reconnectRequired }
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")
  #expect(model.deferredRuntimeApplyPresentation?.actionEnabled == true)
}

@Test @MainActor
func ipv6PreferenceIsSentAsDesiredRuntimeAndLatestChangeWins() async {
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "IPv6",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(id: ProxyNodeID(rawValue: "node-ipv6"), server: "ipv6.example.test")
        ]
      )
    )
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profileID, ipv6Enabled: true
    ),
    sender: sender
  )
  model.coreRunning = true

  model.setIPv6Enabled(false)
  await waitForRequestCount(1, sender: sender)
  let disabledRequest = await sender.recordedRequests()[0]
  #expect(disabledRequest.action == .start)
  #expect(disabledRequest.ipv6Enabled == false)
  #expect(!model.ipv6Enabled)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  await waitForModel { model.runtimeApplyStatus == .reconnectRequired }

  model.setIPv6Enabled(true)
  await waitForRequestCount(2, sender: sender)
  let enabledRequest = await sender.recordedRequests()[1]
  #expect(enabledRequest.ipv6Enabled == true)
  #expect(model.ipv6Enabled)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  await waitForModel { model.runtimeApplyStatus == .reconnectRequired }
  #expect(model.ipv6Enabled)
}

@Test @MainActor
func reconnectToApplyStopsBeforeStartingAndClearsPendingOnlyAfterAuthoritativeStatus() async {
  let profileID = UUID()
  let rule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let profile = ManagedProfile(
    id: profileID,
    name: "Applications",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(
            id: ProxyNodeID(rawValue: "node-reconnect"), server: "reconnect.example.test")
        ],
        applicationRoutingRules: [rule]
      )
    )
  )
  let sender = DelayedHelperSender()
  let model = AppModel(
    runtimeSender: { request in await sender.send(request) },
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profileID)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    runtimeStateReader: {
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profileID,
        message: "authoritative active"
      )
    },
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.coreRunning = true

  model.setApplicationRoutingTarget(rule.id, target: .direct)
  await waitForRequestCount(1, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  await waitForModel { model.runtimeApplyStatus == .reconnectRequired }
  #expect(model.deferredRuntimeApplyPresentation?.action.title == "Reconnect to Apply")

  model.reconnectToApply()
  await waitForRequestCount(2, sender: sender)
  #expect(await sender.recordedRequests().map(\.action) == [.start, .stop])
  model.reconnectToApply()
  #expect(await sender.requestCount() == 2)

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: false,
      activeProfileID: profileID,
      message: "stopped"
    )
  )
  await waitForRequestCount(3, sender: sender)
  #expect(await sender.recordedRequests().map(\.action) == [.start, .stop, .start])
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      message: "connected"
    )
  )
  await waitForModel { model.deferredRuntimeApplyPhase == .idle }
  #expect(model.runtimeApplyStatus == .active)
  #expect(model.deferredRuntimeApplyPresentation == nil)
}

@Test @MainActor
func reconnectToApplyDisconnectFailureDoesNotStartOrHidePendingState() async {
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "Failure",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(
            id: ProxyNodeID(rawValue: "node-stop-failure"), server: "stop-failure.example.test")
        ],
        applicationRoutingRules: [
          ApplicationRoutingRule(
            displayName: "Browser",
            bundlePath: "/Applications/Browser.app",
            executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
            target: .selectedProxy
          )
        ]
      )
    )
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    sender: sender
  )
  model.coreRunning = true
  let ruleID = try! #require(model.applicationRoutingRules.first?.id)
  model.setApplicationRoutingTarget(ruleID, target: .direct)
  await waitForRequestCount(1, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  await waitForModel { model.runtimeApplyStatus == .reconnectRequired }

  model.reconnectToApply()
  await waitForRequestCount(2, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profileID,
      message: "stop refused"
    )
  )
  await waitForModel { model.deferredRuntimeApplyPhase == .failed }
  #expect(await sender.requestCount() == 2)
  #expect(model.coreRunning)
  #expect(model.deferredRuntimeApplyPresentation?.action.title == "Reconnect to Apply")
  #expect(model.deferredRuntimeApplyError != nil)
}

@Test @MainActor
func reconnectToApplyConnectFailureLeavesTheVpnStoppedWithoutRetryLoop() async {
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "Connect failure",
    payload: .compatibility(
      VPNProfile(
        connections: [
          runtimeTestConnection(
            id: ProxyNodeID(rawValue: "node-start-failure"), server: "start-failure.example.test")
        ],
        applicationRoutingRules: [
          ApplicationRoutingRule(
            displayName: "Browser",
            bundlePath: "/Applications/Browser.app",
            executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
            target: .selectedProxy
          )
        ]
      )
    )
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    sender: sender
  )
  model.coreRunning = true
  let ruleID = try! #require(model.applicationRoutingRules.first?.id)
  model.setApplicationRoutingTarget(ruleID, target: .direct)
  await waitForRequestCount(1, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  await waitForModel { model.runtimeApplyStatus == .reconnectRequired }

  model.reconnectToApply()
  await waitForRequestCount(2, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: false,
      activeProfileID: profileID,
      message: "stopped"
    )
  )
  await waitForRequestCount(3, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: false,
      coreRunning: false,
      activeProfileID: profileID,
      message: "candidate rejected"
    )
  )
  await waitForModel { model.deferredRuntimeApplyPhase == .failed }
  #expect(await sender.requestCount() == 3)
  #expect(!model.coreRunning)
  #expect(model.deferredRuntimeApplyPresentation != nil)
  #expect(model.deferredRuntimeApplyError?.contains("remains disconnected") == true)
}

@Test @MainActor func deferredProfileSwitchDoesNotRetargetOldRuntimeNode() async {
  let profileAID = UUID()
  let profileBID = UUID()
  let nodeA = ProxyNodeID(rawValue: "node-a")
  let nodeB = ProxyNodeID(rawValue: "node-b")
  let profileA = ManagedProfile(
    id: profileAID,
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [runtimeTestConnection(id: nodeA, server: "a.example.test")])
    )
  )
  let profileB = ManagedProfile(
    id: profileBID,
    name: "B",
    payload: .compatibility(
      VPNProfile(connections: [runtimeTestConnection(id: nodeB, server: "b.example.test")])
    )
  )
  let sender = DelayedHelperSender()
  let model = runtimeTestModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileAID),
    sender: sender
  )
  model.coreRunning = true

  model.selectProfile(profileBID)
  await waitForRequestCount(1, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileAID,
      nodes: [ProxyNodeDescriptor(id: nodeA, name: "A")],
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  await waitForModel { model.runtimeApplyStatus == .reconnectRequired }

  model.setSelectedNode(nodeB)

  #expect(model.selectedNodeID == nodeB)
  #expect(model.runtimeApplyStatus == .reconnectRequired)
  #expect(await sender.requestCount() == 1)
}

@Test @MainActor func latencyTestDoesNotTargetOldRuntimeAfterDeferredProfileSwitch() async {
  let profileAID = UUID()
  let profileBID = UUID()
  let nodeA = ProxyNodeID(rawValue: "latency-a")
  let nodeB = ProxyNodeID(rawValue: "latency-b")
  let profileA = ManagedProfile(
    id: profileAID,
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [runtimeTestConnection(id: nodeA, server: "a.example.test")])
    )
  )
  let profileB = ManagedProfile(
    id: profileBID,
    name: "B",
    payload: .compatibility(
      VPNProfile(connections: [runtimeTestConnection(id: nodeB, server: "b.example.test")])
    )
  )
  let sender = DelayedHelperSender()
  let latency = LatencyRequestRecorder()
  let model = runtimeTestModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileAID),
    sender: sender,
    latencySender: { node in await latency.send(node) }
  )
  model.coreRunning = true

  model.selectProfile(profileBID)
  await waitForRequestCount(1, sender: sender)
  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileAID,
      nodes: [ProxyNodeDescriptor(id: nodeA, name: "A")],
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  await waitForModel { model.runtimeApplyStatus == .reconnectRequired }

  model.testLatency()

  #expect(await latency.requestCount() == 0)
  #expect(
    model.lastError
      == "Disconnect and reconnect before testing latency for the selected profile."
  )
}

@MainActor
private func runtimeTestModel(
  library: ProfileLibrary,
  sender: DelayedHelperSender,
  userDefaults: UserDefaults = IsolatedTestUserDefaults(),
  manager: SubscriptionManager = SubscriptionManager(),
  latencySender: @escaping @Sendable (ProxyNodeID?) async throws -> HelperResponse = { node in
    HelperResponse(
      success: true,
      coreRunning: true,
      delays: node.map { [NodeDelay(node: $0, milliseconds: 20)] } ?? [],
      message: "latency"
    )
  }
) -> AppModel {
  let model = AppModel(
    helperService: RegisteredRuntimeTestHelper(),
    subscriptionManager: manager,
    runtimeSender: { request in await sender.send(request) },
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    profileLibraryLoader: { library },
    profileLibrarySaver: { _ in },
    userDefaults: userDefaults,
    latencySender: latencySender,
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  return model
}

@MainActor
private func waitForModel(_ predicate: @MainActor () -> Bool) async {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(2))
  while !predicate(), clock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(predicate(), "model condition did not become true within 2 seconds")
}

private func runtimeTestConnection(id: ProxyNodeID, server: String) -> ManagedConnection {
  ManagedConnection(
    id: id,
    outbound: .shadowsocks(
      ShadowsocksProfile(
        server: server,
        port: 443,
        method: "aes-256-gcm",
        password: "test-password",
        displayName: server
      ))
  )
}

extension CoreProfile {
  fileprivate var routingPolicyForTesting: RoutingPolicy? {
    guard case .compatibility(let profile) = self else { return nil }
    return profile.routingPolicy
  }
}

@MainActor
private func prepareRoutingMutationHelper(_ model: AppModel) {
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
}

private func routingPolicyFixture() -> RoutingPolicy {
  RoutingPolicy(
    configuration: Data(
      #"{"route":{"rules":[{"ip_cidr":["8.8.8.8/32"],"action":"route","outbound":"direct"}]}}"#.utf8
    )
  )
}

private func waitForValidationCount(
  _ expected: Int,
  validator: RoutingValidationGate
) async {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(2))
  while clock.now < deadline {
    if await validator.count() >= expected { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(await validator.count() >= expected, "validation count did not reach \(expected)")
}

@MainActor
private func waitForRoutingModel(_ predicate: @MainActor () -> Bool) async {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(2))
  while clock.now < deadline {
    if predicate() { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(predicate(), "routing model condition did not become true within 2 seconds")
}

extension ManagedOutbound {
  fileprivate var serverForRuntimeTest: String {
    switch self {
    case .vless(let value): value.server
    case .hysteria2(let value): value.server
    case .shadowsocks(let value): value.server
    }
  }
}

@Test @MainActor
func runtimeMutationSupersededCompletionCanReentrantlyReplaceVisiblePending() async {
  let sender = DelayedHelperSender()
  let controller = RuntimeMutationController { request in
    await sender.send(request)
  }
  var completions: [String: Int] = [:]
  let latestNode = ProxyNodeID(rawValue: "reentrant-latest")

  controller.submit(HelperRequest(action: .stop)) { _ in
    completions["physical"] = (completions["physical"] ?? 0) + 1
  }
  await waitForRequestCount(1, sender: sender)
  controller.submit(HelperRequest(action: .setMode, mode: .global)) { outcome in
    if case .failure = outcome.result {
      completions["A"] = (completions["A"] ?? 0) + 1
      controller.submit(HelperRequest(action: .setNode, node: latestNode)) { latest in
        completions["C"] = (completions["C"] ?? 0) + 1
        #expect(latest.isCurrent)
      }
    }
  }
  let bGeneration = controller.submit(HelperRequest(action: .setMode, mode: .direct)) { outcome in
    if case .failure = outcome.result {
      completions["B"] = (completions["B"] ?? 0) + 1
    }
  }

  #expect(bGeneration == 3)
  #expect(controller.currentGeneration == 4)
  #expect(completions["A"] == 1)
  #expect(completions["B"] == 1)
  #expect(await sender.recordedRequests().map(\.action) == [.stop])

  await sender.completeNext(
    with: HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  await waitForRequestCount(2, sender: sender)
  let requests = await sender.recordedRequests()
  #expect(requests.map(\.action) == [.stop, .setNode])
  #expect(requests.last?.node == latestNode)
  await sender.completeNext(
    with: HelperResponse(success: true, coreRunning: false, message: "latest applied")
  )
  await waitForModel { !(controller.isApplying) }

  #expect(completions == ["A": 1, "B": 1, "C": 1, "physical": 1])
}
