import CryptoKit
import Foundation

public enum HelperConstants {
  public static let protocolVersion = 14
  public static let helperVersion = "1.2.0"
  public static let helperRevision = 76
  public static let socketPath = "/var/run/com.stillnotfree.sbm.helper.v12.sock"
  public static let daemonPlistName = "com.stillnotfree.sbm.helper.v12.plist"
  public static let legacyDaemonPlistName = "com.stillnotfree.sbm.helper.plist"
  public static let serviceLabelEnvironmentKey = "SBM_HELPER_SERVICE_LABEL"
  public static let currentServiceLabel = "com.stillnotfree.sbm.helper.v12"
  public static let legacyServiceLabel = "com.stillnotfree.sbm.helper"
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
  case shutdown
  case finishLegacy1115Upgrade
}

public enum HelperStopReason: String, Codable, Sendable {
  case userDisconnect
  case reconnectToApply
  case appTermination
  case automaticRecovery
  case other
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

public enum ManagedDNSChoice: Codable, Hashable, Sendable {
  case system
  case cloudflare
  case google
  case yandex
  case quad9
  case adguard
  case customDoH(String)
}

public struct ManagedDNSSettings: Codable, Equatable, Sendable {
  public var direct: ManagedDNSChoice
  public var proxy: ManagedDNSChoice

  public static let defaults = ManagedDNSSettings(direct: .system, proxy: .cloudflare)
  private static let maximumCustomDoHURLBytes = 4096

  public init(direct: ManagedDNSChoice = .system, proxy: ManagedDNSChoice = .cloudflare) {
    self.direct = direct
    self.proxy = proxy
  }

  public func validated() throws -> Self {
    guard proxy != .system else { throw Self.invalid }
    return Self(direct: try Self.validated(direct), proxy: try Self.validated(proxy))
  }

  private static func validated(_ choice: ManagedDNSChoice) throws -> ManagedDNSChoice {
    guard case .customDoH(let rawURL) = choice else { return choice }
    let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf8.count <= maximumCustomDoHURLBytes,
      let components = URLComponents(string: value),
      let source = components.string
    else {
      throw invalid
    }
    guard source.utf8.count <= maximumCustomDoHURLBytes else { throw invalid }
    if components.rangeOfPort == nil, let hostEnd = components.rangeOfHost?.upperBound,
      hostEnd < source.endIndex, source[hostEnd] == ":"
    {
      throw invalid
    }
    if components.rangeOfPort != nil {
      guard let port = components.port, (1...65535).contains(port) else { throw invalid }
    }
    guard components.scheme?.lowercased() == "https",
      components.host?.isEmpty == false,
      components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
      components.percentEncodedQuery == nil, components.percentEncodedFragment == nil,
      components.percentEncodedPath.isEmpty || components.percentEncodedPath.hasPrefix("/"),
      components.url?.host != nil
    else {
      throw invalid
    }
    return .customDoH(value)
  }

  private static let invalid = DecodingError.dataCorrupted(
    .init(codingPath: [], debugDescription: "Invalid DNS.")
  )
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
  case unknown
}

public struct ProxyNodeDescriptor: Codable, Equatable, Hashable, Sendable {
  public let id: ProxyNodeID
  public let name: String
  public let kind: ProxyNodeKind

  public init(id: ProxyNodeID, name: String, kind: ProxyNodeKind = .unknown) {
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

public enum VLESSProfileVariant: Equatable, Sendable {
  case reality(publicKey: String, shortID: String)
  case realityGRPC(publicKey: String, shortID: String, serviceName: String)
  case tlsTCP
  case tlsHTTP(host: String?, path: String?)
  case tlsGRPC(serviceName: String)
  case tlsWebSocket(host: String?, path: String?)
  case tlsQUIC
  case tlsHTTPUpgrade(host: String?, path: String?)

  public var isReality: Bool {
    switch self {
    case .reality, .realityGRPC: true
    default: false
    }
  }
}

public struct VLESSProfile: Codable, Equatable, Sendable {
  public static let supportedFingerprints: Set<String> = [
    "chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random",
    "randomized",
  ]

  public let server: String
  public let port: UInt16
  public let uuid: String
  public let serverName: String
  public let fingerprint: String
  public let variant: VLESSProfileVariant

  /// Compatibility views for the released REALITY-shaped model. They are
  /// empty for TLS profiles and must not be used to build those variants.
  public var publicKey: String {
    switch variant {
    case .reality(let publicKey, _), .realityGRPC(let publicKey, _, _): publicKey
    default: ""
    }
  }

  public var shortID: String {
    switch variant {
    case .reality(_, let shortID), .realityGRPC(_, let shortID, _): shortID
    default: ""
    }
  }

  public var grpcServiceName: String? {
    switch variant {
    case .tlsGRPC(let serviceName), .realityGRPC(_, _, let serviceName): serviceName
    default: nil
    }
  }

  public init(
    server: String,
    port: UInt16,
    uuid: String,
    serverName: String,
    fingerprint: String,
    publicKey: String,
    shortID: String
  ) {
    self.init(
      server: server,
      port: port,
      uuid: uuid,
      serverName: serverName,
      fingerprint: fingerprint,
      variant: .reality(publicKey: publicKey, shortID: shortID)
    )
  }

  public init(
    server: String,
    port: UInt16,
    uuid: String,
    serverName: String,
    fingerprint: String,
    variant: VLESSProfileVariant
  ) {
    self.server = server
    self.port = port
    self.uuid = uuid
    self.serverName = serverName
    self.fingerprint = fingerprint
    self.variant = variant
  }

  private enum CodingKeys: String, CodingKey {
    case server, port, uuid, serverName, fingerprint, publicKey, shortID
    case security, type, serviceName, host, path
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    server = try container.decode(String.self, forKey: .server)
    port = try container.decode(UInt16.self, forKey: .port)
    uuid = try container.decode(String.self, forKey: .uuid)
    serverName = try container.decode(String.self, forKey: .serverName)
    fingerprint = try container.decode(String.self, forKey: .fingerprint)

    if let security = try container.decodeIfPresent(String.self, forKey: .security) {
      let type = try container.decode(String.self, forKey: .type)
      let hasRealityFields = container.contains(.publicKey) || container.contains(.shortID)
      let hasTransportFields = container.contains(.host) || container.contains(.path)
      let hasServiceName = container.contains(.serviceName)
      let invalid = DecodingError.dataCorruptedError(
        forKey: .security,
        in: container,
        debugDescription: "Unsupported VLESS managed security or transport."
      )
      switch (security, type) {
      case ("tls", "grpc"):
        guard !hasRealityFields, !hasTransportFields else { throw invalid }
        variant = .tlsGRPC(serviceName: try container.decode(String.self, forKey: .serviceName))
      case ("reality", "grpc"):
        guard !hasTransportFields else { throw invalid }
        variant = .realityGRPC(
          publicKey: try container.decode(String.self, forKey: .publicKey),
          shortID: try container.decode(String.self, forKey: .shortID),
          serviceName: try container.decode(String.self, forKey: .serviceName)
        )
      case ("tls", "tcp"):
        guard !hasRealityFields, !hasTransportFields, !hasServiceName else { throw invalid }
        variant = .tlsTCP
      case ("tls", "http"), ("tls", "ws"), ("tls", "httpupgrade"):
        guard !hasRealityFields, !hasServiceName else { throw invalid }
        let host = try container.decodeIfPresent(String.self, forKey: .host)
        let path = try container.decodeIfPresent(String.self, forKey: .path)
        switch type {
        case "http": variant = .tlsHTTP(host: host, path: path)
        case "ws": variant = .tlsWebSocket(host: host, path: path)
        default: variant = .tlsHTTPUpgrade(host: host, path: path)
        }
      case ("tls", "quic"):
        guard !hasRealityFields, !hasTransportFields, !hasServiceName else { throw invalid }
        variant = .tlsQUIC
      default: throw invalid
      }
    } else {
      if let type = try container.decodeIfPresent(String.self, forKey: .type), type != "tcp" {
        throw DecodingError.dataCorruptedError(
          forKey: .type,
          in: container,
          debugDescription: "Unsupported VLESS managed transport."
        )
      }
      variant = .reality(
        publicKey: try container.decode(String.self, forKey: .publicKey),
        shortID: try container.decode(String.self, forKey: .shortID)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(server, forKey: .server)
    try container.encode(port, forKey: .port)
    try container.encode(uuid, forKey: .uuid)
    try container.encode(serverName, forKey: .serverName)
    try container.encode(fingerprint, forKey: .fingerprint)
    switch variant {
    case .reality(let publicKey, let shortID):
      // Keep the released current-profile-library representation byte-for-byte
      // equivalent in meaning and readable by older migration DTOs.
      try container.encode(publicKey, forKey: .publicKey)
      try container.encode(shortID, forKey: .shortID)
    case .realityGRPC(let publicKey, let shortID, let serviceName):
      try encodeTransport("reality", type: "grpc", into: &container)
      try container.encode(publicKey, forKey: .publicKey)
      try container.encode(shortID, forKey: .shortID)
      try container.encode(serviceName, forKey: .serviceName)
    case .tlsTCP:
      try encodeTransport("tls", type: "tcp", into: &container)
    case .tlsHTTP(let host, let path):
      try encodeTransport("tls", type: "http", into: &container)
      try container.encodeIfPresent(host, forKey: .host)
      try container.encodeIfPresent(path, forKey: .path)
    case .tlsGRPC(let serviceName):
      try encodeTransport("tls", type: "grpc", into: &container)
      try container.encode(serviceName, forKey: .serviceName)
    case .tlsWebSocket(let host, let path):
      try encodeTransport("tls", type: "ws", into: &container)
      try container.encodeIfPresent(host, forKey: .host)
      try container.encodeIfPresent(path, forKey: .path)
    case .tlsQUIC:
      try encodeTransport("tls", type: "quic", into: &container)
    case .tlsHTTPUpgrade(let host, let path):
      try encodeTransport("tls", type: "httpupgrade", into: &container)
      try container.encodeIfPresent(host, forKey: .host)
      try container.encodeIfPresent(path, forKey: .path)
    }
  }

  private func encodeTransport(
    _ security: String,
    type: String,
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(security, forKey: .security)
    try container.encode(type, forKey: .type)
  }
}

public struct Hysteria2PortRange: Codable, Equatable, Sendable {
  public let start: UInt16
  public let end: UInt16

  public init(start: UInt16, end: UInt16) {
    self.start = start
    self.end = end
  }
}

public struct Hysteria2Profile: Codable, Equatable, Sendable {
  public let server: String
  public let port: UInt16
  public let password: String
  public let serverName: String
  public let obfsPassword: String?
  public let portHoppingRanges: [Hysteria2PortRange]?

  public init(
    server: String,
    port: UInt16,
    password: String,
    serverName: String,
    obfsPassword: String? = nil,
    portHoppingRanges: [Hysteria2PortRange]? = nil
  ) {
    self.server = server
    self.port = port
    self.password = password
    self.serverName = serverName
    self.obfsPassword = obfsPassword
    self.portHoppingRanges = portHoppingRanges
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
      switch value.variant {
      case .reality(let publicKey, let shortID):
        // Preserve the identity formula used by released REALITY profiles.
        return canonicalIdentity([
          "vless", canonicalHost(value.server), String(value.port), value.uuid.lowercased(),
          canonicalHost(value.serverName), value.fingerprint, publicKey, shortID.lowercased(),
        ])
      case .tlsGRPC(let serviceName):
        return canonicalIdentity([
          "vless", "tls-grpc", canonicalHost(value.server), String(value.port),
          value.uuid.lowercased(), canonicalHost(value.serverName), value.fingerprint, serviceName,
        ])
      case .realityGRPC(let publicKey, let shortID, let serviceName):
        return vlessIdentity(
          value, variant: "reality-grpc",
          values: [publicKey, shortID.lowercased(), serviceName]
        )
      case .tlsTCP:
        return vlessIdentity(value, variant: "tls-tcp", values: [])
      case .tlsHTTP(let host, let path):
        return vlessIdentity(value, variant: "tls-http", values: [host ?? "", path ?? ""])
      case .tlsWebSocket(let host, let path):
        return vlessIdentity(value, variant: "tls-ws", values: [host ?? "", path ?? ""])
      case .tlsQUIC:
        return vlessIdentity(value, variant: "tls-quic", values: [])
      case .tlsHTTPUpgrade(let host, let path):
        return vlessIdentity(
          value, variant: "tls-httpupgrade", values: [host ?? "", path ?? ""]
        )
      }
    case .hysteria2(let value):
      let parts = [
        "hysteria2", canonicalHost(value.server), String(value.port), value.password,
        canonicalHost(value.serverName), value.obfsPassword ?? "",
      ]
      guard let ranges = value.portHoppingRanges else {
        return canonicalIdentity(parts)
      }
      let canonicalRanges = ranges.map { "\($0.start):\($0.end)" }.joined(separator: ",")
      return canonicalIdentity(parts + [canonicalRanges])
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

  private func vlessIdentity(_ value: VLESSProfile, variant: String, values: [String]) -> String {
    canonicalIdentity(
      [
        "vless", variant, canonicalHost(value.server), String(value.port), value.uuid.lowercased(),
        canonicalHost(value.serverName), value.fingerprint,
      ] + values)
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
  public let autoExcludedNodeIDs: [ProxyNodeID]

  public init(
    connections: [ManagedConnection],
    routingPolicy: RoutingPolicy? = nil,
    nodeGroups: [ProxyNodeGroup] = [],
    applicationRoutingRules: [ApplicationRoutingRule] = [],
    websiteRoutingRules: [WebsiteRoutingRule] = [],
    autoExcludedNodeIDs: [ProxyNodeID] = []
  ) {
    self.connections = connections
    self.routingPolicy = routingPolicy
    self.nodeGroups = nodeGroups
    self.applicationRoutingRules = applicationRoutingRules
    self.websiteRoutingRules = websiteRoutingRules
    self.autoExcludedNodeIDs = autoExcludedNodeIDs
  }

  private enum CodingKeys: String, CodingKey {
    case connections, routingPolicy, nodeGroups, applicationRoutingRules, websiteRoutingRules
    case autoExcludedNodeIDs
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
    autoExcludedNodeIDs =
      try container.decodeIfPresent([ProxyNodeID].self, forKey: .autoExcludedNodeIDs) ?? []
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
    let orderedExclusions =
      connections.flatMap { connection in
        autoExcludedNodeIDs.filter { $0 == connection.id }
      } + autoExcludedNodeIDs.filter { id in !connections.contains { $0.id == id } }
    try container.encode(orderedExclusions, forKey: .autoExcludedNodeIDs)
  }
}

public enum CoreProfile: Codable, Equatable, Sendable {
  case compatibility(VPNProfile)

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
    }
  }

  public var applicationRoutingRules: [ApplicationRoutingRule] {
    switch self {
    case .compatibility(let profile): profile.applicationRoutingRules
    }
  }

  public var websiteRoutingRules: [WebsiteRoutingRule] {
    switch self {
    case .compatibility(let profile): profile.websiteRoutingRules
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
  public let ipv6Enabled: Bool?
  public let stopReason: HelperStopReason?
  public let observeAutoNode: Bool?
  public let recoverDesiredRuntime: Bool?
  public let dnsSettings: ManagedDNSSettings?

  public init(
    action: HelperAction,
    profile: CoreProfile? = nil,
    profileID: UUID? = nil,
    mode: RoutingMode? = nil,
    node: ProxyNodeID? = nil,
    localSOCKSEnabled: Bool? = nil,
    localSOCKSPort: UInt16? = nil,
    latencyTestURL: String? = nil,
    ipv6Enabled: Bool? = nil,
    stopReason: HelperStopReason? = nil,
    observeAutoNode: Bool? = nil,
    recoverDesiredRuntime: Bool? = nil,
    dnsSettings: ManagedDNSSettings? = nil
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
    self.ipv6Enabled = ipv6Enabled
    self.stopReason = stopReason
    self.observeAutoNode = observeAutoNode
    self.recoverDesiredRuntime = recoverDesiredRuntime
    self.dnsSettings = dnsSettings
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
  public let effectiveAutoNode: ProxyNodeID?
  public let activeProfileID: UUID?
  /// The IPv6 policy in the configuration currently used by a running core.
  /// `nil` means the core is stopped or the authoritative policy is unknown.
  public let activeIPv6Enabled: Bool?
  public let nodes: [ProxyNodeDescriptor]
  public let delays: [NodeDelay]
  /// `true` requires an explicit user connection before recovery can retry.
  public let automaticRecoveryExhausted: Bool
  public let runtimeOutcome: HelperRuntimeOutcome
  public let legacy1115Retired: Bool?
  public let message: String

  public init(
    success: Bool,
    coreRunning: Bool,
    coreVersion: String? = nil,
    mode: RoutingMode = .rule,
    selectedNode: ProxyNodeID = .auto,
    effectiveAutoNode: ProxyNodeID? = nil,
    activeProfileID: UUID? = nil,
    activeIPv6Enabled: Bool? = nil,
    nodes: [ProxyNodeDescriptor] = [],
    delays: [NodeDelay] = [],
    automaticRecoveryExhausted: Bool = false,
    runtimeOutcome: HelperRuntimeOutcome = .applied,
    legacy1115Retired: Bool?,
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
    self.effectiveAutoNode = effectiveAutoNode
    self.activeProfileID = activeProfileID
    self.activeIPv6Enabled = activeIPv6Enabled
    self.nodes = nodes
    self.delays = delays
    self.automaticRecoveryExhausted = automaticRecoveryExhausted
    self.runtimeOutcome = runtimeOutcome
    self.legacy1115Retired = legacy1115Retired
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
    case effectiveAutoNode
    case activeProfileID
    case activeIPv6Enabled
    case nodes
    case delays
    case automaticRecoveryExhausted
    case runtimeOutcome
    case legacy1115Retired
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
    effectiveAutoNode = try container.decodeIfPresent(ProxyNodeID.self, forKey: .effectiveAutoNode)
    activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
    activeIPv6Enabled = try container.decodeIfPresent(Bool.self, forKey: .activeIPv6Enabled)
    nodes = try container.decode([ProxyNodeDescriptor].self, forKey: .nodes)
    delays = try container.decode([NodeDelay].self, forKey: .delays)
    automaticRecoveryExhausted =
      try container.decodeIfPresent(Bool.self, forKey: .automaticRecoveryExhausted) ?? false
    runtimeOutcome =
      try container.decodeIfPresent(HelperRuntimeOutcome.self, forKey: .runtimeOutcome) ?? .applied
    legacy1115Retired = try container.decodeIfPresent(Bool.self, forKey: .legacy1115Retired)
    message = try container.decode(String.self, forKey: .message)
  }
}
