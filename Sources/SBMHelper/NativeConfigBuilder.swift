import Foundation
import SBMShared

struct NativeConfigurationComposer {
  let cachePath: String
  let apiSecret: String

  func compose(
    profile: NativeProfile,
    mode: RoutingMode,
    selectedNode: ProxyNodeID,
    localSOCKSPort: UInt16? = nil
  ) throws -> BuiltConfiguration {
    guard profile.configuration.count <= 1_048_576,
      let source = try JSONSerialization.jsonObject(with: profile.configuration) as? [String: Any]
    else { throw CoreFailure.invalidProfile("The native profile is not a valid JSON object.") }

    try validateTopLevel(source)
    try validateTopLevelTypes(source)
    var importedValueBudget = ImportedValueBudget()
    for key in ["dns", "outbounds", "endpoints", "route"] {
      if let value = source[key] {
        try validateImportedValue(
          value,
          path: "profile.\(key)",
          depth: 0,
          budget: &importedValueBudget
        )
      }
    }

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
            outbounds: &outbounds
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
      try appendManagedAuto(candidates: allCandidates, tags: tags, outbounds: &outbounds)
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

    let directTag = try ensureDirectOutbound(in: &outbounds)
    var route = source["route"] as? [String: Any] ?? [:]
    let rulesValue = route["rules"]
    guard rulesValue == nil || rulesValue is [[String: Any]] else {
      throw CoreFailure.invalidProfile("The native profile route.rules field must be an array.")
    }
    var rules = rulesValue as? [[String: Any]] ?? []
    guard rules.count <= 4096 else {
      throw CoreFailure.invalidProfile("The native profile contains too many routing rules.")
    }
    rules.insert(
      contentsOf: managedRouteRules(selectorTag: selectorTag, directTag: directTag), at: 0)
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
    let names = Dictionary(uniqueKeysWithValues: profile.nodes.map { ($0.id.rawValue, $0.name) })
    let nodes = selectableTags.map { tag in
      ProxyNodeDescriptor(id: ProxyNodeID(rawValue: tag), name: names[tag] ?? tag)
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

  private func validateImportedValue(
    _ value: Any,
    path: String,
    depth: Int,
    budget: inout ImportedValueBudget,
    plainPathAllowed: Bool = false
  ) throws {
    guard depth <= ImportedValueBudget.maximumDepth else {
      throw CoreFailure.invalidProfile(
        "The imported profile exceeds the maximum nesting depth.")
    }
    budget.nodeCount += 1
    guard budget.nodeCount <= ImportedValueBudget.maximumNodeCount else {
      throw CoreFailure.invalidProfile(
        "The imported profile contains too many values.")
    }

    if let object = value as? [String: Any] {
      guard object.count <= ImportedValueBudget.maximumCollectionCount else {
        throw CoreFailure.invalidProfile(
          "The imported object at \(path) contains too many fields.")
      }
      for (key, child) in object {
        guard key.utf8.count <= ImportedValueBudget.maximumKeyBytes else {
          throw CoreFailure.invalidProfile(
            "The imported object at \(path) contains an oversized field name.")
        }
        let normalized = key.lowercased()
        let filesystemField =
          normalized.hasSuffix("_path")
          || normalized == "state_directory"
          || normalized == "data_directory"
          || normalized.hasSuffix("_directory")
        let plainPathIsUnsafe = normalized == "path" && !plainPathAllowed
        if filesystemField || plainPathIsUnsafe
          || [
            "command", "commands", "script", "listen", "listen_port",
            "certificate_provider", "certificate_providers", "acme",
          ].contains(normalized)
        {
          throw CoreFailure.invalidProfile(
            "The imported field \(path).\(key) is not allowed in a privileged profile.")
        }
        if ["system", "system_interface"].contains(normalized),
          let enabled = child as? Bool, enabled
        {
          throw CoreFailure.invalidProfile(
            "System-managed endpoints are not allowed in a privileged profile.")
        }
        if normalized == "relay_server_port", let port = child as? NSNumber,
          port.intValue != 0
        {
          throw CoreFailure.invalidProfile(
            "Privileged relay listeners are not allowed in imported profiles.")
        }
        if normalized == "ssh_server" {
          throw CoreFailure.invalidProfile(
            "Embedded SSH servers are not allowed in imported profiles.")
        }
        try validateImportedValue(
          child,
          path: "\(path).\(key)",
          depth: depth + 1,
          budget: &budget,
          plainPathAllowed: normalized == "transport"
        )
      }
    } else if let array = value as? [Any] {
      guard array.count <= ImportedValueBudget.maximumCollectionCount else {
        throw CoreFailure.invalidProfile(
          "The imported array at \(path) contains too many values.")
      }
      for (index, child) in array.enumerated() {
        try validateImportedValue(
          child,
          path: "\(path)[\(index)]",
          depth: depth + 1,
          budget: &budget,
          plainPathAllowed: plainPathAllowed
        )
      }
    } else if let string = value as? String {
      guard string.utf8.count <= ImportedValueBudget.maximumStringBytes else {
        throw CoreFailure.invalidProfile(
          "The imported string at \(path) is too large.")
      }
    }
  }

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

  private func ensureDirectOutbound(in outbounds: inout [[String: Any]]) throws -> String {
    if let direct = outbounds.first(where: { ($0["type"] as? String) == "direct" }),
      let tag = direct["tag"] as? String
    {
      return tag
    }
    guard !outbounds.contains(where: { ($0["tag"] as? String) == "sbm-direct" }) else {
      throw CoreFailure.invalidProfile("The profile uses the reserved tag sbm-direct.")
    }
    outbounds.append(["type": "direct", "tag": "sbm-direct"])
    return "sbm-direct"
  }

  private func appendManagedAuto(
    candidates: [String],
    tags: Set<String>,
    outbounds: inout [[String: Any]]
  ) throws {
    guard !tags.contains("sbm-auto") else {
      throw CoreFailure.invalidProfile("The profile uses the reserved tag sbm-auto.")
    }
    outbounds.append([
      "type": "urltest",
      "tag": "sbm-auto",
      "outbounds": candidates,
      "url": "https://www.gstatic.com/generate_204",
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
