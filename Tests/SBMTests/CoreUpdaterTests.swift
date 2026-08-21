import Foundation
import SBMShared
import Testing

@Test func stableCoreVersionComparisonRejectsMalformedValuesAndPreventsDowngrades() throws {
  #expect(StableCoreVersionPolicy.compare("1.13.19", "1.13.18") == 1)
  #expect(StableCoreVersionPolicy.compare("1.13.18", "1.13.18") == 0)
  #expect(StableCoreVersionPolicy.compare("1.13.17", "1.13.18") == -1)
  #expect(StableCoreVersionPolicy.compare("1.13", "1.13.18") == nil)
  #expect(StableCoreVersionPolicy.compare("1.13.x", "1.13.18") == nil)
}

@Test func stableCoreUpdaterContainsExplicitNoDowngradeGate() throws {
  let root = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let source = try String(
    contentsOf: root.appending(path: "scripts/update-core.swift"), encoding: .utf8)
  #expect(source.contains("readPinnedVersion"))
  #expect(source.contains("downgradeRefused"))
  #expect(source.contains(#"Pinned sing-box \(pinnedVersion) is already current."#))
  #expect(source.contains("compareStableVersions"))
}
