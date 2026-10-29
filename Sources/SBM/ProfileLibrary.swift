import Foundation
import SBMShared

struct SubscriptionHeaders: Codable, Equatable, Sendable {
  static let defaultUserAgent =
    "Shadowrocket/3445 CFNetwork/3860.700.2 Darwin/25.6.0 iPhone17,1"
  static let defaultAppVersion: String? = nil
  static let defaultDeviceOS = "iOS"
  static let defaultDeviceOSVersion: String? = "26.7"
  static let defaultDeviceModel: String? = "iPhone"

  var userAgent: String
  var appVersion: String?
  var deviceOS: String
  var deviceOSVersion: String?
  var deviceModel: String?
  var hardwareID: String

  init(
    userAgent: String = Self.defaultUserAgent,
    appVersion: String? = Self.defaultAppVersion,
    deviceOS: String = Self.defaultDeviceOS,
    deviceOSVersion: String? = Self.defaultDeviceOSVersion,
    deviceModel: String? = Self.defaultDeviceModel,
    hardwareID: String = Self.makeHardwareID()
  ) {
    self.userAgent = userAgent
    self.appVersion = appVersion
    self.deviceOS = deviceOS
    self.deviceOSVersion = deviceOSVersion
    self.deviceModel = deviceModel
    self.hardwareID = hardwareID
  }

  private enum CodingKeys: String, CodingKey {
    case userAgent, appVersion, deviceOS, deviceOSVersion, deviceModel, hardwareID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userAgent = try container.decode(String.self, forKey: .userAgent)
    appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
    deviceOS = try container.decode(String.self, forKey: .deviceOS)
    // Old schema-11 sources stay without newly introduced request identity values.
    deviceOSVersion = try container.decodeIfPresent(String.self, forKey: .deviceOSVersion)
    deviceModel = try container.decodeIfPresent(String.self, forKey: .deviceModel)
    hardwareID = try container.decode(String.self, forKey: .hardwareID)
  }

  static func makeHardwareID() -> String {
    UUID().uuidString.uppercased()
  }

  func resettingRequestPreset() -> SubscriptionHeaders {
    SubscriptionHeaders(
      userAgent: Self.defaultUserAgent,
      appVersion: Self.defaultAppVersion,
      deviceOS: Self.defaultDeviceOS,
      deviceOSVersion: Self.defaultDeviceOSVersion,
      deviceModel: Self.defaultDeviceModel,
      hardwareID: hardwareID
    )
  }
}

struct ManagedSource: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var name: String
  var value: String
  var headers: SubscriptionHeaders
  var excludeRegex: String?
  var payload: CoreProfile?
  var updatedAt: Date?

  init(
    id: UUID = UUID(),
    name: String = "Subscription",
    value: String = "",
    headers: SubscriptionHeaders = SubscriptionHeaders(),
    excludeRegex: String? = nil,
    payload: CoreProfile? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.value = value
    self.headers = headers
    self.excludeRegex = excludeRegex
    self.payload = payload
    self.updatedAt = updatedAt
  }
}

enum SourceNameFilter {
  static let maximumPatternLength = 512

  static func normalized(_ value: String) throws -> String? {
    try normalizedAndCompiled(value).pattern
  }

  static func matcher(for value: String?) throws -> NSRegularExpression? {
    try normalizedAndCompiled(value).expression
  }

  private static func normalizedAndCompiled(
    _ value: String?
  ) throws -> (pattern: String?, expression: NSRegularExpression?) {
    guard let value else { return (nil, nil) }
    let pattern = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return (nil, nil) }
    guard pattern.utf8.count <= maximumPatternLength,
      !pattern.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw SubscriptionFailure.invalidExcludeRegex
    }
    do {
      let expression = try NSRegularExpression(pattern: pattern)
      return (pattern, expression)
    } catch {
      throw SubscriptionFailure.invalidExcludeRegex
    }
  }

  static func excludes(_ name: String, using expression: NSRegularExpression?) -> Bool {
    guard let expression else { return false }
    let range = NSRange(name.startIndex..<name.endIndex, in: name)
    return expression.firstMatch(in: name, range: range) != nil
  }
}

struct ManagedProfile: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var name: String
  var sources: [ManagedSource]
  var payload: CoreProfile?
  var updatedAt: Date?

  init(
    id: UUID = UUID(),
    name: String,
    sources: [ManagedSource] = [],
    payload: CoreProfile? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.sources = sources
    self.payload = payload
    self.updatedAt = updatedAt
  }
}

enum ProfileAggregator {
  static func merge(
    sources: [ManagedSource],
    routingPolicy: RoutingPolicy?,
    applicationRoutingRules: [ApplicationRoutingRule] = [],
    websiteRoutingRules: [WebsiteRoutingRule] = []
  ) throws -> CoreProfile {
    var connections: [ManagedConnection] = []
    var groups: [ProxyNodeGroup] = []

    for source in sources {
      guard let payload = source.payload else { continue }
      let profile: VPNProfile
      switch payload {
      case .compatibility(let managedProfile): profile = managedProfile
      }
      let sourceName = try SubscriptionClient.validateDisplayName(source.name)
      let filter = try SourceNameFilter.matcher(for: source.excludeRegex)
      var groupNodes: [ProxyNodeID] = []
      for connection in profile.connections
      where !SourceNameFilter.excludes(connection.displayName, using: filter)
        && !connections.contains(where: { $0.semanticIdentity == connection.semanticIdentity })
      {
        connections.append(connection)
        groupNodes.append(connection.id)
      }
      if !groupNodes.isEmpty {
        groups.append(
          ProxyNodeGroup(
            id: source.id.uuidString,
            name: sourceName,
            nodes: groupNodes
          )
        )
      }
    }

    guard !connections.isEmpty else {
      throw SubscriptionFailure.missingProtocols
    }
    guard connections.count <= SubscriptionClient.maximumConnections else {
      throw SubscriptionFailure.tooManyConnections
    }
    return .compatibility(
      VPNProfile(
        connections: connections,
        routingPolicy: routingPolicy,
        nodeGroups: groups,
        applicationRoutingRules: applicationRoutingRules,
        websiteRoutingRules: websiteRoutingRules
      )
    )
  }
}

enum ProfileLibrarySchemaMismatch: Error {
  case legacy(version: Int?)
  case unsupportedFuture(version: Int)
}

struct ProfileLibrary: Codable, Equatable, Sendable {
  var profiles: [ManagedProfile]
  var selectedProfileID: UUID?
  var routingMode: RoutingMode
  var selectedNodeID: ProxyNodeID
  var localSOCKSEnabled: Bool
  var localSOCKSPort: UInt16
  var latencyIntervalMinutes: Int
  var latencyTestURL: String
  var ipv6Enabled: Bool
  var dnsSettings: ManagedDNSSettings

  static let currentSchemaVersion = 11

  private enum CodingKeys: String, CodingKey {
    case profiles
    case selectedProfileID
    case routingMode
    case selectedNodeID
    case localSOCKSEnabled
    case localSOCKSPort
    case latencyIntervalMinutes
    case latencyTestURL
    case ipv6Enabled
    case dnsSettings
    case schemaVersion
  }

  init(
    profiles: [ManagedProfile],
    selectedProfileID: UUID?,
    routingMode: RoutingMode = .rule,
    selectedNodeID: ProxyNodeID = .auto,
    localSOCKSEnabled: Bool = false,
    localSOCKSPort: UInt16 = 1082,
    latencyIntervalMinutes: Int = 10,
    latencyTestURL: String = LatencyTargetPolicy.defaultURL,
    ipv6Enabled: Bool = false,
    dnsSettings: ManagedDNSSettings = .defaults
  ) {
    self.profiles = profiles
    self.selectedProfileID = selectedProfileID
    self.routingMode = routingMode
    self.selectedNodeID = selectedNodeID
    self.localSOCKSEnabled = localSOCKSEnabled
    self.localSOCKSPort = localSOCKSPort
    self.latencyIntervalMinutes = max(latencyIntervalMinutes, 1)
    self.latencyTestURL = latencyTestURL
    self.ipv6Enabled = ipv6Enabled
    self.dnsSettings = dnsSettings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.schemaVersion) else {
      throw ProfileLibrarySchemaMismatch.legacy(version: nil)
    }
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      if version < Self.currentSchemaVersion {
        throw ProfileLibrarySchemaMismatch.legacy(version: version)
      }
      throw ProfileLibrarySchemaMismatch.unsupportedFuture(version: version)
    }
    profiles = try container.decode([ManagedProfile].self, forKey: .profiles)
    selectedProfileID = try container.decode(UUID?.self, forKey: .selectedProfileID)
    routingMode = try container.decode(RoutingMode.self, forKey: .routingMode)
    selectedNodeID = try container.decode(ProxyNodeID.self, forKey: .selectedNodeID)
    localSOCKSEnabled = try container.decode(Bool.self, forKey: .localSOCKSEnabled)
    localSOCKSPort = try container.decode(UInt16.self, forKey: .localSOCKSPort)
    let storedInterval = try container.decode(Int.self, forKey: .latencyIntervalMinutes)
    latencyIntervalMinutes = max(storedInterval, 1)
    let storedTarget = try container.decode(String.self, forKey: .latencyTestURL)
    latencyTestURL = try LatencyTargetPolicy.normalized(storedTarget)
    ipv6Enabled = try container.decode(Bool.self, forKey: .ipv6Enabled)
    dnsSettings =
      container.contains(.dnsSettings)
      ? try container.decode(ManagedDNSSettings.self, forKey: .dnsSettings).validated()
      : .defaults
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(profiles, forKey: .profiles)
    try container.encode(selectedProfileID, forKey: .selectedProfileID)
    try container.encode(routingMode, forKey: .routingMode)
    try container.encode(selectedNodeID, forKey: .selectedNodeID)
    try container.encode(localSOCKSEnabled, forKey: .localSOCKSEnabled)
    try container.encode(localSOCKSPort, forKey: .localSOCKSPort)
    try container.encode(latencyIntervalMinutes, forKey: .latencyIntervalMinutes)
    try container.encode(latencyTestURL, forKey: .latencyTestURL)
    try container.encode(ipv6Enabled, forKey: .ipv6Enabled)
    try container.encode(dnsSettings, forKey: .dnsSettings)
    try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
  }

  static func freshInstall() -> ProfileLibrary {
    let profile = ManagedProfile(
      name: SBMText.localized("Main"),
      sources: [ManagedSource(name: SBMText.localized("Subscription"))]
    )
    return ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  }

  static let empty = ProfileLibrary(profiles: [], selectedProfileID: nil)
}

enum ManagedConnectionReconciler {
  static func reconcile(existing: CoreProfile?, fetched: CoreProfile) -> CoreProfile {
    let incoming: VPNProfile
    switch fetched {
    case .compatibility(let profile): incoming = profile
    }
    guard case .compatibility(let previous) = existing else { return fetched }
    var reusable = Dictionary(grouping: previous.connections, by: \.semanticIdentity)
    let reconciled = incoming.connections.map { connection -> ManagedConnection in
      guard var queue = reusable[connection.semanticIdentity], !queue.isEmpty else {
        return connection
      }
      let prior = queue.removeFirst()
      reusable[connection.semanticIdentity] = queue
      return ManagedConnection(
        id: prior.id, displayName: connection.displayName, outbound: connection.outbound)
    }
    let incomingIDCounts = Dictionary(
      grouping: incoming.connections,
      by: \ManagedConnection.id
    ).mapValues(\.count)
    let remappedIDs: [ProxyNodeID: ProxyNodeID] = Dictionary(
      uniqueKeysWithValues: zip(incoming.connections, reconciled).compactMap {
        incomingConnection, reconciledConnection in
        guard incomingIDCounts[incomingConnection.id] == 1 else { return nil }
        return (incomingConnection.id, reconciledConnection.id)
      }
    )
    let reconciledGroups = (incoming.nodeGroups ?? []).map { group in
      ProxyNodeGroup(
        id: group.id,
        name: group.name,
        nodes: group.nodes.map { remappedIDs[$0] ?? $0 }
      )
    }
    return .compatibility(
      VPNProfile(
        connections: reconciled,
        routingPolicy: incoming.routingPolicy,
        nodeGroups: reconciledGroups,
        applicationRoutingRules: incoming.applicationRoutingRules,
        websiteRoutingRules: previous.websiteRoutingRules,
        autoExcludedNodeIDs: reconciled.flatMap { connection in
          previous.autoExcludedNodeIDs.filter { $0 == connection.id }
        }
      )
    )
  }

  static func requiresActivation(previous: CoreProfile?, next: CoreProfile?) -> Bool {
    switch (previous, next) {
    case (.compatibility(let left)?, .compatibility(let right)?):
      return left.routingPolicy != right.routingPolicy
        || left.applicationRoutingRules != right.applicationRoutingRules
        || left.websiteRoutingRules != right.websiteRoutingRules
        || Set(left.autoExcludedNodeIDs) != Set(right.autoExcludedNodeIDs)
        || activationIdentities(left.connections) != activationIdentities(right.connections)
    case (nil, nil): return false
    default: return true
    }
  }

  private static func activationIdentities(_ connections: [ManagedConnection]) -> [String] {
    connections.map { connection in
      let id = connection.id.rawValue
      return "\(id.utf8.count):\(id)\(connection.semanticIdentity)"
    }.sorted()
  }
}
