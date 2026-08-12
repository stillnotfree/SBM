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

@Test func onlyProfilesWindowUsesFloatingLevelAndStableIdentifier() {
  #expect(SBMWindow.profiles.level == .floating)
  #expect(SBMWindow.diagnostics.level == .normal)
  #expect(SBMWindow.about.level == .normal)
  #expect(Set(SBMWindow.allCases.map(\.identifier)).count == SBMWindow.allCases.count)
}
