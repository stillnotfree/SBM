import Foundation
import SBMShared
import Testing

@testable import SBM

@MainActor
private final class LatencyTestHelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState { .enabled }

  func register() throws {}
  func unregister() async throws {}
  func openSystemSettings() {}
}

private actor BulkLatencySender {
  private let response: HelperResponse
  private var requestCount = 0

  init(response: HelperResponse) {
    self.response = response
  }

  func send() -> HelperResponse {
    requestCount += 1
    return response
  }

  func count() -> Int { requestCount }
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

@Test func bulkLatencyRequestTimeoutIsConservativelyBounded() {
  #expect(LatencyRequestPolicy.bulkReceiveTimeoutSeconds == 25)
  #expect(LatencyRequestPolicy.bulkReceiveTimeoutSeconds > 10)
}

@MainActor
private func waitForLatencyCycle(_ model: AppModel) async {
  for _ in 0..<1_000 {
    if !model.latencyTestInProgress { return }
    await Task.yield()
  }
}

@Test @MainActor func bulkLatencyAppliesArbitraryResultsByIDWithoutReorderingNodes() async {
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
  let response = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: profile.id,
    activeIPv6Enabled: false,
    // Deliberately do not use this order for publication.
    nodes: Array(profileNodes.reversed()),
    delays: [
      NodeDelay(node: nodeB, milliseconds: 80),
      NodeDelay(node: nodeC, milliseconds: nil),
      NodeDelay(node: nodeA, milliseconds: 40),
      NodeDelay(node: .auto, milliseconds: nil),
    ],
    message: "latency"
  )
  let sender = BulkLatencySender(response: response)
  let model = AppModel(
    helperService: LatencyTestHelperService(),
    helperLifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        activeIPv6Enabled: false,
        nodes: profileNodes,
        message: "running"
      )
    },
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    latencyCycleSender: { await sender.send() },
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision

  model.refresh()
  for _ in 0..<1_000 {
    if model.helperStatus == "running" { break }
    await Task.yield()
  }

  model.testLatency()
  await waitForLatencyCycle(model)

  #expect(await sender.count() == 1)
  #expect(model.nodes.map(\.id) == [.auto, nodeA, nodeB, nodeC])
  #expect(model.nodes.map(\.name) == ["Auto", "A", "B", "C"])
  #expect(model.nodes.map(\.delay) == [40, 40, 80, nil])
  #expect(model.latencyTestCompleted)
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
