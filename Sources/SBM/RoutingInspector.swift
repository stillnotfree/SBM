import Darwin
import Foundation
import SBMShared

struct RoutingInspectionResult: Equatable, Sendable {
  enum Decision: Equatable, Hashable, Sendable {
    case direct
    case vpn
    case reject
    case indeterminate

    var label: String {
      switch self {
      case .direct: "DIRECT"
      case .vpn: "PROXY"
      case .reject: "REJECT"
      case .indeterminate: "INDETERMINATE"
      }
    }
  }

  struct Fallback: Equatable, Sendable {
    let decision: Decision
    let matchedRule: String
    let outboundTag: String?
  }

  let decision: Decision
  let matchedRule: String?
  let uncertaintyReason: String?
  let outboundTag: String?
  let ruleIndex: Int?
  let fallback: Fallback?
}

struct RoutingInspectionContext: Equatable, Sendable {
  let domain: String?
  let ipAddress: String?
  let mode: RoutingMode
  let inboundTag: String?
  let applicationPath: String?
  let defaultApplicationPaths: Set<String>

  init(
    domain: String? = nil,
    ipAddress: String? = nil,
    mode: RoutingMode = .rule,
    inboundTag: String? = nil,
    applicationPath: String? = nil,
    defaultApplicationPaths: Set<String> = []
  ) {
    self.domain = domain
    self.ipAddress = ipAddress
    self.mode = mode
    self.inboundTag = inboundTag
    self.applicationPath = applicationPath.map(Self.normalizedApplicationPath)
    self.defaultApplicationPaths = Set(defaultApplicationPaths.map(Self.normalizedApplicationPath))
  }

  private static func normalizedApplicationPath(_ value: String) -> String {
    URL(fileURLWithPath: value).standardizedFileURL.path
  }
}

enum RoutingInspector {
  private enum Match {
    case yes
    case no
    case unknown(String)
  }

  private static let runtimeDependentKeys: Set<String> = [
    "auth_user", "client", "network", "package_name", "port", "port_range", "process_name",
    "process_path", "process_path_regex", "protocol", "source_ip_cidr", "source_ip_is_private",
    "source_port", "source_port_range", "user", "user_id", "network_type",
    "network_is_expensive", "network_is_constrained", "interface_address", "wifi_ssid",
    "wifi_bssid", "network_interface_address", "default_interface_address", "preferred_by",
  ]

  private static let destinationAddressKeys: Set<String> = [
    "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr", "ip_is_private",
  ]

  static func inspect(
    route: [String: Any],
    context: RoutingInspectionContext,
    outboundDecisions: [String: RoutingInspectionResult.Decision],
    selectorOutbound: String,
    ruleSetMatches: [String: Bool] = [:]
  ) -> RoutingInspectionResult {
    let rules = route["rules"] as? [[String: Any]] ?? []
    return inspect(
      rules: rules,
      final: route["final"] as? String,
      startingAt: 0,
      context: context,
      outboundDecisions: outboundDecisions,
      selectorOutbound: selectorOutbound,
      ruleSetMatches: ruleSetMatches,
      includeFallback: true
    )
  }

  private static func inspect(
    rules: [[String: Any]],
    final: String?,
    startingAt startIndex: Int,
    context: RoutingInspectionContext,
    outboundDecisions: [String: RoutingInspectionResult.Decision],
    selectorOutbound: String,
    ruleSetMatches: [String: Bool],
    includeFallback: Bool
  ) -> RoutingInspectionResult {
    for index in startIndex..<rules.count {
      let rule = rules[index]
      guard isTerminal(rule) else { continue }
      switch match(rule, context: context, ruleSetMatches: ruleSetMatches) {
      case .no:
        continue
      case .yes:
        return decision(
          for: rule,
          index: index,
          context: context,
          outboundDecisions: outboundDecisions,
          ruleSetMatches: ruleSetMatches
        )
      case .unknown(let reason):
        let laterResult = inspect(
          rules: rules,
          final: final,
          startingAt: index + 1,
          context: context,
          outboundDecisions: outboundDecisions,
          selectorOutbound: selectorOutbound,
          ruleSetMatches: ruleSetMatches,
          includeFallback: false
        )
        let fallback: RoutingInspectionResult.Fallback? =
          includeFallback && laterResult.decision != .indeterminate
          ? RoutingInspectionResult.Fallback(
            decision: laterResult.decision,
            matchedRule: laterResult.matchedRule ?? "A later route",
            outboundTag: laterResult.outboundTag
          )
          : nil
        return RoutingInspectionResult(
          decision: .indeterminate,
          matchedRule: nil,
          uncertaintyReason: "Rule \(index + 1) may match, but \(reason).",
          outboundTag: nil,
          ruleIndex: index,
          fallback: fallback
        )
      }
    }

    guard let final else {
      return RoutingInspectionResult(
        decision: .indeterminate,
        matchedRule: nil,
        uncertaintyReason: "the composed route has no explicit final outbound",
        outboundTag: nil,
        ruleIndex: nil,
        fallback: nil
      )
    }
    guard let finalDecision = outboundDecisions[final] else {
      return RoutingInspectionResult(
        decision: .indeterminate,
        matchedRule: nil,
        uncertaintyReason: "the final outbound \"\(final)\" cannot be classified locally",
        outboundTag: final,
        ruleIndex: nil,
        fallback: nil
      )
    }
    return RoutingInspectionResult(
      decision: finalDecision,
      matchedRule: "Final route",
      uncertaintyReason: nil,
      outboundTag: final,
      ruleIndex: nil,
      fallback: nil
    )
  }

  static func parseInput(
    _ value: String,
    mode: RoutingMode,
    inboundTag: String?,
    applicationPath: String? = nil,
    defaultApplicationPaths: Set<String> = []
  ) throws
    -> RoutingInspectionContext
  {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 512,
      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw RoutingInspectionFailure.invalidInput }
    if IPAddress.parse(trimmed) != nil {
      return RoutingInspectionContext(
        ipAddress: trimmed,
        mode: mode,
        inboundTag: inboundTag,
        applicationPath: applicationPath,
        defaultApplicationPaths: defaultApplicationPaths
      )
    }
    let domain = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !domain.isEmpty, domain.utf8.count <= 253,
      domain.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0)
      })
    else { throw RoutingInspectionFailure.invalidInput }
    return RoutingInspectionContext(
      domain: domain,
      mode: mode,
      inboundTag: inboundTag,
      applicationPath: applicationPath,
      defaultApplicationPaths: defaultApplicationPaths
    )
  }

  private static func isTerminal(_ rule: [String: Any]) -> Bool {
    guard let action = rule["action"] as? String else { return false }
    return action == "route" || action == "reject"
  }

  private static func decision(
    for rule: [String: Any],
    index: Int,
    context: RoutingInspectionContext,
    outboundDecisions: [String: RoutingInspectionResult.Decision],
    ruleSetMatches: [String: Bool]
  ) -> RoutingInspectionResult {
    if (rule["action"] as? String) == "reject" {
      return RoutingInspectionResult(
        decision: .reject,
        matchedRule: describe(
          rule: rule, index: index, context: context, ruleSetMatches: ruleSetMatches),
        uncertaintyReason: nil,
        outboundTag: nil,
        ruleIndex: index,
        fallback: nil
      )
    }
    guard let outbound = rule["outbound"] as? String else {
      return RoutingInspectionResult(
        decision: .indeterminate,
        matchedRule: nil,
        uncertaintyReason: "rule \(index + 1) has no outbound",
        outboundTag: nil,
        ruleIndex: index,
        fallback: nil
      )
    }
    guard let outboundDecision = outboundDecisions[outbound] else {
      return RoutingInspectionResult(
        decision: .indeterminate,
        matchedRule: describe(
          rule: rule, index: index, context: context, ruleSetMatches: ruleSetMatches),
        uncertaintyReason: "outbound \"\(outbound)\" cannot be classified locally",
        outboundTag: outbound,
        ruleIndex: index,
        fallback: nil
      )
    }
    return RoutingInspectionResult(
      decision: outboundDecision,
      matchedRule: describe(
        rule: rule, index: index, context: context, ruleSetMatches: ruleSetMatches),
      uncertaintyReason: nil,
      outboundTag: outbound,
      ruleIndex: index,
      fallback: nil
    )
  }

  private static func describe(
    rule: [String: Any],
    index: Int,
    context: RoutingInspectionContext,
    ruleSetMatches: [String: Bool]
  ) -> String {
    let conditionOrder = [
      "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr", "ip_is_private",
      "clash_mode", "inbound", "process_path", "protocol", "network", "port", "rule_set",
    ]
    let descriptions = conditionOrder.compactMap { key -> String? in
      guard let value = rule[key] else { return nil }
      if let values = value as? [String] {
        guard let first = values.first else { return nil }
        if key == "domain_suffix", let domain = context.domain {
          return values.first(where: { suffixMatches(domain, suffix: $0) }) ?? first
        }
        if key == "domain", let domain = context.domain {
          return values.first(where: { normalizedDomain($0) == domain }) ?? first
        }
        if key == "domain_keyword", let domain = context.domain {
          return values.first(where: domain.contains) ?? first
        }
        if key == "ip_cidr", let rawIP = context.ipAddress, let ip = IPAddress.parse(rawIP) {
          return values.first(where: ip.matches(cidr:)) ?? first
        }
        if key == "rule_set" {
          return values.first(where: { ruleSetMatches[$0] == true }) ?? "Configured rule-set"
        }
        if key == "process_path" {
          return URL(fileURLWithPath: first).lastPathComponent
        }
        return values.count == 1 ? first : "\(first) +\(values.count - 1)"
      }
      if let string = value as? String { return string }
      if let boolean = value as? Bool { return "\(key) = \(boolean)" }
      return key
    }
    return descriptions.isEmpty ? "Rule \(index + 1)" : descriptions.joined(separator: " + ")
  }

  private static func match(
    _ rule: [String: Any],
    context: RoutingInspectionContext,
    ruleSetMatches: [String: Bool]
  ) -> Match {
    let base: Match
    if (rule["type"] as? String) == "logical" {
      base = matchLogical(rule, context: context, ruleSetMatches: ruleSetMatches)
    } else {
      base = matchFlat(rule, context: context, ruleSetMatches: ruleSetMatches)
    }
    guard (rule["invert"] as? Bool) == true else { return base }
    return switch base {
    case .yes: .no
    case .no: .yes
    case .unknown(let reason): .unknown(reason)
    }
  }

  private static func matchLogical(
    _ rule: [String: Any],
    context: RoutingInspectionContext,
    ruleSetMatches: [String: Bool]
  ) -> Match {
    guard let mode = rule["mode"] as? String,
      ["and", "or"].contains(mode),
      let children = rule["rules"] as? [[String: Any]],
      !children.isEmpty
    else { return .unknown("a malformed logical rule") }

    var unknownReason: String?
    for child in children {
      switch match(child, context: context, ruleSetMatches: ruleSetMatches) {
      case .yes where mode == "or": return .yes
      case .no where mode == "and": return .no
      case .unknown(let reason): unknownReason = unknownReason ?? reason
      default: break
      }
    }
    if let unknownReason { return .unknown(unknownReason) }
    return mode == "and" ? .yes : .no
  }

  private static func matchFlat(
    _ rule: [String: Any],
    context: RoutingInspectionContext,
    ruleSetMatches: [String: Bool]
  ) -> Match {
    let structuralKeys: Set<String> = ["action", "outbound", "invert", "type", "mode", "rules"]
    let destinationKeys = destinationAddressKeys.filter { rule[$0] != nil }.sorted()
    let destinationMatch = matchAny(keys: destinationKeys, rule: rule, context: context)
    var unknownReason: String?
    for key in rule.keys.sorted()
    where !structuralKeys.contains(key)
      && !destinationAddressKeys.contains(key)
      && key != "rule_set"
      && key != "rule_set_ip_cidr_match_source"
    {
      let result = matchCondition(key: key, value: rule[key] as Any, context: context)
      switch result {
      case .no: return .no
      case .unknown(let reason): unknownReason = unknownReason ?? reason
      case .yes: break
      }
    }
    if let ruleSets = rule["rule_set"] {
      let tags = stringValues(ruleSets)
      guard !tags.isEmpty else { return .unknown("the rule-set condition is invalid") }
      if tags.contains(where: { ruleSetMatches[$0] == true }) {
        // A rule-set is an OR group, combined with the outer conditions above.
      } else if tags.allSatisfy({ ruleSetMatches[$0] == false }) {
        return .no
      } else {
        return .unknown("the active rule-set cache is required for \(quotedList(tags))")
      }
    }
    switch destinationMatch {
    case .no: return .no
    case .unknown(let reason): unknownReason = unknownReason ?? reason
    case .yes: break
    }
    return unknownReason.map(Match.unknown) ?? .yes
  }

  static func referencedRuleSetTags(in route: [String: Any]) -> [String] {
    var tags: [String] = []
    var seen = Set<String>()
    for rule in route["rules"] as? [[String: Any]] ?? [] {
      collectRuleSetTags(rule, into: &tags, seen: &seen)
    }
    return tags
  }

  private static func collectRuleSetTags(
    _ rule: [String: Any],
    into tags: inout [String],
    seen: inout Set<String>
  ) {
    for tag in stringValues(rule["rule_set"] as Any) where seen.insert(tag).inserted {
      tags.append(tag)
    }
    for child in rule["rules"] as? [[String: Any]] ?? [] {
      collectRuleSetTags(child, into: &tags, seen: &seen)
    }
  }

  private static func matchAny(
    keys: [String], rule: [String: Any], context: RoutingInspectionContext
  ) -> Match {
    guard !keys.isEmpty else { return .yes }
    var unknownReason: String?
    for key in keys {
      switch matchCondition(key: key, value: rule[key] as Any, context: context) {
      case .yes: return .yes
      case .unknown(let reason): unknownReason = unknownReason ?? reason
      case .no: break
      }
    }
    return unknownReason.map(Match.unknown) ?? .no
  }

  private static func matchCondition(
    key: String,
    value: Any,
    context: RoutingInspectionContext
  ) -> Match {
    switch key {
    case "process_path":
      let paths = Set(
        stringValues(value).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
      guard !paths.isEmpty else { return .unknown("the process path condition is invalid") }
      if let applicationPath = context.applicationPath {
        return paths.contains(applicationPath) ? .yes : .no
      }
      if paths.isSubset(of: context.defaultApplicationPaths) { return .no }
      return .unknown("select an application to evaluate the process path condition")
    case "process_name":
      guard let applicationPath = context.applicationPath else {
        return .unknown("select an application to evaluate the process name condition")
      }
      return stringValues(value).contains(URL(fileURLWithPath: applicationPath).lastPathComponent)
        ? .yes : .no
    case "process_path_regex":
      guard let applicationPath = context.applicationPath else {
        return .unknown("select an application to evaluate the process path condition")
      }
      for pattern in stringValues(value) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
          return .unknown("the process path regular expression is invalid")
        }
        let range = NSRange(
          applicationPath.startIndex..<applicationPath.endIndex, in: applicationPath)
        if expression.firstMatch(in: applicationPath, range: range) != nil { return .yes }
      }
      return .no
    default:
      break
    }
    if runtimeDependentKeys.contains(key) { return .unknown(runtimeReason(for: key)) }
    switch key {
    case "clash_mode":
      return stringValues(value).contains(context.mode.rawValue) ? .yes : .no
    case "inbound":
      guard let inboundTag = context.inboundTag else { return .unknown("the runtime inbound") }
      return stringValues(value).contains(inboundTag) ? .yes : .no
    case "domain":
      guard let domain = context.domain else { return .no }
      return stringValues(value).map(normalizedDomain).contains(domain) ? .yes : .no
    case "domain_suffix":
      guard let domain = context.domain else { return .no }
      return stringValues(value).contains(where: { suffixMatches(domain, suffix: $0) }) ? .yes : .no
    case "domain_keyword":
      guard let domain = context.domain else { return .no }
      return stringValues(value).contains(where: domain.contains) ? .yes : .no
    case "domain_regex":
      guard let domain = context.domain else { return .no }
      for pattern in stringValues(value) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
          return .unknown("an invalid domain regular expression")
        }
        let range = NSRange(domain.startIndex..<domain.endIndex, in: domain)
        if expression.firstMatch(in: domain, range: range) != nil { return .yes }
      }
      return .no
    case "ip_cidr":
      guard let ipAddress = context.ipAddress, let address = IPAddress.parse(ipAddress) else {
        return context.domain == nil ? .no : .unknown("the resolved destination IP")
      }
      return stringValues(value).contains(where: address.matches(cidr:)) ? .yes : .no
    case "ip_version":
      guard let ipAddress = context.ipAddress, let address = IPAddress.parse(ipAddress) else {
        return .unknown("the resolved destination IP")
      }
      return integerValues(value).contains(address.version) ? .yes : .no
    case "ip_is_private":
      guard boolValue(value) == true else { return .unknown("an invalid private-IP condition") }
      guard let ipAddress = context.ipAddress, let address = IPAddress.parse(ipAddress) else {
        // Domain inspection deliberately explains hostname policy without a DNS probe.
        return context.domain == nil ? .no : .no
      }
      return address.isPrivate ? .yes : .no
    default:
      return .unknown("condition \"\(key)\" is not supported by Routing Inspector")
    }
  }

  private static func runtimeReason(for key: String) -> String {
    switch key {
    case "process_name", "process_path", "process_path_regex":
      "the rule needs a running process, but no application was supplied"
    case "protocol", "client":
      "the rule needs sniffed protocol information, which is unavailable before traffic exists"
    case "network", "port", "port_range", "source_port", "source_port_range":
      "the rule needs network or port information, which was not supplied"
    case "source_ip_cidr", "source_ip_is_private":
      "the rule needs the runtime source address, which was not supplied"
    default:
      "the rule needs runtime \(key) information, which was not supplied"
    }
  }

  private static func quotedList(_ values: [String]) -> String {
    values.map { "\"\($0)\"" }.joined(separator: ", ")
  }

  private static func stringValues(_ value: Any) -> [String] {
    if let string = value as? String { return [string] }
    return value as? [String] ?? []
  }

  private static func integerValues(_ value: Any) -> [Int] {
    if let number = value as? NSNumber { return [number.intValue] }
    return (value as? [NSNumber] ?? []).map(\.intValue)
  }

  private static func boolValue(_ value: Any) -> Bool? {
    value as? Bool
  }

  private static func normalizedDomain(_ value: String) -> String {
    value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
  }

  private static func suffixMatches(_ domain: String, suffix: String) -> Bool {
    let suffix = normalizedDomain(suffix)
    return domain == suffix || domain.hasSuffix(".\(suffix)")
  }
}

struct ComposedRoutingInspection {
  let route: [String: Any]
  let outboundDecisions: [String: RoutingInspectionResult.Decision]
  let vpnServerNames: [String: String]
  let selectorOutbound: String
  let inboundTag: String

  static func make(
    profile: CoreProfile,
    selectedNode: ProxyNodeID = .auto
  ) throws -> ComposedRoutingInspection {
    switch profile {
    case .compatibility(let compatibility):
      var route: [String: Any] = [
        "auto_detect_interface": true,
        "default_domain_resolver": "dns-local",
        "final": "proxy-selector",
      ]
      var rules = managedRules(proxyOutbound: "proxy-selector", directOutbound: "direct")
      rules.append(
        contentsOf: applicationRules(
          compatibility.applicationRoutingRules,
          directOutbound: "direct",
          proxyOutbound: "proxy-selector",
          allowedNodeIDs: Set(compatibility.connections.map(\.id))
        )
      )
      if let policy = compatibility.routingPolicy {
        guard
          let root = try JSONSerialization.jsonObject(with: policy.configuration)
            as? [String: Any],
          let importedRoute = root["route"] as? [String: Any]
        else { throw RoutingInspectionFailure.unavailable }
        rules.append(contentsOf: importedRoute["rules"] as? [[String: Any]] ?? [])
        if let ruleSets = importedRoute["rule_set"] { route["rule_set"] = ruleSets }
      }
      route["rules"] = rules
      var decisions: [String: RoutingInspectionResult.Decision] = [
        "direct": .direct,
        "block": .reject,
        "auto": .vpn,
        "proxy-selector": .vpn,
      ]
      var names = ["auto": "Auto (chosen automatically)"]
      for connection in compatibility.connections {
        decisions[connection.id.rawValue] = .vpn
        names[connection.id.rawValue] = connection.displayName
      }
      let chosen = decisions[selectedNode.rawValue] == .vpn ? selectedNode.rawValue : "auto"
      names["proxy-selector"] = names[chosen] ?? chosen
      return ComposedRoutingInspection(
        route: route,
        outboundDecisions: decisions,
        vpnServerNames: names,
        selectorOutbound: "proxy-selector",
        inboundTag: "tun-in"
      )
    case .native(let native):
      guard
        let root = try JSONSerialization.jsonObject(with: native.configuration)
          as? [String: Any]
      else { throw RoutingInspectionFailure.unavailable }
      var route = root["route"] as? [String: Any] ?? [:]
      var rules = managedRules(proxyOutbound: native.selectorTag, directOutbound: "sbm-direct")
      let fixedNodeIDs = nativeFixedNodeIDs(root: root)
      rules.append(
        contentsOf: applicationRules(
          native.applicationRoutingRules,
          directOutbound: "sbm-direct",
          proxyOutbound: native.selectorTag,
          allowedNodeIDs: fixedNodeIDs
        )
      )
      rules.append(contentsOf: route["rules"] as? [[String: Any]] ?? [])
      route["rules"] = rules
      route["final"] = native.selectorTag
      route["auto_detect_interface"] = true
      if root["dns"] == nil, route["default_domain_resolver"] == nil {
        route["default_domain_resolver"] = "sbm-dns-local"
      }
      let entries =
        (root["outbounds"] as? [[String: Any]] ?? [])
        + (root["endpoints"] as? [[String: Any]] ?? [])
      var decisions = classify(entries: entries)
      decisions["sbm-direct"] = .direct
      let nodeIDs = Set(native.nodes.map(\.id))
      let chosen = nodeIDs.contains(selectedNode) ? selectedNode : native.nodes.first?.id
      if decisions["sbm-auto"] == nil { decisions["sbm-auto"] = .vpn }
      if let chosen, let chosenDecision = decisions[chosen.rawValue] {
        decisions[native.selectorTag] = chosenDecision
      } else if chosen?.rawValue == "sbm-auto" {
        decisions[native.selectorTag] = .vpn
      }
      var names = Dictionary(uniqueKeysWithValues: native.nodes.map { ($0.id.rawValue, $0.name) })
      if let chosen {
        let chosenName = names[chosen.rawValue] ?? chosen.rawValue
        names[native.selectorTag] =
          chosen.kind(in: native.nodes) == .automatic
          ? "\(chosenName) (chosen automatically)" : chosenName
      }
      return ComposedRoutingInspection(
        route: route,
        outboundDecisions: decisions,
        vpnServerNames: names,
        selectorOutbound: native.selectorTag,
        inboundTag: "sbm-tun-in"
      )
    }
  }

  func presentation(for result: RoutingInspectionResult) -> String {
    guard result.decision != .indeterminate else {
      return result.uncertaintyReason ?? "Additional routing context is required."
    }
    var decision = result.decision.label
    if result.decision == .vpn, let outbound = result.outboundTag,
      let server = vpnServerNames[outbound]
    {
      decision += " · \(server.replacingOccurrences(of: " (chosen automatically)", with: ""))"
    }
    let matched = result.matchedRule ?? "Final route"
    return "\(decision)\nMatched: \(matched)"
  }

  func details(for result: RoutingInspectionResult, contextLabel: String) -> String {
    var lines = ["Traffic from: \(contextLabel)"]
    if let ruleIndex = result.ruleIndex { lines.append("Rule: \(ruleIndex + 1)") }
    if let outbound = result.outboundTag { lines.append("Outbound: \(outbound)") }
    if let fallback = result.fallback {
      lines.append("If not matched: \(fallback.decision.label) · \(fallback.matchedRule)")
    }
    return lines.joined(separator: "\n")
  }

  private static func managedRules(
    proxyOutbound: String,
    directOutbound: String
  ) -> [[String: Any]] {
    [
      ["action": "sniff"],
      ["protocol": "dns", "action": "hijack-dns"],
      [
        "clash_mode": RoutingMode.direct.rawValue,
        "action": "route",
        "outbound": directOutbound,
      ],
      [
        "clash_mode": RoutingMode.global.rawValue,
        "action": "route",
        "outbound": proxyOutbound,
      ],
      [
        "ip_is_private": true,
        "action": "route",
        "outbound": directOutbound,
      ],
    ]
  }

  private static func applicationRules(
    _ rules: [ApplicationRoutingRule],
    directOutbound: String,
    proxyOutbound: String,
    allowedNodeIDs: Set<ProxyNodeID>
  ) -> [[String: Any]] {
    rules.compactMap { rule in
      let action: [String: Any]
      switch rule.target {
      case .direct:
        action = ["action": "route", "outbound": directOutbound]
      case .selectedProxy:
        action = ["action": "route", "outbound": proxyOutbound]
      case .reject:
        action = ["action": "reject"]
      case .node(let node):
        guard allowedNodeIDs.contains(node) else { return nil }
        action = ["action": "route", "outbound": node.rawValue]
      }
      var composed = action
      composed["process_path"] = [
        URL(fileURLWithPath: rule.executablePath).standardizedFileURL.path
      ]
      return composed
    }
  }

  private static func nativeFixedNodeIDs(root: [String: Any]) -> Set<ProxyNodeID> {
    let entries =
      (root["outbounds"] as? [[String: Any]] ?? [])
      + (root["endpoints"] as? [[String: Any]] ?? [])
    return Set(
      entries.compactMap { entry in
        guard let tag = entry["tag"] as? String,
          let type = entry["type"] as? String,
          !["direct", "block", "dns", "selector", "urltest"].contains(type)
        else { return nil }
        return ProxyNodeID(rawValue: tag)
      }
    )
  }

  private static func classify(entries: [[String: Any]])
    -> [String: RoutingInspectionResult.Decision]
  {
    var decisions: [String: RoutingInspectionResult.Decision] = [:]
    for entry in entries {
      guard let tag = entry["tag"] as? String, let type = entry["type"] as? String else {
        continue
      }
      switch type {
      case "direct": decisions[tag] = .direct
      case "block": decisions[tag] = .reject
      case "dns", "selector", "urltest": break
      default: decisions[tag] = .vpn
      }
    }
    for _ in 0..<entries.count {
      var changed = false
      for entry in entries {
        guard let tag = entry["tag"] as? String, decisions[tag] == nil,
          let type = entry["type"] as? String, ["selector", "urltest"].contains(type),
          let children = entry["outbounds"] as? [String], !children.isEmpty
        else { continue }
        let childDecisions = children.compactMap { decisions[$0] }
        guard childDecisions.count == children.count,
          Set(childDecisions).count == 1,
          let decision = childDecisions.first
        else { continue }
        decisions[tag] = decision
        changed = true
      }
      if !changed { break }
    }
    return decisions
  }
}

extension ProxyNodeID {
  fileprivate func kind(in nodes: [ProxyNodeDescriptor]) -> ProxyNodeKind? {
    nodes.first(where: { $0.id == self })?.kind
  }
}

enum RoutingInspectionFailure: LocalizedError {
  case invalidInput
  case unavailable

  var errorDescription: String? {
    switch self {
    case .invalidInput: "Enter one domain name or IP address."
    case .unavailable: "The selected profile has no inspectable composed route."
    }
  }
}

private struct IPAddress {
  let family: Int32
  let bytes: [UInt8]

  var version: Int { family == AF_INET ? 4 : 6 }

  var isPrivate: Bool {
    let privateRanges =
      family == AF_INET
      ? [
        "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
        "192.168.0.0/16",
      ]
      : ["::1/128", "fc00::/7", "fe80::/10"]
    return privateRanges.contains(where: matches(cidr:))
  }

  static func parse(_ value: String) -> IPAddress? {
    for (family, size) in [(AF_INET, 4), (AF_INET6, 16)] {
      var bytes = [UInt8](repeating: 0, count: size)
      if inet_pton(family, value, &bytes) == 1 {
        return IPAddress(family: family, bytes: bytes)
      }
    }
    return nil
  }

  func matches(cidr: String) -> Bool {
    let pieces = cidr.split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.count == 2,
      let network = Self.parse(String(pieces[0])),
      network.family == family,
      let prefix = Int(pieces[1]),
      (0...bytes.count * 8).contains(prefix)
    else { return false }
    let completeBytes = prefix / 8
    let remainingBits = prefix % 8
    guard bytes.prefix(completeBytes) == network.bytes.prefix(completeBytes) else { return false }
    guard remainingBits > 0 else { return true }
    let mask = UInt8(0xFF << (8 - remainingBits))
    return bytes[completeBytes] & mask == network.bytes[completeBytes] & mask
  }
}
