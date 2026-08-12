import Foundation
import SBMShared

struct SubscriptionHeaders: Codable, Equatable, Sendable {
  /// Exact stable client-identification fields observed in a Happ 5.4.0 iOS request capture.
  static let defaultUserAgent = "Happ/5.4.0/ios/2607311456556"
  static let defaultAppVersion = "5.4.0"
  static let defaultDeviceOS = "iOS"

  var userAgent: String
  var appVersion: String?
  var deviceOS: String
  var hardwareID: String

  init(
    userAgent: String = Self.defaultUserAgent,
    appVersion: String? = Self.defaultAppVersion,
    deviceOS: String = Self.defaultDeviceOS,
    hardwareID: String = Self.makeHardwareID()
  ) {
    self.userAgent = userAgent
    self.appVersion = appVersion
    self.deviceOS = deviceOS
    self.hardwareID = hardwareID
  }

  private enum CodingKeys: String, CodingKey {
    case userAgent, appVersion, deviceOS, hardwareID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userAgent = try container.decode(String.self, forKey: .userAgent)
    // Missing means a pre-preset source. Do not silently add a new request header.
    appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
    deviceOS = try container.decode(String.self, forKey: .deviceOS)
    hardwareID = try container.decode(String.self, forKey: .hardwareID)
  }

  static func makeHardwareID() -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<16).map { _ in alphabet.randomElement()! })
  }

  func resettingRequestPreset() -> SubscriptionHeaders {
    SubscriptionHeaders(
      userAgent: Self.defaultUserAgent,
      appVersion: Self.defaultAppVersion,
      deviceOS: Self.defaultDeviceOS,
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
    let pattern = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return nil }
    guard pattern.utf8.count <= maximumPatternLength,
      !pattern.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw SubscriptionFailure.invalidExcludeRegex
    }
    do {
      _ = try NSRegularExpression(pattern: pattern)
      return pattern
    } catch {
      throw SubscriptionFailure.invalidExcludeRegex
    }
  }

  static func matcher(for value: String?) throws -> NSRegularExpression? {
    guard let value, let pattern = try normalized(value) else { return nil }
    return try NSRegularExpression(pattern: pattern)
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
    applicationRoutingRules: [ApplicationRoutingRule] = []
  ) throws -> CoreProfile {
    var connections: [ManagedConnection] = []
    var groups: [ProxyNodeGroup] = []

    for source in sources {
      guard let payload = source.payload else { continue }
      guard case .compatibility(let profile) = payload else {
        throw SubscriptionFailure.nativeProfileCannotBeMerged
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
        applicationRoutingRules: applicationRoutingRules
      )
    )
  }
}

struct ProfileLibrary: Codable, Equatable, Sendable {
  var profiles: [ManagedProfile]
  var selectedProfileID: UUID?
  var localSOCKSEnabled: Bool
  var localSOCKSPort: UInt16
  var latencyIntervalMinutes: Int
  var latencyTestURL: String
  /// Not encoded. ProfileStore writes the upgraded schema before it is used.
  var requiresMigration = false

  static let currentSchemaVersion = 3

  private enum CodingKeys: String, CodingKey {
    case profiles
    case selectedProfileID
    case localSOCKSEnabled
    case localSOCKSPort
    case latencyIntervalMinutes
    case latencyTestURL
    case schemaVersion
  }

  init(
    profiles: [ManagedProfile],
    selectedProfileID: UUID?,
    localSOCKSEnabled: Bool = false,
    localSOCKSPort: UInt16 = 1082,
    latencyIntervalMinutes: Int = 10,
    latencyTestURL: String = LatencyTargetPolicy.defaultURL
  ) {
    self.profiles = profiles
    self.selectedProfileID = selectedProfileID
    self.localSOCKSEnabled = localSOCKSEnabled
    self.localSOCKSPort = localSOCKSPort
    self.latencyIntervalMinutes = max(latencyIntervalMinutes, 1)
    self.latencyTestURL = latencyTestURL
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    profiles = try container.decode([ManagedProfile].self, forKey: .profiles)
    selectedProfileID = try container.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
    localSOCKSEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .localSOCKSEnabled) ?? false
    localSOCKSPort =
      try container.decodeIfPresent(UInt16.self, forKey: .localSOCKSPort) ?? 1082
    let storedInterval =
      try container.decodeIfPresent(Int.self, forKey: .latencyIntervalMinutes) ?? 10
    latencyIntervalMinutes = max(storedInterval, 1)
    let storedTarget =
      try container.decodeIfPresent(String.self, forKey: .latencyTestURL)
      ?? LatencyTargetPolicy.defaultURL
    latencyTestURL = try LatencyTargetPolicy.normalized(storedTarget)
    let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard (1...Self.currentSchemaVersion).contains(version) else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Unsupported profile-library schema version."
      )
    }
    let containsLegacyConnections = profiles.contains(
      where: ProfileLibraryMigrator.containsLegacyConnections)
    if version == Self.currentSchemaVersion, containsLegacyConnections {
      throw DecodingError.dataCorruptedError(
        forKey: .profiles,
        in: container,
        debugDescription: "Current profile-library schema must use managed connections."
      )
    }
    if version == 1 {
      profiles = ProfileLibraryMigrator.migrateLegacyConnections(in: profiles)
    }
    if version < Self.currentSchemaVersion {
      requiresMigration = true
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(profiles, forKey: .profiles)
    try container.encodeIfPresent(selectedProfileID, forKey: .selectedProfileID)
    try container.encode(localSOCKSEnabled, forKey: .localSOCKSEnabled)
    try container.encode(localSOCKSPort, forKey: .localSOCKSPort)
    try container.encode(latencyIntervalMinutes, forKey: .latencyIntervalMinutes)
    try container.encode(latencyTestURL, forKey: .latencyTestURL)
    try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
  }

  static let empty = ProfileLibrary(profiles: [], selectedProfileID: nil)
}

enum ManagedConnectionReconciler {
  static func reconcile(existing: CoreProfile?, fetched: CoreProfile) -> CoreProfile {
    guard case .compatibility(let incoming) = fetched else { return fetched }
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
        applicationRoutingRules: incoming.applicationRoutingRules
      )
    )
  }

  static func requiresActivation(previous: CoreProfile?, next: CoreProfile?) -> Bool {
    switch (previous, next) {
    case (.compatibility(let left)?, .compatibility(let right)?):
      return left.routingPolicy != right.routingPolicy
        || left.applicationRoutingRules != right.applicationRoutingRules
        || activationIdentities(left.connections) != activationIdentities(right.connections)
    case (.native(let left)?, .native(let right)?):
      return left.configuration != right.configuration || left.selectorTag != right.selectorTag
        || left.applicationRoutingRules != right.applicationRoutingRules
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

enum ProfileLibraryMigrator {
  /// Reconstructs the pre-v1.1.12 aggregate order. Its IDs were assigned to
  /// all VLESS entries first, then all Hysteria2 entries, after source-order
  /// filtering and exact old-payload de-duplication.
  static func migrateLegacyConnections(in profiles: [ManagedProfile]) -> [ManagedProfile] {
    profiles.map(migrateLegacyConnections(in:))
  }

  static func containsLegacyConnections(in profile: ManagedProfile) -> Bool {
    if case .compatibility(let payload) = profile.payload, payload.usesLegacyConnectionEncoding {
      return true
    }
    return profile.sources.contains { source in
      if case .compatibility(let payload) = source.payload {
        return payload.usesLegacyConnectionEncoding
      }
      return false
    }
  }

  private static func migrateLegacyConnections(in profile: ManagedProfile) -> ManagedProfile {
    var migrated = profile
    var assigned: [String: ProxyNodeID] = [:]
    var seen: Set<String> = []
    var vlessCount = 0
    var hysteriaCount = 0

    for source in migrated.sources {
      guard case .compatibility(let payload) = source.payload else { continue }
      let filter = try? SourceNameFilter.matcher(for: source.excludeRegex)
      for connection in payload.connections
      where !SourceNameFilter.excludes(connection.displayName, using: filter) {
        let legacyKey = legacyIdentity(connection)
        guard seen.insert(legacyKey).inserted else { continue }
        switch connection.kind {
        case .vless:
          vlessCount += 1
          assigned[legacyKey] = ProxyNodeID(rawValue: "vless-\(vlessCount)")
        case .hysteria2:
          hysteriaCount += 1
          assigned[legacyKey] = ProxyNodeID(rawValue: "hysteria2-\(hysteriaCount)")
        default:
          break
        }
      }
    }

    func migratedPayload(_ payload: CoreProfile?, aggregate: Bool) -> CoreProfile? {
      guard case .compatibility(let compatibility) = payload else { return payload }
      var fallbackVLESS = 0
      var fallbackHysteria2 = 0
      let connections = compatibility.connections.map { connection -> ManagedConnection in
        let legacyKey = legacyIdentity(connection)
        let id: ProxyNodeID
        if let assignedID = assigned[legacyKey] {
          id = assignedID
        } else if aggregate {
          switch connection.kind {
          case .vless:
            fallbackVLESS += 1
            id = ProxyNodeID(rawValue: "vless-\(fallbackVLESS)")
          case .hysteria2:
            fallbackHysteria2 += 1
            id = ProxyNodeID(rawValue: "hysteria2-\(fallbackHysteria2)")
          default:
            id = connection.id
          }
        } else {
          // Excluded source entries never had an old aggregate ID. Giving them
          // a fresh ID prevents a later filter change from aliasing a live node.
          id = ProxyNodeID(rawValue: "node-\(UUID().uuidString)")
        }
        return ManagedConnection(
          id: id, displayName: connection.displayName, outbound: connection.outbound)
      }
      return .compatibility(
        VPNProfile(
          connections: connections,
          routingPolicy: compatibility.routingPolicy,
          nodeGroups: compatibility.nodeGroups ?? [],
          applicationRoutingRules: compatibility.applicationRoutingRules
        ))
    }

    migrated.sources = migrated.sources.map { source in
      var copy = source
      copy.payload = migratedPayload(source.payload, aggregate: false)
      return copy
    }
    migrated.payload = migratedPayload(migrated.payload, aggregate: true)
    return migrated
  }

  private static func legacyIdentity(_ connection: ManagedConnection) -> String {
    "\(connection.semanticIdentity)|\(connection.displayName)"
  }
}
