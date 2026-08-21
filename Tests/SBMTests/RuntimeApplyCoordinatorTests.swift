import Foundation
import SBMShared
import Testing

@testable import SBM

private actor DelayedRuntimeSender {
  private var requests: [String] = []
  private var continuations: [CheckedContinuation<String, Never>] = []

  func send(_ request: String) async -> String {
    requests.append(request)
    return await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func requestCount() -> Int { requests.count }

  func recordedRequests() -> [String] { requests }

  func completeNext(with response: String) {
    continuations.removeFirst().resume(returning: response)
  }
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

private actor LatencyRequestRecorder {
  private var nodes: [ProxyNodeID] = []

  func send(_ node: ProxyNodeID) -> HelperResponse {
    nodes.append(node)
    return HelperResponse(
      success: true,
      coreRunning: true,
      delays: [NodeDelay(node: node, milliseconds: 20)],
      message: "latency"
    )
  }

  func requestCount() -> Int { nodes.count }
}

private struct RecordedOutcome: Equatable {
  let response: String
  let isCurrent: Bool
}

private func waitForRequestCount(
  _ expected: Int,
  sender: DelayedRuntimeSender
) async {
  for _ in 0..<100 {
    if await sender.requestCount() == expected { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
}

private func waitForRequestCount(
  _ expected: Int,
  sender: DelayedHelperSender
) async {
  for _ in 0..<100 {
    if await sender.requestCount() == expected { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
}

@Test @MainActor func runtimeApplyConvergesToChangeSavedDuringDelayedStart() async {
  let sender = DelayedRuntimeSender()
  let coordinator = RuntimeApplyCoordinator<String, String> { request in
    await sender.send(request)
  }
  var outcomes: [RecordedOutcome] = []

  coordinator.submit("routing-a") { outcome in
    if case .success(let response) = outcome.result {
      outcomes.append(RecordedOutcome(response: response, isCurrent: outcome.isCurrent))
    }
  }
  await waitForRequestCount(1, sender: sender)

  coordinator.markSaved()
  coordinator.submit("routing-b") { outcome in
    if case .success(let response) = outcome.result {
      outcomes.append(RecordedOutcome(response: response, isCurrent: outcome.isCurrent))
    }
  }

  #expect(await sender.recordedRequests() == ["routing-a"])
  #expect(coordinator.status == .applying)

  await sender.completeNext(with: "active-a")
  await waitForRequestCount(2, sender: sender)
  #expect(await sender.recordedRequests() == ["routing-a", "routing-b"])
  #expect(outcomes == [RecordedOutcome(response: "active-a", isCurrent: false)])

  await sender.completeNext(with: "active-b")
  while coordinator.isApplying { await Task.yield() }

  #expect(
    outcomes == [
      RecordedOutcome(response: "active-a", isCurrent: false),
      RecordedOutcome(response: "active-b", isCurrent: true),
    ]
  )
  #expect(coordinator.status == .active)
}

@Test @MainActor func runtimeApplyCoalescesPendingChangesToLatestGeneration() async {
  let sender = DelayedRuntimeSender()
  let coordinator = RuntimeApplyCoordinator<String, String> { request in
    await sender.send(request)
  }

  coordinator.submit("profile-a") { _ in }
  await waitForRequestCount(1, sender: sender)
  coordinator.submit("profile-b") { _ in }
  coordinator.submit("profile-c") { _ in }

  await sender.completeNext(with: "active-a")
  await waitForRequestCount(2, sender: sender)
  #expect(await sender.recordedRequests() == ["profile-a", "profile-c"])

  await sender.completeNext(with: "active-c")
  while coordinator.isApplying { await Task.yield() }
  #expect(coordinator.status == .active)
}

@Test @MainActor func replacedPendingGenerationReceivesSupersededCompletion() async {
  let sender = DelayedRuntimeSender()
  let coordinator = RuntimeApplyCoordinator<String, String> { request in
    await sender.send(request)
  }
  var pendingWasSuperseded = false

  coordinator.submit("in-flight") { _ in }
  await waitForRequestCount(1, sender: sender)
  coordinator.submit("pending-shutdown") { outcome in
    if case .failure(let error) = outcome.result,
      error is RuntimeApplyCoordinatorFailure
    {
      pendingWasSuperseded = !outcome.isCurrent
    }
  }
  coordinator.submit("newer-start") { _ in }

  #expect(pendingWasSuperseded)
  await sender.completeNext(with: "stale")
  await waitForRequestCount(2, sender: sender)
  #expect(await sender.recordedRequests() == ["in-flight", "newer-start"])
  await sender.completeNext(with: "current")
  while coordinator.isApplying { await Task.yield() }
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
    profileLibraryLoader: { library },
    profileLibrarySaver: { savedLibraries.append($0) },
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
  #expect(model.subscriptionStatus == "Routing policy removal applying")
  #expect(savedLibraries.last?.profiles.first?.payload?.routingPolicyForTesting == nil)

  await sender.completeNext(
    with: HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      message: "active-a"
    )
  )
  await waitForRequestCount(2, sender: sender)
  let requests = await sender.recordedRequests()
  #expect(requests.map(\.action) == [.start, .start])
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
  while model.runtimeApplyStatus == .applying { await Task.yield() }

  #expect(model.runtimeApplyStatus == .active)
  #expect(model.subscriptionStatus == "Routing policy removed and active")
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
  while model.runtimeApplyStatus == .applying { await Task.yield() }
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
  let generationDuringApply = model.desiredRuntimeGeneration
  model.routingInspectorApplicationID = applicationRule.id
  model.routingInspectorInput = "google.com"
  model.inspectRouting()
  #expect(model.desiredRuntimeGeneration == generationDuringApply)
  #expect(await sender.requestCount() == 1)
  #expect(model.routingInspectorOutput == "Depends on resolved IP")
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
  while model.runtimeApplyStatus == .applying { await Task.yield() }
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
  #expect(model.routingPolicyStatusLevel == .warning)
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
    model.subscriptionStatus == "Apply failed — previous routing remains active"
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
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
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
  await Task.yield()
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
  await Task.yield()

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
  await Task.yield()

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
  manager: SubscriptionManager = SubscriptionManager(),
  latencySender: @escaping @Sendable (ProxyNodeID) async throws -> HelperResponse = { node in
    HelperResponse(
      success: true,
      coreRunning: true,
      delays: [NodeDelay(node: node, milliseconds: 20)],
      message: "latency"
    )
  }
) -> AppModel {
  let model = AppModel(
    subscriptionManager: manager,
    runtimeSender: { request in await sender.send(request) },
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    profileLibraryLoader: { library },
    profileLibrarySaver: { _ in },
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
  for _ in 0..<1_000 {
    if predicate() { return }
    await Task.yield()
  }
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

extension ManagedOutbound {
  fileprivate var serverForRuntimeTest: String {
    switch self {
    case .vless(let value): value.server
    case .hysteria2(let value): value.server
    case .shadowsocks(let value): value.server
    }
  }
}
