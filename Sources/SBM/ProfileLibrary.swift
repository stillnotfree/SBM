import Foundation
import SBMShared

struct SubscriptionHeaders: Codable, Equatable, Sendable {
  static let defaultUserAgent = "Shadowrocket/2.2.42 (iPhone; iOS 17.5.1; Scale/3.00)"
  static let defaultDeviceOS = "macOS"

  var userAgent: String
  var deviceOS: String
  var hardwareID: String

  init(
    userAgent: String = Self.defaultUserAgent,
    deviceOS: String = Self.defaultDeviceOS,
    hardwareID: String = UUID().uuidString
  ) {
    self.userAgent = userAgent
    self.deviceOS = deviceOS
    self.hardwareID = hardwareID
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
    routingPolicy: RoutingPolicy?
  ) throws -> CoreProfile {
    var vless: [VLESSProfile] = []
    var hysteria2: [Hysteria2Profile] = []
    var groups: [ProxyNodeGroup] = []

    for source in sources {
      guard let payload = source.payload else { continue }
      guard case .compatibility(let profile) = payload else {
        throw SubscriptionFailure.nativeProfileCannotBeMerged
      }
      let sourceName = try SubscriptionClient.validateDisplayName(source.name)
      let filter = try SourceNameFilter.matcher(for: source.excludeRegex)
      var groupNodes: [ProxyNodeID] = []
      for connection in profile.vless
      where !SourceNameFilter.excludes(connection.displayName, using: filter)
        && !vless.contains(connection)
      {
        vless.append(connection)
        groupNodes.append(ProxyNodeID(rawValue: "vless-\(vless.count)"))
      }
      for connection in profile.hysteria2
      where !SourceNameFilter.excludes(connection.displayName, using: filter)
        && !hysteria2.contains(connection)
      {
        hysteria2.append(connection)
        groupNodes.append(ProxyNodeID(rawValue: "hysteria2-\(hysteria2.count)"))
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

    guard !vless.isEmpty || !hysteria2.isEmpty else {
      throw SubscriptionFailure.missingProtocols
    }
    guard vless.count + hysteria2.count <= SubscriptionClient.maximumConnections else {
      throw SubscriptionFailure.tooManyConnections
    }
    return .compatibility(
      VPNProfile(
        vless: vless,
        hysteria2: hysteria2,
        routingPolicy: routingPolicy,
        nodeGroups: groups
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

  private enum CodingKeys: String, CodingKey {
    case profiles
    case selectedProfileID
    case localSOCKSEnabled
    case localSOCKSPort
    case latencyIntervalMinutes
  }

  init(
    profiles: [ManagedProfile],
    selectedProfileID: UUID?,
    localSOCKSEnabled: Bool = false,
    localSOCKSPort: UInt16 = 1082,
    latencyIntervalMinutes: Int = 10
  ) {
    self.profiles = profiles
    self.selectedProfileID = selectedProfileID
    self.localSOCKSEnabled = localSOCKSEnabled
    self.localSOCKSPort = localSOCKSPort
    self.latencyIntervalMinutes = min(max(latencyIntervalMinutes, 1), 9_999)
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
    latencyIntervalMinutes = min(max(storedInterval, 1), 9_999)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(profiles, forKey: .profiles)
    try container.encodeIfPresent(selectedProfileID, forKey: .selectedProfileID)
    try container.encode(localSOCKSEnabled, forKey: .localSOCKSEnabled)
    try container.encode(localSOCKSPort, forKey: .localSOCKSPort)
    try container.encode(latencyIntervalMinutes, forKey: .latencyIntervalMinutes)
  }

  static let empty = ProfileLibrary(profiles: [], selectedProfileID: nil)
}
