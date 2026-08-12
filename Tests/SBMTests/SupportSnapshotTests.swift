import Foundation
import SBMShared
import Testing

@testable import SBM

@Test func supportSnapshotIsRedactedBoundedAndDecodable() throws {
  let urlCanary = "https://subscription-canary.example/secret-path"
  let passwordCanary = "password-canary"
  let hardwareIDCanary = "9d2c43a3-5f5d-4f31-924f-2e5b0a8d7c11"
  let nativeJSONCanary = #"{"outbounds":[{"password":"native-json-canary"}]}"#
  let snapshot = SupportSnapshot(
    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
    appVersion: "1.2.3",
    appBuild: "123",
    macOSVersion: "macOS test",
    helperReachable: true,
    helperVersion: "1.2.3",
    helperRevision: 40,
    helperState: .reachable,
    coreRunning: true,
    coreVersion: "1.13.16",
    routingMode: .rule,
    profileKind: .nativeJSON,
    profileUpdatedAt: Date(timeIntervalSince1970: 1_700_000_001),
    profileLibraryAvailable: true,
    sourceCount: 999,
    localSOCKSEnabled: true,
    localSOCKSPort: 1082,
    selectedProtocolKind: .vless,
    nodes: (0..<130).map { _ in
      SupportSnapshot.NodeObservation(kind: .vless, delayMilliseconds: 42)
    },
    lastError:
      "Failed for \(urlCanary), password=\(passwordCanary), hwid=\(hardwareIDCanary), \(nativeJSONCanary)",
    redactionSecrets: [urlCanary, passwordCanary, hardwareIDCanary]
  )

  let text = snapshot.text
  let json = snapshot.jsonText()
  for canary in [urlCanary, passwordCanary, hardwareIDCanary, nativeJSONCanary] {
    #expect(!text.contains(canary))
    #expect(!json.contains(canary))
  }
  #expect(snapshot.profile.sourceCount == SupportSnapshot.maximumSources)
  #expect(snapshot.profile.sourceCountCapped)
  #expect(snapshot.nodeObservationsCapped)
  #expect(json.utf8.count <= SupportSnapshot.maximumSerializedBytes)

  let decoded = try JSONDecoder().decode(
    SupportSnapshot.self, from: try #require(json.data(using: .utf8)))
  #expect(decoded.schemaVersion == SupportSnapshot.schemaVersion)
  #expect(!decoded.activeProbesRun)
  #expect(
    decoded.protocolSummaries == [
      SupportSnapshot.ProtocolSummary(
        kind: .vless,
        nodeCount: SupportSnapshot.maximumNodes,
        delays: SupportSnapshot.DelaySummary(
          measuredCount: SupportSnapshot.maximumNodes,
          unmeasuredCount: 0,
          minimumMilliseconds: 42,
          maximumMilliseconds: 42
        )
      )
    ])
}

@Test func supportSnapshotTextAndJSONDescribeKnownObservations() throws {
  let snapshot = SupportSnapshot(
    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
    appVersion: "1.2.3",
    appBuild: "123",
    macOSVersion: "macOS test",
    helperReachable: false,
    helperVersion: nil,
    helperRevision: nil,
    helperState: .notEnabled,
    coreRunning: false,
    coreVersion: nil,
    routingMode: .direct,
    profileKind: .compatibilitySubscription,
    profileUpdatedAt: nil,
    profileLibraryAvailable: false,
    sourceCount: 2,
    localSOCKSEnabled: false,
    localSOCKSPort: 1082,
    selectedProtocolKind: .hysteria2,
    nodes: [
      SupportSnapshot.NodeObservation(kind: .hysteria2, delayMilliseconds: 30),
      SupportSnapshot.NodeObservation(kind: .hysteria2, delayMilliseconds: nil),
      SupportSnapshot.NodeObservation(kind: .shadowsocks, delayMilliseconds: 70),
    ],
    lastError: nil,
    redactionSecrets: []
  )

  #expect(snapshot.text.contains("observations only"))
  #expect(snapshot.text.contains("Active DNS/network probes run: no"))
  #expect(snapshot.text.contains("hysteria2: 2 nodes, 1 measured, 1 unmeasured, 30 ms"))
  #expect(snapshot.text.contains("shadowsocks: 1 nodes, 1 measured, 0 unmeasured, 70 ms"))
  let json = snapshot.jsonText()
  #expect(json.contains(#""active_probes_run":false"#))
  #expect(json.contains(#""routing_mode":"Direct""#))
  #expect(json.contains(#""selected_protocol_kind":"hysteria2""#))
  #expect(json.contains(#""state":"not_enabled""#))
}

@Test func diagnosticsRefreshDoesNotDirectlyStartLatencyTesting() throws {
  let packageRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let source = try String(
    contentsOf: packageRoot.appending(path: "Sources/SBM/SBMApp.swift"), encoding: .utf8)
  #expect(!source.contains("model.testLatency()"))
}
