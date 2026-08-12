import Foundation
import SBMShared

struct NativeConfigurationComposer {
  let cachePath: String
  let apiSecret: String

  func compose(
    profile: NativeProfile,
    mode: RoutingMode,
    selectedNode: ProxyNodeID,
    localSOCKSPort: UInt16? = nil,
    latencyTestURL: String = LatencyTargetPolicy.defaultURL
  ) throws -> BuiltConfiguration {
    let latencyTestURL = try LatencyTargetPolicy.normalized(latencyTestURL)
    try NativeCapabilityPolicy.requireReviewedCore()
    guard profile.configuration.count <= 1_048_576,
      let source = try JSONSerialization.jsonObject(with: profile.configuration) as? [String: Any]
    else { throw CoreFailure.invalidProfile("The native profile is not a valid JSON object.") }

    try validateTopLevel(source)
    try validateTopLevelTypes(source)
    try validateImportedSections(source)

    var outbounds = source["outbounds"] as? [[String: Any]] ?? []
    let endpoints = source["endpoints"] as? [[String: Any]] ?? []
    if endpoints.contains(where: { ($0["type"] as? String) == "tailscale" }) {
      throw CoreFailure.invalidProfile(
        "Tailscale endpoints are not accepted by the privileged helper."
      )
    }
    guard !outbounds.isEmpty || !endpoints.isEmpty else {
      throw CoreFailure.invalidProfile("The native profile must contain an outbound or endpoint.")
    }
    guard outbounds.count <= 256 else {
      throw CoreFailure.invalidProfile("The native profile contains too many outbounds.")
    }
    guard endpoints.count <= 256 else {
      throw CoreFailure.invalidProfile("The native profile contains too many endpoints.")
    }

    var tags = try validateTags(outbounds, kind: "outbound")
    let endpointTags = try validateTags(endpoints, kind: "endpoint")
    guard tags.isDisjoint(with: endpointTags) else {
      throw CoreFailure.invalidProfile("Outbound and endpoint tags must be unique.")
    }
    tags.formUnion(endpointTags)
    let typePairs: [(String, String)] = (outbounds + endpoints).compactMap { outbound in
      guard let tag = outbound["tag"] as? String, let type = outbound["type"] as? String else {
        return nil
      }
      return (tag, type)
    }
    let typesByTag: [String: String] = Dictionary(uniqueKeysWithValues: typePairs)
    let selectorIndex = outbounds.firstIndex { outbound in
      (outbound["type"] as? String) == "selector"
        && (outbound["tag"] as? String) == profile.selectorTag
    }

    let selectorTag: String
    var selectableTags: [String]
    if let selectorIndex {
      selectorTag = profile.selectorTag
      guard let children = outbounds[selectorIndex]["outbounds"] as? [String], !children.isEmpty,
        children.allSatisfy(tags.contains)
      else {
        throw CoreFailure.invalidProfile(
          "The selected selector contains an unknown or empty outbound list.")
      }
      selectableTags = children
      if !children.contains(where: { typesByTag[$0] == "urltest" }) {
        let candidates: [String] = children.filter { tag in
          guard let type = typesByTag[tag] else { return false }
          return !["direct", "block", "dns", "selector", "urltest"].contains(type)
        }
        if !candidates.isEmpty {
          try appendManagedAuto(
            candidates: candidates,
            tags: tags,
            outbounds: &outbounds,
            latencyTestURL: latencyTestURL
          )
          selectableTags.insert("sbm-auto", at: 0)
          outbounds[selectorIndex]["outbounds"] = selectableTags
        }
      }
    } else {
      selectorTag = "sbm-selector"
      guard !tags.contains(selectorTag) else {
        throw CoreFailure.invalidProfile("The profile uses the reserved tag sbm-selector.")
      }
      let candidates: [String] = outbounds.compactMap { outbound in
        guard let type = outbound["type"] as? String,
          !["direct", "block", "dns", "selector"].contains(type),
          let tag = outbound["tag"] as? String
        else { return nil }
        return tag
      }
      let endpointCandidates = endpoints.compactMap { $0["tag"] as? String }
      let allCandidates = candidates + endpointCandidates
      guard !allCandidates.isEmpty else {
        throw CoreFailure.invalidProfile("The native profile has no selectable proxy outbounds.")
      }
      try appendManagedAuto(
        candidates: allCandidates,
        tags: tags,
        outbounds: &outbounds,
        latencyTestURL: latencyTestURL
      )
      selectableTags = ["sbm-auto"] + allCandidates
      outbounds.insert(
        [
          "type": "selector",
          "tag": selectorTag,
          "outbounds": selectableTags,
          "default": selectableTags[0],
          "interrupt_exist_connections": false,
        ],
        at: 0
      )
    }

    let chosen =
      selectableTags.contains(selectedNode.rawValue)
      ? selectedNode.rawValue : selectableTags[0]
    guard selectableTags.count <= 64 else {
      throw CoreFailure.invalidProfile("A selector may expose at most 64 outbounds.")
    }
    if let index = outbounds.firstIndex(where: { ($0["tag"] as? String) == selectorTag }) {
      outbounds[index]["default"] = chosen
      outbounds[index]["interrupt_exist_connections"] = false
    }

    let directTag = try ensureDirectOutbound(in: &outbounds, endpoints: endpoints)
    var route = source["route"] as? [String: Any] ?? [:]
    let availableRouteTags = Set(
      (outbounds + endpoints).compactMap { $0["tag"] as? String }
    )
    try validateNativeRuleSets(
      route["rule_set"],
      availableTags: availableRouteTags
    )
    let rulesValue = route["rules"]
    guard rulesValue == nil || rulesValue is [[String: Any]] else {
      throw CoreFailure.invalidProfile("The native profile route.rules field must be an array.")
    }
    var rules = rulesValue as? [[String: Any]] ?? []
    guard rules.count <= 4096 else {
      throw CoreFailure.invalidProfile("The native profile contains too many routing rules.")
    }
    let applicationRules = try ProfileValidator.applicationRouteRules(
      profile.applicationRoutingRules,
      directOutbound: directTag,
      proxyOutbound: selectorTag,
      allowedNodeIDs: Set(
        selectableTags.filter { tag in
          tag != "sbm-auto"
            && !["direct", "block", "dns", "selector", "urltest"].contains(typesByTag[tag])
        })
    )
    rules.insert(
      contentsOf: managedRouteRules(selectorTag: selectorTag, directTag: directTag)
        + applicationRules,
      at: 0
    )
    route["rules"] = rules
    route["auto_detect_interface"] = true
    // Rule mode preserves every imported rule, while unmatched traffic must
    // still follow the server selected in the menu. Keeping an unrelated
    // imported final outbound would make the server picker misleading.
    route["final"] = selectorTag

    let dns = try composeDNS(
      imported: source["dns"] as? [String: Any],
      selectorTag: selectorTag
    )
    if source["dns"] == nil, route["default_domain_resolver"] == nil {
      route["default_domain_resolver"] = "sbm-dns-local"
    }

    var inbounds: [[String: Any]] = [
      [
        "type": "tun",
        "tag": "sbm-tun-in",
        "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
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
        "tag": "sbm-local-socks-in",
        "listen": "127.0.0.1",
        "listen_port": Int(localSOCKSPort),
      ])
    }

    var root: [String: Any] = [
      "log": [
        "level": "error",
        "timestamp": true,
        "output": "/dev/null",
      ],
      "dns": dns,
      "inbounds": inbounds,
      "outbounds": outbounds,
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
    if !endpoints.isEmpty {
      root["endpoints"] = endpoints
    }
    var names: [String: String] = [:]
    for node in profile.nodes {
      guard names.updateValue(node.name, forKey: node.id.rawValue) == nil else {
        throw CoreFailure.invalidProfile(
          "The native profile contains duplicate node metadata for \(node.id.rawValue)."
        )
      }
    }
    let metadataByID = Dictionary(uniqueKeysWithValues: profile.nodes.map { ($0.id.rawValue, $0) })
    let nodes = selectableTags.map { tag in
      ProxyNodeDescriptor(
        id: ProxyNodeID(rawValue: tag),
        name: names[tag] ?? tag,
        kind: tag == "sbm-auto" || typesByTag[tag] == "urltest"
          ? .automatic : metadataByID[tag]?.kind ?? .native
      )
    }
    let data = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    return BuiltConfiguration(
      data: data,
      selectorTag: selectorTag,
      nodes: nodes,
      selectedNode: ProxyNodeID(rawValue: chosen)
    )
  }

  private func validateTopLevel(_ source: [String: Any]) throws {
    let owned = Set(["log", "inbounds", "experimental", "sbm"])
    let imported = Set(["dns", "outbounds", "endpoints", "route"])
    let unsupported = Set(source.keys).subtracting(owned).subtracting(imported)
    guard unsupported.isEmpty else {
      throw CoreFailure.invalidProfile(
        "Unsupported top-level profile sections: \(unsupported.sorted().joined(separator: ", ")).")
    }
  }

  private func validateTopLevelTypes(_ source: [String: Any]) throws {
    for key in ["dns", "route"] {
      if let value = source[key], !(value is [String: Any]) {
        throw CoreFailure.invalidProfile("The native profile \(key) section must be an object.")
      }
    }
    for key in ["outbounds", "endpoints"] {
      if let value = source[key], !(value is [[String: Any]]) {
        throw CoreFailure.invalidProfile("The native profile \(key) section must be an array.")
      }
    }
  }

  private func validateImportedSections(_ source: [String: Any]) throws {
    if let dns = source["dns"] as? [String: Any] {
      try requireAllowedKeys(dns, allowed: Self.safeDNSKeys, path: "profile.dns")
      guard dns["servers"] == nil || dns["servers"] is [[String: Any]],
        dns["rules"] == nil || dns["rules"] is [[String: Any]]
      else {
        throw CoreFailure.invalidProfile("The imported DNS servers and rules must be arrays.")
      }
      for (index, server) in (dns["servers"] as? [[String: Any]] ?? []).enumerated() {
        try validateDNSServer(server, path: "profile.dns.servers[\(index)]")
      }
      if let fakeIP = dns["fakeip"] as? [String: Any] {
        try requireAllowedKeys(
          fakeIP,
          allowed: ["enabled", "inet4_range", "inet6_range"],
          path: "profile.dns.fakeip"
        )
      } else if dns["fakeip"] != nil {
        throw CoreFailure.invalidProfile("The imported DNS fakeip section must be an object.")
      }
    }

    for (index, outbound) in (source["outbounds"] as? [[String: Any]] ?? []).enumerated() {
      try validateOutbound(outbound, path: "profile.outbounds[\(index)]")
    }
    for (index, endpoint) in (source["endpoints"] as? [[String: Any]] ?? []).enumerated() {
      try validateEndpoint(endpoint, path: "profile.endpoints[\(index)]")
    }
    if let route = source["route"] as? [String: Any] {
      try requireAllowedKeys(route, allowed: Self.safeRouteKeys, path: "profile.route")
      guard route["rules"] == nil || route["rules"] is [[String: Any]] else {
        throw CoreFailure.invalidProfile("The native profile route.rules field must be an array.")
      }
      try validateOptionalDomainResolver(
        route["default_domain_resolver"], path: "profile.route.default_domain_resolver")
    }

    var budget = ImportedValueBudget()
    for key in ["dns", "outbounds", "endpoints", "route"] {
      if let value = source[key] {
        try validateBoundedValue(value, path: "profile.\(key)", depth: 0, budget: &budget)
      }
    }
  }

  private func validateDNSServer(_ server: [String: Any], path: String) throws {
    let type = (server["type"] as? String) ?? ""
    try NativeCapabilityPolicy.requireAllowedDNSServerType(type)
    var allowed = NativeCapabilityPolicy.dialKeys.union(Self.safeDNSServerKeys)
    if ["https", "h3"].contains(type) { allowed.insert("path") }
    try requireAllowedKeys(server, allowed: allowed, path: path)
    if let httpPath = server["path"] as? String {
      guard httpPath.utf8.count <= 2_048, httpPath.hasPrefix("/"),
        !httpPath.contains("\\"),
        !httpPath.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0)
        })
      else {
        throw CoreFailure.invalidProfile("The imported DNS HTTP path is invalid.")
      }
    }
    try validateOptionalOutboundTLS(server["tls"], path: "\(path).tls")
    try validateOptionalDomainResolver(server["domain_resolver"], path: "\(path).domain_resolver")
  }

  private func validateOutbound(_ outbound: [String: Any], path: String) throws {
    guard let type = outbound["type"] as? String, !type.isEmpty else {
      throw CoreFailure.invalidProfile("Every imported outbound must have a type.")
    }
    try requireAllowedKeys(
      outbound,
      allowed: try NativeCapabilityPolicy.allowedOutboundKeys(for: type),
      path: path
    )
    try validateOptionalOutboundTLS(outbound["tls"], path: "\(path).tls")
    try validateOptionalDomainResolver(outbound["domain_resolver"], path: "\(path).domain_resolver")

    if let transport = outbound["transport"] as? [String: Any] {
      guard let transportType = transport["type"] as? String, !transportType.isEmpty else {
        throw CoreFailure.invalidProfile("The imported outbound transport has no type.")
      }
      try requireAllowedKeys(
        transport,
        allowed: try NativeCapabilityPolicy.allowedTransportKeys(for: transportType),
        path: "\(path).transport"
      )
    } else if outbound["transport"] != nil {
      throw CoreFailure.invalidProfile("The imported outbound transport must be an object.")
    }
    if let multiplex = outbound["multiplex"] as? [String: Any] {
      try requireAllowedKeys(
        multiplex, allowed: Self.safeMultiplexKeys, path: "\(path).multiplex")
      if let brutal = multiplex["brutal"] as? [String: Any] {
        try requireAllowedKeys(
          brutal,
          allowed: ["enabled", "up_mbps", "down_mbps"],
          path: "\(path).multiplex.brutal"
        )
      }
    } else if outbound["multiplex"] != nil {
      throw CoreFailure.invalidProfile("The imported outbound multiplex section must be an object.")
    }
    if let udpOverTCP = outbound["udp_over_tcp"], !(udpOverTCP is Bool) {
      guard let options = udpOverTCP as? [String: Any] else {
        throw CoreFailure.invalidProfile("The imported udp_over_tcp option is invalid.")
      }
      try requireAllowedKeys(
        options, allowed: ["enabled", "version"], path: "\(path).udp_over_tcp")
    }
    if let obfs = outbound["obfs"] as? [String: Any] {
      try requireAllowedKeys(obfs, allowed: ["type", "password"], path: "\(path).obfs")
    }
  }

  private func validateEndpoint(_ endpoint: [String: Any], path: String) throws {
    guard (endpoint["type"] as? String) == "wireguard" else {
      throw CoreFailure.invalidProfile(
        "Only userspace WireGuard endpoints are accepted by the privileged helper."
      )
    }
    try requireAllowedKeys(
      endpoint,
      allowed: NativeCapabilityPolicy.dialKeys.union(Self.safeWireGuardEndpointKeys),
      path: path
    )
    guard (endpoint["system"] as? Bool) != true else {
      throw CoreFailure.invalidProfile(
        "System-managed endpoints are not allowed in a privileged profile.")
    }
    guard endpoint["peers"] == nil || endpoint["peers"] is [[String: Any]] else {
      throw CoreFailure.invalidProfile("WireGuard endpoint peers must be an array.")
    }
    for (index, peer) in (endpoint["peers"] as? [[String: Any]] ?? []).enumerated() {
      try requireAllowedKeys(
        peer, allowed: Self.safeWireGuardPeerKeys, path: "\(path).peers[\(index)]")
    }
    try validateOptionalDomainResolver(endpoint["domain_resolver"], path: "\(path).domain_resolver")
  }

  private func validateOptionalOutboundTLS(_ value: Any?, path: String) throws {
    guard let value else { return }
    guard let tls = value as? [String: Any] else {
      throw CoreFailure.invalidProfile("The imported TLS section at \(path) must be an object.")
    }
    try requireAllowedKeys(tls, allowed: Self.safeOutboundTLSKeys, path: path)
    if let ech = tls["ech"] as? [String: Any] {
      try requireAllowedKeys(ech, allowed: Self.safeECHKeys, path: "\(path).ech")
    }
    if let utls = tls["utls"] as? [String: Any] {
      try requireAllowedKeys(utls, allowed: ["enabled", "fingerprint"], path: "\(path).utls")
    }
    if let reality = tls["reality"] as? [String: Any] {
      try requireAllowedKeys(
        reality, allowed: ["enabled", "public_key", "short_id"], path: "\(path).reality")
    }
  }

  private func validateOptionalDomainResolver(_ value: Any?, path: String) throws {
    guard let value, !(value is String) else { return }
    guard let resolver = value as? [String: Any] else {
      throw CoreFailure.invalidProfile("The domain resolver at \(path) is invalid.")
    }
    try requireAllowedKeys(
      resolver,
      allowed: ["server", "strategy", "disable_cache", "rewrite_ttl", "client_subnet"],
      path: path
    )
  }

  private func requireAllowedKeys(
    _ object: [String: Any],
    allowed: Set<String>,
    path: String
  ) throws {
    let unsupported = Set(object.keys).subtracting(allowed)
    guard unsupported.isEmpty else {
      throw CoreFailure.invalidProfile(
        "Unsupported fields at \(path): \(unsupported.sorted().joined(separator: ", "))."
      )
    }
  }

  private func validateBoundedValue(
    _ value: Any,
    path: String,
    depth: Int,
    budget: inout ImportedValueBudget
  ) throws {
    guard depth <= ImportedValueBudget.maximumDepth else {
      throw CoreFailure.invalidProfile("The imported profile exceeds the maximum nesting depth.")
    }
    budget.nodeCount += 1
    guard budget.nodeCount <= ImportedValueBudget.maximumNodeCount else {
      throw CoreFailure.invalidProfile("The imported profile contains too many values.")
    }
    if let object = value as? [String: Any] {
      guard object.count <= ImportedValueBudget.maximumCollectionCount else {
        throw CoreFailure.invalidProfile("The imported object at \(path) contains too many fields.")
      }
      for (key, child) in object {
        guard key.utf8.count <= ImportedValueBudget.maximumKeyBytes else {
          throw CoreFailure.invalidProfile("The imported object at \(path) has an oversized key.")
        }
        try validateBoundedValue(
          child, path: "\(path).\(key)", depth: depth + 1, budget: &budget)
      }
    } else if let array = value as? [Any] {
      guard array.count <= ImportedValueBudget.maximumCollectionCount else {
        throw CoreFailure.invalidProfile("The imported array at \(path) contains too many values.")
      }
      for (index, child) in array.enumerated() {
        try validateBoundedValue(
          child, path: "\(path)[\(index)]", depth: depth + 1, budget: &budget)
      }
    } else if let string = value as? String,
      string.utf8.count > ImportedValueBudget.maximumStringBytes
    {
      throw CoreFailure.invalidProfile("The imported string at \(path) is too large.")
    }
  }

  private static let safeDNSKeys: Set<String> = [
    "servers", "rules", "final", "reverse_mapping", "strategy", "disable_cache",
    "disable_expire", "independent_cache", "cache_capacity", "client_subnet", "fakeip",
  ]

  private static let safeDNSServerKeys: Set<String> = [
    "type", "tag", "address", "address_resolver", "address_strategy",
    "address_fallback_delay", "strategy", "client_subnet", "server", "server_port",
    "tls", "method", "headers", "prefer_go", "interface", "predefined", "inet4_range",
    "inet6_range",
  ]

  private static let safeRouteKeys: Set<String> = [
    "rules", "rule_set", "final", "auto_detect_interface", "default_domain_resolver",
    "default_network_strategy", "default_network_type", "default_fallback_network_type",
    "default_fallback_delay", "find_process",
  ]

  private static let safeMultiplexKeys: Set<String> = [
    "enabled", "protocol", "max_connections", "min_streams", "max_streams", "padding",
    "brutal",
  ]

  private static let safeWireGuardEndpointKeys: Set<String> = [
    "type", "tag", "system", "name", "mtu", "address", "private_key", "peers",
    "udp_timeout", "workers",
  ]

  private static let safeWireGuardPeerKeys: Set<String> = [
    "address", "port", "public_key", "pre_shared_key", "allowed_ips",
    "persistent_keepalive_interval", "reserved",
  ]

  private static let safeOutboundTLSKeys: Set<String> = [
    "enabled", "disable_sni", "server_name", "insecure", "alpn", "min_version",
    "max_version", "cipher_suites", "curve_preferences", "certificate",
    "certificate_public_key_sha256", "client_certificate", "client_key", "fragment",
    "fragment_fallback_delay", "record_fragment", "kernel_tx", "kernel_rx", "ech", "utls",
    "reality",
  ]

  private static let safeECHKeys: Set<String> = [
    "enabled", "config", "query_server_name", "pq_signature_schemes_enabled",
    "dynamic_record_sizing_disabled",
  ]

  private func validateTags(_ items: [[String: Any]], kind: String) throws -> Set<String> {
    var tags = Set<String>()
    for item in items {
      guard let type = item["type"] as? String, !type.isEmpty,
        let tag = item["tag"] as? String, !tag.isEmpty,
        tag.utf8.count <= 128,
        !tag.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else { throw CoreFailure.invalidProfile("Every \(kind) must have a valid type and tag.") }
      guard tags.insert(tag).inserted else {
        throw CoreFailure.invalidProfile("Duplicate \(kind) tag: \(tag).")
      }
    }
    return tags
  }

  private func ensureDirectOutbound(
    in outbounds: inout [[String: Any]],
    endpoints: [[String: Any]]
  ) throws -> String {
    guard
      !(outbounds + endpoints).contains(where: {
        ($0["tag"] as? String) == "sbm-direct"
      })
    else {
      throw CoreFailure.invalidProfile("The profile uses the reserved tag sbm-direct.")
    }
    outbounds.append(["type": "direct", "tag": "sbm-direct"])
    return "sbm-direct"
  }

  private func validateNativeRuleSets(
    _ value: Any?,
    availableTags: Set<String>
  ) throws {
    guard let value else { return }
    guard let items = value as? [[String: Any]], items.count <= 256 else {
      throw CoreFailure.invalidProfile(
        "The native profile route.rule_set field must be a bounded array."
      )
    }
    let allowedKeys = Set([
      "type", "tag", "format", "url", "download_detour", "update_interval",
    ])
    var tags = Set<String>()
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
          "Native rule set \(index + 1) must be a unique remote HTTPS rule set."
        )
      }
      if let detour = item["download_detour"] as? String,
        !availableTags.contains(detour)
      {
        throw CoreFailure.invalidProfile(
          "Native rule set \(index + 1) uses an unknown download detour."
        )
      }
    }
  }

  private func appendManagedAuto(
    candidates: [String],
    tags: Set<String>,
    outbounds: inout [[String: Any]],
    latencyTestURL: String
  ) throws {
    guard !tags.contains("sbm-auto") else {
      throw CoreFailure.invalidProfile("The profile uses the reserved tag sbm-auto.")
    }
    outbounds.append([
      "type": "urltest",
      "tag": "sbm-auto",
      "outbounds": candidates,
      "url": latencyTestURL,
      "interval": "10m",
      "tolerance": 50,
      "idle_timeout": "30m",
      "interrupt_exist_connections": false,
    ])
  }

  private func managedRouteRules(selectorTag: String, directTag: String) -> [[String: Any]] {
    [
      ["action": "sniff"],
      ["protocol": "dns", "action": "hijack-dns"],
      [
        "clash_mode": RoutingMode.direct.rawValue,
        "action": "route",
        "outbound": directTag,
      ],
      [
        "clash_mode": RoutingMode.global.rawValue,
        "action": "route",
        "outbound": selectorTag,
      ],
      [
        "ip_is_private": true,
        "action": "route",
        "outbound": directTag,
      ],
    ]
  }

  private func managedDNS(selectorTag: String) -> [String: Any] {
    [
      "servers": [
        ["type": "local", "tag": "sbm-dns-local"],
        [
          "type": "https",
          "tag": "sbm-dns-remote",
          "server": "1.1.1.1",
          "detour": selectorTag,
          "tls": [
            "enabled": true,
            "server_name": "cloudflare-dns.com",
          ],
        ],
      ],
      "rules": [
        [
          "clash_mode": RoutingMode.direct.rawValue,
          "action": "route",
          "server": "sbm-dns-local",
        ],
        ["action": "route", "server": "sbm-dns-remote"],
      ],
      "final": "sbm-dns-remote",
      "strategy": "ipv4_only",
      "cache_capacity": 4096,
    ]
  }

  private func composeDNS(
    imported: [String: Any]?,
    selectorTag: String
  ) throws -> [String: Any] {
    guard var dns = imported else { return managedDNS(selectorTag: selectorTag) }
    dns["strategy"] = "ipv4_only"
    guard var servers = dns["servers"] as? [[String: Any]], !servers.isEmpty else {
      throw CoreFailure.invalidProfile("The imported DNS configuration has no servers.")
    }
    let tags = Set(servers.compactMap { $0["tag"] as? String })
    guard !tags.contains("sbm-dns-local"), !tags.contains("sbm-dns-remote") else {
      throw CoreFailure.invalidProfile(
        "The profile uses a reserved DNS server tag (sbm-dns-local or sbm-dns-remote).")
    }
    servers.append(["type": "local", "tag": "sbm-dns-local"])
    servers.append([
      "type": "https",
      "tag": "sbm-dns-remote",
      "server": "1.1.1.1",
      "detour": selectorTag,
      "tls": [
        "enabled": true,
        "server_name": "cloudflare-dns.com",
      ],
    ])
    let rulesValue = dns["rules"]
    guard rulesValue == nil || rulesValue is [[String: Any]] else {
      throw CoreFailure.invalidProfile("The imported DNS rules field must be an array.")
    }
    var rules = rulesValue as? [[String: Any]] ?? []
    rules.insert(
      contentsOf: [
        [
          "clash_mode": RoutingMode.direct.rawValue,
          "action": "route",
          "server": "sbm-dns-local",
        ],
        [
          "clash_mode": RoutingMode.global.rawValue,
          "action": "route",
          "server": "sbm-dns-remote",
        ],
      ],
      at: 0
    )
    dns["servers"] = servers
    dns["rules"] = rules
    return dns
  }
}

private struct ImportedValueBudget {
  static let maximumDepth = 32
  static let maximumNodeCount = 32_768
  static let maximumCollectionCount = 4_096
  static let maximumKeyBytes = 256
  static let maximumStringBytes = 256 * 1_024

  var nodeCount = 0
}
