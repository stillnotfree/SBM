import Foundation
import SBMShared

struct ConfigBuilder {
  let cachePath: String
  let apiSecret: String

  func makeConfiguration(
    profile: CoreProfile,
    mode: RoutingMode,
    selectedNode: ProxyNodeID,
    localSOCKSPort: UInt16? = nil
  ) throws -> BuiltConfiguration {
    switch profile {
    case .compatibility(let compatibility):
      return try makeCompatibilityConfiguration(
        profile: compatibility,
        mode: mode,
        selectedNode: selectedNode,
        localSOCKSPort: localSOCKSPort
      )
    case .native(let native):
      return try NativeConfigurationComposer(
        cachePath: cachePath,
        apiSecret: apiSecret
      ).compose(
        profile: native,
        mode: mode,
        selectedNode: selectedNode,
        localSOCKSPort: localSOCKSPort
      )
    }
  }

  private func makeCompatibilityConfiguration(
    profile: VPNProfile,
    mode: RoutingMode,
    selectedNode: ProxyNodeID,
    localSOCKSPort: UInt16?
  ) throws -> BuiltConfiguration {
    try ProfileValidator.validate(profile)

    var proxyTags: [String] = []
    if profile.vless != nil { proxyTags.append(ProxyNodeID.reality.rawValue) }
    if profile.hysteria2 != nil { proxyTags.append(ProxyNodeID.hysteria2.rawValue) }
    let allowedNodes = [ProxyNodeID.auto] + proxyTags.map(ProxyNodeID.init(rawValue:))
    let selectedTag = allowedNodes.contains(selectedNode) ? selectedNode.rawValue : "auto"

    var inbounds: [[String: Any]] = [
      [
        "type": "tun",
        "tag": "tun-in",
        "address": ["172.19.0.1/30"],
        "mtu": 1400,
        "auto_route": true,
        "strict_route": true,
        "stack": "system",
        "udp_timeout": "5m",
      ]
    ]
    if let localSOCKSPort {
      inbounds.append([
        "type": "socks",
        "tag": "local-socks-in",
        "listen": "127.0.0.1",
        "listen_port": Int(localSOCKSPort),
      ])
    }

    var proxyOutbounds: [[String: Any]] = []
    if let vless = profile.vless {
      proxyOutbounds.append([
        "type": "vless",
        "tag": "reality",
        "server": vless.server,
        "server_port": Int(vless.port),
        "uuid": vless.uuid,
        "flow": "xtls-rprx-vision",
        "network": "tcp",
        "packet_encoding": "xudp",
        "tls": [
          "enabled": true,
          "server_name": vless.serverName,
          "utls": [
            "enabled": true,
            "fingerprint": vless.fingerprint,
          ],
          "reality": [
            "enabled": true,
            "public_key": vless.publicKey,
            "short_id": vless.shortID,
          ],
        ],
      ])
    }
    if let hysteria2 = profile.hysteria2 {
      var outbound: [String: Any] = [
        "type": "hysteria2",
        "tag": "hysteria2",
        "server": hysteria2.server,
        "server_port": Int(hysteria2.port),
        "password": hysteria2.password,
        "tls": [
          "enabled": true,
          "server_name": hysteria2.serverName,
        ],
        "domain_resolver": "dns-local",
      ]
      if let obfsPassword = hysteria2.obfsPassword {
        outbound["obfs"] = [
          "type": "salamander",
          "password": obfsPassword,
        ]
      }
      proxyOutbounds.append(outbound)
    }

    var route: [String: Any] = [
      "auto_detect_interface": true,
      "default_domain_resolver": "dns-local",
      "rules": [
        ["action": "sniff"],
        ["protocol": "dns", "action": "hijack-dns"],
        [
          "clash_mode": RoutingMode.direct.rawValue,
          "action": "route",
          "outbound": "direct",
        ],
        [
          "clash_mode": RoutingMode.global.rawValue,
          "action": "route",
          "outbound": "proxy-selector",
        ],
        [
          "ip_is_private": true,
          "action": "route",
          "outbound": "direct",
        ],
      ],
      "final": "proxy-selector",
    ]
    var directDNSRules: [[String: Any]] = []
    if let policy = profile.routingPolicy {
      let composer = RoutingPolicyComposer()
      route = try composer.merge(policy, into: route)
      directDNSRules = try composer.directDNSRules(from: policy)
    }

    var dnsRules: [[String: Any]] = [
      [
        "clash_mode": RoutingMode.direct.rawValue,
        "action": "route",
        "server": "dns-local",
      ]
    ]
    dnsRules.append(contentsOf: directDNSRules)
    dnsRules.append([
      "action": "route",
      "server": "dns-remote",
    ])

    let root: [String: Any] = [
      "log": [
        "level": "error",
        "timestamp": true,
        "output": "/dev/null",
      ],
      "dns": [
        "servers": [
          [
            "type": "local",
            "tag": "dns-local",
          ],
          [
            "type": "https",
            "tag": "dns-remote",
            "server": "1.1.1.1",
            "detour": "proxy-selector",
            "tls": [
              "enabled": true,
              "server_name": "cloudflare-dns.com",
            ],
          ],
        ],
        "rules": dnsRules,
        "final": "dns-remote",
        "strategy": "ipv4_only",
        "cache_capacity": 4096,
      ],
      "inbounds": inbounds,
      "outbounds": [
        [
          "type": "selector",
          "tag": "proxy-selector",
          "outbounds": ["auto"] + proxyTags,
          "default": selectedTag,
          "interrupt_exist_connections": false,
        ],
        [
          "type": "urltest",
          "tag": "auto",
          "outbounds": proxyTags,
          "url": "https://www.gstatic.com/generate_204",
          "interval": "10m",
          "tolerance": 50,
          "idle_timeout": "30m",
          "interrupt_exist_connections": false,
        ],
      ] + proxyOutbounds + [
        ["type": "direct", "tag": "direct"],
        ["type": "block", "tag": "block"],
      ],
      "route": route,
      "experimental": [
        "cache_file": [
          "enabled": true,
          "path": cachePath,
          "store_fakeip": false,
        ],
        "clash_api": [
          "external_controller": "127.0.0.1:19090",
          "secret": apiSecret,
          "default_mode": mode.rawValue,
        ],
      ],
    ]

    let data = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    return BuiltConfiguration(
      data: data,
      selectorTag: "proxy-selector",
      nodes: profileNodes(profile),
      selectedNode: ProxyNodeID(rawValue: selectedTag)
    )
  }

  private func profileNodes(_ profile: VPNProfile) -> [ProxyNodeDescriptor] {
    var nodes = [ProxyNodeDescriptor(id: .auto, name: "Auto")]
    if let vless = profile.vless {
      nodes.append(ProxyNodeDescriptor(id: .reality, name: vless.displayName))
    }
    if let hysteria2 = profile.hysteria2 {
      nodes.append(ProxyNodeDescriptor(id: .hysteria2, name: hysteria2.displayName))
    }
    return nodes
  }
}

struct BuiltConfiguration {
  let data: Data
  let selectorTag: String
  let nodes: [ProxyNodeDescriptor]
  let selectedNode: ProxyNodeID
}

enum ProfileValidator {
  static func validate(_ profile: VPNProfile) throws {
    guard profile.vless != nil || profile.hysteria2 != nil else {
      throw CoreFailure.invalidProfile("The profile has no supported proxy connection.")
    }
    if let vless = profile.vless {
      guard vless.port > 0 else { throw CoreFailure.invalidProfile("Server port is invalid.") }
      try validateHost(vless.server, field: "VLESS server")
      try validateHost(vless.serverName, field: "REALITY server name")
      guard UUID(uuidString: vless.uuid) != nil else {
        throw CoreFailure.invalidProfile("VLESS UUID is invalid.")
      }
      try validateToken(vless.fingerprint, field: "fingerprint", maximum: 32)
      try validateBase64URL(vless.publicKey, field: "REALITY public key")
      try validateHex(vless.shortID, field: "REALITY short ID")
    }
    if let hysteria2 = profile.hysteria2 {
      guard hysteria2.port > 0 else {
        throw CoreFailure.invalidProfile("Server port is invalid.")
      }
      try validateHost(hysteria2.server, field: "Hysteria2 server")
      try validateHost(hysteria2.serverName, field: "Hysteria2 server name")
      try validateSecret(hysteria2.password, field: "Hysteria2 password")
      if let obfsPassword = hysteria2.obfsPassword {
        try validateSecret(obfsPassword, field: "Hysteria2 obfuscation password")
      }
    }
  }

  private static func validateHost(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 253,
      !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
    else {
      throw CoreFailure.invalidProfile("\(field) is invalid.")
    }
  }

  private static func validateToken(_ value: String, field: String, maximum: Int) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard !value.isEmpty, value.utf8.count <= maximum,
      value.unicodeScalars.allSatisfy(allowed.contains)
    else {
      throw CoreFailure.invalidProfile("\(field) is invalid.")
    }
  }

  private static func validateBase64URL(_ value: String, field: String) throws {
    try validateToken(value, field: field, maximum: 128)
  }

  private static func validateHex(_ value: String, field: String) throws {
    let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    guard !value.isEmpty, value.utf8.count <= 16, value.utf8.count.isMultiple(of: 2),
      value.unicodeScalars.allSatisfy(allowed.contains)
    else {
      throw CoreFailure.invalidProfile("\(field) is invalid.")
    }
  }

  private static func validateSecret(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 512,
      !value.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) })
    else {
      throw CoreFailure.invalidProfile("\(field) is invalid.")
    }
  }
}

private struct RoutingPolicyComposer {
  private let allowedRuleKeys = Set([
    "inbound", "ip_version", "network", "auth_user", "protocol", "client",
    "domain", "domain_suffix", "domain_keyword", "domain_regex",
    "source_ip_cidr", "ip_cidr", "source_port", "source_port_range",
    "port", "port_range", "process_name", "process_path", "package_name",
    "user", "user_id", "clash_mode", "network_type", "network_is_expensive",
    "network_is_constrained", "interface_address", "wifi_ssid", "wifi_bssid",
    "rule_set", "rule_set_ip_cidr_match_source", "invert", "action", "outbound",
  ])

  func merge(_ policy: RoutingPolicy, into managedRoute: [String: Any]) throws
    -> [String: Any]
  {
    guard !policy.configuration.isEmpty, policy.configuration.count <= 262_144,
      let root = try JSONSerialization.jsonObject(with: policy.configuration) as? [String: Any],
      Set(root.keys) == ["route"],
      let importedRoute = root["route"] as? [String: Any],
      !importedRoute.isEmpty,
      Set(importedRoute.keys).isSubset(of: ["rules", "rule_set"])
    else {
      throw CoreFailure.invalidProfile(
        "The routing policy may contain only route.rules and route.rule_set."
      )
    }

    let importedRules = importedRoute["rules"] as? [[String: Any]] ?? []
    guard importedRoute["rules"] == nil || importedRoute["rules"] is [[String: Any]],
      importedRules.count <= 1024
    else {
      throw CoreFailure.invalidProfile("The routing policy contains invalid or too many rules.")
    }
    for (index, rule) in importedRules.enumerated() {
      try validateRule(rule, index: index)
    }

    let importedRuleSets = importedRoute["rule_set"] as? [[String: Any]] ?? []
    guard importedRoute["rule_set"] == nil || importedRoute["rule_set"] is [[String: Any]],
      importedRuleSets.count <= 64
    else {
      throw CoreFailure.invalidProfile(
        "The routing policy contains invalid or too many rule sets.")
    }
    try validateRuleSets(importedRuleSets)

    var route = managedRoute
    var rules = route["rules"] as? [[String: Any]] ?? []
    rules.append(contentsOf: importedRules)
    route["rules"] = rules
    if !importedRuleSets.isEmpty {
      route["rule_set"] = importedRuleSets
    }
    return route
  }

  func directDNSRules(from policy: RoutingPolicy) throws -> [[String: Any]] {
    let importedRoute = try parsedRoute(from: policy)
    let rules = importedRoute["rules"] as? [[String: Any]] ?? []
    let dnsMatchKeys = Set([
      "domain", "domain_suffix", "domain_keyword", "domain_regex", "invert",
    ])
    return rules.compactMap { rule in
      guard (rule["action"] as? String) == "route",
        (rule["outbound"] as? String) == "direct"
      else { return nil }
      var dnsRule = rule.filter { dnsMatchKeys.contains($0.key) }
      guard !dnsRule.isEmpty else { return nil }
      dnsRule["action"] = "route"
      dnsRule["server"] = "dns-local"
      return dnsRule
    }
  }

  private func parsedRoute(from policy: RoutingPolicy) throws -> [String: Any] {
    guard !policy.configuration.isEmpty, policy.configuration.count <= 262_144,
      let root = try JSONSerialization.jsonObject(with: policy.configuration) as? [String: Any],
      Set(root.keys) == ["route"],
      let route = root["route"] as? [String: Any]
    else {
      throw CoreFailure.invalidProfile(
        "The routing policy may contain only route.rules and route.rule_set."
      )
    }
    return route
  }

  private func validateRule(_ rule: [String: Any], index: Int) throws {
    let unsupported = Set(rule.keys).subtracting(allowedRuleKeys)
    guard unsupported.isEmpty,
      (rule["action"] as? String) == "route",
      let outbound = rule["outbound"] as? String,
      ["direct", "proxy-selector"].contains(outbound)
    else {
      throw CoreFailure.invalidProfile(
        "Routing rule \(index + 1) must be a flat route action to direct or proxy-selector."
      )
    }
    guard rule.keys.contains(where: { $0 != "action" && $0 != "outbound" }) else {
      throw CoreFailure.invalidProfile("Routing rule \(index + 1) has no match condition.")
    }
    try validateJSONValue(rule, depth: 0)
  }

  private func validateRuleSets(_ items: [[String: Any]]) throws {
    var tags = Set<String>()
    let allowedKeys = Set(["type", "tag", "format", "url", "download_detour", "update_interval"])
    for (index, item) in items.enumerated() {
      guard Set(item.keys).isSubset(of: allowedKeys),
        (item["type"] as? String) == "remote",
        let tag = item["tag"] as? String,
        !tag.isEmpty,
        tag.utf8.count <= 128,
        tags.insert(tag).inserted,
        let format = item["format"] as? String,
        ["binary", "source"].contains(format),
        let urlValue = item["url"] as? String,
        urlValue.utf8.count <= 4096,
        let url = URL(string: urlValue),
        url.scheme?.lowercased() == "https",
        url.host != nil
      else {
        throw CoreFailure.invalidProfile(
          "Routing rule set \(index + 1) must be a unique remote HTTPS rule set."
        )
      }
      if let detour = item["download_detour"] as? String,
        !["direct", "proxy-selector"].contains(detour)
      {
        throw CoreFailure.invalidProfile(
          "Routing rule set \(index + 1) uses an unsupported download detour."
        )
      }
      try validateJSONValue(item, depth: 0)
    }
  }

  private func validateJSONValue(_ value: Any, depth: Int) throws {
    guard depth <= 8 else {
      throw CoreFailure.invalidProfile("The routing policy is nested too deeply.")
    }
    if let object = value as? [String: Any] {
      guard object.count <= 128 else {
        throw CoreFailure.invalidProfile("The routing policy object is too large.")
      }
      for child in object.values {
        try validateJSONValue(child, depth: depth + 1)
      }
    } else if let array = value as? [Any] {
      guard array.count <= 4096 else {
        throw CoreFailure.invalidProfile("The routing policy array is too large.")
      }
      for child in array {
        try validateJSONValue(child, depth: depth + 1)
      }
    } else if let string = value as? String {
      guard string.utf8.count <= 4096,
        !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else {
        throw CoreFailure.invalidProfile("The routing policy contains an invalid string.")
      }
    } else if value is NSNumber || value is NSNull {
      return
    } else {
      throw CoreFailure.invalidProfile("The routing policy contains an unsupported value.")
    }
  }
}
