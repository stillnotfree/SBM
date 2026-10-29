import Foundation
import Testing

@testable import SBM

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

@Test func runtimeLivenessReportsObservationFreshness() {
  let now = Date(timeIntervalSince1970: 1_000)

  #expect(
    RuntimeLivenessPolicy.isFresh(
      lastObservationAt: now.addingTimeInterval(-30),
      now: now
    )
  )
  #expect(
    !RuntimeLivenessPolicy.isFresh(
      lastObservationAt: now.addingTimeInterval(-91),
      now: now
    )
  )
  #expect(
    !RuntimeLivenessPolicy.isFresh(
      lastObservationAt: nil,
      now: now
    )
  )
}
