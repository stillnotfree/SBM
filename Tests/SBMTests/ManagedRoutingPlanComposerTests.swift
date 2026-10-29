import Foundation
import SBMShared
import Testing

@Test func managedRoutingPlanComposerOrdersManagedRouteLayers() throws {
  let fixedNode = ProxyNodeID(rawValue: "node-fixed")
  let applications = [
    ApplicationRoutingRule(
      displayName: "Direct",
      bundlePath: "/Applications/Direct.app",
      executablePath: "/Applications/Direct.app/Contents/MacOS/../MacOS/Direct",
      target: .direct
    ),
    ApplicationRoutingRule(
      displayName: "Selected",
      bundlePath: "/Applications/Selected.app",
      executablePath: "/Applications/Selected.app/Contents/MacOS/Selected",
      target: .selectedProxy
    ),
    ApplicationRoutingRule(
      displayName: "Fixed",
      bundlePath: "/Applications/Fixed.app",
      executablePath: "/Applications/Fixed.app/Contents/MacOS/Fixed",
      target: .node(fixedNode)
    ),
    ApplicationRoutingRule(
      displayName: "Reject",
      bundlePath: "/Applications/Reject.app",
      executablePath: "/Applications/Reject.app/Contents/MacOS/Reject",
      target: .reject
    ),
    ApplicationRoutingRule(
      displayName: "Inactive",
      bundlePath: "/Applications/Inactive.app",
      executablePath: "/Applications/Inactive.app/Contents/MacOS/Inactive",
      target: .node(ProxyNodeID(rawValue: "node-missing"))
    ),
  ]
  let importedPolicy = RoutingPolicy(
    configuration: Data(
      #"{"route":{"rules":[{"domain_suffix":[".imported.example.test"],"action":"route","outbound":"direct"}]}}"#
        .utf8
    )
  )
  let profile = VPNProfile(
    connections: [managedRoutingPlanTestConnection(id: fixedNode)],
    routingPolicy: importedPolicy,
    applicationRoutingRules: applications,
    websiteRoutingRules: [WebsiteRoutingRule(domain: "example.test", target: .reject)]
  )

  let rules = ManagedRoutingPlanComposer.routeRules(for: profile, ipv6Enabled: false)
  #expect(rules[0]["ip_version"] as? Int == 6)
  #expect(rules[1]["action"] as? String == "sniff")
  #expect(rules[2]["action"] as? String == "hijack-dns")

  let directIndex = try #require(
    routingRuleIndex(
      rules,
      processPath: URL(fileURLWithPath: applications[0].executablePath).standardizedFileURL.path
    )
  )
  let selectedIndex = try #require(
    routingRuleIndex(rules, processPath: applications[1].executablePath))
  let fixedIndex = try #require(
    routingRuleIndex(rules, processPath: applications[2].executablePath))
  let rejectIndex = try #require(
    routingRuleIndex(rules, processPath: applications[3].executablePath))
  #expect(routingRuleIndex(rules, processPath: applications[4].executablePath) == nil)
  let directModeIndex = try #require(routingRuleIndex(rules, matcher: "Direct"))
  let globalModeIndex = try #require(routingRuleIndex(rules, matcher: "Global"))
  let privateIndex = try #require(rules.firstIndex { $0["ip_is_private"] as? Bool == true })
  let websiteIndex = try #require(
    rules.firstIndex { $0["domain"] as? [String] == ["example.test"] }
  )

  #expect(directIndex == 3)
  #expect(rules[directIndex]["outbound"] as? String == "direct")
  #expect(rules[selectedIndex]["outbound"] as? String == "proxy-selector")
  #expect(rules[fixedIndex]["outbound"] as? String == fixedNode.rawValue)
  #expect(rules[rejectIndex]["action"] as? String == "reject")
  #expect(rules[rejectIndex]["outbound"] == nil)
  #expect(directModeIndex == 7)
  #expect(globalModeIndex == 8)
  #expect(privateIndex == 9)
  #expect(websiteIndex == 10)
  #expect(directIndex < directModeIndex && selectedIndex < directModeIndex)
  #expect(fixedIndex < directModeIndex && rejectIndex < privateIndex)
  #expect(
    !rules.contains {
      $0["domain_suffix"] as? [String] == [".imported.example.test"]
    }
  )

  let ipv6Allowed = ManagedRoutingPlanComposer.routeRules(for: profile, ipv6Enabled: true)
  #expect(ipv6Allowed.first?["action"] as? String == "sniff")
  #expect(!ipv6Allowed.contains { $0["ip_version"] as? Int == 6 })
}

@Test func managedRoutingPlanComposerOrdersOnlyDirectApplicationDNS() {
  let directPath = "/Applications/Direct.app/Contents/MacOS/Direct"
  let nonstandardDirectPath = "/Applications/Direct.app/Contents/MacOS/../MacOS/Direct"
  let profile = VPNProfile(
    connections: [managedRoutingPlanTestConnection(id: ProxyNodeID(rawValue: "node-fixed"))],
    applicationRoutingRules: [
      ApplicationRoutingRule(
        displayName: "Direct",
        bundlePath: "/Applications/Direct.app",
        executablePath: nonstandardDirectPath,
        target: .direct
      ),
      ApplicationRoutingRule(
        displayName: "Selected",
        bundlePath: "/Applications/Selected.app",
        executablePath: "/Applications/Selected.app/Contents/MacOS/Selected",
        target: .selectedProxy
      ),
      ApplicationRoutingRule(
        displayName: "Fixed",
        bundlePath: "/Applications/Fixed.app",
        executablePath: "/Applications/Fixed.app/Contents/MacOS/Fixed",
        target: .node(ProxyNodeID(rawValue: "node-fixed"))
      ),
      ApplicationRoutingRule(
        displayName: "Inactive",
        bundlePath: "/Applications/Inactive.app",
        executablePath: "/Applications/Inactive.app/Contents/MacOS/Inactive",
        target: .node(ProxyNodeID(rawValue: "node-missing"))
      ),
      ApplicationRoutingRule(
        displayName: "Reject",
        bundlePath: "/Applications/Reject.app",
        executablePath: "/Applications/Reject.app/Contents/MacOS/Reject",
        target: .reject
      ),
    ],
    websiteRoutingRules: [
      WebsiteRoutingRule(domain: "direct.example.test", target: .direct),
      WebsiteRoutingRule(domain: "reject.example.test", target: .reject),
    ]
  )

  let rules = ManagedRoutingPlanComposer.dnsRules(for: profile)
  #expect(rules.count == 3)
  #expect(rules[0]["clash_mode"] as? String == RoutingMode.direct.rawValue)
  #expect(rules[0]["server"] as? String == "dns-local")
  #expect(rules[1]["action"] as? String == "route")
  #expect(rules[2]["domain"] as? [String] == ["direct.example.test"])
  #expect(rules[1]["process_path"] as? [String] == [directPath])
  #expect(rules[1]["server"] as? String == "dns-local")
  #expect(
    !rules.contains {
      $0["process_path"] as? [String] == [
        "/Applications/Selected.app/Contents/MacOS/Selected"
      ]
    })
}

private func managedRoutingPlanTestConnection(id: ProxyNodeID) -> ManagedConnection {
  ManagedConnection(
    id: id,
    outbound: .shadowsocks(
      ShadowsocksProfile(
        server: "vpn.example.test",
        port: 443,
        method: "aes-128-gcm",
        password: "test-password",
        displayName: "Test"
      )
    )
  )
}

private func routingRuleIndex(
  _ rules: [[String: Any]],
  processPath: String
) -> Int? {
  rules.firstIndex { $0["process_path"] as? [String] == [processPath] }
}

private func routingRuleIndex(_ rules: [[String: Any]], matcher: String) -> Int? {
  rules.firstIndex { $0["clash_mode"] as? String == matcher }
}
