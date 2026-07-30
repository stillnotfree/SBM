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
  var payload: CoreProfile?
  var updatedAt: Date?

  init(
    id: UUID = UUID(),
    name: String = "Subscription",
    value: String = "",
    headers: SubscriptionHeaders = SubscriptionHeaders(),
    payload: CoreProfile? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.value = value
    self.headers = headers
    self.payload = payload
    self.updatedAt = updatedAt
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

    for source in sources {
      guard let payload = source.payload else { continue }
      guard case .compatibility(let profile) = payload else {
        throw SubscriptionFailure.nativeProfileCannotBeMerged
      }
      for connection in profile.vless where !vless.contains(connection) {
        vless.append(connection)
      }
      for connection in profile.hysteria2 where !hysteria2.contains(connection) {
        hysteria2.append(connection)
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
        routingPolicy: routingPolicy
      )
    )
  }
}

struct ProfileLibrary: Codable, Equatable, Sendable {
  var profiles: [ManagedProfile]
  var selectedProfileID: UUID?
  var localSOCKSEnabled: Bool
  var localSOCKSPort: UInt16

  init(
    profiles: [ManagedProfile],
    selectedProfileID: UUID?,
    localSOCKSEnabled: Bool = false,
    localSOCKSPort: UInt16 = 1082
  ) {
    self.profiles = profiles
    self.selectedProfileID = selectedProfileID
    self.localSOCKSEnabled = localSOCKSEnabled
    self.localSOCKSPort = localSOCKSPort
  }

  static let empty = ProfileLibrary(profiles: [], selectedProfileID: nil)
}
