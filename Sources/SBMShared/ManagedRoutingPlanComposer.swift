import Foundation

public enum ManagedRoutingPlanComposer {
  public static func routeRules(
    for profile: VPNProfile,
    ipv6Enabled: Bool
  ) -> [[String: Any]] {
    var rules: [[String: Any]] = []
    if !ipv6Enabled {
      rules.append(["ip_version": 6, "action": "reject"])
    }
    rules.append(["action": "sniff"])
    rules.append(["protocol": "dns", "action": "hijack-dns"])
    rules.append(contentsOf: applicationRouteRules(for: profile))
    rules.append([
      "clash_mode": RoutingMode.direct.rawValue,
      "action": "route",
      "outbound": "direct",
    ])
    rules.append([
      "clash_mode": RoutingMode.global.rawValue,
      "action": "route",
      "outbound": "proxy-selector",
    ])
    rules.append([
      "ip_is_private": true,
      "action": "route",
      "outbound": "direct",
    ])
    rules.append(contentsOf: websiteRouteRules(for: profile))
    return rules
  }

  public static func dnsRules(for profile: VPNProfile) -> [[String: Any]] {
    var rules: [[String: Any]] = [
      [
        "clash_mode": RoutingMode.direct.rawValue,
        "action": "route",
        "server": "dns-local",
      ]
    ]
    rules.append(contentsOf: applicationDirectDNSRules(for: profile))
    rules.append(contentsOf: websiteDirectDNSRules(for: profile))
    return rules
  }

  private static func applicationRouteRules(for profile: VPNProfile) -> [[String: Any]] {
    let nodeIDs = Set(profile.connections.map(\.id))
    return profile.applicationRoutingRules.compactMap { rule in
      var composed: [String: Any]
      switch rule.target {
      case .direct:
        composed = ["action": "route", "outbound": "direct"]
      case .selectedProxy:
        composed = ["action": "route", "outbound": "proxy-selector"]
      case .reject:
        composed = ["action": "reject"]
      case .node(let node):
        guard nodeIDs.contains(node) else { return nil }
        composed = ["action": "route", "outbound": node.rawValue]
      }
      let executablePath = URL(fileURLWithPath: rule.executablePath).standardizedFileURL.path
      composed["process_path"] = [executablePath]
      return composed
    }
  }

  private static func websiteRouteRules(for profile: VPNProfile) -> [[String: Any]] {
    profile.websiteRoutingRules.map { rule in
      var composed: [String: Any] = [
        "domain": [rule.domain],
        "domain_suffix": [".\(rule.domain)"],
      ]
      switch rule.target {
      case .direct:
        composed["action"] = "route"
        composed["outbound"] = "direct"
      case .selectedProxy:
        composed["action"] = "route"
        composed["outbound"] = "proxy-selector"
      case .reject:
        composed["action"] = "reject"
      }
      return composed
    }
  }

  private static func applicationDirectDNSRules(for profile: VPNProfile) -> [[String: Any]] {
    profile.applicationRoutingRules.compactMap { rule in
      guard case .direct = rule.target else { return nil }
      let executablePath = URL(fileURLWithPath: rule.executablePath).standardizedFileURL.path
      return [
        "process_path": [executablePath],
        "action": "route",
        "server": "dns-local",
      ]
    }
  }

  private static func websiteDirectDNSRules(for profile: VPNProfile) -> [[String: Any]] {
    profile.websiteRoutingRules.compactMap { rule in
      guard case .direct = rule.target else { return nil }
      return [
        "domain": [rule.domain],
        "domain_suffix": [".\(rule.domain)"],
        "action": "route",
        "server": "dns-local",
      ]
    }
  }
}
