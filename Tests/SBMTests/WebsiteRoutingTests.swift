import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

private func websiteTestConnection() -> ManagedConnection {
  ManagedConnection(
    id: ProxyNodeID(rawValue: "node-website"),
    outbound: .shadowsocks(
      ShadowsocksProfile(
        server: "proxy.example.test",
        port: 443,
        method: "aes-256-gcm",
        password: "test-password",
        displayName: "Proxy"
      )
    )
  )
}

@Test func websiteDomainNormalizationIsStrictAndDeterministic() throws {
  #expect(try WebsiteDomainNormalizer.normalize(" stepik.org ") == "stepik.org")
  #expect(try WebsiteDomainNormalizer.normalize("STEPiK.ORG") == "stepik.org")
  #expect(try WebsiteDomainNormalizer.normalize("stepik.org.") == "stepik.org")
  #expect(
    try WebsiteDomainNormalizer.normalize("https://stepik.org/course/1?unit=2#lesson")
      == "stepik.org"
  )
  #expect(
    try WebsiteDomainNormalizer.normalize("https://пример.рф/course")
      == "xn--e1afmkfd.xn--p1ai"
  )

  for invalid in [
    "", "*.stepik.org", "^stepik\\.org$", "/course/1", "ftp://stepik.org/file",
    "https://user:password@stepik.org/", "127.0.0.1", "[2001:db8::1]", "single-label",
    "bad..example",
  ] {
    #expect(throws: (any Error).self) {
      _ = try WebsiteDomainNormalizer.normalize(invalid)
    }
  }
}

@Test func websiteRulesRoundTripInCurrentProfileLibrary() throws {
  let rule = WebsiteRoutingRule(domain: "stepik.org", target: .selectedProxy)
  let profile = ManagedProfile(
    name: "Websites",
    payload: .compatibility(
      VPNProfile(connections: [websiteTestConnection()], websiteRoutingRules: [rule])
    )
  )
  let library = ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  let data = try JSONEncoder().encode(library)
  let decoded = try JSONDecoder().decode(ProfileLibrary.self, from: data)
  #expect(decoded.profiles.first?.payload?.websiteRoutingRules == [rule])

}

@Test func websiteRuleChangesRequireRuntimeConvergence() {
  let base = CoreProfile.compatibility(
    VPNProfile(connections: [websiteTestConnection()])
  )
  let changed = CoreProfile.compatibility(
    VPNProfile(
      connections: [websiteTestConnection()],
      websiteRoutingRules: [
        WebsiteRoutingRule(domain: "stepik.org", target: .selectedProxy)
      ]
    )
  )
  #expect(ManagedConnectionReconciler.requiresActivation(previous: base, next: changed))
}

@Test func subscriptionReconciliationPreservesWebsiteRules() {
  let rule = WebsiteRoutingRule(domain: "stepik.org", target: .direct)
  let existing = CoreProfile.compatibility(
    VPNProfile(connections: [websiteTestConnection()], websiteRoutingRules: [rule])
  )
  let fetched = CoreProfile.compatibility(
    VPNProfile(connections: [websiteTestConnection()])
  )
  let reconciled = ManagedConnectionReconciler.reconcile(existing: existing, fetched: fetched)
  #expect(reconciled.websiteRoutingRules == [rule])
}

@Test func compatibilityApplicationRulesPrecedeWebsiteAndImportedRouting() throws {
  let website = WebsiteRoutingRule(domain: "stepik.org", target: .selectedProxy)
  let application = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .direct
  )
  let imported = RoutingPolicy(
    configuration: Data(
      #"{"route":{"rules":[{"domain_suffix":[".org"],"action":"route","outbound":"direct"}]}}"#
        .utf8
    )
  )
  let profile = VPNProfile(
    connections: [websiteTestConnection()],
    routingPolicy: imported,
    applicationRoutingRules: [application],
    websiteRoutingRules: [website]
  )
  let built = try ConfigBuilder(cachePath: "/tmp/cache.db", apiSecret: "test-secret")
    .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let route = try #require(root["route"] as? [String: Any])
  let rules = try #require(route["rules"] as? [[String: Any]])
  let privateIndex = try #require(rules.firstIndex { $0["ip_is_private"] as? Bool == true })
  let websiteIndex = try #require(
    rules.firstIndex { ($0["domain"] as? [String]) == ["stepik.org"] })
  let applicationIndex = try #require(rules.firstIndex { $0["process_path"] != nil })
  let importedIndex = try #require(
    rules.firstIndex { ($0["domain_suffix"] as? [String]) == [".org"] })
  #expect(applicationIndex < privateIndex)
  #expect(privateIndex < websiteIndex)
  #expect(applicationIndex < importedIndex)
  #expect(websiteIndex < importedIndex)

  let dns = try #require(root["dns"] as? [String: Any])
  let dnsRules = try #require(dns["rules"] as? [[String: Any]])
  let appDNSIndex = try #require(
    dnsRules.firstIndex {
      $0["process_path"] as? [String] == [application.executablePath]
    }
  )
  #expect(dnsRules[appDNSIndex]["action"] as? String == "route")
  #expect(dnsRules[appDNSIndex]["server"] as? String == "dns-local")
  #expect(
    appDNSIndex
      < (dnsRules.firstIndex { $0["domain_suffix"] as? [String] == [".org"] } ?? Int.max)
  )
  #expect(dnsRules.last?["server"] as? String == "dns-remote")

  let composed = try ComposedRoutingInspection.make(profile: .compatibility(profile))
  for domain in ["stepik.org", "welcome.stepik.org"] {
    let result = RoutingInspector.inspect(
      route: composed.route,
      context: RoutingInspectionContext(
        domain: domain,
        ipAddress: "93.184.216.34",
        applicationPath: application.executablePath
      ),
      outboundDecisions: composed.outboundDecisions,
    )
    #expect(result.decision == .direct)
    #expect(result.ruleIndex == 3)

    let defaultResult = RoutingInspector.inspect(
      route: composed.route,
      context: RoutingInspectionContext(
        domain: domain,
        ipAddress: "93.184.216.34",
        defaultApplicationPaths: [application.executablePath]
      ),
      outboundDecisions: composed.outboundDecisions,
    )
    #expect(defaultResult.decision == .vpn)
    #expect(defaultResult.ruleIndex == 7)
  }
}

@Test func websiteDirectAndRejectRulesComposeForManagedProfile() throws {
  let direct = WebsiteRoutingRule(domain: "direct.example", target: .direct)
  let reject = WebsiteRoutingRule(domain: "reject.example", target: .reject)
  let compatibility = VPNProfile(
    connections: [websiteTestConnection()],
    websiteRoutingRules: [direct, reject]
  )
  let compatibilityBuilt = try ConfigBuilder(
    cachePath: "/tmp/cache.db", apiSecret: "test-secret"
  ).makeConfiguration(profile: .compatibility(compatibility), mode: .rule, selectedNode: .auto)
  let compatibilityRoot = try #require(
    JSONSerialization.jsonObject(with: compatibilityBuilt.data) as? [String: Any]
  )
  let compatibilityDNS = try #require(compatibilityRoot["dns"] as? [String: Any])
  let compatibilityDNSRules = try #require(compatibilityDNS["rules"] as? [[String: Any]])
  #expect(
    compatibilityDNSRules.contains {
      ($0["domain"] as? [String]) == ["direct.example"]
        && ($0["server"] as? String) == "dns-local"
    }
  )
  #expect(
    !compatibilityDNSRules.contains {
      ($0["domain"] as? [String]) == ["reject.example"]
    }
  )

}
