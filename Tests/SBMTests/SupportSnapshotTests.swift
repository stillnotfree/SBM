import Foundation
import SBMShared
import Testing

@testable import SBM

private func supportSnapshot(
  coreState: ObservedCoreState,
  localSOCKSEnabled: Bool,
  localSOCKSPort: UInt16
) -> SupportSnapshot {
  SupportSnapshot(
    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
    appVersion: "1.2.3",
    appBuild: "123",
    macOSVersion: "macOS test",
    helperReachable: false,
    helperVersion: nil,
    helperRevision: nil,
    helperState: .unreachable,
    coreState: coreState,
    coreVersion: nil,
    routingMode: .rule,
    profileKind: .compatibilitySubscription,
    profileUpdatedAt: nil,
    profileLibraryAvailable: true,
    sourceCount: 0,
    localSOCKSEnabled: localSOCKSEnabled,
    localSOCKSPort: localSOCKSPort,
    selectedProtocolKind: nil,
    nodes: [],
    lastError: nil,
    redactionSecrets: []
  )
}

@Test func supportSnapshotIsRedactedBoundedAndDecodable() throws {
  let urlCanary = "https://subscription-canary.example/secret-path"
  let passwordCanary = "password-canary"
  let hardwareIDCanary = "9d2c43a3-5f5d-4f31-924f-2e5b0a8d7c11"
  let snapshot = SupportSnapshot(
    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
    appVersion: "1.2.3",
    appBuild: "123",
    macOSVersion: "macOS test",
    helperReachable: true,
    helperVersion: "1.2.3",
    helperRevision: 40,
    helperState: .reachable,
    coreState: .running,
    coreVersion: "1.13.16",
    routingMode: .rule,
    profileKind: .compatibilitySubscription,
    profileUpdatedAt: Date(timeIntervalSince1970: 1_700_000_001),
    profileLibraryAvailable: true,
    sourceCount: 999,
    localSOCKSEnabled: true,
    localSOCKSPort: 1082,
    selectedProtocolKind: .vless,
    nodes: (0..<130).map { _ in
      SupportSnapshot.NodeObservation(kind: .vless, delayMilliseconds: 42)
    },
    lastError: "Failed for \(urlCanary), password=\(passwordCanary), hwid=\(hardwareIDCanary)",
    redactionSecrets: [urlCanary, passwordCanary, hardwareIDCanary]
  )

  let text = snapshot.text
  let json = snapshot.jsonText()
  for canary in [urlCanary, passwordCanary, hardwareIDCanary] {
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
    coreState: .stopped,
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

  #expect(snapshot.text.contains("SBM support snapshot"))
  #expect(!snapshot.text.contains("observations only"))
  #expect(snapshot.text.contains("Local SOCKS5 saved configuration: disabled"))
  #expect(
    snapshot.text.contains("Local SOCKS5 listener presence: not observed by this snapshot"))
  #expect(snapshot.text.contains("Active DNS/network probes run: no"))
  #expect(snapshot.text.contains("hysteria2: 2 nodes, 1 measured, 1 unmeasured, 30 ms"))
  #expect(snapshot.text.contains("shadowsocks: 1 nodes, 1 measured, 0 unmeasured, 70 ms"))
  let json = snapshot.jsonText()
  #expect(json.contains(#""active_probes_run":false"#))
  #expect(json.contains(#""routing_mode":"Direct""#))
  #expect(json.contains(#""selected_protocol_kind":"hysteria2""#))
  #expect(json.contains(#""state":"not_enabled""#))
  #expect(json.contains(#""local_socks":{"enabled":false}"#))
}

@Test func localSOCKSTextDescribesSavedConfigurationWithoutInferringListener() throws {
  let stopped = supportSnapshot(
    coreState: .stopped, localSOCKSEnabled: true, localSOCKSPort: 2080)
  let unknown = supportSnapshot(
    coreState: .unknown, localSOCKSEnabled: true, localSOCKSPort: 2080)
  let running = supportSnapshot(
    coreState: .running, localSOCKSEnabled: true, localSOCKSPort: 2080)
  let disabled = supportSnapshot(
    coreState: .running, localSOCKSEnabled: false, localSOCKSPort: 2080)

  for snapshot in [stopped, unknown, running] {
    #expect(
      snapshot.statusText.contains(
        "Local SOCKS5 saved configuration: enabled on 127.0.0.1:2080"))
    #expect(
      snapshot.statusText.contains(
        "Local SOCKS5 listener presence: not observed by this snapshot"))
    #expect(!snapshot.statusText.localizedCaseInsensitiveContains("listener is active"))
    #expect(!snapshot.statusText.contains("Local SOCKS5: enabled"))
    #expect(
      snapshot.jsonText().contains(#""local_socks":{"enabled":true,"port":2080}"#))
  }
  #expect(stopped.core.state == .stopped)
  #expect(unknown.core.state == .unknown)
  #expect(running.core.state == .running)
  #expect(disabled.statusText.contains("Local SOCKS5 saved configuration: disabled"))
  #expect(
    disabled.statusText.contains(
      "Local SOCKS5 listener presence: not observed by this snapshot"))
  #expect(disabled.jsonText().contains(#""local_socks":{"enabled":false}"#))
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

@Test func maximumRecentErrorsKeepUsefulBoundedStatusAndValidJSON() throws {
  let errors = (0..<50).map { index in
    "Failure \(index): " + String(repeating: Character(UnicodeScalar(97 + index % 26)!), count: 500)
  }
  let snapshot = SupportSnapshot(
    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
    appVersion: "1.2.3",
    appBuild: "123",
    macOSVersion: "macOS test",
    helperReachable: false,
    helperVersion: "1.1.3",
    helperRevision: 43,
    helperState: .unreachable,
    coreState: .unknown,
    coreVersion: "1.13.18",
    routingMode: .rule,
    profileKind: .compatibilitySubscription,
    profileUpdatedAt: nil,
    profileLibraryAvailable: true,
    sourceCount: 2,
    localSOCKSEnabled: false,
    localSOCKSPort: 1082,
    selectedProtocolKind: .shadowsocks,
    nodes: [],
    lastError: "Current useful failure",
    recentErrors: errors,
    redactionSecrets: []
  )

  #expect(snapshot.statusText.contains("Core: unknown"))
  #expect(snapshot.text.contains("Current useful failure"))
  #expect(snapshot.text.contains("truncated"))
  #expect(snapshot.text.utf8.count <= SupportSnapshot.maximumTextBytes)
  #expect(snapshot.recentErrorsTruncated)
  let json = snapshot.jsonText()
  #expect(json.utf8.count <= SupportSnapshot.maximumSerializedBytes)
  let decoded = try JSONDecoder().decode(
    SupportSnapshot.self,
    from: try #require(json.data(using: .utf8))
  )
  #expect(decoded.core.state == .unknown)
  #expect(decoded.recentErrorsTruncated)
  #expect(decoded.lastError == "Current useful failure")
}

@Test func diagnosticsCurrentStatusDoesNotRenderRecentErrorsTwice() throws {
  let root = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let source = try String(
    contentsOf: root.appending(path: "Sources/SBM/SBMApp.swift"), encoding: .utf8)
  #expect(source.contains("Text(snapshot.statusText)"))
  #expect(!source.contains("Text(snapshot.text)"))
}
