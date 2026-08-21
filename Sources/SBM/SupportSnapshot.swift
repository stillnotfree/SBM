import Foundation
import SBMShared

/// A bounded, local-only description of state already observed by the app.
/// It deliberately does not perform health checks, export configuration, or
/// retain user-visible profile and node identifiers.
struct SupportSnapshot: Codable, Sendable, Equatable {
  static let schemaVersion = 3
  static let maximumSerializedBytes = 16 * 1024
  static let maximumTextBytes = 8 * 1024
  static let maximumNodes = 128
  static let maximumSources = 128
  static let maximumRecentErrorBytes = 4 * 1024

  struct App: Codable, Sendable, Equatable {
    let version: String
    let build: String
    let macOS: String

    private enum CodingKeys: String, CodingKey {
      case version, build
      case macOS = "macos"
    }
  }

  struct Helper: Codable, Sendable, Equatable {
    let reachable: Bool
    let version: String?
    let revision: Int?
    let state: HelperState
  }

  enum HelperState: String, Codable, Sendable, Equatable {
    case reachable
    case setupInProgress = "setup_in_progress"
    case unreachable
    case notEnabled = "not_enabled"
  }

  struct Core: Codable, Sendable, Equatable {
    let state: ObservedCoreState
    let version: String?
  }

  enum ProfileKind: String, Codable, Sendable, Equatable {
    case compatibilitySubscription = "compatibility_subscription"
    case nativeJSON = "native_json"
    case none
  }

  struct Profile: Codable, Sendable, Equatable {
    let kind: ProfileKind
    let updatedAt: String?
    let libraryAvailable: Bool
    let sourceCount: Int
    let sourceCountCapped: Bool

    private enum CodingKeys: String, CodingKey {
      case kind
      case updatedAt = "updated_at"
      case libraryAvailable = "library_available"
      case sourceCount = "source_count"
      case sourceCountCapped = "source_count_capped"
    }
  }

  struct LocalSOCKS: Codable, Sendable, Equatable {
    let enabled: Bool
    let port: UInt16?

    private enum CodingKeys: String, CodingKey { case enabled, port }
  }

  struct NodeObservation: Sendable, Equatable {
    let kind: ProxyNodeKind
    let delayMilliseconds: Int?
  }

  struct DelaySummary: Codable, Sendable, Equatable {
    let measuredCount: Int
    let unmeasuredCount: Int
    let minimumMilliseconds: Int?
    let maximumMilliseconds: Int?

    private enum CodingKeys: String, CodingKey {
      case measuredCount = "measured_count"
      case unmeasuredCount = "unmeasured_count"
      case minimumMilliseconds = "minimum_milliseconds"
      case maximumMilliseconds = "maximum_milliseconds"
    }
  }

  struct ProtocolSummary: Codable, Sendable, Equatable {
    let kind: ProxyNodeKind
    let nodeCount: Int
    let delays: DelaySummary

    private enum CodingKeys: String, CodingKey {
      case kind
      case nodeCount = "node_count"
      case delays
    }
  }

  let schemaVersion: Int
  let capturedAt: String
  let activeProbesRun: Bool
  let app: App
  let helper: Helper
  let core: Core
  let routingMode: RoutingMode
  let profile: Profile
  let localSOCKS: LocalSOCKS
  let selectedProtocolKind: ProxyNodeKind?
  let protocolSummaries: [ProtocolSummary]
  let nodeObservationsCapped: Bool
  let lastError: String?
  let recentErrors: [String]
  let recentErrorCount: Int
  let recentErrorsTruncated: Bool

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case capturedAt = "captured_at"
    case activeProbesRun = "active_probes_run"
    case app, helper, core
    case routingMode = "routing_mode"
    case profile
    case localSOCKS = "local_socks"
    case selectedProtocolKind = "selected_protocol_kind"
    case protocolSummaries = "protocol_summaries"
    case nodeObservationsCapped = "node_observations_capped"
    case lastError = "last_error"
    case recentErrors = "recent_errors"
    case recentErrorCount = "recent_error_count"
    case recentErrorsTruncated = "recent_errors_truncated"
  }

  init(
    capturedAt: Date,
    appVersion: String,
    appBuild: String,
    macOSVersion: String,
    helperReachable: Bool,
    helperVersion: String?,
    helperRevision: Int?,
    helperState: HelperState,
    coreState: ObservedCoreState,
    coreVersion: String?,
    routingMode: RoutingMode,
    profileKind: ProfileKind,
    profileUpdatedAt: Date?,
    profileLibraryAvailable: Bool,
    sourceCount: Int,
    localSOCKSEnabled: Bool,
    localSOCKSPort: UInt16,
    selectedProtocolKind: ProxyNodeKind?,
    nodes: [NodeObservation],
    lastError: String?,
    recentErrors: [String] = [],
    redactionSecrets: [String]
  ) {
    schemaVersion = Self.schemaVersion
    self.capturedAt = Self.timestamp(capturedAt)
    activeProbesRun = false
    app = App(
      version: Self.clean(appVersion, limit: 128, secrets: redactionSecrets),
      build: Self.clean(appBuild, limit: 128, secrets: redactionSecrets),
      macOS: Self.clean(macOSVersion, limit: 256, secrets: redactionSecrets)
    )
    helper = Helper(
      reachable: helperReachable,
      version: Self.cleanOptional(helperVersion, limit: 128, secrets: redactionSecrets),
      revision: helperRevision,
      state: helperState
    )
    core = Core(
      state: coreState,
      version: Self.cleanOptional(coreVersion, limit: 128, secrets: redactionSecrets)
    )
    self.routingMode = routingMode
    profile = Profile(
      kind: profileKind,
      updatedAt: profileUpdatedAt.map(Self.timestamp),
      libraryAvailable: profileLibraryAvailable,
      sourceCount: min(max(sourceCount, 0), Self.maximumSources),
      sourceCountCapped: sourceCount > Self.maximumSources
    )
    localSOCKS = LocalSOCKS(
      enabled: localSOCKSEnabled, port: localSOCKSEnabled ? localSOCKSPort : nil)
    self.selectedProtocolKind = selectedProtocolKind
    let boundedNodes = Array(nodes.prefix(Self.maximumNodes))
    nodeObservationsCapped = nodes.count > Self.maximumNodes
    protocolSummaries = Self.makeProtocolSummaries(from: boundedNodes)
    self.lastError = Self.cleanError(lastError, secrets: redactionSecrets)
    let cleanedRecentErrors = recentErrors.prefix(50).compactMap {
      Self.cleanError($0, secrets: redactionSecrets)
    }
    recentErrorCount = cleanedRecentErrors.count
    var retainedNewestFirst: [String] = []
    var retainedBytes = 0
    for error in cleanedRecentErrors.reversed() {
      let cost = error.utf8.count + 4
      guard retainedBytes + cost <= Self.maximumRecentErrorBytes else { break }
      retainedNewestFirst.append(error)
      retainedBytes += cost
    }
    self.recentErrors = retainedNewestFirst.reversed()
    recentErrorsTruncated = self.recentErrors.count < recentErrorCount
  }

  var statusText: String {
    var lines = [
      "SBM support snapshot (observations only)",
      "Schema: \(schemaVersion)",
      "Captured: \(capturedAt)",
      "Active DNS/network probes run: no",
      "App: \(app.version) (\(app.build))",
      "macOS: \(app.macOS)",
      "Helper: \(helper.state.rawValue)",
      "Helper version: \(helper.version ?? "unknown"), revision: \(helper.revision.map(String.init) ?? "unknown")",
      "Core: \(core.state.rawValue), \(core.version ?? "unknown")",
      "Routing mode: \(routingMode.rawValue)",
      "Profile: \(profile.kind.rawValue), updated \(profile.updatedAt ?? "never")",
      "Profile library: \(profile.libraryAvailable ? "available" : "unavailable"), sources: \(profile.sourceCount)\(profile.sourceCountCapped ? "+" : "")",
      "Local SOCKS5: \(localSOCKS.enabled ? "enabled on 127.0.0.1:\(localSOCKS.port ?? 0)" : "disabled")",
      "Selected protocol: \(selectedProtocolKind?.rawValue ?? "none")",
    ]
    for summary in protocolSummaries {
      let range: String
      if let minimum = summary.delays.minimumMilliseconds,
        let maximum = summary.delays.maximumMilliseconds
      {
        range = minimum == maximum ? "\(minimum) ms" : "\(minimum)-\(maximum) ms"
      } else {
        range = "not measured"
      }
      lines.append(
        "\(summary.kind.rawValue): \(summary.nodeCount) nodes, \(summary.delays.measuredCount) measured, \(summary.delays.unmeasuredCount) unmeasured, \(range)"
      )
    }
    if nodeObservationsCapped { lines.append("Node observations: capped") }
    lines.append(lastError.map { "Last error: \($0)" } ?? "No current error.")
    let output = lines.joined(separator: "\n")
    guard output.utf8.count <= Self.maximumTextBytes else {
      return
        "SBM support snapshot (observations only)\nSnapshot text omitted: too large\nActive DNS/network probes run: no"
    }
    return output
  }

  var text: String {
    var lines = [statusText]
    let suffix =
      recentErrorsTruncated
      ? " (\(recentErrors.count) of \(recentErrorCount) exported; truncated)" : ""
    lines.append("Recent errors: \(recentErrorCount)\(suffix)")
    lines.append(contentsOf: recentErrors.map { "- \($0)" })
    let output = lines.joined(separator: "\n")
    guard output.utf8.count <= Self.maximumTextBytes else {
      return statusText + "\nRecent errors: truncated to preserve the current status"
    }
    return output
  }

  func jsonText() -> String {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self), data.count <= Self.maximumSerializedBytes,
      let text = String(data: data, encoding: .utf8)
    else {
      return
        #"{"active_probes_run":false,"error":"snapshot omitted: too large","schema_version":3}"#
    }
    return text
  }

  private static func makeProtocolSummaries(from nodes: [NodeObservation]) -> [ProtocolSummary] {
    let kinds = ProxyNodeKind.allCasesExcludingAutomatic
    return kinds.compactMap { kind in
      let matching = nodes.filter { $0.kind == kind }
      guard !matching.isEmpty else { return nil }
      let measured = matching.compactMap(\.delayMilliseconds).map { min(max($0, 0), 3_600_000) }
      return ProtocolSummary(
        kind: kind,
        nodeCount: matching.count,
        delays: DelaySummary(
          measuredCount: measured.count,
          unmeasuredCount: matching.count - measured.count,
          minimumMilliseconds: measured.min(),
          maximumMilliseconds: measured.max()
        )
      )
    }
  }

  private static func cleanOptional(_ value: String?, limit: Int, secrets: [String]) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return clean(value, limit: limit, secrets: secrets)
  }

  private static func cleanError(_ value: String?, secrets: [String]) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return SafeDiagnosticError.sanitize(value, secrets: secrets)
  }

  private static func clean(_ value: String, limit: Int, secrets: [String]) -> String {
    let redacted = SecretRedactor.redact(value, secrets: secrets)
    let normalized = redacted.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    guard normalized.count > limit else { return normalized }
    return String(normalized.prefix(limit)) + "…"
  }

  private static func timestamp(_ value: Date) -> String {
    value.formatted(.iso8601)
  }
}

extension ProxyNodeKind {
  fileprivate static let allCasesExcludingAutomatic: [ProxyNodeKind] = [
    .vless, .hysteria2, .shadowsocks, .native, .unknown,
  ]
}
