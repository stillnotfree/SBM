import CryptoKit
import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

private struct ReleasedV9RequestShape: Decodable {
  let protocolVersion: Int
  let profile: ReleasedV9CoreProfile?
}

private struct ReleasedV9CoreProfile: Decodable {
  let compatibility: ReleasedV9ProfileWrapper
}

private struct ReleasedV9ProfileWrapper: Decodable {
  let value: ReleasedV9Profile

  private enum CodingKeys: String, CodingKey {
    case value = "_0"
  }
}

private struct ReleasedV9Profile: Decodable {
  let connections: [ReleasedV9Connection]
}

private struct ReleasedV9Connection: Decodable {
  let outbound: ReleasedV9Outbound
}

private enum ReleasedV9Outbound: Decodable {
  private enum CodingKeys: String, CodingKey {
    case kind, vless
  }

  private enum Kind: String, Decodable {
    case vless
  }

  case vless(ReleasedV9VLESS)

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .vless:
      self = .vless(try container.decode(ReleasedV9VLESS.self, forKey: .vless))
    }
  }
}

private struct ReleasedV9VLESS: Decodable {
  let displayName: String
}

@Test func currentIPCShapeRequiresTheNewProtocolBoundary() throws {
  #expect(HelperConstants.protocolVersion == 10)
  #expect(HelperConstants.helperRevision == 50)

  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          displayName: "Current authoritative name",
          outbound: .vless(
            VLESSProfile(
              server: "203.0.113.10",
              port: 443,
              uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
              serverName: "example.test",
              fingerprint: "chrome",
              publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
              shortID: ""
            )
          )
        )
      ]
    )
  )
  let request = HelperRequest(action: .start, profile: profile)
  let encoded = try JSONEncoder().encode(request)
  let object = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
  )
  let profileObject = try #require(object["profile"] as? [String: Any])
  let compatibility = try #require(profileObject["compatibility"] as? [String: Any])
  let profilePayload = try #require(compatibility["_0"] as? [String: Any])
  let connections = try #require(profilePayload["connections"] as? [[String: Any]])
  let connection = try #require(connections.first)
  let outbound = try #require(connection["outbound"] as? [String: Any])
  let vless = try #require(outbound["vless"] as? [String: Any])
  #expect(vless["displayName"] == nil)

  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(ReleasedV9RequestShape.self, from: encoded)
  }
}

@Test func profileLibraryDefaultsLatencyIntervalForOlderStores() throws {
  let data = Data(
    """
    {
      "profiles": [],
      "selectedProfileID": null,
      "localSOCKSEnabled": false,
      "localSOCKSPort": 1082
    }
    """.utf8
  )
  let decoded = try JSONDecoder().decode(ProfileLibrary.self, from: data)
  #expect(decoded.latencyIntervalMinutes == 10)
}

@Test func immediatelyPreviousLibrarySchemaMigratesCurrentConnectionModel() throws {
  let library = ProfileLibrary(
    profiles: [
      ManagedProfile(
        name: "Schema Four",
        payload: .compatibility(
          VPNProfile(
            connections: [
              ManagedConnection(
                id: ProxyNodeID(rawValue: "node-schema-four"),
                displayName: "Schema Four Node",
                outbound: .shadowsocks(
                  ShadowsocksProfile(
                    server: "203.0.113.44",
                    port: 443,
                    method: "aes-256-gcm",
                    password: "schema-four-password"
                  ))
              )
            ]
          )
        )
      )
    ],
    selectedProfileID: nil
  )
  var root = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as? [String: Any])
  root["schemaVersion"] = 4
  let decoded = try JSONDecoder().decode(
    ProfileLibrary.self,
    from: JSONSerialization.data(withJSONObject: root)
  )
  #expect(decoded.requiresMigration)

  let rewritten = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
  #expect(rewritten["schemaVersion"] as? Int == ProfileLibrary.currentSchemaVersion)
  let profiles = try #require(rewritten["profiles"] as? [[String: Any]])
  let payload = try #require(profiles[0]["payload"] as? [String: Any])
  let compatibility = try #require(payload["compatibility"] as? [String: Any])
  let current = try #require(compatibility["_0"] as? [String: Any])
  #expect(current["connections"] != nil)
  #expect(current["vless"] == nil)
  #expect(current["hysteria2"] == nil)
  #expect(current["shadowsocks"] == nil)
}

@Test func persistentHelperStateDefaultsRecoveryAndDeferredMarkersForOlderStores() throws {
  let data = Data(
    """
    {
      "mode": "Rule",
      "selectedNode": "auto",
      "selectorTag": "proxy-selector",
      "nodes": [],
      "desiredRunning": true,
      "localSOCKSEnabled": false,
      "localSOCKSPort": 1082,
      "apiSecret": "test-secret"
    }
    """.utf8
  )
  let state = try JSONDecoder().decode(PersistentState.self, from: data)
  #expect(state.desiredRunning)
  #expect(!state.automaticRecoveryAttempted)
  #expect(!state.deferredRuntimeApplyPending)
}

@Test func legacyManagedLibraryMigratesExactAggregateIDsAndAtomicallyRewrites() throws {
  let profileID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  let sourceAID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  let sourceBID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  let realityA = VLESSProfile(
    server: "203.0.113.1", port: 443,
    uuid: "5efab93b-90d0-4904-93d6-44b4f0b00001", serverName: "a.example.com",
    fingerprint: "chrome", publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
    shortID: "", displayName: "Reality A"
  )
  let realityB = VLESSProfile(
    server: "203.0.113.2", port: 443,
    uuid: "5efab93b-90d0-4904-93d6-44b4f0b00002", serverName: "b.example.com",
    fingerprint: "firefox", publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
    shortID: "", displayName: "Reality B"
  )
  let hysteria = Hysteria2Profile(
    server: "hy.example.com", port: 443, password: "hy-password",
    serverName: "hy.example.com", displayName: "Hysteria A"
  )
  let sourceAConnections = [
    ManagedConnection(
      id: ProxyNodeID(rawValue: "vless-1"), displayName: "Reality A", outbound: .vless(realityA)
    ),
    ManagedConnection(
      id: ProxyNodeID(rawValue: "hysteria2-1"),
      displayName: "Hysteria A",
      outbound: .hysteria2(hysteria)
    ),
  ]
  let sourceA = CoreProfile.compatibility(
    VPNProfile(connections: sourceAConnections)
  )
  let sourceB = CoreProfile.compatibility(
    VPNProfile(connections: [
      ManagedConnection(
        id: ProxyNodeID(rawValue: "vless-1"), displayName: "Reality A", outbound: .vless(realityA)
      ),
      ManagedConnection(
        id: ProxyNodeID(rawValue: "vless-2"), displayName: "Reality B", outbound: .vless(realityB)
      ),
    ])
  )
  let aggregate = CoreProfile.compatibility(
    VPNProfile(
      connections: sourceAConnections,
      nodeGroups: [
        ProxyNodeGroup(
          id: sourceAID.uuidString, name: "First",
          nodes: [ProxyNodeID(rawValue: "vless-1"), ProxyNodeID(rawValue: "hysteria2-1")]
        )
      ]
    ))
  let modern = ProfileLibrary(
    profiles: [
      ManagedProfile(
        id: profileID, name: "Legacy",
        sources: [
          ManagedSource(id: sourceAID, name: "First", value: "vless://first", payload: sourceA),
          ManagedSource(
            id: sourceBID, name: "Second", value: "vless://second", excludeRegex: "Reality B",
            payload: sourceB
          ),
        ], payload: aggregate
      )
    ],
    selectedProfileID: profileID
  )
  var root = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(modern)) as? [String: Any])
  var profiles = try #require(root["profiles"] as? [[String: Any]])
  var entry = profiles[0]
  entry["payload"] = try legacyCompatibilityPayload(aggregate)
  var sources = try #require(entry["sources"] as? [[String: Any]])
  sources[0]["payload"] = try legacyCompatibilityPayload(sourceA)
  sources[1]["payload"] = try legacyCompatibilityPayload(sourceB)
  entry["sources"] = sources
  profiles[0] = entry
  root["profiles"] = profiles
  root.removeValue(forKey: "schemaVersion")
  let legacyData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

  let decoded = try JSONDecoder().decode(ProfileLibrary.self, from: legacyData)
  #expect(decoded.requiresMigration)
  let migrated = try #require(decoded.profiles.first)
  let aggregateProfile: VPNProfile
  if case .compatibility(let value) = try #require(migrated.payload) {
    aggregateProfile = value
  } else {
    fatalError()
  }
  #expect(aggregateProfile.connections.map(\.id.rawValue) == ["vless-1", "hysteria2-1"])
  #expect(
    aggregateProfile.nodeGroups?.map(\.nodes) == [
      [ProxyNodeID(rawValue: "vless-1"), ProxyNodeID(rawValue: "hysteria2-1")]
    ])
  guard case .compatibility(let migratedSourceB) = try #require(migrated.sources.last?.payload)
  else {
    Issue.record("Expected a compatibility source")
    return
  }
  #expect(migratedSourceB.connections.map(\.id.rawValue).first == "vless-1")
  #expect(migratedSourceB.connections.map(\.id.rawValue).last?.hasPrefix("node-") == true)

  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMLegacyMigration-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  FileManager.default.createFile(
    atPath: url.path, contents: legacyData,
    attributes: [.posixPermissions: 0o600])
  let loaded = try ProfileStore.loadProfileLibrary(from: url)
  let persisted = try #require(loaded)
  #expect(!persisted.requiresMigration)
  let rewritten = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  #expect(rewritten["schemaVersion"] as? Int == ProfileLibrary.currentSchemaVersion)
  let rewrittenProfiles = try #require(rewritten["profiles"] as? [[String: Any]])
  let rewrittenPayload = try #require(rewrittenProfiles[0]["payload"] as? [String: Any])
  let compatibility = try #require(rewrittenPayload["compatibility"] as? [String: Any])
  let value = try #require(compatibility["_0"] as? [String: Any])
  #expect(value["connections"] != nil)
  #expect(value["vless"] == nil)
}

@Test func persistentStateMigratesLegacySelectionAndFallsBackForCorruptMapping() throws {
  let profile = CoreProfile.compatibility(
    VPNProfile(vless: [
      VLESSProfile(
        server: "203.0.113.1", port: 443,
        uuid: "5efab93b-90d0-4904-93d6-44b4f0b00001", serverName: "a.example.com",
        fingerprint: "chrome", publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
        shortID: "", displayName: "Reality"
      )
    ]))
  var root = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
  root = try legacyCompatibilityPayload(profile)
  let state: [String: Any] = [
    "profile": root,
    "selectedNode": "vless-1",
    "nodes": [["id": "vless-1", "name": "Reality"]],
    "apiSecret": "test-secret",
  ]
  let preserved = try JSONDecoder().decode(
    PersistentState.self, from: JSONSerialization.data(withJSONObject: state))
  #expect(preserved.selectedNode == ProxyNodeID(rawValue: "vless-1"))
  #expect(preserved.nodes.first?.kind == .vless)
  var corrupt = state
  corrupt["selectedNode"] = "vless-99"
  let recovered = try JSONDecoder().decode(
    PersistentState.self, from: JSONSerialization.data(withJSONObject: corrupt))
  #expect(recovered.selectedNode == .auto)
}

@Test func persistentStateDuplicateManagedIDsFailClosedWithoutTrapping() throws {
  let outbound = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "ss.example.com",
      port: 443,
      method: "aes-128-gcm",
      password: "password",
      displayName: "Shadowsocks"
    ))
  let duplicateID = ProxyNodeID(rawValue: "node-duplicate")
  let profile = CoreProfile.compatibility(
    VPNProfile(connections: [
      ManagedConnection(id: duplicateID, outbound: outbound),
      ManagedConnection(id: duplicateID, outbound: outbound),
    ]))
  let state: [String: Any] = [
    "profile": try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)),
    "selectedNode": duplicateID.rawValue,
    "nodes": [["id": duplicateID.rawValue, "name": "Duplicate"]],
    "apiSecret": "test-secret",
  ]

  let decoded = try JSONDecoder().decode(
    PersistentState.self,
    from: JSONSerialization.data(withJSONObject: state)
  )
  #expect(decoded.selectedNode == .auto)
}

@Test func failedLegacyMigrationWriteDoesNotQuarantineValidJSONAsCorrupt() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMMigrationWriteFailure-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try? FileManager.default.removeItem(at: directory)
  }
  let url = directory.appendingPathComponent("profiles.json")
  let validLegacy = Data(
    """
    {"profiles":[],"selectedProfileID":null,"localSOCKSEnabled":false,"localSOCKSPort":1082}
    """.utf8)
  FileManager.default.createFile(
    atPath: url.path, contents: validLegacy,
    attributes: [.posixPermissions: 0o600])
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
  do {
    _ = try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
    Issue.record("Expected the atomic migration write to fail")
  } catch let failure as ProfileStoreFailure {
    if case .invalidJSON = failure {
      Issue.record("Valid legacy JSON was misclassified as invalid")
    }
  } catch {
    // The underlying write failure is the expected fail-closed outcome.
  }
  let preserved = try FileManager.default.contentsOfDirectory(
    at: directory, includingPropertiesForKeys: nil
  )
  .filter { $0.lastPathComponent.hasPrefix("profiles.invalid-") }
  #expect(preserved.isEmpty)
  #expect(try Data(contentsOf: url) == validLegacy)
}

@Test func profileLibraryRejectsUnknownOrSchemaMismatchedManagedConnectionEncoding() throws {
  let future = Data(
    """
    {"schemaVersion":6,"profiles":[],"selectedProfileID":null,"localSOCKSEnabled":false,"localSOCKSPort":1082}
    """.utf8)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(ProfileLibrary.self, from: future)
  }
  let vless = VLESSProfile(
    server: "203.0.113.1", port: 443,
    uuid: "5efab93b-90d0-4904-93d6-44b4f0b00001", serverName: "a.example.com",
    fingerprint: "chrome", publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
    shortID: "", displayName: "Reality"
  )
  let payload = CoreProfile.compatibility(VPNProfile(vless: [vless]))
  let current = ProfileLibrary(
    profiles: [ManagedProfile(name: "Current", payload: payload)], selectedProfileID: nil)
  var root = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
  var profiles = try #require(root["profiles"] as? [[String: Any]])
  profiles[0]["payload"] = try legacyCompatibilityPayload(payload)
  root["profiles"] = profiles
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(
      ProfileLibrary.self, from: JSONSerialization.data(withJSONObject: root))
  }
}

private func legacyCompatibilityPayload(_ profile: CoreProfile) throws -> [String: Any] {
  guard case .compatibility = profile else { fatalError() }
  var root = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
  var wrapper = try #require(root["compatibility"] as? [String: Any])
  var value = try #require(wrapper["_0"] as? [String: Any])
  let connections = try #require(value["connections"] as? [[String: Any]])
  var vless: [[String: Any]] = []
  var hysteria2: [[String: Any]] = []
  var shadowsocks: [[String: Any]] = []
  for connection in connections {
    let displayName = try #require(connection["displayName"] as? String)
    let outbound = try #require(connection["outbound"] as? [String: Any])
    let kind = try #require(outbound["kind"] as? String)
    var payload: [String: Any]
    switch kind {
    case "vless": payload = try #require(outbound["vless"] as? [String: Any])
    case "hysteria2": payload = try #require(outbound["hysteria2"] as? [String: Any])
    case "shadowsocks": payload = try #require(outbound["shadowsocks"] as? [String: Any])
    default: continue
    }
    payload["displayName"] = displayName
    switch kind {
    case "vless": vless.append(payload)
    case "hysteria2": hysteria2.append(payload)
    case "shadowsocks": shadowsocks.append(payload)
    default: break
    }
  }
  value.removeValue(forKey: "connections")
  value["vless"] = vless
  value["hysteria2"] = hysteria2
  value["shadowsocks"] = shadowsocks
  wrapper["_0"] = value
  root["compatibility"] = wrapper
  return root
}

@Test func desiredRuntimeRecoveryAllowsOnlyOneAutomaticAttempt() {
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      desiredRunning: false,
      coreRunning: true,
      profileAvailable: true,
      configurationAvailable: true,
      recoveryAlreadyAttempted: false
    ) == .stop
  )
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      desiredRunning: true,
      coreRunning: true,
      profileAvailable: true,
      configurationAvailable: true,
      recoveryAlreadyAttempted: false
    ) == .noAction
  )
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      desiredRunning: true,
      coreRunning: false,
      profileAvailable: true,
      configurationAvailable: true,
      recoveryAlreadyAttempted: false
    ) == .attemptRecovery
  )
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      desiredRunning: true,
      coreRunning: false,
      profileAvailable: true,
      configurationAvailable: true,
      recoveryAlreadyAttempted: true
    ) == .disableDesiredState
  )
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      desiredRunning: true,
      coreRunning: false,
      profileAvailable: false,
      configurationAvailable: true,
      recoveryAlreadyAttempted: false
    ) == .disableDesiredState
  )
}

@Test func exhaustedHelperRecoveryDoesNotTriggerAutomaticConnection() {
  #expect(
    !AutomaticConnectionPolicy.shouldConnect(
      didAttemptAutomaticConnection: false,
      automaticRecoveryExhausted: true,
      helperReady: true,
      profileAvailable: true,
      coreRunningForSelectedProfile: false
    )
  )
  #expect(
    !AutomaticConnectionPolicy.shouldConnect(
      didAttemptAutomaticConnection: true,
      automaticRecoveryExhausted: false,
      helperReady: true,
      profileAvailable: true,
      coreRunningForSelectedProfile: false
    )
  )
  #expect(
    AutomaticConnectionPolicy.shouldConnect(
      didAttemptAutomaticConnection: false,
      automaticRecoveryExhausted: false,
      helperReady: true,
      profileAvailable: true,
      coreRunningForSelectedProfile: false
    )
  )
}

@Test func helperResponseDefaultsMissingRecoverySignalForOlderHelpers() throws {
  let response = HelperResponse(success: true, coreRunning: false, message: "ready")
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
  object.removeValue(forKey: "automaticRecoveryExhausted")
  let legacy = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder().decode(HelperResponse.self, from: legacy)
  #expect(!decoded.automaticRecoveryExhausted)
  #expect(decoded.runtimeOutcome == .applied)
}

@Test func helperResponseRoundTripsReconnectRequiredOutcome() throws {
  let response = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: UUID(uuidString: "00000000-0000-0000-0000-000000000044"),
    runtimeOutcome: .reconnectRequired,
    message: HelperRuntimeOutcome.reconnectRequired.userMessage!
  )

  let decoded = try JSONDecoder().decode(
    HelperResponse.self,
    from: JSONEncoder().encode(response)
  )
  #expect(decoded.runtimeOutcome == .reconnectRequired)
  #expect(decoded.message == "Changes ready to apply")
}

@Test func restoredCoreMetadataUsesPostRenameFileIdentity() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMCoreRollbackMetadataTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let backup = directory.appendingPathComponent("sing-box.backup")
  let candidate = directory.appendingPathComponent("sing-box.rollback")
  let restored = directory.appendingPathComponent("sing-box")
  let contents = Data("previous reviewed core".utf8)
  try contents.write(to: backup)
  try FileManager.default.copyItem(at: backup, to: candidate)
  let backupIdentity = try #require(CoreFileIdentity.read(backup))
  let candidateIdentity = try #require(CoreFileIdentity.read(candidate))
  #expect(backupIdentity.inode != candidateIdentity.inode)

  try FileManager.default.moveItem(at: candidate, to: restored)
  let restoredIdentity = try #require(CoreFileIdentity.read(restored))
  let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
  let metadata = CoreMetadata(
    digest: digest,
    identity: restoredIdentity,
    version: "sing-box version previous-reviewed"
  )

  #expect(metadata.matches(restoredIdentity))
  #expect(!metadata.matches(backupIdentity))
  #expect(
    try JSONDecoder().decode(CoreMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
}

@Test func profileLibraryRequiresPositiveLatencyIntervalWithoutSmallUpperCap() throws {
  let library = ProfileLibrary(
    profiles: [],
    selectedProfileID: nil,
    latencyIntervalMinutes: 100_000
  )
  #expect(library.latencyIntervalMinutes == 100_000)
}

@Test func generatedSubscriptionHWIDUsesCanonicalUUIDFormat() {
  let hardwareID = SubscriptionHeaders.makeHardwareID()
  #expect(UUID(uuidString: hardwareID) != nil)
  #expect(hardwareID.count == 36)
  #expect(hardwareID == hardwareID.uppercased())
}

@Test func resettingRequestPresetPreservesHWID() {
  let original = SubscriptionHeaders(
    userAgent: "Custom/1.0",
    appVersion: nil,
    deviceOS: "CustomOS",
    hardwareID: "stable-device-id"
  )

  let reset = original.resettingRequestPreset()

  #expect(reset.userAgent == SubscriptionHeaders.defaultUserAgent)
  #expect(reset.appVersion == SubscriptionHeaders.defaultAppVersion)
  #expect(reset.deviceOS == SubscriptionHeaders.defaultDeviceOS)
  #expect(reset.hardwareID == "stable-device-id")
}

@Test func newSourcesUseCapturedHappPresetWithoutMigratingStoredHeaders() throws {
  let fresh = ManagedSource()
  #expect(fresh.headers.userAgent == "Happ/5.4.0/ios/2607311456556")
  #expect(fresh.headers.appVersion == "5.4.0")
  #expect(fresh.headers.deviceOS == "iOS")
  #expect(UUID(uuidString: fresh.headers.hardwareID) != nil)
  #expect(fresh.headers.hardwareID.count == 36)
  #expect(fresh.headers.hardwareID == fresh.headers.hardwareID.uppercased())

  let stored = ManagedSource(
    name: "Existing",
    headers: SubscriptionHeaders(
      userAgent: "Custom Existing Client/7.0",
      appVersion: nil,
      deviceOS: "CustomOS",
      hardwareID: "existing-hwid"
    )
  )
  let restored = try JSONDecoder().decode(
    ManagedSource.self,
    from: JSONEncoder().encode(stored)
  )
  #expect(restored.headers.userAgent == "Custom Existing Client/7.0")
  #expect(restored.headers.appVersion == nil)
  #expect(restored.headers.deviceOS == "CustomOS")
  #expect(restored.headers.hardwareID == "existing-hwid")
}

@Test func profileStorePreservesMalformedLibraryAndReportsFailure() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMInvalidStoreTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let malformed = Data("{not-json".utf8)
  FileManager.default.createFile(
    atPath: url.path,
    contents: malformed,
    attributes: [.posixPermissions: 0o600]
  )

  #expect(throws: ProfileStoreFailure.self) {
    try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
  }
  #expect(try Data(contentsOf: url) == malformed)
  let preserved = try FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: nil
  ).filter { $0.lastPathComponent.hasPrefix("profiles.invalid-") }
  #expect(preserved.count == 1)
  #expect(try Data(contentsOf: preserved[0]) == malformed)
}

@Test func profileStoreImportsValidatedRecoveryWithoutLosingDestination() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMRecoveryImportTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }

  let destination = directory.appendingPathComponent("profiles.json")
  let source = directory.appendingPathComponent("recovered.json")
  let original = Data("{broken".utf8)
  FileManager.default.createFile(
    atPath: destination.path,
    contents: original,
    attributes: [.posixPermissions: 0o600]
  )
  let recovered = ProfileLibrary(
    profiles: [ManagedProfile(name: "Recovered")],
    selectedProfileID: nil
  )
  FileManager.default.createFile(
    atPath: source.path,
    contents: try JSONEncoder().encode(recovered),
    attributes: [.posixPermissions: 0o600]
  )

  let imported = try ProfileStore.importProfileLibrary(from: source, to: destination)
  #expect(imported == recovered)
  #expect(
    try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: destination)) == recovered)
}

@Test func profileStoreRejectsMalformedRecoveryBeforeReplacingDestination() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMInvalidRecoveryTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }

  let destination = directory.appendingPathComponent("profiles.json")
  let source = directory.appendingPathComponent("recovered.json")
  let original = try JSONEncoder().encode(ProfileLibrary.empty)
  FileManager.default.createFile(
    atPath: destination.path,
    contents: original,
    attributes: [.posixPermissions: 0o600]
  )
  FileManager.default.createFile(
    atPath: source.path,
    contents: Data("{broken".utf8),
    attributes: [.posixPermissions: 0o600]
  )

  #expect(throws: ProfileStoreFailure.self) {
    try ProfileStore.importProfileLibrary(from: source, to: destination)
  }
  #expect(try Data(contentsOf: destination) == original)
}

@Test func profileStoreRejectsSymlinkedRecoveryBeforeReplacingDestination() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMSymlinkRecoveryTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }

  let destination = directory.appendingPathComponent("profiles.json")
  let target = directory.appendingPathComponent("recovered-target.json")
  let source = directory.appendingPathComponent("recovered-link.json")
  let original = try JSONEncoder().encode(ProfileLibrary.empty)
  FileManager.default.createFile(
    atPath: destination.path,
    contents: original,
    attributes: [.posixPermissions: 0o600]
  )
  FileManager.default.createFile(
    atPath: target.path,
    contents: try JSONEncoder().encode(ProfileLibrary.empty),
    attributes: [.posixPermissions: 0o600]
  )
  try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)

  #expect(throws: ProfileStoreFailure.self) {
    try ProfileStore.importProfileLibrary(from: source, to: destination)
  }
  #expect(try Data(contentsOf: destination) == original)
}

@Test func profileStoreResetPreservesOriginalBeforeStartingEmpty() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMRecoveryResetTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }

  let destination = directory.appendingPathComponent("profiles.json")
  let original = Data("{broken".utf8)
  FileManager.default.createFile(
    atPath: destination.path,
    contents: original,
    attributes: [.posixPermissions: 0o600]
  )

  let reset = try ProfileStore.resetProfileLibrary(at: destination)
  #expect(reset == .empty)
  #expect(
    try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: destination)) == .empty
  )
  let preserved = try FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: nil
  ).filter { $0.lastPathComponent.hasPrefix("profiles.invalid-") }
  #expect(preserved.count == 1)
  #expect(try Data(contentsOf: preserved[0]) == original)
}

@Test func diagnosticRedactionRemovesKnownAndPatternSecrets() throws {
  let sourceURL = "https://user:subscription-token@example.com/private"
  let profile = try SubscriptionClient.parsePayload(
    "hysteria2://proxy-password@vpn.example.com:443/?sni=vpn.example.com#Hysteria2"
  )
  let profiles = [
    ManagedProfile(
      name: "Private",
      sources: [
        ManagedSource(
          name: "Provider",
          value: sourceURL,
          headers: SubscriptionHeaders(hardwareID: "private-hwid-value"),
          payload: profile
        )
      ],
      payload: profile
    )
  ]
  let report = SecretRedactor.redact(
    "URL \(sourceURL) HWID private-hwid-value password proxy-password Authorization: Bearer auth-token",
    secrets: DiagnosticSecrets.collect(from: profiles)
  )

  for secret in [
    sourceURL, "subscription-token", "private-hwid-value", "proxy-password", "auth-token",
  ] {
    #expect(!report.contains(secret))
  }
}

@Test func pinnedCoreMatchesGeneratedBuildInformation() throws {
  let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".vendor/sing-box")
  let digest = SHA256.hash(data: try Data(contentsOf: core))
    .map { String(format: "%02x", $0) }.joined()
  #expect(digest == CoreBuildInfo.signedSHA256)

  let process = Process()
  let output = Pipe()
  process.executableURL = core
  process.arguments = ["version"]
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  let versionOutput = String(
    decoding: output.fileHandleForReading.readDataToEndOfFile(),
    as: UTF8.self
  )
  #expect(process.terminationStatus == 0)
  #expect(versionOutput.hasPrefix("sing-box version \(CoreBuildInfo.version)\n"))
}

@Test func profileStoreWritesCredentialsWithUserOnlyPermissions() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMStoreTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let library = ProfileLibrary(
    profiles: [
      ManagedProfile(
        name: "Private",
        sources: [
          ManagedSource(
            name: "Private subscription",
            value: "https://user:secret@example.com/subscription",
            headers: SubscriptionHeaders(
              userAgent: "Custom Client/1.0",
              deviceOS: "macOS",
              hardwareID: "private-hwid"
            )
          )
        ]
      )
    ],
    selectedProfileID: nil
  )

  try ProfileStore.saveProfileLibrary(library, to: url)
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  let decoded = try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: url))
  #expect(decoded == library)
}

@Test func importedRootOwnedSectionsAreReplaced() throws {
  let source = Data(
    """
    {
      "log": { "output": "/tmp/untrusted.log", "level": "trace" },
      "inbounds": [
        { "type": "mixed", "tag": "untrusted-listener", "listen": "0.0.0.0", "listen_port": 8080 }
      ],
      "outbounds": [
        { "type": "socks", "tag": "proxy", "server": "203.0.113.10", "server_port": 1080 }
      ],
      "experimental": {
        "clash_api": { "external_controller": "0.0.0.0:9090", "secret": "untrusted" }
      }
    }
    """.utf8)
  let profile = try NativeProfileParser.parse(source)
  let built = try ConfigBuilder(
    cachePath: "/safe/cache.db",
    apiSecret: "safe-secret"
  ).makeConfiguration(profile: .native(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let log = try #require(root["log"] as? [String: Any])
  #expect(log["output"] as? String == "/dev/null")
  let inbounds = try #require(root["inbounds"] as? [[String: Any]])
  #expect(inbounds.count == 1)
  #expect(inbounds[0]["tag"] as? String == "sbm-tun-in")
  #expect(inbounds[0]["mtu"] as? Int == 1400)
  let route = try #require(root["route"] as? [String: Any])
  let rules = try #require(route["rules"] as? [[String: Any]])
  #expect(
    !rules.contains {
      ($0["protocol"] as? String) == "quic"
        && ($0["action"] as? String) == "reject"
    })
  let experimental = try #require(root["experimental"] as? [String: Any])
  let api = try #require(experimental["clash_api"] as? [String: Any])
  #expect(api["external_controller"] as? String == "127.0.0.1:19090")
  #expect(api["secret"] as? String == "safe-secret")
}

@Test func nativeProfileRoutesUnmatchedTrafficThroughManagedSelector() throws {
  let source = Data(
    """
    {
      "outbounds": [
        { "type": "socks", "tag": "proxy", "server": "203.0.113.10", "server_port": 1080 },
        { "type": "direct", "tag": "bypass" }
      ],
      "route": {
        "rules": [
          { "domain_suffix": ["example.org"], "action": "route", "outbound": "bypass" }
        ],
        "final": "bypass"
      }
    }
    """.utf8)
  let profile = try NativeProfileParser.parse(source)
  let built = try ConfigBuilder(
    cachePath: "/safe/cache.db",
    apiSecret: "safe-secret"
  ).makeConfiguration(
    profile: .native(profile),
    mode: .rule,
    selectedNode: ProxyNodeID(rawValue: "proxy")
  )
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let route = try #require(root["route"] as? [String: Any])
  #expect(route["final"] as? String == "sbm-selector")
  let rules = try #require(route["rules"] as? [[String: Any]])
  #expect(rules.contains { ($0["outbound"] as? String) == "bypass" })
}

@Test func nativeProfileKeepsRuleDNSAndOverridesOnlyDirectGlobalModes() throws {
  let source = Data(
    """
    {
      "dns": {
        "servers": [
          { "type": "tls", "tag": "user-dns", "server": "1.1.1.1" }
        ],
        "rules": [
          { "domain_suffix": ["example.org"], "action": "route", "server": "user-dns" }
        ],
        "final": "user-dns"
      },
      "outbounds": [
        { "type": "socks", "tag": "proxy", "server": "203.0.113.10", "server_port": 1080 }
      ]
    }
    """.utf8)
  let profile = try NativeProfileParser.parse(source)
  let built = try ConfigBuilder(
    cachePath: "/safe/cache.db",
    apiSecret: "safe-secret"
  ).makeConfiguration(profile: .native(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let dns = try #require(root["dns"] as? [String: Any])
  let servers = try #require(dns["servers"] as? [[String: Any]])
  #expect(
    servers.compactMap { $0["tag"] as? String } == [
      "user-dns", "sbm-dns-local", "sbm-dns-remote",
    ])
  let rules = try #require(dns["rules"] as? [[String: Any]])
  #expect(rules[0]["clash_mode"] as? String == "Direct")
  #expect(rules[1]["clash_mode"] as? String == "Global")
  #expect((rules[2]["domain_suffix"] as? [String]) == ["example.org"])
  #expect(dns["final"] as? String == "user-dns")
}

@Test func nativeProfileRejectsSystemManagedEndpoint() throws {
  let source = Data(
    """
    {
      "outbounds": [
        { "type": "socks", "tag": "proxy", "server": "203.0.113.10", "server_port": 1080 }
      ],
      "endpoints": [
        { "type": "wireguard", "tag": "wg", "system": true }
      ]
    }
    """.utf8)
  let profile = try NativeProfileParser.parse(source)
  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .native(profile), mode: .rule, selectedNode: .auto)
  }
}

@Test func nativeProfileRejectsUnsupportedPrivilegedServices() throws {
  let source = Data(
    """
    {
      "outbounds": [
        { "type": "socks", "tag": "proxy", "server": "203.0.113.10", "server_port": 1080 }
      ],
      "services": [
        { "type": "resolved", "listen": "0.0.0.0" }
      ]
    }
    """.utf8)
  let profile = try NativeProfileParser.parse(source)
  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .native(profile), mode: .rule, selectedNode: .auto)
  }
}

@Test func nativeProfileRejectsMalformedRoutingInsteadOfDiscardingIt() throws {
  let source = Data(
    """
    {
      "outbounds": [
        { "type": "socks", "tag": "proxy", "server": "203.0.113.10", "server_port": 1080 }
      ],
      "route": { "rules": "not-an-array" }
    }
    """.utf8)
  let profile = try NativeProfileParser.parse(source)
  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .native(profile), mode: .rule, selectedNode: .auto)
  }
}

@Test func nativeProfileRejectsExcessiveNesting() throws {
  var nested: Any = "leaf"
  for index in 0..<40 {
    nested = ["layer\(index)": nested]
  }
  let source = try JSONSerialization.data(withJSONObject: [
    "outbounds": [
      [
        "type": "socks",
        "tag": "proxy",
        "server": "203.0.113.10",
        "server_port": 1080,
        "headers": ["X-Test": nested],
      ]
    ]
  ])
  let profile = try NativeProfileParser.parse(source)

  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .native(profile), mode: .rule, selectedNode: .auto)
  }
}

@Test func nativeProfileRejectsOversizedCollections() throws {
  let source = try JSONSerialization.data(withJSONObject: [
    "outbounds": [
      [
        "type": "socks",
        "tag": "proxy",
        "server": "203.0.113.10",
        "server_port": 1080,
        "headers": ["X-Test": Array(repeating: "value", count: 5_000)],
      ]
    ]
  ])
  let profile = try NativeProfileParser.parse(source)

  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .native(profile), mode: .rule, selectedNode: .auto)
  }
}
