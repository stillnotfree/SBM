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

  struct Alternative: Equatable, Sendable {
    let decision: Decision
    let condition: String
    let matchedRule: String?
    let outboundTag: String?
    let ruleIndex: Int?
  }

  let decision: Decision
  let matchedRule: String?
  let uncertaintyReason: String?
  let outboundTag: String?
  let ruleIndex: Int?
  let fallback: Fallback?
  let alternatives: [Alternative]
  let collapsedPathCount: Int
  let analysisLimited: Bool

  init(
    decision: Decision,
    matchedRule: String?,
    uncertaintyReason: String?,
    outboundTag: String?,
    ruleIndex: Int?,
    fallback: Fallback?,
    alternatives: [Alternative] = [],
    collapsedPathCount: Int = 0,
    analysisLimited: Bool = false
  ) {
    self.decision = decision
    self.matchedRule = matchedRule
    self.uncertaintyReason = uncertaintyReason
    self.outboundTag = outboundTag
    self.ruleIndex = ruleIndex
    self.fallback = fallback
    self.alternatives = alternatives
    self.collapsedPathCount = collapsedPathCount
    self.analysisLimited = analysisLimited
  }
}

struct RoutingInspectionSnapshot: Equatable, Sendable {
  let profileID: UUID?
  let profileRevision: Date?
  let applicationID: UUID?
  let applicationPath: String?
  let destination: String
  let selectedNodeID: ProxyNodeID
  let mode: RoutingMode
  let routingRevision: UInt64
  let ipv6Enabled: Bool
}

enum RoutingInspectorState: Equatable, Sendable {
  case idle
  case result(snapshot: RoutingInspectionSnapshot, output: String, details: String)
  case failed(snapshot: RoutingInspectionSnapshot, output: String, details: String)

  static let idleOutput = ""

  var snapshot: RoutingInspectionSnapshot? {
    switch self {
    case .idle: nil
    case .result(let snapshot, _, _), .failed(let snapshot, _, _):
      snapshot
    }
  }

  var output: String {
    switch self {
    case .idle: Self.idleOutput
    case .result(_, let output, _), .failed(_, let output, _): output
    }
  }

  var details: String {
    switch self {
    case .idle: ""
    case .result(_, _, let details), .failed(_, _, let details):
      details
    }
  }
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
    case unknown(reason: String, predicate: SymbolicPredicate?)
  }

  private enum SymbolicPredicate: Hashable {
    case ipVersion([Int])
    case ipIsPrivate(Bool)
    case ipCIDR([String])
  }

  private struct SymbolicContext: Hashable {
    enum AddressFamily: Hashable {
      case unknown
      case ipv4
      case ipv6
    }

    enum Privacy: Hashable {
      case unknown
      case `private`
      case `public`
    }

    struct Branch {
      let context: SymbolicContext
      let condition: String
    }

    private struct CIDR: Hashable {
      let family: Int
      let bytes: [UInt8]
      let prefix: Int
      let rawValue: String

      init?(_ value: String) {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
          let address = IPAddress.parse(String(pieces[0])),
          let prefix = Int(pieces[1]),
          (0...address.bytes.count * 8).contains(prefix)
        else { return nil }

        var bytes = address.bytes
        let completeBytes = prefix / 8
        let remainingBits = prefix % 8
        if remainingBits > 0 {
          let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remainingBits))
          bytes[completeBytes] &= mask
          if completeBytes + 1 < bytes.count {
            for index in (completeBytes + 1)..<bytes.count { bytes[index] = 0 }
          }
        } else if completeBytes < bytes.count {
          for index in completeBytes..<bytes.count { bytes[index] = 0 }
        }
        family = address.version
        self.bytes = bytes
        self.prefix = prefix
        rawValue = value
      }

      func contains(_ other: CIDR) -> Bool {
        guard family == other.family, prefix <= other.prefix else { return false }
        let completeBytes = prefix / 8
        guard bytes.prefix(completeBytes) == other.bytes.prefix(completeBytes) else {
          return false
        }
        let remainingBits = prefix % 8
        guard remainingBits > 0 else { return true }
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remainingBits))
        return bytes[completeBytes] & mask == other.bytes[completeBytes] & mask
      }

      func isSubset(of other: CIDR) -> Bool {
        other.contains(self)
      }

      func isDisjoint(with other: CIDR) -> Bool {
        guard family == other.family else { return true }
        return !contains(other) && !other.contains(self)
      }
    }

    var addressFamily: AddressFamily
    var privacy: Privacy
    var predicateFacts: [SymbolicPredicate: Bool]
    private var includedCIDRs: [CIDR]
    private var excludedCIDRs: [CIDR]

    init(context: RoutingInspectionContext) {
      if let ipAddress = context.ipAddress, let address = IPAddress.parse(ipAddress) {
        addressFamily = address.version == 4 ? .ipv4 : .ipv6
        privacy = address.isPrivate ? .private : .public
      } else {
        addressFamily = .unknown
        privacy = .unknown
      }
      predicateFacts = [:]
      includedCIDRs = []
      excludedCIDRs = []
    }

    func knownValue(for predicate: SymbolicPredicate) -> Bool? {
      if let fact = predicateFacts[predicate] { return fact }
      switch predicate {
      case .ipVersion(let values):
        guard values.allSatisfy({ $0 == 4 || $0 == 6 }) else { return nil }
        switch addressFamily {
        case .ipv4: return values.contains(4)
        case .ipv6: return values.contains(6)
        case .unknown: return nil
        }
      case .ipIsPrivate(let expected):
        switch privacy {
        case .private: return expected
        case .public: return !expected
        case .unknown: return nil
        }
      case .ipCIDR(let values):
        let cidrs = values.compactMap(CIDR.init)
        guard cidrs.count == values.count, !cidrs.isEmpty else { return nil }
        let facts = cidrs.map(membership(of:))
        if facts.contains(true) { return true }
        if facts.allSatisfy({ $0 == false }) { return false }
        return nil
      }
    }

    func branches(for predicate: SymbolicPredicate) -> [Branch] {
      switch predicate {
      case .ipVersion(let values):
        let valid = Set(values.filter { $0 == 4 || $0 == 6 })
        guard !valid.isEmpty else { return [] }
        var branches: [Branch] = []
        if valid.contains(4), let context = applying(predicate, matches: true, family: .ipv4) {
          branches.append(
            Branch(context: context, condition: SBMText.localized("IPv4"))
          )
        }
        if valid.contains(6), let context = applying(predicate, matches: true, family: .ipv6) {
          branches.append(
            Branch(context: context, condition: SBMText.localized("IPv6"))
          )
        }
        if !valid.contains(4), let context = applying(predicate, matches: false, family: .ipv4) {
          branches.append(
            Branch(context: context, condition: SBMText.localized("IPv4"))
          )
        }
        if !valid.contains(6), let context = applying(predicate, matches: false, family: .ipv6) {
          branches.append(
            Branch(context: context, condition: SBMText.localized("IPv6"))
          )
        }
        return unique(branches)
      case .ipIsPrivate:
        return [true, false].compactMap { matches in
          applying(predicate, matches: matches).map {
            Branch(context: $0, condition: condition(for: predicate, matches: matches))
          }
        }
      case .ipCIDR(let values):
        let valid = values.compactMap(CIDR.init)
        guard valid.count == values.count, !valid.isEmpty else { return [] }
        var branches: [Branch] = valid.compactMap { cidr in
          applying(.ipCIDR([cidr.rawValue]), matches: true).map {
            Branch(
              context: $0,
              condition: condition(
                for: .ipCIDR([cidr.rawValue]),
                matches: true
              )
            )
          }
        }
        if let context = applying(predicate, matches: false) {
          branches.append(
            Branch(context: context, condition: condition(for: predicate, matches: false))
          )
        }
        return unique(branches)
      }
    }

    private func applying(
      _ predicate: SymbolicPredicate,
      matches: Bool,
      family: AddressFamily? = nil
    ) -> SymbolicContext? {
      var copy = self
      if let existing = copy.predicateFacts[predicate], existing != matches { return nil }
      copy.predicateFacts[predicate] = matches
      if let family, !copy.setFamily(family) { return nil }
      switch predicate {
      case .ipVersion(let values):
        let valid = Set(values.filter { $0 == 4 || $0 == 6 })
        let possible = matches ? valid : Set([4, 6]).subtracting(valid)
        guard !possible.isEmpty else { return nil }
        if addressFamily != .unknown {
          let current = addressFamily == .ipv4 ? 4 : 6
          guard possible.contains(current) else { return nil }
        }
        if possible.count == 1, let version = possible.first {
          if !copy.setFamily(version == 4 ? .ipv4 : .ipv6) { return nil }
        }
      case .ipIsPrivate(let expected):
        let privacy: Privacy = (matches == expected) ? .private : .public
        if !copy.setPrivacy(privacy) { return nil }
      case .ipCIDR(let values):
        let cidrs = values.compactMap(CIDR.init)
        guard cidrs.count == values.count, !cidrs.isEmpty else { return nil }
        if matches {
          guard cidrs.count == 1, copy.addIncluded(cidrs[0]) else { return nil }
        } else {
          for cidr in cidrs {
            guard copy.addExcluded(cidr) else { return nil }
          }
        }
      }
      return copy
    }

    private mutating func setFamily(_ family: AddressFamily) -> Bool {
      switch (addressFamily, family) {
      case (.unknown, _):
        addressFamily = family
        return true
      case (let existing, _) where existing == family:
        return true
      default:
        return false
      }
    }

    private mutating func setPrivacy(_ value: Privacy) -> Bool {
      switch (privacy, value) {
      case (.unknown, _):
        privacy = value
        return true
      case (let existing, _) where existing == value:
        return true
      default:
        return false
      }
    }

    private static let privateCIDRs: [CIDR] = [
      "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
      "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10",
    ].compactMap(CIDR.init)

    private func membership(of cidr: CIDR) -> Bool? {
      if addressFamily != .unknown {
        let current = addressFamily == .ipv4 ? 4 : 6
        if current != cidr.family { return false }
      }
      if includedCIDRs.contains(where: { $0.isSubset(of: cidr) }) { return true }
      if includedCIDRs.contains(where: { $0.isDisjoint(with: cidr) }) { return false }
      if excludedCIDRs.contains(where: { cidr.isSubset(of: $0) }) { return false }
      return nil
    }

    private mutating func addIncluded(_ cidr: CIDR) -> Bool {
      let family: AddressFamily = cidr.family == 4 ? .ipv4 : .ipv6
      guard setFamily(family), !includedCIDRs.contains(where: { $0.isDisjoint(with: cidr) }),
        !excludedCIDRs.contains(where: { cidr.isSubset(of: $0) })
      else { return false }
      includedCIDRs.append(cidr)
      if let impliedPrivacy = impliedPrivacy(for: cidr), !setPrivacy(impliedPrivacy) {
        return false
      }
      return true
    }

    private mutating func addExcluded(_ cidr: CIDR) -> Bool {
      guard !includedCIDRs.contains(where: { $0.isSubset(of: cidr) }) else { return false }
      excludedCIDRs.append(cidr)
      return true
    }

    private func impliedPrivacy(for cidr: CIDR) -> Privacy? {
      let sameFamily = Self.privateCIDRs.filter { $0.family == cidr.family }
      if sameFamily.contains(where: { $0.contains(cidr) }) { return .private }
      if sameFamily.allSatisfy({ $0.isDisjoint(with: cidr) }) { return .public }
      return nil
    }

    private func unique(_ branches: [Branch]) -> [Branch] {
      var seen = Set<SymbolicContext>()
      return branches.filter { seen.insert($0.context).inserted }
    }

    private func condition(for predicate: SymbolicPredicate, matches: Bool) -> String {
      switch predicate {
      case .ipVersion(let values):
        let valid = values.filter { $0 == 4 || $0 == 6 }
        let selected = matches ? valid : [4, 6].filter { !valid.contains($0) }
        return selected.map { "IPv\($0)" }.joined(separator: " / ")
      case .ipIsPrivate(let expected):
        let isPrivate = matches == expected
        return SBMText.localized(isPrivate ? "Private address" : "Public address")
      case .ipCIDR(let values):
        let cidrs = values.joined(separator: ", ")
        return SBMText.format(
          matches ? "IP matches %@" : "IP does not match %@",
          cidrs
        )
      }
    }
  }

  private struct Path {
    let ruleIndex: Int
    let symbolic: SymbolicContext
    let conditions: [String]
  }

  private struct TerminalOutcome {
    let result: RoutingInspectionResult
    let conditions: [String]
  }

  private struct EffectiveOutcome: Hashable {
    let decision: RoutingInspectionResult.Decision
    let outboundTag: String?

    init(_ result: RoutingInspectionResult) {
      decision = result.decision
      outboundTag = result.decision == .vpn ? result.outboundTag : nil
    }
  }

  private struct Evaluation {
    let outcomes: [TerminalOutcome]
    let limited: Bool
    let uncertaintyReason: String?
    let uncertaintyRuleIndex: Int?
    let fallback: RoutingInspectionResult.Fallback?
  }

  private static let symbolicPathLimit = 32

  private static let runtimeDependentKeys: Set<String> = [
    "auth_user", "client", "network", "package_name", "port", "port_range", "process_name",
    "process_path", "protocol", "source_ip_cidr", "source_ip_is_private",
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
    outboundDecisions: [String: RoutingInspectionResult.Decision]
  ) -> RoutingInspectionResult {
    let rules = route["rules"] as? [[String: Any]] ?? []
    let evaluation = evaluate(
      rules: rules,
      final: route["final"] as? String,
      startingAt: 0,
      context: context,
      outboundDecisions: outboundDecisions
    )
    return summarize(evaluation)
  }

  private struct PathKey: Hashable {
    let ruleIndex: Int
    let symbolic: SymbolicContext
  }

  private static func evaluate(
    rules: [[String: Any]],
    final: String?,
    startingAt startIndex: Int,
    context: RoutingInspectionContext,
    outboundDecisions: [String: RoutingInspectionResult.Decision]
  ) -> Evaluation {
    var pending = [
      Path(
        ruleIndex: startIndex,
        symbolic: SymbolicContext(context: context),
        conditions: []
      )
    ]
    var seen = Set<PathKey>()
    var outcomes: [TerminalOutcome] = []
    var limited = false
    var uncertaintyReason: String?
    var uncertaintyRuleIndex: Int?
    var fallback: RoutingInspectionResult.Fallback?

    while let path = pending.popLast() {
      guard seen.insert(PathKey(ruleIndex: path.ruleIndex, symbolic: path.symbolic)).inserted
      else { continue }
      var index = path.ruleIndex
      var terminated = false

      while index < rules.count {
        let rule = rules[index]
        guard isTerminal(rule) else {
          index += 1
          continue
        }
        switch match(
          rule,
          context: context,
          symbolic: path.symbolic
        ) {
        case .no:
          index += 1
        case .yes:
          outcomes.append(
            TerminalOutcome(
              result: decision(
                for: rule,
                index: index,
                context: context,
                outboundDecisions: outboundDecisions
              ),
              conditions: path.conditions
            )
          )
          terminated = true
        case .unknown(let reason, let predicate):
          if let predicate {
            uncertaintyReason = uncertaintyReason ?? reason
            uncertaintyRuleIndex = uncertaintyRuleIndex ?? index
            let branches = path.symbolic.branches(for: predicate)
            guard !branches.isEmpty else {
              index += 1
              continue
            }
            guard outcomes.count + pending.count + branches.count <= symbolicPathLimit else {
              limited = true
              terminated = true
              break
            }
            for branch in branches.reversed() {
              pending.append(
                Path(
                  ruleIndex: index,
                  symbolic: branch.context,
                  conditions: path.conditions + [branch.condition]
                )
              )
            }
            terminated = true
          } else {
            uncertaintyReason =
              uncertaintyReason
              ?? SBMText.format(
                "Rule %lld may match, but %@.",
                index + 1,
                reason
              )
            uncertaintyRuleIndex = uncertaintyRuleIndex ?? index
            let laterResult = deterministicContinuation(
              rules: rules,
              final: final,
              startingAt: index + 1,
              context: context,
              symbolic: path.symbolic,
              outboundDecisions: outboundDecisions
            )
            if fallback == nil, let later = laterResult, later.decision != .indeterminate {
              fallback = RoutingInspectionResult.Fallback(
                decision: later.decision,
                matchedRule: later.matchedRule ?? SBMText.localized("A later route"),
                outboundTag: later.outboundTag
              )
            }
            guard outcomes.count + pending.count + 2 <= symbolicPathLimit else {
              limited = true
              terminated = true
              break
            }
            outcomes.append(
              TerminalOutcome(
                result: decision(
                  for: rule,
                  index: index,
                  context: context,
                  outboundDecisions: outboundDecisions
                ),
                conditions: path.conditions + [SBMText.localized("Condition matches")]
              )
            )
            pending.append(
              Path(
                ruleIndex: index + 1,
                symbolic: path.symbolic,
                conditions: path.conditions + [SBMText.localized("Condition does not match")]
              )
            )
            terminated = true
          }
        }
        if terminated { break }
      }

      guard !terminated else { continue }
      outcomes.append(
        TerminalOutcome(
          result: finalResult(final: final, outboundDecisions: outboundDecisions),
          conditions: path.conditions
        )
      )
    }
    return Evaluation(
      outcomes: outcomes,
      limited: limited,
      uncertaintyReason: uncertaintyReason,
      uncertaintyRuleIndex: uncertaintyRuleIndex,
      fallback: fallback
    )
  }

  private static func deterministicContinuation(
    rules: [[String: Any]],
    final: String?,
    startingAt startIndex: Int,
    context: RoutingInspectionContext,
    symbolic: SymbolicContext,
    outboundDecisions: [String: RoutingInspectionResult.Decision]
  ) -> RoutingInspectionResult? {
    var index = startIndex
    while index < rules.count {
      let rule = rules[index]
      guard isTerminal(rule) else {
        index += 1
        continue
      }
      switch match(
        rule,
        context: context,
        symbolic: symbolic
      ) {
      case .no:
        index += 1
      case .yes:
        return decision(
          for: rule,
          index: index,
          context: context,
          outboundDecisions: outboundDecisions
        )
      case .unknown:
        return nil
      }
    }
    return finalResult(final: final, outboundDecisions: outboundDecisions)
  }

  private static func finalResult(
    final: String?,
    outboundDecisions: [String: RoutingInspectionResult.Decision]
  ) -> RoutingInspectionResult {
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
      matchedRule: SBMText.localized("Final route"),
      uncertaintyReason: nil,
      outboundTag: final,
      ruleIndex: nil,
      fallback: nil
    )
  }

  private static func summarize(_ evaluation: Evaluation) -> RoutingInspectionResult {
    if evaluation.limited {
      return RoutingInspectionResult(
        decision: .indeterminate,
        matchedRule: nil,
        uncertaintyReason: "routing analysis exceeded the supported complexity limit",
        outboundTag: nil,
        ruleIndex: nil,
        fallback: nil,
        analysisLimited: true
      )
    }
    guard !evaluation.outcomes.isEmpty else {
      return RoutingInspectionResult(
        decision: .indeterminate,
        matchedRule: nil,
        uncertaintyReason: "the composed route has no feasible symbolic path",
        outboundTag: nil,
        ruleIndex: nil,
        fallback: nil
      )
    }
    let uncertain = evaluation.outcomes.filter { $0.result.decision == .indeterminate }
    let certain = evaluation.outcomes.filter { $0.result.decision != .indeterminate }
    if !uncertain.isEmpty {
      let first = uncertain[0].result
      let alternatives = makeAlternatives(from: certain)
      guard !alternatives.isEmpty else { return first }
      return RoutingInspectionResult(
        decision: .indeterminate,
        matchedRule: nil,
        uncertaintyReason:
          first.uncertaintyReason
          ?? normalizedUncertaintyReason(evaluation.uncertaintyReason),
        outboundTag: nil,
        ruleIndex: first.ruleIndex ?? evaluation.uncertaintyRuleIndex,
        fallback: first.fallback ?? evaluation.fallback,
        alternatives: alternatives
      )
    }

    let outcomes = Set(evaluation.outcomes.map { EffectiveOutcome($0.result) })
    if outcomes.count == 1, let effective = outcomes.first {
      let decision = effective.decision
      let matchedRules = Set(evaluation.outcomes.compactMap { $0.result.matchedRule })
      let outbounds = Set(evaluation.outcomes.compactMap { $0.result.outboundTag })
      let ruleIndexes = Set(evaluation.outcomes.compactMap { $0.result.ruleIndex })
      return RoutingInspectionResult(
        decision: decision,
        matchedRule: matchedRules.count == 1
          ? matchedRules.first
          : SBMText.localized("Multiple routing paths"),
        uncertaintyReason: nil,
        outboundTag: outbounds.count == 1 ? outbounds.first : nil,
        ruleIndex: ruleIndexes.count == 1 ? ruleIndexes.first : nil,
        fallback: nil,
        collapsedPathCount: evaluation.outcomes.count > 1 ? evaluation.outcomes.count : 0
      )
    }

    return RoutingInspectionResult(
      decision: .indeterminate,
      matchedRule: nil,
      uncertaintyReason: normalizedUncertaintyReason(evaluation.uncertaintyReason),
      outboundTag: nil,
      ruleIndex: evaluation.uncertaintyRuleIndex,
      fallback: evaluation.fallback,
      alternatives: makeAlternatives(from: evaluation.outcomes)
    )
  }

  private static func normalizedUncertaintyReason(_ reason: String?) -> String {
    guard let reason else { return "routing result depends on unresolved IP conditions" }
    if reason == "the resolved destination IP" {
      return "routing result depends on unresolved IP conditions"
    }
    return reason
  }

  private static func makeAlternatives(
    from outcomes: [TerminalOutcome]
  ) -> [RoutingInspectionResult.Alternative] {
    var order: [EffectiveOutcome] = []
    var grouped: [EffectiveOutcome: [TerminalOutcome]] = [:]
    for outcome in outcomes {
      guard outcome.result.decision != .indeterminate else { continue }
      let effective = EffectiveOutcome(outcome.result)
      if grouped[effective] == nil { order.append(effective) }
      grouped[effective, default: []].append(outcome)
    }
    return order.compactMap { effective in
      guard let values = grouped[effective], !values.isEmpty else { return nil }
      let pathConditions = values.map { value in
        let condition = value.conditions.joined(separator: " + ")
        return condition.isEmpty ? SBMText.localized("Possible route") : condition
      }
      let conditions = Array(Set(pathConditions)).sorted().joined(separator: " / ")
      let matchedRules = Set(values.compactMap { $0.result.matchedRule })
      let outbounds = Set(values.compactMap { $0.result.outboundTag })
      let indexes = Set(values.compactMap { $0.result.ruleIndex })
      return RoutingInspectionResult.Alternative(
        decision: effective.decision,
        condition: conditions,
        matchedRule: matchedRules.count == 1 ? matchedRules.first : nil,
        outboundTag: outbounds.count == 1 ? outbounds.first : nil,
        ruleIndex: indexes.count == 1 ? indexes.first : nil
      )
    }
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
    let domain: String
    if trimmed.unicodeScalars.allSatisfy({ $0.value < 128 }) {
      domain = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      guard !domain.isEmpty, domain.utf8.count <= 253,
        domain.unicodeScalars.allSatisfy({
          CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0)
        })
      else { throw RoutingInspectionFailure.invalidInput }
    } else {
      do {
        domain = try WebsiteDomainNormalizer.normalize(trimmed)
      } catch {
        throw RoutingInspectionFailure.invalidInput
      }
    }
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
    outboundDecisions: [String: RoutingInspectionResult.Decision]
  ) -> RoutingInspectionResult {
    if (rule["action"] as? String) == "reject" {
      return RoutingInspectionResult(
        decision: .reject,
        matchedRule: describe(rule: rule, index: index, context: context),
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
        matchedRule: describe(rule: rule, index: index, context: context),
        uncertaintyReason: "outbound \"\(outbound)\" cannot be classified locally",
        outboundTag: outbound,
        ruleIndex: index,
        fallback: nil
      )
    }
    return RoutingInspectionResult(
      decision: outboundDecision,
      matchedRule: describe(rule: rule, index: index, context: context),
      uncertaintyReason: nil,
      outboundTag: outbound,
      ruleIndex: index,
      fallback: nil
    )
  }

  private static func describe(
    rule: [String: Any],
    index: Int,
    context: RoutingInspectionContext
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
          return values.first(where: { $0 == domain }) ?? first
        }
        if key == "domain_keyword", let domain = context.domain {
          return values.first(where: domain.contains) ?? first
        }
        if key == "ip_cidr", let rawIP = context.ipAddress, let ip = IPAddress.parse(rawIP) {
          return values.first(where: ip.matches(cidr:)) ?? first
        }
        if key == "rule_set" {
          return SBMText.localized("Configured rule-set")
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
    let summary =
      descriptions.isEmpty
      ? SBMText.format("Rule %lld", index + 1)
      : descriptions.joined(separator: " + ")
    return summary
  }

  private static func match(
    _ rule: [String: Any],
    context: RoutingInspectionContext,
    symbolic: SymbolicContext
  ) -> Match {
    let base: Match =
      (rule["type"] as? String) == "logical"
      ? .unknown(
        reason: "condition \"logical\" is not supported by Routing Inspector",
        predicate: nil
      )
      : matchFlat(
        rule,
        context: context,
        symbolic: symbolic
      )
    guard (rule["invert"] as? Bool) == true else { return base }
    return switch base {
    case .yes: .no
    case .no: .yes
    case .unknown(let reason, let predicate): .unknown(reason: reason, predicate: predicate)
    }
  }

  private static func matchFlat(
    _ rule: [String: Any],
    context: RoutingInspectionContext,
    symbolic: SymbolicContext
  ) -> Match {
    let structuralKeys: Set<String> = [
      "action", "outbound", "invert", "type", "mode", "rules",
    ]
    let destinationKeys = destinationAddressKeys.filter { rule[$0] != nil }.sorted()
    let destinationMatch = matchAny(
      keys: destinationKeys,
      rule: rule,
      context: context,
      symbolic: symbolic
    )
    var unknownReason: String?
    var unknownPredicate: SymbolicPredicate?
    for key in rule.keys.sorted()
    where !structuralKeys.contains(key)
      && !destinationAddressKeys.contains(key)
      && key != "rule_set"
      && key != "rule_set_ip_cidr_match_source"
    {
      let result = matchCondition(
        key: key,
        value: rule[key] as Any,
        context: context,
        symbolic: symbolic
      )
      switch result {
      case .no: return .no
      case .unknown(let reason, let predicate):
        unknownReason = unknownReason ?? reason
        unknownPredicate = unknownPredicate ?? predicate
      case .yes: break
      }
    }
    if let ruleSets = rule["rule_set"] {
      let tags = stringValues(ruleSets)
      guard !tags.isEmpty else {
        return .unknown(reason: "the rule-set condition is invalid", predicate: nil)
      }
      if boolValue(rule["rule_set_ip_cidr_match_source"] as Any) == true {
        return .unknown(
          reason: "rule-set source CIDR matching requires source address metadata",
          predicate: nil
        )
      }
      let reason = "remote rule-set membership is unknown locally for \(quotedList(tags))"
      return .unknown(reason: reason, predicate: nil)
    }
    switch destinationMatch {
    case .no: return .no
    case .unknown(let reason, let predicate):
      unknownReason = unknownReason ?? reason
      unknownPredicate = unknownPredicate ?? predicate
    case .yes: break
    }
    return unknownReason.map {
      .unknown(reason: $0, predicate: unknownPredicate)
    } ?? .yes
  }

  private static func matchAny(
    keys: [String],
    rule: [String: Any],
    context: RoutingInspectionContext,
    symbolic: SymbolicContext
  ) -> Match {
    guard !keys.isEmpty else { return .yes }
    var unknownReason: String?
    var unknownPredicate: SymbolicPredicate?
    for key in keys {
      switch matchCondition(
        key: key,
        value: rule[key] as Any,
        context: context,
        symbolic: symbolic
      ) {
      case .yes: return .yes
      case .unknown(let reason, let predicate):
        unknownReason = unknownReason ?? reason
        unknownPredicate = unknownPredicate ?? predicate
      case .no: break
      }
    }
    return unknownReason.map {
      .unknown(reason: $0, predicate: unknownPredicate)
    } ?? .no
  }

  private static func matchCondition(
    key: String,
    value: Any,
    context: RoutingInspectionContext,
    symbolic: SymbolicContext
  ) -> Match {
    switch key {
    case "process_path":
      let paths = Set(stringValues(value))
      guard !paths.isEmpty else {
        return .unknown(reason: "the process path condition is invalid", predicate: nil)
      }
      if let applicationPath = context.applicationPath {
        return paths.contains(applicationPath) ? .yes : .no
      }
      if paths.isSubset(of: context.defaultApplicationPaths) { return .no }
      return .unknown(
        reason: "select an application to evaluate the process path condition",
        predicate: nil
      )
    case "process_name":
      guard let applicationPath = context.applicationPath else {
        return .unknown(
          reason: "select an application to evaluate the process name condition",
          predicate: nil
        )
      }
      return stringValues(value).contains(URL(fileURLWithPath: applicationPath).lastPathComponent)
        ? .yes : .no
    default:
      break
    }
    if runtimeDependentKeys.contains(key) {
      return .unknown(reason: runtimeReason(for: key), predicate: nil)
    }
    switch key {
    case "clash_mode":
      return stringValues(value).contains(context.mode.rawValue) ? .yes : .no
    case "inbound":
      guard let inboundTag = context.inboundTag else {
        return .unknown(reason: "the runtime inbound", predicate: nil)
      }
      return stringValues(value).contains(inboundTag) ? .yes : .no
    case "domain":
      guard let domain = context.domain else { return .no }
      return stringValues(value).contains(domain) ? .yes : .no
    case "domain_suffix":
      guard let domain = context.domain else { return .no }
      return stringValues(value).contains(where: { suffixMatches(domain, suffix: $0) }) ? .yes : .no
    case "domain_keyword":
      guard let domain = context.domain else { return .no }
      return stringValues(value).contains(where: domain.contains) ? .yes : .no
    case "domain_regex":
      guard context.domain != nil else { return .no }
      return .unknown(
        reason: "exact domain regular expression matching belongs to the active routing core",
        predicate: nil
      )
    case "ip_cidr":
      let values = stringValues(value)
      guard !values.isEmpty else { return .no }
      if let ipAddress = context.ipAddress, let address = IPAddress.parse(ipAddress) {
        return values.contains(where: address.matches(cidr:)) ? .yes : .no
      }
      guard context.domain != nil else { return .no }
      if let known = symbolic.knownValue(for: .ipCIDR(values)) {
        return known ? .yes : .no
      }
      return .unknown(
        reason: "the resolved destination IP",
        predicate: .ipCIDR(values)
      )
    case "ip_version":
      let values = integerValues(value)
      guard !values.isEmpty else { return .no }
      guard values.allSatisfy({ $0 == 4 || $0 == 6 }) else {
        return .unknown(
          reason: "condition \"ip_version\" is not supported by Routing Inspector",
          predicate: nil
        )
      }
      if let ipAddress = context.ipAddress, let address = IPAddress.parse(ipAddress) {
        return values.contains(address.version) ? .yes : .no
      }
      guard context.domain != nil else { return .no }
      if let known = symbolic.knownValue(for: .ipVersion(values)) {
        return known ? .yes : .no
      }
      switch symbolic.addressFamily {
      case .ipv4: return values.contains(4) ? .yes : .no
      case .ipv6: return values.contains(6) ? .yes : .no
      case .unknown: break
      }
      return .unknown(reason: "the resolved destination IP", predicate: .ipVersion(values))
    case "ip_is_private":
      guard let expected = boolValue(value) else {
        return .unknown(reason: "an invalid private-IP condition", predicate: nil)
      }
      if let ipAddress = context.ipAddress, let address = IPAddress.parse(ipAddress) {
        return address.isPrivate == expected ? .yes : .no
      }
      guard context.domain != nil else { return .no }
      if let known = symbolic.knownValue(for: .ipIsPrivate(expected)) {
        return known ? .yes : .no
      }
      switch symbolic.privacy {
      case .private: return expected ? .yes : .no
      case .public: return expected ? .no : .yes
      case .unknown: break
      }
      // Domain inspection deliberately explains hostname policy without a DNS probe.
      return .unknown(
        reason: "the resolved destination IP",
        predicate: .ipIsPrivate(expected)
      )
    default:
      return .unknown(
        reason: "condition \"\(key)\" is not supported by Routing Inspector",
        predicate: nil
      )
    }
  }

  private static func runtimeReason(for key: String) -> String {
    switch key {
    case "process_name", "process_path":
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
    if let numbers = value as? [NSNumber] { return numbers.map(\.intValue) }
    return value as? [Int] ?? []
  }

  private static func boolValue(_ value: Any) -> Bool? {
    value as? Bool
  }

  private static func suffixMatches(_ domain: String, suffix: String) -> Bool {
    if suffix.hasPrefix(".") { return domain.hasSuffix(suffix) }
    return domain == suffix || domain.hasSuffix(".\(suffix)")
  }
}

struct ComposedRoutingInspection {
  let route: [String: Any]
  let outboundDecisions: [String: RoutingInspectionResult.Decision]
  let vpnServerNames: [String: String]
  let inboundTag: String

  static func make(
    profile: CoreProfile,
    selectedNode: ProxyNodeID = .auto,
    ipv6Enabled: Bool = false
  ) throws -> ComposedRoutingInspection {
    switch profile {
    case .compatibility(let compatibility):
      var route: [String: Any] = [
        "auto_detect_interface": true,
        "default_domain_resolver": "dns-local",
        "final": "proxy-selector",
      ]
      var rules = ManagedRoutingPlanComposer.routeRules(
        for: compatibility,
        ipv6Enabled: ipv6Enabled
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
      var names = ["auto": SBMText.localized("Auto")]
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
        inboundTag: "tun-in"
      )

    }
  }

  func presentation(for result: RoutingInspectionResult) -> String {
    if !result.alternatives.isEmpty {
      var lines = result.alternatives.map {
        SBMText.format(
          "%@: %@",
          $0.condition,
          decisionSummary($0.decision, outbound: $0.outboundTag)
        )
      }
      if let reason = result.uncertaintyReason,
        !reason.hasPrefix("routing result depends on unresolved IP conditions")
      {
        lines.append(conciseUncertainty(for: reason))
      }
      return lines.joined(separator: "\n")
    }
    guard result.decision != .indeterminate else {
      if result.analysisLimited {
        return SBMText.localized("Routing analysis exceeded the supported complexity limit")
      }
      var lines = [conciseUncertainty(for: result.uncertaintyReason)]
      if let fallback = result.fallback {
        lines.append(
          SBMText.format(
            "Otherwise: %@ · %@",
            decisionSummary(fallback.decision, outbound: fallback.outboundTag),
            fallback.matchedRule
          )
        )
      }
      return lines.joined(separator: "\n")
    }
    let decision = decisionSummary(result.decision, outbound: result.outboundTag)
    let matched = result.matchedRule ?? SBMText.localized("Final route")
    return SBMText.format("%@\nMatched: %@", decision, matched)
  }

  func details(for result: RoutingInspectionResult, contextLabel: String) -> String {
    var lines = [SBMText.format("Traffic from: %@", contextLabel)]
    if result.collapsedPathCount > 1 {
      lines.append(SBMText.localized("Multiple routing paths lead to the same result"))
    }
    if let ruleIndex = result.ruleIndex {
      lines.append(SBMText.format("Rule: %lld", ruleIndex + 1))
    }
    if let outbound = result.outboundTag {
      lines.append(SBMText.format("Outbound: %@", outbound))
    }
    if let reason = result.uncertaintyReason {
      lines.append(SBMText.format("Reason: %@", localizedReason(reason)))
    }
    if let fallback = result.fallback {
      lines.append(
        SBMText.format(
          "If not matched: %@ · %@",
          decisionSummary(fallback.decision, outbound: fallback.outboundTag),
          fallback.matchedRule
        )
      )
    }
    for alternative in result.alternatives {
      lines.append(
        SBMText.format(
          "Possible route: %@ → %@",
          alternative.condition,
          decisionSummary(alternative.decision, outbound: alternative.outboundTag)
        )
      )
    }
    return lines.joined(separator: "\n")
  }

  private func decisionSummary(
    _ decision: RoutingInspectionResult.Decision,
    outbound: String?
  ) -> String {
    guard decision == .vpn, let outbound, let server = vpnServerNames[outbound] else {
      return decision.label
    }
    return SBMText.format("PROXY · %@", server)
  }

  private func conciseUncertainty(for reason: String?) -> String {
    let value = reason?.lowercased() ?? ""
    if value.contains("domain regular expression") {
      return SBMText.localized(
        "Exact domain regular expression matching is owned by the active routing core."
      )
    }
    if value.contains("complexity limit") {
      return SBMText.localized("Routing analysis exceeded the supported complexity limit")
    }
    if value.contains("unresolved ip conditions") {
      return SBMText.localized("Routing result depends on unresolved IP conditions")
    }
    if value.contains("resolved destination ip") {
      return SBMText.localized("Depends on resolved IP")
    }
    if value.contains("remote rule-set membership") {
      return SBMText.localized("Depends on remote rule-set membership")
    }
    if value.contains("process path") || value.contains("application") {
      return SBMText.localized("Depends on application context")
    }
    if value.contains("protocol") || value.contains("network") || value.contains("port") {
      return SBMText.localized("Depends on connection context")
    }
    if value.contains("final outbound") || value.contains("outbound") {
      return SBMText.localized("Depends on outbound classification")
    }
    return SBMText.localized("Additional routing context is required")
  }

  private func localizedReason(_ reason: String) -> String {
    switch reason {
    case "routing analysis exceeded the supported complexity limit":
      return SBMText.localized("Routing analysis exceeded the supported complexity limit")
    case "routing result depends on unresolved IP conditions":
      return SBMText.localized("Routing result depends on unresolved IP conditions")
    case "the composed route has no feasible symbolic path":
      return SBMText.localized("the composed route has no feasible symbolic path")
    case "the resolved destination IP":
      return SBMText.localized("the resolved destination IP")
    case "the runtime inbound":
      return SBMText.localized("the runtime inbound")
    case "the process path condition is invalid":
      return SBMText.localized("the process path condition is invalid")
    case "select an application to evaluate the process path condition":
      return SBMText.localized("select an application to evaluate the process path condition")
    case "select an application to evaluate the process name condition":
      return SBMText.localized("select an application to evaluate the process name condition")
    case "the rule-set condition is invalid":
      return SBMText.localized("the rule-set condition is invalid")
    case "rule-set source CIDR matching requires source address metadata":
      return SBMText.localized(
        "rule-set source CIDR matching requires source address metadata"
      )
    case "exact domain regular expression matching belongs to the active routing core":
      return SBMText.localized(
        "Exact domain regular expression matching is owned by the active routing core."
      )
    case "an invalid private-IP condition":
      return SBMText.localized("an invalid private-IP condition")
    case "the rule needs a running process, but no application was supplied":
      return SBMText.localized(
        "the rule needs a running process, but no application was supplied"
      )
    case "the rule needs sniffed protocol information, which is unavailable before traffic exists":
      return SBMText.localized(
        "the rule needs sniffed protocol information, which is unavailable before traffic exists"
      )
    case "the rule needs network or port information, which was not supplied":
      return SBMText.localized("the rule needs network or port information, which was not supplied")
    case "the rule needs the runtime source address, which was not supplied":
      return SBMText.localized("the rule needs the runtime source address, which was not supplied")
    default:
      break
    }

    let runtimePrefix = "the rule needs runtime "
    let runtimeSuffix = " information, which was not supplied"
    if reason.hasPrefix(runtimePrefix), reason.hasSuffix(runtimeSuffix) {
      let key = String(
        reason.dropFirst(runtimePrefix.count).dropLast(runtimeSuffix.count)
      )
      return SBMText.format(
        "the rule needs runtime %@ information, which was not supplied", key
      )
    }

    let ruleSetPrefix = "remote rule-set membership is unknown locally for "
    if reason.hasPrefix(ruleSetPrefix) {
      let tags = String(reason.dropFirst(ruleSetPrefix.count))
      return SBMText.format("remote rule-set membership is unknown locally for %@", tags)
    }

    let conditionPrefix = "condition \""
    let conditionSuffix = "\" is not supported by Routing Inspector"
    if reason.hasPrefix(conditionPrefix), reason.hasSuffix(conditionSuffix) {
      let key = String(reason.dropFirst(conditionPrefix.count).dropLast(conditionSuffix.count))
      return SBMText.format("condition \"%@\" is not supported by Routing Inspector", key)
    }

    return reason
  }

}

enum RoutingInspectionFailure: LocalizedError {
  case invalidInput
  case unavailable

  var errorDescription: String? {
    switch self {
    case .invalidInput: return SBMText.localized("Enter one domain name or IP address.")
    case .unavailable:
      return SBMText.localized("The selected profile has no inspectable composed route.")
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
    let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remainingBits))
    return bytes[completeBytes] & mask == network.bytes[completeBytes] & mask
  }
}
