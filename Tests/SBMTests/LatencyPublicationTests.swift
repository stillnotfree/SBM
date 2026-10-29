import Foundation
import SBMShared
import Testing

@testable import SBM

@MainActor
private final class LatencyTestHelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState { .enabled }
  var legacyRegistrationState: HelperRegistrationState { .notRegistered }

  func register() throws {}
  func unregister() async throws {}
  func unregisterLegacy() async throws {}
  func openSystemSettings() {}
}

private actor LatencySenderRecorder {
  private let profileID: UUID
  private let nodes: [ProxyNodeDescriptor]
  private let collectedDelays: [NodeDelay]
  private let activeIPv6Enabled: Bool?
  private var requests: [ProxyNodeID?] = []

  init(
    profileID: UUID,
    nodes: [ProxyNodeDescriptor],
    collectedDelays: [NodeDelay],
    activeIPv6Enabled: Bool? = nil
  ) {
    self.profileID = profileID
    self.nodes = nodes
    self.collectedDelays = collectedDelays
    self.activeIPv6Enabled = activeIPv6Enabled
  }

  func send(_ node: ProxyNodeID?) -> HelperResponse {
    requests.append(node)
    return HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      activeIPv6Enabled: activeIPv6Enabled,
      nodes: nodes,
      delays: node.map { [NodeDelay(node: $0, milliseconds: 999)] } ?? collectedDelays,
      message: "latency"
    )
  }

  func recordedRequests() -> [ProxyNodeID?] { requests }
}

private actor RuntimeRequestRecorder {
  private var requests: [HelperRequest] = []

  func send(_ request: HelperRequest) -> HelperResponse {
    requests.append(request)
    return HelperResponse(success: true, coreRunning: false, message: "stopped")
  }

  func recordedRequests() -> [HelperRequest] { requests }
}

private actor LatencyStatusSequence {
  private var responses: [HelperResponse]

  init(_ responses: [HelperResponse]) {
    self.responses = responses
  }

  func next() -> HelperResponse {
    responses.removeFirst()
  }
}

private func latencyTestConnection(id: ProxyNodeID, name: String) -> ManagedConnection {
  ManagedConnection(
    id: id,
    displayName: name,
    outbound: .shadowsocks(
      ShadowsocksProfile(
        server: "\(id.rawValue).example.test",
        port: 443,
        method: "aes-256-gcm",
        password: "test-password",
        displayName: name
      )
    )
  )
}

@MainActor
private func waitForLatencyCycle(_ model: AppModel) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(1))
  while model.latencyTestInProgress, clock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(!model.latencyTestInProgress)
}

@MainActor
private func waitForPublishedCoreVersion(_ model: AppModel, _ expected: String) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(2))
  while model.coreVersion != expected, clock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return model.coreVersion == expected
}

@MainActor
private func waitForLatencyRecorderCondition(
  _ condition: @MainActor () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(2))
  while !(await condition()), clock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return await condition()
}

@Test @MainActor func latencyTriggersConcreteNodesThenPublishesOnlyStoredHistory() async throws {
  let nodeA = ProxyNodeID(rawValue: "latency-a")
  let nodeB = ProxyNodeID(rawValue: "latency-b")
  let nodeC = ProxyNodeID(rawValue: "latency-c")
  let profile = ManagedProfile(
    name: "Latency",
    payload: .compatibility(
      VPNProfile(connections: [
        latencyTestConnection(id: nodeA, name: "A"),
        latencyTestConnection(id: nodeB, name: "B"),
        latencyTestConnection(id: nodeC, name: "C"),
      ])
    )
  )
  let profileNodes = profile.payload!.nodes
  let descriptors = profileNodes.map {
    ProxyNodeDescriptor(id: $0.id, name: $0.name, kind: $0.kind)
  }
  let sender = LatencySenderRecorder(
    profileID: profile.id,
    nodes: Array(descriptors.reversed()),
    collectedDelays: [
      NodeDelay(node: nodeB, milliseconds: 80),
      NodeDelay(node: nodeC, milliseconds: nil),
      NodeDelay(node: nodeA, milliseconds: 40),
      NodeDelay(node: .auto, milliseconds: nil),
    ]
  )
  let model = AppModel(
    helperService: LatencyTestHelperService(),
    helperLifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        coreVersion: "latency-initial-status",
        activeProfileID: profile.id,
        activeIPv6Enabled: false,
        nodes: descriptors,
        message: "running"
      )
    },
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    latencySender: { node in await sender.send(node) },
    latencySettleDelay: .zero,
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision

  model.refresh()
  #expect(await waitForPublishedCoreVersion(model, "latency-initial-status"))

  model.testLatency()
  try await waitForLatencyCycle(model)

  #expect(await sender.recordedRequests() == [nodeA, nodeB, nodeC, nil])
  #expect(model.nodes.map(\.id) == [.auto, nodeA, nodeB, nodeC])
  #expect(model.nodes.map(\.name) == ["Auto", "A", "B", "C"])
  #expect(model.nodes.map(\.delay) == [nil, 40, 80, nil])
  #expect(model.latencyTestCompleted)
}

@Test @MainActor
func initialRunningObservationAutomaticallyTestsAndPublishesLatency() async throws {
  let node = ProxyNodeID(rawValue: "startup-latency")
  let profile = ManagedProfile(
    name: "Latency",
    payload: .compatibility(
      VPNProfile(connections: [latencyTestConnection(id: node, name: "Startup")])
    )
  )
  let descriptors = profile.payload!.nodes.map {
    ProxyNodeDescriptor(id: $0.id, name: $0.name, kind: $0.kind)
  }
  let latency = LatencySenderRecorder(
    profileID: profile.id,
    nodes: descriptors,
    collectedDelays: [NodeDelay(node: node, milliseconds: 42)],
    activeIPv6Enabled: false
  )
  let runtime = RuntimeRequestRecorder()
  let model = AppModel(
    helperService: LatencyTestHelperService(),
    helperLifecycleSender: { request, _ in
      #expect(request.action == .status)
      return HelperResponse(
        success: true,
        coreRunning: true,
        coreVersion: "startup-running",
        activeProfileID: profile.id,
        activeIPv6Enabled: false,
        nodes: descriptors,
        message: "running"
      )
    },
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    runtimeSender: { request in await runtime.send(request) },
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    latencySender: { node in await latency.send(node) },
    latencySettleDelay: .zero,
    updateChecker: { _ in nil },
    performStartup: true
  )

  #expect(
    await waitForLatencyRecorderCondition {
      model.latencyTestCompleted && !model.latencyTestInProgress
    }
  )
  #expect(await latency.recordedRequests() == [node, nil])
  #expect(model.nodes.first(where: { $0.id == node })?.delay == 42)
  #expect(await runtime.recordedRequests().isEmpty)
}

@Test @MainActor
func initialStoppedObservationDoesNotStartRuntimeOrLatencyTesting() async throws {
  let node = ProxyNodeID(rawValue: "offline-latency")
  let profile = ManagedProfile(
    name: "Latency",
    payload: .compatibility(
      VPNProfile(connections: [latencyTestConnection(id: node, name: "Offline")])
    )
  )
  let descriptors = profile.payload!.nodes.map {
    ProxyNodeDescriptor(id: $0.id, name: $0.name, kind: $0.kind)
  }
  let latency = LatencySenderRecorder(
    profileID: profile.id,
    nodes: descriptors,
    collectedDelays: [NodeDelay(node: node, milliseconds: 42)]
  )
  let runtime = RuntimeRequestRecorder()
  let model = AppModel(
    helperService: LatencyTestHelperService(),
    helperLifecycleSender: { request, _ in
      #expect(request.action == .status)
      return HelperResponse(
        success: true,
        coreRunning: false,
        coreVersion: "startup-stopped",
        activeProfileID: nil,
        message: "stopped"
      )
    },
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    runtimeSender: { request in await runtime.send(request) },
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    latencySender: { node in await latency.send(node) },
    latencySettleDelay: .zero,
    updateChecker: { _ in nil },
    performStartup: true
  )

  #expect(await waitForPublishedCoreVersion(model, "startup-stopped"))
  try await Task.sleep(for: .milliseconds(350))
  #expect(!model.coreRunning)
  #expect(await latency.recordedRequests().isEmpty)
  #expect(await runtime.recordedRequests().isEmpty)
}

@Test @MainActor func disconnectCancelsLatencyCollectionDuringSettleDelay() async {
  let node = ProxyNodeID(rawValue: "settle-node")
  let profile = ManagedProfile(
    name: "Latency",
    payload: .compatibility(
      VPNProfile(connections: [latencyTestConnection(id: node, name: "Node")])
    )
  )
  let profileNodes = profile.payload!.nodes
  let descriptors = profileNodes.map {
    ProxyNodeDescriptor(id: $0.id, name: $0.name, kind: $0.kind)
  }
  let latency = LatencySenderRecorder(
    profileID: profile.id,
    nodes: descriptors,
    collectedDelays: [NodeDelay(node: node, milliseconds: 25)]
  )
  let runtime = RuntimeRequestRecorder()
  let model = AppModel(
    helperService: LatencyTestHelperService(),
    helperLifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        coreVersion: "settle-initial-status",
        activeProfileID: profile.id,
        activeIPv6Enabled: false,
        nodes: descriptors,
        message: "running"
      )
    },
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    runtimeSender: { request in await runtime.send(request) },
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    latencySender: { node in await latency.send(node) },
    latencySettleDelay: .seconds(30),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision

  model.refresh()
  #expect(await waitForPublishedCoreVersion(model, "settle-initial-status"))
  model.testLatency()
  #expect(await waitForLatencyRecorderCondition { !(await latency.recordedRequests()).isEmpty })
  #expect(await latency.recordedRequests() == [node])

  model.setCoreEnabled(false)
  #expect(await waitForLatencyRecorderCondition { !(await runtime.recordedRequests()).isEmpty })

  #expect((await runtime.recordedRequests().first)?.action == .stop)
  #expect((await runtime.recordedRequests()).map(\.action) == [.stop])
  #expect(await latency.recordedRequests() == [node])
  #expect(!model.latencyTestInProgress)
}

@Test @MainActor func livenessRefreshPreservesPublishedNodeNamesAndDelays() async throws {
  let nodeA = ProxyNodeID(rawValue: "liveness-a")
  let nodeB = ProxyNodeID(rawValue: "liveness-b")
  let profile = ManagedProfile(
    name: "Liveness",
    payload: .compatibility(
      VPNProfile(connections: [
        latencyTestConnection(id: nodeA, name: "A"),
        latencyTestConnection(id: nodeB, name: "B"),
      ])
    )
  )
  let descriptors = profile.payload!.nodes.map {
    ProxyNodeDescriptor(id: $0.id, name: "Helper \($0.name)", kind: $0.kind)
  }
  let latency = LatencySenderRecorder(
    profileID: profile.id,
    nodes: descriptors,
    collectedDelays: [
      NodeDelay(node: nodeA, milliseconds: 34),
      NodeDelay(node: nodeB, milliseconds: 55),
    ]
  )
  let statuses = LatencyStatusSequence([
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "liveness-initial-status",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      nodes: descriptors,
      message: "running"
    ),
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "liveness-refresh-status",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      nodes: descriptors,
      message: "running"
    ),
  ])
  let model = AppModel(
    helperService: LatencyTestHelperService(),
    helperLifecycleSender: { _, _ in await statuses.next() },
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    latencySender: { node in await latency.send(node) },
    latencySettleDelay: .zero,
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision

  model.refresh()
  #expect(await waitForPublishedCoreVersion(model, "liveness-initial-status"))
  #expect(model.nodes.map(\.name) == ["Auto", "A", "B"])

  model.testLatency()
  try await waitForLatencyCycle(model)
  #expect(model.nodes.map(\.delay) == [nil, 34, 55])

  model.refresh()
  #expect(await waitForPublishedCoreVersion(model, "liveness-refresh-status"))
  #expect(model.nodes.map(\.name) == ["Auto", "A", "B"])
  #expect(model.nodes.map(\.delay) == [nil, 34, 55])
}

@Test @MainActor func latencyPublicationIsDeferredUntilMenuTrackingEnds() {
  let first = LatencyPublication(
    response: HelperResponse(
      success: true,
      coreRunning: true,
      delays: [NodeDelay(node: ProxyNodeID(rawValue: "a"), milliseconds: 10)],
      message: "first"
    ),
    profileID: nil,
    activeProfileID: nil,
    operationGeneration: 0,
    runtimeGeneration: 0
  )
  let second = LatencyPublication(
    response: HelperResponse(
      success: true,
      coreRunning: true,
      delays: [NodeDelay(node: ProxyNodeID(rawValue: "b"), milliseconds: 20)],
      message: "second"
    ),
    profileID: nil,
    activeProfileID: nil,
    operationGeneration: 0,
    runtimeGeneration: 0
  )
  let coordinator = LatencyPublicationCoordinator()

  coordinator.beginMenuTracking()
  #expect(coordinator.submit(first) == nil)
  coordinator.beginMenuTracking()
  #expect(coordinator.submit(second) == nil)
  #expect(coordinator.endMenuTracking() == nil)
  let published = coordinator.endMenuTracking()

  #expect(published?.response.delays.map(\.node) == [ProxyNodeID(rawValue: "b")])
  #expect(published?.response.delays.map(\.milliseconds) == [20])
  #expect(published?.response.success == true)
}
