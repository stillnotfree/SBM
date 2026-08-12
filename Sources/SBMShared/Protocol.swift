import CryptoKit
import Foundation

public enum HelperConstants {
  public static let protocolVersion = 9
  public static let helperVersion = "1.1.3"
  public static let helperRevision = 42
  public static let socketPath = "/var/run/com.stillnotfree.sbm.helper.sock"
  public static let daemonPlistName = "com.stillnotfree.sbm.helper.plist"
}

public enum HelperAction: String, Codable, Sendable {
  case status
  case start
  case stop
  case setMode
  case setNode
  case setLatencyTarget
  case testLatency
  case validateProfile
  case matchRuleSets
  case shutdown
}

public enum RoutingMode: String, Codable, CaseIterable, Hashable, Sendable {
  case rule = "Rule"
  case global = "Global"
  case direct = "Direct"
}

public struct ProxyNodeID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    rawValue = try container.decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let auto = ProxyNodeID(rawValue: "auto")
}

public enum ProxyNodeKind: String, Codable, Equatable, Hashable, Sendable {
  case automatic
  case vless
  case hysteria2
  case shadowsocks
  case native
  case unknown
}

public struct ProxyNodeDescriptor: Codable, Equatable, Hashable, Sendable {
  public let id: ProxyNodeID
  public let name: String
  public let kind: ProxyNodeKind

  public init(id: ProxyNodeID, name: String, kind: ProxyNodeKind = .native) {
    self.id = id
    self.name = name
    self.kind = kind
  }

  private enum CodingKeys: String, CodingKey { case id, name, kind }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(ProxyNodeID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    kind = try container.decodeIfPresent(ProxyNodeKind.self, forKey: .kind) ?? .unknown
  }
}

public struct VLESSProfile: Codable, Equatable, Sendable {
  public let server: String
  public let port: UInt16
  public let uuid: String
  public let serverName: String
  public let fingerprint: String
  public let publicKey: String
  public let shortID: String
  public let displayName: String

  public init(
    server: String,
    port: UInt16,
    uuid: String,
    serverName: String,
    fingerprint: String,
    publicKey: String,
    shortID: String,
    displayName: String
  ) {
    self.server = server
    self.port = port
    self.uuid = uuid
    self.serverName = serverName
    self.fingerprint = fingerprint
    self.publicKey = publicKey
    self.shortID = shortID
    self.displayName = displayName
  }
}

public struct Hysteria2Profile: Codable, Equatable, Sendable {
  public let server: String
  public let port: UInt16
  public let password: String
  public let serverName: String
  public let obfsPassword: String?
  public let displayName: String

  public init(
    server: String,
    port: UInt16,
    password: String,
    serverName: String,
    obfsPassword: String? = nil,
    displayName: String
  ) {
    self.server = server
    self.port = port
    self.password = password
    self.serverName = serverName
    self.obfsPassword = obfsPassword
    self.displayName = displayName
  }
}

public struct ShadowsocksProfile: Codable, Equatable, Sendable {
  public let server: String
  public let port: UInt16
  public let method: String
  public let password: String
  public let displayName: String

  public init(server: String, port: UInt16, method: String, password: String, displayName: String) {
    self.server = server
    self.port = port
    self.method = method
    self.password = password
    self.displayName = displayName
  }
}

public enum ManagedOutbound: Codable, Equatable, Sendable {
  case vless(VLESSProfile)
  case hysteria2(Hysteria2Profile)
  case shadowsocks(ShadowsocksProfile)

  public var displayName: String {
    switch self {
    case .vless(let value): value.displayName
    case .hysteria2(let value): value.displayName
    case .shadowsocks(let value): value.displayName
    }
  }

  public var kind: ProxyNodeKind {
    switch self {
    case .vless: .vless
    case .hysteria2: .hysteria2
    case .shadowsocks: .shadowsocks
    }
  }

  /// Stable reconciliation identity.  A subscription may rename a node without
  /// making it a different connection; credentials and endpoint remain part of it.
  public var semanticIdentity: String {
    switch self {
    case .vless(let value):
      return canonicalIdentity([
        "vless", canonicalHost(value.server), String(value.port), value.uuid.lowercased(),
        canonicalHost(value.serverName), value.fingerprint, value.publicKey,
        value.shortID.lowercased(),
      ])
    case .hysteria2(let value):
      return canonicalIdentity([
        "hysteria2", canonicalHost(value.server), String(value.port), value.password,
        canonicalHost(value.serverName), value.obfsPassword ?? "",
      ])
    case .shadowsocks(let value):
      return canonicalIdentity([
        "shadowsocks", canonicalHost(value.server), String(value.port), value.method.lowercased(),
        value.password,
      ])
    }
  }

  public var stableNodeID: ProxyNodeID {
    let input = Data("sbm-managed-node-id-v1\0\(semanticIdentity)".utf8)
    let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    return ProxyNodeID(rawValue: "node-v1-\(digest)")
  }

  private func canonicalIdentity(_ parts: [String]) -> String {
    parts.map { "\($0.utf8.count):\($0)" }.joined()
  }

  private func canonicalHost(_ value: String) -> String {
    value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
  }

  private enum CodingKeys: String, CodingKey { case kind, vless, hysteria2, shadowsocks }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .vless(let value):
      try container.encode(ProxyNodeKind.vless, forKey: .kind)
      try container.encode(value, forKey: .vless)
    case .hysteria2(let value):
      try container.encode(ProxyNodeKind.hysteria2, forKey: .kind)
      try container.encode(value, forKey: .hysteria2)
    case .shadowsocks(let value):
      try container.encode(ProxyNodeKind.shadowsocks, forKey: .kind)
      try container.encode(value, forKey: .shadowsocks)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(ProxyNodeKind.self, forKey: .kind) {
    case .vless: self = .vless(try container.decode(VLESSProfile.self, forKey: .vless))
    case .hysteria2:
      self = .hysteria2(try container.decode(Hysteria2Profile.self, forKey: .hysteria2))
    case .shadowsocks:
      self = .shadowsocks(try container.decode(ShadowsocksProfile.self, forKey: .shadowsocks))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container, debugDescription: "Unsupported managed outbound kind")
    }
  }

}

public struct ManagedConnection: Codable, Equatable, Sendable, Identifiable {
  public let id: ProxyNodeID
  public let displayName: String
  public let outbound: ManagedOutbound

  public init(
    id: ProxyNodeID? = nil,
    displayName: String? = nil, outbound: ManagedOutbound
  ) {
    self.id = id ?? outbound.stableNodeID
    self.displayName = displayName ?? outbound.displayName
    self.outbound = outbound
  }

  public var kind: ProxyNodeKind { outbound.kind }
  public var semanticIdentity: String { outbound.semanticIdentity }
}

public struct RoutingPolicy: Codable, Equatable, Sendable {
  public let configuration: Data

  public init(configuration: Data) {
    self.configuration = configuration
  }
}

public struct ProxyNodeGroup: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let nodes: [ProxyNodeID]

  public init(id: String, name: String, nodes: [ProxyNodeID]) {
    self.id = id
    self.name = name
    self.nodes = nodes
  }
}

public enum ApplicationRoutingTarget: Codable, Equatable, Hashable, Sendable {
  case direct
  case selectedProxy
  case reject
  case node(ProxyNodeID)
}

public struct ApplicationRoutingRule: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let displayName: String
  public let bundlePath: String
  public let executablePath: String
  public let target: ApplicationRoutingTarget

  public init(
    id: UUID = UUID(),
    displayName: String,
    bundlePath: String,
    executablePath: String,
    target: ApplicationRoutingTarget
  ) {
    self.id = id
    self.displayName = displayName
    self.bundlePath = bundlePath
    self.executablePath = executablePath
    self.target = target
  }
}

public struct VPNProfile: Codable, Equatable, Sendable {
  public let connections: [ManagedConnection]
  public let routingPolicy: RoutingPolicy?
  public let nodeGroups: [ProxyNodeGroup]?
  public let applicationRoutingRules: [ApplicationRoutingRule]
  /// Decoding marker only. The user-library schema coordinates migration of
  /// old parallel arrays; a current schema must never silently contain them.
  public let usesLegacyConnectionEncoding: Bool

  /// Compatibility views are source-compatible with the v1.1.11 API. New code
  /// must operate on `connections`, which keeps the user-visible stable ID.
  public var vless: [VLESSProfile] {
    connections.compactMap { if case .vless(let value) = $0.outbound { value } else { nil } }
  }
  public var hysteria2: [Hysteria2Profile] {
    connections.compactMap { if case .hysteria2(let value) = $0.outbound { value } else { nil } }
  }
  public var shadowsocks: [ShadowsocksProfile] {
    connections.compactMap { if case .shadowsocks(let value) = $0.outbound { value } else { nil } }
  }

  public init(
    connections: [ManagedConnection],
    routingPolicy: RoutingPolicy? = nil,
    nodeGroups: [ProxyNodeGroup] = [],
    applicationRoutingRules: [ApplicationRoutingRule] = []
  ) {
    self.connections = connections
    self.routingPolicy = routingPolicy
    self.nodeGroups = nodeGroups
    self.applicationRoutingRules = applicationRoutingRules
    self.usesLegacyConnectionEncoding = false
  }

  public init(
    vless: [VLESSProfile] = [],
    hysteria2: [Hysteria2Profile] = [],
    shadowsocks: [ShadowsocksProfile] = [],
    routingPolicy: RoutingPolicy? = nil,
    nodeGroups: [ProxyNodeGroup] = [],
    applicationRoutingRules: [ApplicationRoutingRule] = []
  ) {
    self.connections =
      vless.enumerated().map {
        ManagedConnection(
          id: ProxyNodeID(rawValue: "vless-\($0.offset + 1)"), outbound: .vless($0.element))
      }
      + hysteria2.enumerated().map {
        ManagedConnection(
          id: ProxyNodeID(rawValue: "hysteria2-\($0.offset + 1)"), outbound: .hysteria2($0.element))
      }
      + shadowsocks.enumerated().map {
        ManagedConnection(
          id: ProxyNodeID(rawValue: "shadowsocks-\($0.offset + 1)"),
          outbound: .shadowsocks($0.element))
      }
    self.routingPolicy = routingPolicy
    self.nodeGroups = nodeGroups
    self.applicationRoutingRules = applicationRoutingRules
    self.usesLegacyConnectionEncoding = false
  }

  private enum CodingKeys: String, CodingKey {
    case connections, vless, hysteria2, routingPolicy, nodeGroups, applicationRoutingRules
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    routingPolicy = try container.decodeIfPresent(RoutingPolicy.self, forKey: .routingPolicy)
    nodeGroups = try container.decodeIfPresent([ProxyNodeGroup].self, forKey: .nodeGroups)
    applicationRoutingRules =
      try container.decodeIfPresent(
        [ApplicationRoutingRule].self,
        forKey: .applicationRoutingRules
      ) ?? []
    if let connections = try container.decodeIfPresent(
      [ManagedConnection].self, forKey: .connections)
    {
      self.connections = connections
      usesLegacyConnectionEncoding = false
    } else {
      let vless = try container.decodeIfPresent([VLESSProfile].self, forKey: .vless) ?? []
      let hysteria2 =
        try container.decodeIfPresent([Hysteria2Profile].self, forKey: .hysteria2) ?? []
      self.connections =
        vless.enumerated().map {
          ManagedConnection(
            id: ProxyNodeID(rawValue: "vless-\($0.offset + 1)"), outbound: .vless($0.element))
        }
        + hysteria2.enumerated().map {
          ManagedConnection(
            id: ProxyNodeID(rawValue: "hysteria2-\($0.offset + 1)"),
            outbound: .hysteria2($0.element))
        }
      usesLegacyConnectionEncoding = true
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(connections, forKey: .connections)
    try container.encodeIfPresent(routingPolicy, forKey: .routingPolicy)
    try container.encodeIfPresent(nodeGroups, forKey: .nodeGroups)
    try container.encode(applicationRoutingRules, forKey: .applicationRoutingRules)
  }
}

public struct NativeProfile: Codable, Equatable, Sendable {
  public let configuration: Data
  public let selectorTag: String
  public let nodes: [ProxyNodeDescriptor]
  public let applicationRoutingRules: [ApplicationRoutingRule]

  public init(
    configuration: Data,
    selectorTag: String,
    nodes: [ProxyNodeDescriptor],
    applicationRoutingRules: [ApplicationRoutingRule] = []
  ) {
    self.configuration = configuration
    self.selectorTag = selectorTag
    self.nodes = nodes
    self.applicationRoutingRules = applicationRoutingRules
  }

  private enum CodingKeys: String, CodingKey {
    case configuration, selectorTag, nodes, applicationRoutingRules
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    configuration = try container.decode(Data.self, forKey: .configuration)
    selectorTag = try container.decode(String.self, forKey: .selectorTag)
    nodes = try container.decode([ProxyNodeDescriptor].self, forKey: .nodes)
    applicationRoutingRules =
      try container.decodeIfPresent(
        [ApplicationRoutingRule].self,
        forKey: .applicationRoutingRules
      ) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(configuration, forKey: .configuration)
    try container.encode(selectorTag, forKey: .selectorTag)
    try container.encode(nodes, forKey: .nodes)
    try container.encode(applicationRoutingRules, forKey: .applicationRoutingRules)
  }
}

public enum CoreProfile: Codable, Equatable, Sendable {
  case compatibility(VPNProfile)
  case native(NativeProfile)

  public var nodes: [ProxyNodeDescriptor] {
    switch self {
    case .compatibility(let profile):
      var nodes = [ProxyNodeDescriptor(id: .auto, name: "Auto", kind: .automatic)]
      for connection in profile.connections {
        nodes.append(
          ProxyNodeDescriptor(
            id: connection.id,
            name: connection.displayName,
            kind: connection.kind
          )
        )
      }
      return nodes
    case .native(let profile):
      return profile.nodes
    }
  }

  public var applicationRoutingRules: [ApplicationRoutingRule] {
    switch self {
    case .compatibility(let profile): profile.applicationRoutingRules
    case .native(let profile): profile.applicationRoutingRules
    }
  }
}

public struct NodeDelay: Codable, Sendable {
  public let node: ProxyNodeID
  public let milliseconds: Int?

  public init(node: ProxyNodeID, milliseconds: Int?) {
    self.node = node
    self.milliseconds = milliseconds
  }
}

public struct RuleSetMatch: Codable, Equatable, Sendable {
  public let tag: String
  public let matches: Bool

  public init(tag: String, matches: Bool) {
    self.tag = tag
    self.matches = matches
  }
}

public struct HelperRequest: Codable, Sendable {
  public let protocolVersion: Int
  public let action: HelperAction
  public let profile: CoreProfile?
  public let profileID: UUID?
  public let mode: RoutingMode?
  public let node: ProxyNodeID?
  public let localSOCKSEnabled: Bool?
  public let localSOCKSPort: UInt16?
  public let latencyTestURL: String?
  public let ruleSetTags: [String]?
  public let routingDestination: String?

  public init(
    action: HelperAction,
    profile: CoreProfile? = nil,
    profileID: UUID? = nil,
    mode: RoutingMode? = nil,
    node: ProxyNodeID? = nil,
    localSOCKSEnabled: Bool? = nil,
    localSOCKSPort: UInt16? = nil,
    latencyTestURL: String? = nil,
    ruleSetTags: [String]? = nil,
    routingDestination: String? = nil
  ) {
    self.protocolVersion = HelperConstants.protocolVersion
    self.action = action
    self.profile = profile
    self.profileID = profileID
    self.mode = mode
    self.node = node
    self.localSOCKSEnabled = localSOCKSEnabled
    self.localSOCKSPort = localSOCKSPort
    self.latencyTestURL = latencyTestURL
    self.ruleSetTags = ruleSetTags
    self.routingDestination = routingDestination
  }
}

public struct HelperResponse: Codable, Sendable {
  public let protocolVersion: Int
  public let success: Bool
  public let helperVersion: String
  public let helperRevision: Int
  public let coreRunning: Bool
  public let coreVersion: String?
  public let mode: RoutingMode
  public let selectedNode: ProxyNodeID
  public let activeProfileID: UUID?
  public let nodes: [ProxyNodeDescriptor]
  public let delays: [NodeDelay]
  /// `true` requires an explicit user connection before recovery can retry.
  public let automaticRecoveryExhausted: Bool
  public let ruleSetMatches: [RuleSetMatch]
  public let message: String

  public init(
    success: Bool,
    coreRunning: Bool,
    coreVersion: String? = nil,
    mode: RoutingMode = .rule,
    selectedNode: ProxyNodeID = .auto,
    activeProfileID: UUID? = nil,
    nodes: [ProxyNodeDescriptor] = [],
    delays: [NodeDelay] = [],
    automaticRecoveryExhausted: Bool = false,
    ruleSetMatches: [RuleSetMatch] = [],
    message: String
  ) {
    self.protocolVersion = HelperConstants.protocolVersion
    self.success = success
    self.helperVersion = HelperConstants.helperVersion
    self.helperRevision = HelperConstants.helperRevision
    self.coreRunning = coreRunning
    self.coreVersion = coreVersion
    self.mode = mode
    self.selectedNode = selectedNode
    self.activeProfileID = activeProfileID
    self.nodes = nodes
    self.delays = delays
    self.automaticRecoveryExhausted = automaticRecoveryExhausted
    self.ruleSetMatches = ruleSetMatches
    self.message = message
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case success
    case helperVersion
    case helperRevision
    case coreRunning
    case coreVersion
    case mode
    case selectedNode
    case activeProfileID
    case nodes
    case delays
    case automaticRecoveryExhausted
    case ruleSetMatches
    case message
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    success = try container.decode(Bool.self, forKey: .success)
    helperVersion = try container.decode(String.self, forKey: .helperVersion)
    helperRevision = try container.decode(Int.self, forKey: .helperRevision)
    coreRunning = try container.decode(Bool.self, forKey: .coreRunning)
    coreVersion = try container.decodeIfPresent(String.self, forKey: .coreVersion)
    mode = try container.decode(RoutingMode.self, forKey: .mode)
    selectedNode = try container.decode(ProxyNodeID.self, forKey: .selectedNode)
    activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
    nodes = try container.decode([ProxyNodeDescriptor].self, forKey: .nodes)
    delays = try container.decode([NodeDelay].self, forKey: .delays)
    automaticRecoveryExhausted =
      try container.decodeIfPresent(Bool.self, forKey: .automaticRecoveryExhausted) ?? false
    ruleSetMatches =
      try container.decodeIfPresent([RuleSetMatch].self, forKey: .ruleSetMatches) ?? []
    message = try container.decode(String.self, forKey: .message)
  }
}
