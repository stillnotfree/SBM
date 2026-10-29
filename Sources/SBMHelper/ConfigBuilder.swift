import Darwin
import Foundation
import SBMShared

struct ConfigBuilder {
  let cachePath: String
  let apiSecret: String

  func makeConfiguration(
    profile: CoreProfile,
    mode: RoutingMode,
    selectedNode: ProxyNodeID,
    localSOCKSPort: UInt16? = nil,
    latencyTestURL: String = LatencyTargetPolicy.defaultURL,
    ipv6Enabled: Bool = false,
    dnsSettings: ManagedDNSSettings = .defaults
  ) throws -> BuiltConfiguration {
    let latencyTestURL = try LatencyTargetPolicy.normalized(latencyTestURL)
    let dnsSettings = try dnsSettings.validated()
    let compatibility: VPNProfile
    switch profile {
    case .compatibility(let managedProfile): compatibility = managedProfile
    }
    return try makeCompatibilityConfiguration(
      profile: compatibility,
      mode: mode,
      selectedNode: selectedNode,
      localSOCKSPort: localSOCKSPort,
      latencyTestURL: latencyTestURL,
      ipv6Enabled: ipv6Enabled,
      dnsSettings: dnsSettings
    )
  }

  private func makeCompatibilityConfiguration(
    profile: VPNProfile,
    mode: RoutingMode,
    selectedNode: ProxyNodeID,
    localSOCKSPort: UInt16?,
    latencyTestURL: String,
    ipv6Enabled: Bool,
    dnsSettings: ManagedDNSSettings
  ) throws -> BuiltConfiguration {
    try ProfileValidator.validate(profile)

    let proxyTags = profile.connections.map(\.id.rawValue)
    guard Set(proxyTags).count == proxyTags.count,
      proxyTags.allSatisfy(ProfileValidator.isValidManagedNodeID)
    else { throw CoreFailure.invalidProfile("Managed connection IDs are invalid.") }
    let excludedNodeIDs = Set(profile.autoExcludedNodeIDs)
    let autoCandidates = profile.connections
      .filter { !excludedNodeIDs.contains($0.id) }
      .map { $0.id.rawValue }
    let allowedNodes = [ProxyNodeID.auto] + proxyTags.map(ProxyNodeID.init(rawValue:))
    let selectedTag = allowedNodes.contains(selectedNode) ? selectedNode.rawValue : "auto"

    var inbounds: [[String: Any]] = [
      [
        "type": "tun",
        "tag": "tun-in",
        "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
        "mtu": 1400,
        "auto_route": true,
        "strict_route": true,
        "dns_mode": "disabled",
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
    for connection in profile.connections {
      switch connection.outbound {
      case .vless(let vless):
        var outbound: [String: Any] = [
          "type": "vless",
          "tag": connection.id.rawValue,
          "server": vless.server,
          "server_port": Int(vless.port),
          "uuid": vless.uuid,
        ]
        if !vless.variant.isReality {
          outbound["tls"] = Self.vlessTLSSettings(vless)
          outbound["domain_resolver"] = "dns-local"
        }
        switch vless.variant {
        case .reality(let publicKey, let shortID):
          outbound["flow"] = "xtls-rprx-vision"
          outbound["network"] = "tcp"
          outbound["packet_encoding"] = "xudp"
          outbound["tls"] = Self.vlessTLSSettings(vless, reality: (publicKey, shortID))
        case .realityGRPC(let publicKey, let shortID, let serviceName):
          outbound["tls"] = Self.vlessTLSSettings(vless, reality: (publicKey, shortID))
          outbound["transport"] = ["type": "grpc", "service_name": serviceName]
        case .tlsGRPC(let serviceName):
          outbound["transport"] = ["type": "grpc", "service_name": serviceName]
        case .tlsTCP:
          break
        case .tlsHTTP(let host, let path):
          var transport: [String: Any] = ["type": "http"]
          if let host { transport["host"] = host }
          if let path { transport["path"] = path }
          outbound["transport"] = transport
        case .tlsWebSocket(let host, let path):
          var transport: [String: Any] = ["type": "ws"]
          if let host { transport["headers"] = ["Host": host] }
          if let path { transport["path"] = path }
          outbound["transport"] = transport
        case .tlsQUIC:
          outbound["transport"] = ["type": "quic"]
        case .tlsHTTPUpgrade(let host, let path):
          var transport: [String: Any] = ["type": "httpupgrade"]
          if let host { transport["host"] = host }
          if let path { transport["path"] = path }
          outbound["transport"] = transport
        }
        proxyOutbounds.append(outbound)
      case .hysteria2(let hysteria2):
        var outbound: [String: Any] = [
          "type": "hysteria2",
          "tag": connection.id.rawValue,
          "server": hysteria2.server,
          "password": hysteria2.password,
          "tls": [
            "enabled": true,
            "server_name": hysteria2.serverName,
          ],
          "domain_resolver": "dns-local",
          "disable_chrome_parrot": true,
        ]
        if let ranges = hysteria2.portHoppingRanges {
          outbound["server_ports"] = ranges.map { "\($0.start):\($0.end)" }
        } else {
          outbound["server_port"] = Int(hysteria2.port)
        }
        if let obfsPassword = hysteria2.obfsPassword {
          outbound["obfs"] = [
            "type": "salamander",
            "password": obfsPassword,
          ]
        }
        proxyOutbounds.append(outbound)
      case .shadowsocks(let shadowsocks):
        proxyOutbounds.append([
          "type": "shadowsocks",
          "tag": connection.id.rawValue,
          "server": shadowsocks.server,
          "server_port": Int(shadowsocks.port),
          "method": shadowsocks.method,
          "password": shadowsocks.password,
          "domain_resolver": "dns-local",
        ])
      }
    }

    var route: [String: Any] = [
      "auto_detect_interface": true,
      "default_domain_resolver": "dns-local",
      "rules": ManagedRoutingPlanComposer.routeRules(
        for: profile,
        ipv6Enabled: ipv6Enabled
      ),
      "final": "proxy-selector",
    ]
    var directDNSRules: [[String: Any]] = []
    if let policy = profile.routingPolicy {
      let composer = RoutingPolicyComposer()
      route = try composer.merge(policy, into: route)
      directDNSRules = try composer.directDNSRules(from: policy)
    }

    var dnsRules = ManagedRoutingPlanComposer.dnsRules(for: profile)
    dnsRules.append(contentsOf: directDNSRules)
    dnsRules.append([
      "action": "route",
      "server": "dns-remote",
    ])

    let (localDNSServer, needsBootstrap) = try makeDNSServer(dnsSettings.direct, direct: true)
    let (remoteDNSServer, _) = try makeDNSServer(dnsSettings.proxy, direct: false)
    let dnsServers: [[String: Any]] =
      (needsBootstrap ? [["type": "local", "tag": "dns-bootstrap"]] : [])
      + [localDNSServer, remoteDNSServer]

    var dns: [String: Any] = [
      "servers": dnsServers,
      "rules": dnsRules,
      "final": "dns-remote",
      "cache_capacity": 4096,
    ]
    if !ipv6Enabled {
      dns["strategy"] = "ipv4_only"
    }
    let root: [String: Any] = [
      "log": [
        "level": "error",
        "timestamp": true,
        "output": "/dev/null",
      ],
      "dns": dns,
      "inbounds": inbounds,
      "outbounds": [
        [
          "type": "selector",
          "tag": "proxy-selector",
          "outbounds": ["auto"] + proxyTags,
          "default": selectedTag,
          "interrupt_exist_connections": false,
        ],
        autoCandidates.isEmpty
          ? ["type": "block", "tag": "auto"]
          : [
            "type": "urltest",
            "tag": "auto",
            "outbounds": autoCandidates,
            "url": latencyTestURL,
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
      nodes: CoreProfile.compatibility(profile).nodes,
      selectedNode: ProxyNodeID(rawValue: selectedTag)
    )
  }

  private func makeDNSServer(_ choice: ManagedDNSChoice, direct: Bool) throws
    -> (server: [String: Any], needsBootstrap: Bool)
  {
    let (tag, detour) = direct ? ("dns-local", "direct") : ("dns-remote", "proxy-selector")
    var server: String
    var serverName: String?
    var port: Int?
    var path: String?
    var resolver: String?
    switch choice {
    case .system:
      return (["type": "local", "tag": tag], false)
    case .cloudflare:
      (server, serverName) = ("1.1.1.1", "cloudflare-dns.com")
    case .google:
      (server, serverName) = ("8.8.8.8", "dns.google")
    case .yandex:
      (server, serverName) = ("77.88.8.8", "common.dot.dns.yandex.net")
    case .quad9:
      (server, serverName) = ("9.9.9.9", "dns.quad9.net")
    case .adguard:
      (server, serverName) = ("94.140.14.140", "unfiltered.adguard-dns.com")
    case .customDoH(let value):
      guard let components = URLComponents(string: value), let url = components.url,
        let host = url.host
      else { throw CoreFailure.invalidProfile("Custom DoH URL is invalid.") }
      server = host
      port = url.port ?? 443
      path = components.percentEncodedPath.isEmpty ? "/dns-query" : components.percentEncodedPath
      if !Self.isIPLiteral(host) {
        serverName = host
        resolver = direct ? "dns-bootstrap" : "dns-local"
      }
    }
    var tls: [String: Any] = ["enabled": true]
    if let serverName { tls["server_name"] = serverName }
    var result: [String: Any] = [
      "type": "https", "tag": tag, "server": server, "detour": detour, "tls": tls,
    ]
    if let port { result["server_port"] = port }
    if let path { result["path"] = path }
    if let resolver { result["domain_resolver"] = resolver }
    return (result, resolver == "dns-bootstrap")
  }

  private static func isIPLiteral(_ host: String) -> Bool {
    if host.contains(":") { return true }
    var address = in_addr()
    return host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
  }

  private static func vlessTLSSettings(
    _ vless: VLESSProfile,
    reality: (String, String)? = nil
  ) -> [String: Any] {
    var settings: [String: Any] = [
      "enabled": true,
      "server_name": vless.serverName,
      "utls": ["enabled": true, "fingerprint": vless.fingerprint],
    ]
    if let (publicKey, shortID) = reality {
      settings["reality"] = [
        "enabled": true,
        "public_key": publicKey,
        "short_id": shortID,
      ]
    }
    return settings
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
    guard !profile.connections.isEmpty else {
      throw CoreFailure.invalidProfile("The profile has no supported proxy connection.")
    }
    guard profile.connections.count <= SubscriptionClientMaximum.connections
    else {
      throw CoreFailure.invalidProfile("The profile has more than 63 proxy connections.")
    }
    let nodeIDs = profile.connections.map(\.id.rawValue)
    guard Set(nodeIDs).count == nodeIDs.count,
      nodeIDs.allSatisfy(isValidManagedNodeID)
    else {
      throw CoreFailure.invalidProfile("Managed connection IDs are invalid.")
    }
    let allowedNodeIDs = Set(nodeIDs)
    let excludedNodeIDs = profile.autoExcludedNodeIDs
    guard Set(excludedNodeIDs).count == excludedNodeIDs.count,
      excludedNodeIDs.allSatisfy({ $0 != .auto && allowedNodeIDs.contains($0.rawValue) })
    else {
      throw CoreFailure.invalidProfile("Managed Auto exclusions are invalid.")
    }
    var groupIDs = Set<String>()
    for group in profile.nodeGroups ?? [] {
      guard isValidGroupID(group.id), groupIDs.insert(group.id).inserted,
        !group.name.isEmpty, group.name.utf8.count <= 96,
        !group.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        Set(group.nodes).count == group.nodes.count,
        group.nodes.allSatisfy({ allowedNodeIDs.contains($0.rawValue) })
      else {
        throw CoreFailure.invalidProfile("Managed connection group references invalid nodes.")
      }
    }
    for connection in profile.connections {
      guard !connection.displayName.isEmpty, connection.displayName.utf8.count <= 96 else {
        throw CoreFailure.invalidProfile("Managed connection name is invalid.")
      }
      switch connection.outbound {
      case .vless(let vless):
        guard vless.port > 0 else { throw CoreFailure.invalidProfile("Server port is invalid.") }
        try validateHost(vless.server, field: "VLESS server")
        try validateHost(
          vless.serverName,
          field: vless.variant.isReality ? "REALITY server name" : "VLESS TLS server name"
        )
        guard UUID(uuidString: vless.uuid) != nil else {
          throw CoreFailure.invalidProfile("VLESS UUID is invalid.")
        }
        try validateToken(vless.fingerprint, field: "fingerprint", maximum: 32)
        if !vless.variant.isReality {
          guard VLESSProfile.supportedFingerprints.contains(vless.fingerprint) else {
            throw CoreFailure.invalidProfile("VLESS TLS fingerprint is unsupported.")
          }
        }
        switch vless.variant {
        case .reality(let publicKey, let shortID):
          try validateBase64URL(publicKey, field: "REALITY public key")
          try validateHex(shortID, field: "REALITY short ID")
        case .realityGRPC(let publicKey, let shortID, let serviceName):
          guard VLESSProfile.supportedFingerprints.contains(vless.fingerprint) else {
            throw CoreFailure.invalidProfile("VLESS REALITY fingerprint is unsupported.")
          }
          try validateBase64URL(publicKey, field: "REALITY public key")
          try validateHex(shortID, field: "REALITY short ID")
          try validateServiceName(serviceName)
        case .tlsGRPC(let serviceName):
          try validateServiceName(serviceName)
        case .tlsTCP, .tlsQUIC:
          break
        case .tlsHTTP(let host, let path), .tlsWebSocket(let host, let path),
          .tlsHTTPUpgrade(let host, let path):
          try validateVLESSTransportValues(host: host, path: path)
        }
      case .hysteria2(let hysteria2):
        guard hysteria2.port > 0 else {
          throw CoreFailure.invalidProfile("Server port is invalid.")
        }
        if let ranges = hysteria2.portHoppingRanges {
          guard !ranges.isEmpty, ranges.count <= 64,
            !(ranges.count == 1 && ranges[0].start == ranges[0].end),
            ranges[0].start == hysteria2.port,
            ranges.allSatisfy({ $0.start > 0 && $0.start <= $0.end }),
            zip(ranges, ranges.dropFirst()).allSatisfy({ Int($1.start) > Int($0.end) + 1 })
          else {
            throw CoreFailure.invalidProfile(
              "Hysteria2 port hopping ranges are invalid or noncanonical.")
          }
        }
        try validateHost(hysteria2.server, field: "Hysteria2 server")
        try validateHost(hysteria2.serverName, field: "Hysteria2 server name")
        try validateSecret(hysteria2.password, field: "Hysteria2 password")
        if let obfsPassword = hysteria2.obfsPassword {
          try validateSecret(obfsPassword, field: "Hysteria2 obfuscation password")
        }
      case .shadowsocks(let shadowsocks):
        guard shadowsocks.port > 0 else {
          throw CoreFailure.invalidProfile("Server port is invalid.")
        }
        try validateHost(shadowsocks.server, field: "Shadowsocks server")
        let invalidMethodCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !shadowsocks.method.isEmpty, shadowsocks.method.utf8.count <= 128,
          !shadowsocks.method.unicodeScalars.contains(where: invalidMethodCharacters.contains)
        else {
          throw CoreFailure.invalidProfile("Shadowsocks method is invalid.")
        }
        try validateSecret(shadowsocks.password, field: "Shadowsocks password")
      }
    }
    try validateApplicationRoutingRules(profile.applicationRoutingRules)
    try validateWebsiteRoutingRules(profile.websiteRoutingRules)
  }

  private static func validateWebsiteRoutingRules(_ rules: [WebsiteRoutingRule]) throws {
    guard rules.count <= 128 else {
      throw CoreFailure.invalidProfile("A profile may contain at most 128 website rules.")
    }
    var ids = Set<UUID>()
    var domains = Set<String>()
    for rule in rules {
      guard ids.insert(rule.id).inserted, domains.insert(rule.domain).inserted,
        validNormalizedDomain(rule.domain)
      else { throw CoreFailure.invalidProfile("A website routing rule is invalid.") }
    }
  }

  private static func validNormalizedDomain(_ domain: String) -> Bool {
    guard !domain.isEmpty, domain.utf8.count <= 253, domain == domain.lowercased(),
      !domain.hasPrefix("."), !domain.hasSuffix("."), domain.contains(".")
    else { return false }
    return domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      guard !label.isEmpty, label.utf8.count <= 63,
        label.first != "-", label.last != "-"
      else { return false }
      return label.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
      }
    }
  }

  private static func validateApplicationRoutingRules(_ rules: [ApplicationRoutingRule]) throws {
    guard rules.count <= 32 else {
      throw CoreFailure.invalidProfile("A profile may contain at most 32 application rules.")
    }
    var ids = Set<UUID>()
    var executablePaths = Set<String>()
    for rule in rules {
      let bundleURL = URL(fileURLWithPath: rule.bundlePath).standardizedFileURL
      let executableURL = URL(fileURLWithPath: rule.executablePath).standardizedFileURL
      let bundlePrefix = bundleURL.path.hasSuffix("/") ? bundleURL.path : bundleURL.path + "/"
      guard ids.insert(rule.id).inserted,
        executablePaths.insert(executableURL.path).inserted,
        !rule.displayName.isEmpty,
        rule.displayName.utf8.count <= 96,
        !rule.displayName.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0)
        }),
        bundleURL.path.hasPrefix("/"),
        bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
        bundleURL.path.utf8.count <= 4096,
        executableURL.path.hasPrefix(bundlePrefix),
        executableURL.path.utf8.count <= 4096,
        !rule.bundlePath.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0)
        }),
        !rule.executablePath.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0)
        })
      else {
        throw CoreFailure.invalidProfile("An application routing rule is invalid.")
      }
    }
  }

  static func isValidManagedNodeID(_ value: String) -> Bool {
    return value != ProxyNodeID.auto.rawValue
      && !value.isEmpty
      && value.utf8.count <= 128
      && value.utf8.allSatisfy(isASCIIManagedTagByte)
  }

  private static func isValidGroupID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy(isASCIIManagedTagByte)
  }

  private static func isASCIIManagedTagByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
      || byte == 45 || byte == 46 || byte == 95
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

  private static func validateServiceName(_ value: String) throws {
    guard value.utf8.count <= 256,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw CoreFailure.invalidProfile("VLESS gRPC service name is invalid.")
    }
  }

  private static func validateVLESSTransportValues(host: String?, path: String?) throws {
    if let host {
      guard !host.isEmpty, host.utf8.count <= 253,
        !host.unicodeScalars.contains(where: {
          CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
        }), !host.contains(where: { ":/\\?#[]@!$&'()*+,;=%".contains($0) })
      else { throw CoreFailure.invalidProfile("VLESS transport host is invalid.") }
    }
    if let path {
      guard !path.isEmpty, path.hasPrefix("/"), path.utf8.count <= 1024,
        !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else { throw CoreFailure.invalidProfile("VLESS transport path is invalid.") }
    }
  }

  private static func validateBase64URL(_ value: String, field: String) throws {
    try validateToken(value, field: field, maximum: 128)
  }

  private static func validateHex(_ value: String, field: String) throws {
    let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    guard value.utf8.count <= 16, value.utf8.count.isMultiple(of: 2),
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

private enum SubscriptionClientMaximum {
  static let connections = 63
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
    try validatePolicyJSON(policy)
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
      "domain", "domain_suffix", "domain_keyword", "domain_regex",
    ])
    return rules.compactMap { rule in
      guard (rule["action"] as? String) == "route",
        (rule["outbound"] as? String) == "direct",
        (rule["invert"] as? Bool) != true
      else { return nil }
      var dnsRule = rule.filter { dnsMatchKeys.contains($0.key) }
      guard !dnsRule.isEmpty else { return nil }
      dnsRule["action"] = "route"
      dnsRule["server"] = "dns-local"
      return dnsRule
    }
  }

  private func parsedRoute(from policy: RoutingPolicy) throws -> [String: Any] {
    try validatePolicyJSON(policy)
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

  private func validatePolicyJSON(_ policy: RoutingPolicy) throws {
    do {
      try StrictJSONDuplicateValidator.validate(
        policy.configuration,
        maximumBytes: 262_144,
        maximumDepth: 64,
        maximumStringBytes: 262_144
      )
    } catch {
      throw CoreFailure.invalidProfile(
        "The routing policy may contain only route.rules and route.rule_set."
      )
    }
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
