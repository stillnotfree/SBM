import AppKit
import SBMShared
import Testing

@testable import SBM

@Test func serverMenuTitleShowsSelectionAndMeasuredDelay() {
  let title = ProxyNodeMenuPresentation.latencyLabel(
    delay: 42,
    testCompleted: true
  )
  #expect(title == "42 ms")
}

@Test func serverMenuTitleReservesSelectionSpaceBeforeTesting() {
  let title = ProxyNodeMenuPresentation.latencyLabel(
    delay: nil,
    testCompleted: false
  )
  #expect(title.isEmpty)
}

@Test func serverMenuLatencyShowsTimeoutAfterTesting() {
  let title = ProxyNodeMenuPresentation.latencyLabel(
    delay: nil,
    testCompleted: true
  )
  #expect(title == "timeout")
}

@Test func appWindowsUseNormalLevelAndStableIdentifier() {
  #expect(SBMWindow.profiles.level == .normal)
  #expect(SBMWindow.diagnostics.level == .normal)
  #expect(SBMWindow.about.level == .normal)
  #expect(Set(SBMWindow.allCases.map(\.identifier)).count == SBMWindow.allCases.count)
}

@Test func preservedRuntimeFailureUsesProtectedPresentationIcon() {
  let presentation = ConnectionPresentation.failed(previousRuntimePreserved: true)
  #expect(presentation.systemImage == "lock.shield.fill")
  #expect(presentation.title.contains("previous VPN active"))
}

@Test func deferredRuntimeApplyUsesOneExplicitActionForEachObservedState() {
  let running = DeferredRuntimeApplyPresentation(
    headline: DeferredRuntimeApplyPresentation.changesReadyToApply,
    action: .reconnect,
    phase: .pending
  )
  #expect(running.headline == "Changes ready to apply")
  #expect(running.action.title == "Reconnect to Apply")

  let stopped = DeferredRuntimeApplyPresentation(
    headline: DeferredRuntimeApplyPresentation.changesReadyToApply,
    action: .reconnect,
    phase: .pending
  )
  #expect(stopped.headline == "Changes ready to apply")
  #expect(stopped.action.title == "Reconnect to Apply")
}
