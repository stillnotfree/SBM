import Foundation
import SBMShared

struct ManagedProfile: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var name: String
  var subscriptionURL: String
  var payload: CoreProfile?
  var updatedAt: Date?

  init(
    id: UUID = UUID(),
    name: String,
    subscriptionURL: String = "",
    payload: CoreProfile? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.subscriptionURL = subscriptionURL
    self.payload = payload
    self.updatedAt = updatedAt
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
