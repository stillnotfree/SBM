import Foundation
import Testing

@testable import SBM

@Test @MainActor func defaultAppModelUsesHermeticEnvironment() {
  let model = AppModel(performStartup: false)

  #expect(model.dependencyEnvironmentKind == .hermetic)
}

@Test @MainActor func hermeticEnvironmentHasNoLiveRuntimeOrNetworkTransport() async {
  let environment = AppEnvironment.hermetic()

  await #expect(throws: AppEnvironmentFailure.self) {
    _ = try await environment.runtimeStateReader()
  }
  await #expect(throws: AppEnvironmentFailure.self) {
    _ = try await environment.subscriptionManager.synchronize(
      ManagedSource(value: "https://example.com")
    )
  }
}

@Test func runtimeLivenessDecaysAStaleRunningObservationToUnknown() {
  let now = Date(timeIntervalSince1970: 1_000)

  #expect(
    RuntimeLivenessPolicy.presentationState(
      observed: .running,
      lastObservationAt: now.addingTimeInterval(-30),
      now: now
    ) == .running
  )
  #expect(
    RuntimeLivenessPolicy.presentationState(
      observed: .running,
      lastObservationAt: now.addingTimeInterval(-91),
      now: now
    ) == .unknown
  )
  #expect(
    RuntimeLivenessPolicy.presentationState(
      observed: .stopped,
      lastObservationAt: nil,
      now: now
    ) == .stopped
  )
}
