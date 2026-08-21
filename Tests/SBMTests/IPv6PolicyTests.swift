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

private func ipv6NativeProfile() throws -> CoreProfile {
  let parsed = try NativeProfileParser.parse(
    Data(
      #"{"outbounds":[{"type":"socks","tag":"proxy-node","server":"127.0.0.1","server_port":1080}]}"#
        .utf8
    )
  )
  return .native(
    NativeProfile(
      configuration: parsed.configuration,
      selectorTag: parsed.selectorTag,
      nodes: parsed.nodes,
      applicationRoutingRules: parsed.applicationRoutingRules,
      websiteRoutingRules: [
        WebsiteRoutingRule(domain: "proxy.example", target: .selectedProxy),
        WebsiteRoutingRule(domain: "direct.example", target: .direct),
        WebsiteRoutingRule(domain: "reject.example", target: .reject),
      ]
    )
  )
}

@Test func generatedIPv6PolicyIsDualStackStrictAndAcceptedInEveryMode() throws {
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMIPv6Policy-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".vendor/sing-box")

  for (kind, profile) in [
    ("compatibility", ipv6CompatibilityProfile()),
    ("native", try ipv6NativeProfile()),
  ] {
    for mode in [RoutingMode.rule, .global, .direct] {
      let built = try ConfigBuilder(
        cachePath: temporary.appendingPathComponent("\(kind)-\(mode.rawValue).db").path,
        apiSecret: "synthetic-api-secret"
      ).makeConfiguration(profile: profile, mode: mode, selectedNode: .auto)
      let root = try #require(
        JSONSerialization.jsonObject(with: built.data) as? [String: Any]
      )
      let inbounds = try #require(root["inbounds"] as? [[String: Any]])
      let tunnel = try #require(
        inbounds.first { ($0["type"] as? String) == "tun" }
      )
      let addresses = try #require(tunnel["address"] as? [String])
      #expect(addresses.contains("172.19.0.1/30"))
      #expect(addresses.contains("fdfe:dcba:9876::1/126"))
      #expect(tunnel["auto_route"] as? Bool == true)
      #expect(tunnel["strict_route"] as? Bool == true)
      #expect(tunnel["stack"] as? String == "system")

      let dns = try #require(root["dns"] as? [String: Any])
      #expect(dns["strategy"] as? String == "ipv4_only")
      let route = try #require(root["route"] as? [String: Any])
      let rules = try #require(route["rules"] as? [[String: Any]])
      let ipv6RejectIndex = try #require(
        rules.firstIndex {
          ($0["ip_version"] as? Int) == 6
            && ($0["action"] as? String) == "reject"
        }
      )
      let sniffIndex = try #require(
        rules.firstIndex { ($0["action"] as? String) == "sniff" }
      )
      #expect(ipv6RejectIndex < sniffIndex)
      #expect(rules[ipv6RejectIndex]["outbound"] == nil)
      #expect(rules[ipv6RejectIndex]["clash_mode"] == nil)
      #expect(route["final"] as? String == built.selectorTag)

      let configURL = temporary.appendingPathComponent("\(kind)-\(mode.rawValue).json")
      try built.data.write(to: configURL)
      let process = Process()
      let output = Pipe()
      process.executableURL = core
      process.arguments = ["check", "-c", configURL.path]
      process.standardOutput = output
      process.standardError = output
      try process.run()
      process.waitUntilExit()
      let message =
        String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      #expect(process.terminationStatus == 0, Comment(rawValue: message))
    }
  }
}

@Test func literalIPv6IsRejectedBeforeWebsitePolicy() throws {
  for profile in [ipv6CompatibilityProfile(), try ipv6NativeProfile()] {
    let composed = try ComposedRoutingInspection.make(profile: profile)
    for (mode, expected) in [
      (RoutingMode.rule, RoutingInspectionResult.Decision.reject),
      (.global, .reject),
      (.direct, .reject),
    ] {
      let literal = RoutingInspector.inspect(
        route: composed.route,
        context: RoutingInspectionContext(
          ipAddress: "2001:4860:4860::8888", mode: mode, inboundTag: composed.inboundTag
        ),
        outboundDecisions: composed.outboundDecisions,
        selectorOutbound: composed.selectorOutbound
      )
      #expect(literal.decision == expected)
      #expect(literal.ruleIndex == 0)
    }

    for domain in ["proxy.example", "direct.example", "reject.example"] {
      let website = RoutingInspector.inspect(
        route: composed.route,
        context: RoutingInspectionContext(
          domain: domain,
          ipAddress: "2001:4860:4860::8888",
          mode: .rule,
          inboundTag: composed.inboundTag
        ),
        outboundDecisions: composed.outboundDecisions,
        selectorOutbound: composed.selectorOutbound
      )
      #expect(website.decision == .reject)
      #expect(website.ruleIndex == 0)
    }
  }
}
