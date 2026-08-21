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

@Test func websiteRulesRoundTripAndOlderLibrariesDefaultToEmpty() throws {
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

  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object["schemaVersion"] = 3
  var profiles = try #require(object["profiles"] as? [[String: Any]])
  var storedProfile = profiles[0]
  var payload = try #require(storedProfile["payload"] as? [String: Any])
  var compatibility = try #require(payload["compatibility"] as? [String: Any])
  var associated = try #require(compatibility["_0"] as? [String: Any])
  associated.removeValue(forKey: "websiteRoutingRules")
  compatibility["_0"] = associated
  payload["compatibility"] = compatibility
  storedProfile["payload"] = payload
  profiles[0] = storedProfile
  object["profiles"] = profiles
  let oldData = try JSONSerialization.data(withJSONObject: object)
  let migrated = try JSONDecoder().decode(ProfileLibrary.self, from: oldData)
  #expect(migrated.profiles.first?.payload?.websiteRoutingRules.isEmpty == true)
  #expect(migrated.requiresMigration)
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

@Test func compatibilityWebsiteRulesPrecedeApplicationAndImportedRouting() throws {
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
  #expect(privateIndex < websiteIndex)
  #expect(websiteIndex < applicationIndex)
  #expect(applicationIndex < importedIndex)

  let dns = try #require(root["dns"] as? [String: Any])
  let dnsRules = try #require(dns["rules"] as? [[String: Any]])
  #expect(!dnsRules.contains { ($0["domain"] as? [String]) == ["stepik.org"] })

  let composed = try ComposedRoutingInspection.make(profile: .compatibility(profile))
  for domain in ["stepik.org", "welcome.stepik.org"] {
    let result = RoutingInspector.inspect(
      route: composed.route,
      context: RoutingInspectionContext(
        domain: domain,
        applicationPath: application.executablePath
      ),
      outboundDecisions: composed.outboundDecisions,
      selectorOutbound: composed.selectorOutbound
    )
    #expect(result.decision == .indeterminate)
    #expect(result.fallback?.decision == .vpn)
    #expect(result.fallback?.matchedRule.contains("Website Routing") == true)
  }
}

@Test func websiteDirectAndRejectRulesComposeForCompatibilityAndNative() throws {
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

  let nativeJSON = Data(
    #"{"outbounds":[{"type":"socks","tag":"proxy-node","server":"127.0.0.1","server_port":1080},{"type":"selector","tag":"proxy","outbounds":["proxy-node"]}],"route":{"rules":[]}}"#
      .utf8
  )
  let native = NativeProfile(
    configuration: nativeJSON,
    selectorTag: "proxy",
    nodes: [
      ProxyNodeDescriptor(id: ProxyNodeID(rawValue: "proxy-node"), name: "Proxy", kind: .native)
    ],
    websiteRoutingRules: [direct, reject]
  )
  let nativeBuilt = try ConfigBuilder(cachePath: "/tmp/cache.db", apiSecret: "test-secret")
    .makeConfiguration(
      profile: .native(native), mode: .rule, selectedNode: ProxyNodeID(rawValue: "proxy-node"))
  let nativeRoot = try #require(
    JSONSerialization.jsonObject(with: nativeBuilt.data) as? [String: Any])
  let nativeRoute = try #require(nativeRoot["route"] as? [String: Any])
  let nativeRules = try #require(nativeRoute["rules"] as? [[String: Any]])
  #expect(
    nativeRules.contains {
      ($0["domain"] as? [String]) == ["reject.example"]
        && ($0["action"] as? String) == "reject"
    }
  )
  let nativeDNS = try #require(nativeRoot["dns"] as? [String: Any])
  let nativeDNSRules = try #require(nativeDNS["rules"] as? [[String: Any]])
  #expect(
    nativeDNSRules.contains {
      ($0["domain"] as? [String]) == ["direct.example"]
        && ($0["server"] as? String) == "sbm-dns-local"
    }
  )
}
