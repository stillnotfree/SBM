import Foundation

public enum HelperConstants {
  public static let protocolVersion = 4
  public static let helperVersion = "1.1.0"
  public static let helperRevision = 29
  public static let socketPath = "/var/run/com.stillnotfree.sbm.helper.sock"
  public static let daemonPlistName = "com.stillnotfree.sbm.helper.plist"
}

public enum HelperAction: String, Codable, Sendable {
  case status
  case start
  case stop
  case setMode
  case setNode
  case testLatency
  case validateProfile
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

public struct ProxyNodeDescriptor: Codable, Equatable, Hashable, Sendable {
  public let id: ProxyNodeID
  public let name: String

  public init(id: ProxyNodeID, name: String) {
    self.id = id
    self.name = name
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

public struct RoutingPolicy: Codable, Equatable, Sendable {
  public let configuration: Data

  public init(configuration: Data) {
    self.configuration = configuration
  }
}

public struct VPNProfile: Codable, Equatable, Sendable {
  public let vless: [VLESSProfile]
  public let hysteria2: [Hysteria2Profile]
  public let routingPolicy: RoutingPolicy?

  public init(
    vless: [VLESSProfile] = [],
    hysteria2: [Hysteria2Profile] = [],
    routingPolicy: RoutingPolicy? = nil
  ) {
    self.vless = vless
    self.hysteria2 = hysteria2
    self.routingPolicy = routingPolicy
  }
}

public struct NativeProfile: Codable, Equatable, Sendable {
  public let configuration: Data
  public let selectorTag: String
  public let nodes: [ProxyNodeDescriptor]

  public init(
    configuration: Data,
    selectorTag: String,
    nodes: [ProxyNodeDescriptor]
  ) {
    self.configuration = configuration
    self.selectorTag = selectorTag
    self.nodes = nodes
  }
}

public enum CoreProfile: Codable, Equatable, Sendable {
  case compatibility(VPNProfile)
  case native(NativeProfile)

  public var nodes: [ProxyNodeDescriptor] {
    switch self {
    case .compatibility(let profile):
      var nodes = [ProxyNodeDescriptor(id: .auto, name: "Auto")]
      for (index, vless) in profile.vless.enumerated() {
        nodes.append(
          ProxyNodeDescriptor(
            id: ProxyNodeID(rawValue: "vless-\(index + 1)"),
            name: vless.displayName
          )
        )
      }
      for (index, hysteria2) in profile.hysteria2.enumerated() {
        nodes.append(
          ProxyNodeDescriptor(
            id: ProxyNodeID(rawValue: "hysteria2-\(index + 1)"),
            name: hysteria2.displayName
          )
        )
      }
      return nodes
    case .native(let profile):
      return profile.nodes
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

  public init(
    action: HelperAction,
    profile: CoreProfile? = nil,
    profileID: UUID? = nil,
    mode: RoutingMode? = nil,
    node: ProxyNodeID? = nil,
    localSOCKSEnabled: Bool? = nil,
    localSOCKSPort: UInt16? = nil
  ) {
    self.protocolVersion = HelperConstants.protocolVersion
    self.action = action
    self.profile = profile
    self.profileID = profileID
    self.mode = mode
    self.node = node
    self.localSOCKSEnabled = localSOCKSEnabled
    self.localSOCKSPort = localSOCKSPort
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
    self.message = message
  }
}
