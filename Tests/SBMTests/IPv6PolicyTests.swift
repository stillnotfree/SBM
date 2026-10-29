import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

private func ipv6CompatibilityProfile() -> CoreProfile {
  let connection = ManagedConnection(
    outbound: .shadowsocks(
      ShadowsocksProfile(
        server: "203.0.113.10",
        port: 443,
        method: "aes-256-gcm",
        password: "synthetic-test-password",
        displayName: "Test"
      )
    )
  )
  return .compatibility(
    VPNProfile(
      connections: [connection],
      websiteRoutingRules: [
        WebsiteRoutingRule(domain: "proxy.example", target: .selectedProxy),
        WebsiteRoutingRule(domain: "direct.example", target: .direct),
        WebsiteRoutingRule(domain: "reject.example", target: .reject),
      ]
    )
  )
}

private func ipv6RejectIndex(in root: [String: Any]) -> Int? {
  let route = root["route"] as? [String: Any]
  let rules = route?["rules"] as? [[String: Any]]
  return rules?.firstIndex {
    ($0["ip_version"] as? Int) == 6 && ($0["action"] as? String) == "reject"
  }
}

@Test func generatedIPv6PolicyKeepsDualStackAndCoreCheckForBothStates() throws {
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMIPv6Policy-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".vendor/sing-box")

  let profile = ipv6CompatibilityProfile()
  for ipv6Enabled in [false, true] {
    for mode in [RoutingMode.rule, .global, .direct] {
      let built = try ConfigBuilder(
        cachePath: temporary.appendingPathComponent(
          "\(ipv6Enabled)-\(mode.rawValue).db"
        ).path,
        apiSecret: "synthetic-api-secret"
      ).makeConfiguration(
        profile: profile,
        mode: mode,
        selectedNode: .auto,
        ipv6Enabled: ipv6Enabled
      )
      let root = try #require(
        JSONSerialization.jsonObject(with: built.data) as? [String: Any]
      )
      let inbounds = try #require(root["inbounds"] as? [[String: Any]])
      let tunnel = try #require(inbounds.first { ($0["type"] as? String) == "tun" })
      let addresses = try #require(tunnel["address"] as? [String])
      #expect(addresses.contains("172.19.0.1/30"))
      #expect(addresses.contains("fdfe:dcba:9876::1/126"))
      #expect(tunnel["auto_route"] as? Bool == true)
      #expect(tunnel["strict_route"] as? Bool == true)
      #expect(tunnel["stack"] as? String == "system")

      let dns = try #require(root["dns"] as? [String: Any])
      #expect((dns["strategy"] as? String) == (ipv6Enabled ? nil : "ipv4_only"))
      let route = try #require(root["route"] as? [String: Any])
      let rules = try #require(route["rules"] as? [[String: Any]])
      let sniffIndex = try #require(
        rules.firstIndex { ($0["action"] as? String) == "sniff" }
      )
      if ipv6Enabled {
        #expect(ipv6RejectIndex(in: root) == nil)
      } else {
        let rejectIndex = try #require(ipv6RejectIndex(in: root))
        #expect(rejectIndex < sniffIndex)
        #expect(rules[rejectIndex]["outbound"] == nil)
        #expect(rules[rejectIndex]["clash_mode"] == nil)
      }
      #expect(route["final"] as? String == built.selectorTag)

      let configURL = temporary.appendingPathComponent(
        "\(ipv6Enabled)-\(mode.rawValue).json"
      )
      try built.data.write(to: configURL)
      let result = try TestProcessSupport.run(
        executableURL: core,
        arguments: ["check", "-c", configURL.path]
      )
      #expect(result.status == 0, Comment(rawValue: result.output))
    }
  }
}

@Test func helperResponseKeepsActiveIPv6SeparateFromDesiredAndLegacyDecodesUnknown() throws {
  let response = HelperResponse(
    success: true,
    coreRunning: true,
    activeIPv6Enabled: false,
    message: "active"
  )
  let encoded = try JSONEncoder().encode(response)
  let decoded = try JSONDecoder().decode(HelperResponse.self, from: encoded)
  #expect(decoded.activeIPv6Enabled == false)

  var legacyObject = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
  )
  legacyObject.removeValue(forKey: "activeIPv6Enabled")
  let legacy = try JSONDecoder().decode(
    HelperResponse.self,
    from: try JSONSerialization.data(withJSONObject: legacyObject)
  )
  #expect(legacy.activeIPv6Enabled == nil)
}

@Test func existingConfigurationRecoveryPreservesUnknownActiveIPv6Policy() throws {
  let legacy = try JSONDecoder().decode(
    PersistentState.self,
    from: Data(
      """
      {
        "desiredRunning": true,
        "automaticRecoveryAttempted": false,
        "apiSecret": "legacy-recovery"
      }
      """.utf8
    )
  )
  #expect(legacy.activeIPv6Policy == nil)

  let afterRecovery = ActiveIPv6PolicyTransition.afterExistingConfigurationRecovery(
    activePolicyKnown: legacy.activeIPv6PolicyKnown,
    activePolicy: legacy.activeIPv6Enabled
  )
  #expect(!afterRecovery.known)
  #expect(afterRecovery.value == nil)

  var persisted = legacy
  persisted.activeIPv6PolicyKnown = afterRecovery.known
  persisted.activeIPv6Enabled = afterRecovery.value
  let reloaded = try JSONDecoder().decode(
    PersistentState.self,
    from: JSONEncoder().encode(persisted)
  )
  #expect(reloaded.activeIPv6Policy == nil)
}

@Test func existingConfigurationRecoveryPreservesAlreadyKnownActiveIPv6Policy() {
  for active in [false, true] {
    let afterRecovery = ActiveIPv6PolicyTransition.afterExistingConfigurationRecovery(
      activePolicyKnown: true,
      activePolicy: active
    )
    #expect(afterRecovery.known)
    #expect(afterRecovery.value == active)
  }
}

@Test func byteIdenticalValidatedConfigurationMarksActiveIPv6PolicyKnown() {
  let identical = ActiveIPv6PolicyTransition.afterValidatedByteIdenticalSnapshot(
    desired: false,
    configurationMatches: true
  )
  let changed = ActiveIPv6PolicyTransition.afterValidatedByteIdenticalSnapshot(
    desired: false,
    configurationMatches: false
  )

  #expect(identical.known)
  #expect(identical.value == false)
  #expect(!changed.known)
  #expect(changed.value == nil)
}

@Test func routingInspectorMatchesIPv6PolicyForLiteralAddresses() throws {
  let profile = ipv6CompatibilityProfile()
  for ipv6Enabled in [false, true] {
    let composed = try ComposedRoutingInspection.make(
      profile: profile,
      ipv6Enabled: ipv6Enabled
    )
    for (mode, expected) in [
      (RoutingMode.rule, ipv6Enabled ? RoutingInspectionResult.Decision.vpn : .reject),
      (.global, ipv6Enabled ? .vpn : .reject),
      (.direct, ipv6Enabled ? .direct : .reject),
    ] {
      let literal = RoutingInspector.inspect(
        route: composed.route,
        context: RoutingInspectionContext(
          ipAddress: "2001:4860:4860::8888", mode: mode, inboundTag: composed.inboundTag
        ),
        outboundDecisions: composed.outboundDecisions,
      )
      #expect(literal.decision == expected)
      if ipv6Enabled {
        #expect(literal.ruleIndex != 0)
      } else {
        #expect(literal.ruleIndex == 0)
      }
    }

    let domainOnly = RoutingInspector.inspect(
      route: composed.route,
      context: RoutingInspectionContext(domain: "example.com"),
      outboundDecisions: composed.outboundDecisions,
    )
    #expect(
      domainOnly.decision == .indeterminate || domainOnly.decision == .vpn
    )
    if domainOnly.decision == .indeterminate {
      #expect(domainOnly.alternatives.isEmpty == false)
    }
  }
}
