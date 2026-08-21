import CryptoKit
import Foundation

public enum HelperConstants {
  public static let protocolVersion = 10
  public static let helperVersion = "1.1.3"
  public static let helperRevision = 50
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

public enum HelperRuntimeOutcome: String, Codable, Equatable, Sendable {
  case applied
  case reconnectRequired

  public var userMessage: String? {
    switch self {
    case .applied:
      nil
    case .reconnectRequired:
      "Changes ready to apply"
    }
  }
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

  public init(
    server: String,
    port: UInt16,
    uuid: String,
    serverName: String,
    fingerprint: String,
    publicKey: String,
    shortID: String
  ) {
    self.server = server
    self.port = port
    self.uuid = uuid
    self.serverName = serverName
    self.fingerprint = fingerprint
    self.publicKey = publicKey
    self.shortID = shortID
  }
}

public struct Hysteria2Profile: Codable, Equatable, Sendable {
  public let server: String
  public let port: UInt16
  public let password: String
  public let serverName: String
  public let obfsPassword: String?

  public init(
    server: String,
    port: UInt16,
    password: String,
    serverName: String,
    obfsPassword: String? = nil
  ) {
    self.server = server
    self.port = port
    self.password = password
    self.serverName = serverName
    self.obfsPassword = obfsPassword
  }
}

public struct ShadowsocksProfile: Codable, Equatable, Sendable {
  public let server: String
  public let port: UInt16
  public let method: String
  public let password: String

  public init(server: String, port: UInt16, method: String, password: String) {
    self.server = server
    self.port = port
    self.method = method
    self.password = password
  }
}

/// Decoder-only representation used at the boundary for profile libraries
/// written before managed connections became the sole current representation.
/// It is intentionally not used by the runtime model or current encoder.
public enum LegacyCoreProfileDTO: Decodable, Sendable {
  case compatibility(LegacyVPNProfileDTO)
  case native(NativeProfile)

  private struct Wrapper<Value: Decodable>: Decodable {
    let value: Value

    private enum CodingKeys: String, CodingKey { case value = "_0" }
  }

  private enum CodingKeys: String, CodingKey { case compatibility, native }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let wrapped = try container.decodeIfPresent(
      Wrapper<LegacyVPNProfileDTO>.self,
      forKey: .compatibility
    ) {
      self = .compatibility(wrapped.value)
    } else if let native = try container.decodeIfPresent(NativeProfile.self, forKey: .native) {
      self = .native(native)
    } else {
      throw DecodingError.dataCorruptedError(
        forKey: .compatibility,
        in: container,
        debugDescription: "Legacy profile payload has no supported kind."
      )
    }
  }

  public func currentProfile() -> CoreProfile {
    switch self {
    case .compatibility(let value): .compatibility(value.currentProfile())
    case .native(let value): .native(value)
    }
  }
}

public struct LegacyVPNProfileDTO: Decodable, Sendable {
  public let vless: [LegacyVLESSProfileDTO]
  public let hysteria2: [LegacyHysteria2ProfileDTO]
  public let shadowsocks: [LegacyShadowsocksProfileDTO]
  public let routingPolicy: RoutingPolicy?
  public let nodeGroups: [ProxyNodeGroup]?
  public let applicationRoutingRules: [ApplicationRoutingRule]
  public let websiteRoutingRules: [WebsiteRoutingRule]

  private enum CodingKeys: String, CodingKey {
    case vless, hysteria2, shadowsocks, routingPolicy, nodeGroups, applicationRoutingRules,
      websiteRoutingRules
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    vless = try container.decodeIfPresent([LegacyVLESSProfileDTO].self, forKey: .vless) ?? []
    hysteria2 =
      try container.decodeIfPresent([LegacyHysteria2ProfileDTO].self, forKey: .hysteria2) ?? []
    shadowsocks =
      try container.decodeIfPresent([LegacyShadowsocksProfileDTO].self, forKey: .shadowsocks)
      ?? []
    routingPolicy = try container.decodeIfPresent(RoutingPolicy.self, forKey: .routingPolicy)
    nodeGroups = try container.decodeIfPresent([ProxyNodeGroup].self, forKey: .nodeGroups)
    applicationRoutingRules =
      try container.decodeIfPresent(
        [ApplicationRoutingRule].self,
        forKey: .applicationRoutingRules
      ) ?? []
    websiteRoutingRules =
      try container.decodeIfPresent(
        [WebsiteRoutingRule].self,
        forKey: .websiteRoutingRules
      ) ?? []
  }

  public func currentProfile() -> VPNProfile {
    let vless = vless.enumerated().map { entry in
      ManagedConnection(
        id: ProxyNodeID(rawValue: "vless-\(entry.offset + 1)"),
        displayName: entry.element.displayName,
        outbound: .vless(entry.element.currentProfile())
      )
    }
    let hysteria2 = hysteria2.enumerated().map { entry in
      ManagedConnection(
        id: ProxyNodeID(rawValue: "hysteria2-\(entry.offset + 1)"),
        displayName: entry.element.displayName,
        outbound: .hysteria2(entry.element.currentProfile())
      )
    }
    let shadowsocks = shadowsocks.enumerated().map { entry in
      ManagedConnection(
        id: ProxyNodeID(rawValue: "shadowsocks-\(entry.offset + 1)"),
        displayName: entry.element.displayName,
        outbound: .shadowsocks(entry.element.currentProfile())
      )
    }
    return VPNProfile(
      connections: vless + hysteria2 + shadowsocks,
      routingPolicy: routingPolicy,
      nodeGroups: nodeGroups ?? [],
      applicationRoutingRules: applicationRoutingRules,
      websiteRoutingRules: websiteRoutingRules
    )
  }
}

public struct LegacyVLESSProfileDTO: Decodable, Sendable {
  public let server: String
  public let port: UInt16
  public let uuid: String
  public let serverName: String
  public let fingerprint: String
  public let publicKey: String
  public let shortID: String
  public let displayName: String

  public func currentProfile() -> VLESSProfile {
    VLESSProfile(
      server: server,
      port: port,
      uuid: uuid,
      serverName: serverName,
      fingerprint: fingerprint,
      publicKey: publicKey,
      shortID: shortID
    )
  }
}

public struct LegacyHysteria2ProfileDTO: Decodable, Sendable {
  public let server: String
  public let port: UInt16
  public let password: String
  public let serverName: String
  public let obfsPassword: String?
  public let displayName: String

  public func currentProfile() -> Hysteria2Profile {
    Hysteria2Profile(
      server: server,
      port: port,
      password: password,
      serverName: serverName,
      obfsPassword: obfsPassword
    )
  }
}

public struct LegacyShadowsocksProfileDTO: Decodable, Sendable {
  public let server: String
  public let port: UInt16
  public let method: String
  public let password: String
  public let displayName: String

  public func currentProfile() -> ShadowsocksProfile {
    ShadowsocksProfile(
      server: server,
      port: port,
      method: method,
      password: password
    )
  }
}

public enum ManagedOutbound: Codable, Equatable, Sendable {
  case vless(VLESSProfile)
  case hysteria2(Hysteria2Profile)
  case shadowsocks(ShadowsocksProfile)

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
    displayName: String,
    outbound: ManagedOutbound
  ) {
    self.id = id ?? outbound.stableNodeID
    self.displayName = displayName
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

public enum WebsiteRoutingTarget: String, Codable, Equatable, Hashable, Sendable {
  case selectedProxy
  case direct
  case reject
}

public struct WebsiteRoutingRule: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let domain: String
  public let target: WebsiteRoutingTarget

  public init(
    id: UUID = UUID(),
    domain: String,
    target: WebsiteRoutingTarget
  ) {
    self.id = id
    self.domain = domain
    self.target = target
  }
}

public struct VPNProfile: Codable, Equatable, Sendable {
  public let connections: [ManagedConnection]
  public let routingPolicy: RoutingPolicy?
  public let nodeGroups: [ProxyNodeGroup]?
  public let applicationRoutingRules: [ApplicationRoutingRule]
  public let websiteRoutingRules: [WebsiteRoutingRule]

  public init(
    connections: [ManagedConnection],
    routingPolicy: RoutingPolicy? = nil,
    nodeGroups: [ProxyNodeGroup] = [],
    applicationRoutingRules: [ApplicationRoutingRule] = [],
    websiteRoutingRules: [WebsiteRoutingRule] = []
  ) {
    self.connections = connections
    self.routingPolicy = routingPolicy
    self.nodeGroups = nodeGroups
    self.applicationRoutingRules = applicationRoutingRules
    self.websiteRoutingRules = websiteRoutingRules
  }

  private enum CodingKeys: String, CodingKey {
    case connections, routingPolicy, nodeGroups, applicationRoutingRules, websiteRoutingRules
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
    websiteRoutingRules =
      try container.decodeIfPresent(
        [WebsiteRoutingRule].self,
        forKey: .websiteRoutingRules
      ) ?? []
    if let connections = try container.decodeIfPresent(
      [ManagedConnection].self, forKey: .connections)
    {
      self.connections = connections
    } else {
      throw DecodingError.keyNotFound(
        CodingKeys.connections,
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "Current VPN profile has no managed connections."
        )
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(connections, forKey: .connections)
    try container.encodeIfPresent(routingPolicy, forKey: .routingPolicy)
    try container.encodeIfPresent(nodeGroups, forKey: .nodeGroups)
    try container.encode(applicationRoutingRules, forKey: .applicationRoutingRules)
    try container.encode(websiteRoutingRules, forKey: .websiteRoutingRules)
  }
}

public struct NativeProfile: Codable, Equatable, Sendable {
  public let configuration: Data
  public let selectorTag: String
  public let nodes: [ProxyNodeDescriptor]
  public let applicationRoutingRules: [ApplicationRoutingRule]
  public let websiteRoutingRules: [WebsiteRoutingRule]

  public init(
    configuration: Data,
    selectorTag: String,
    nodes: [ProxyNodeDescriptor],
    applicationRoutingRules: [ApplicationRoutingRule] = [],
    websiteRoutingRules: [WebsiteRoutingRule] = []
  ) {
    self.configuration = configuration
    self.selectorTag = selectorTag
    self.nodes = nodes
    self.applicationRoutingRules = applicationRoutingRules
    self.websiteRoutingRules = websiteRoutingRules
  }

  private enum CodingKeys: String, CodingKey {
    case configuration, selectorTag, nodes, applicationRoutingRules, websiteRoutingRules
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
    websiteRoutingRules =
      try container.decodeIfPresent(
        [WebsiteRoutingRule].self,
        forKey: .websiteRoutingRules
      ) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(configuration, forKey: .configuration)
    try container.encode(selectorTag, forKey: .selectorTag)
    try container.encode(nodes, forKey: .nodes)
    try container.encode(applicationRoutingRules, forKey: .applicationRoutingRules)
    try container.encode(websiteRoutingRules, forKey: .websiteRoutingRules)
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

  public var websiteRoutingRules: [WebsiteRoutingRule] {
    switch self {
    case .compatibility(let profile): profile.websiteRoutingRules
    case .native(let profile): profile.websiteRoutingRules
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
  public let runtimeOutcome: HelperRuntimeOutcome
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
    runtimeOutcome: HelperRuntimeOutcome = .applied,
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
    self.runtimeOutcome = runtimeOutcome
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
    case runtimeOutcome
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
    runtimeOutcome =
      try container.decodeIfPresent(HelperRuntimeOutcome.self, forKey: .runtimeOutcome) ?? .applied
    message = try container.decode(String.self, forKey: .message)
  }
}
