import Darwin
import Foundation
import SBMShared
import Testing
import XCTest

@testable import SBM
@testable import SBMHelper

private enum ProfileLibraryPersistenceTestFailure: Error {
  case persistence
}

@MainActor
private func waitForProfileLibraryCondition(
  timeout: Duration = .seconds(2),
  _ condition: @MainActor () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !condition(), clock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return condition()
}

@MainActor
private final class PersistenceReadyHelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState = .enabled
  var legacyRegistrationState: HelperRegistrationState = .notRegistered

  func register() throws {}
  func unregister() async throws {}
  func unregisterLegacy() async throws {}
  func openSystemSettings() {}
}

private actor RuntimeRequestRecorder {
  private var actions: [String] = []
  private var requests: [HelperRequest] = []
  private let response: HelperResponse
  private var actionWaiter:
    (
      minimumCount: Int,
      continuation: CheckedContinuation<[String], Never>
    )?

  init(
    response: HelperResponse = HelperResponse(
      success: true, coreRunning: false, message: "accepted")
  ) {
    self.response = response
  }

  func send(_ request: HelperRequest) -> HelperResponse {
    actions.append(request.action.rawValue)
    requests.append(request)
    if let actionWaiter, actions.count >= actionWaiter.minimumCount {
      self.actionWaiter = nil
      actionWaiter.continuation.resume(returning: actions)
    }
    return response
  }

  func waitForActions(_ count: Int) async -> [String] {
    if actions.count >= count { return actions }
    return await withCheckedContinuation { continuation in
      precondition(actionWaiter == nil)
      actionWaiter = (count, continuation)
    }
  }

  func recordedActions() -> [String] {
    actions
  }

  func recordedRequests() -> [HelperRequest] {
    requests
  }
}

private actor FreshInstallEffectRecorder {
  private var subscriptionFetches = 0
  private var helperRequests = 0
  private var validations = 0

  func recordSubscriptionFetch(_ value: String) {
    #expect(value.isEmpty)
    subscriptionFetches += 1
  }

  func send(_ request: HelperRequest) -> HelperResponse {
    helperRequests += 1
    return HelperResponse(success: true, coreRunning: false, message: request.action.rawValue)
  }

  func validate() -> HelperResponse {
    validations += 1
    return HelperResponse(success: true, coreRunning: false, message: "validated")
  }

  func counts() -> (subscriptionFetches: Int, helperRequests: Int, validations: Int) {
    (subscriptionFetches, helperRequests, validations)
  }
}

private func profileLibrary(
  routingMode: RoutingMode = .rule,
  selectedNodeID: ProxyNodeID = .auto
) -> ProfileLibrary {
  let profileID = UUID()
  let connection = ManagedConnection(
    id: ProxyNodeID(rawValue: "node-selected"),
    displayName: "Selected",
    outbound: .shadowsocks(
      ShadowsocksProfile(
        server: "proxy.example.test",
        port: 443,
        method: "aes-128-gcm",
        password: "test-password"
      )
    )
  )
  let profile = ManagedProfile(
    id: profileID,
    name: "Current",
    payload: .compatibility(VPNProfile(connections: [connection]))
  )
  return ProfileLibrary(
    profiles: [profile],
    selectedProfileID: profileID,
    routingMode: routingMode,
    selectedNodeID: selectedNodeID
  )
}

private func secureDirectory(_ name: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-\(name)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  return directory
}

private func writeSecureFile(_ data: Data, to url: URL) throws {
  try data.write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func profileBackupSourceData() throws -> Data {
  var data = Data([0x20, 0x0a])
  data.append(try JSONEncoder().encode(profileLibrary()))
  data.append(contentsOf: [0x0a])
  return data
}

private func filePermissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func expectProfileBackupFailure(
  from sourceURL: URL,
  to destinationURL: URL
) throws {
  var failed = false
  do {
    try ProfileStore.exportProfileLibrary(from: sourceURL, to: destinationURL)
  } catch {
    failed = true
  }
  #expect(failed)
}

private func expectUnclassifiedProfileStoreFailure(_ operation: () throws -> Void) {
  do {
    try operation()
    Issue.record("Expected unclassified profile-library JSON to be rejected.")
  } catch let failure as ProfileStoreFailure {
    if case .unclassifiedJSON = failure {
      #expect(!failure.isMalformedCurrentLibrary)
    } else {
      Issue.record("Expected unclassified JSON, got \(failure).")
    }
  } catch {
    Issue.record("Expected ProfileStoreFailure, got \(error).")
  }
}

private func preservedCopies(in directory: URL) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: nil
  ).filter { $0.lastPathComponent.hasPrefix("profiles.invalid-") }
}

@Test func schema11EncodesAndDecodesOnlyTheCurrentPersistedShape() throws {
  let managedProfile = ManagedProfile(
    name: "Current",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "node-selected"),
          displayName: "Selected",
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "proxy.example.test",
              port: 443,
              method: "aes-128-gcm",
              password: "test-password"
            )
          )
        )
      ])
    )
  )
  let library = ProfileLibrary(
    profiles: [managedProfile],
    selectedProfileID: nil,
    routingMode: .global,
    selectedNodeID: ProxyNodeID(rawValue: "node-selected"),
    localSOCKSEnabled: true,
    localSOCKSPort: 1083,
    latencyIntervalMinutes: 15,
    latencyTestURL: "https://example.test/health",
    ipv6Enabled: true
  )

  let data = try JSONEncoder().encode(library)
  let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(root["schemaVersion"] as? Int == 11)
  #expect(ProfileLibrary.empty.routingMode == .rule)
  #expect(ProfileLibrary.empty.selectedNodeID == .auto)
  #expect(root["selectedProfileID"] is NSNull)
  #expect(root["routingMode"] as? String == RoutingMode.global.rawValue)
  #expect(root["selectedNodeID"] as? String == "node-selected")
  #expect(
    Set(root.keys)
      == Set([
        "profiles", "selectedProfileID", "routingMode", "selectedNodeID",
        "localSOCKSEnabled", "localSOCKSPort", "latencyIntervalMinutes",
        "latencyTestURL", "ipv6Enabled", "dnsSettings", "schemaVersion",
      ])
  )
  #expect(try JSONDecoder().decode(ProfileLibrary.self, from: data) == library)
  let persistedProfiles = try #require(root["profiles"] as? [[String: Any]])
  let persistedProfile = try #require(persistedProfiles.first)
  let payload = try #require(persistedProfile["payload"] as? [String: Any])
  #expect(Set(payload.keys) == ["compatibility"])
  let compatibilityCase = try #require(payload["compatibility"] as? [String: Any])
  #expect(Set(compatibilityCase.keys) == ["_0"])
  let managedPayload = try #require(compatibilityCase["_0"] as? [String: Any])
  #expect(
    Set(managedPayload.keys)
      == Set([
        "connections", "nodeGroups", "applicationRoutingRules", "websiteRoutingRules",
        "autoExcludedNodeIDs",
      ])
  )
  #expect(managedPayload["routingPolicy"] == nil)
}

@Test func schema11MissingDNSSettingsUsesDefaultsAndWritesCurrentField() throws {
  let data = try JSONEncoder().encode(ProfileLibrary.empty)
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "dnsSettings")
  let missing = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(ProfileLibrary.self, from: missing)
  #expect(decoded.dnsSettings == .defaults)
  let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
  let root = try #require(encoded as? [String: Any])
  #expect(root["schemaVersion"] as? Int == 11)
  #expect(root["dnsSettings"] != nil)
}

@Test func schema11Hysteria2PortHoppingRoundTripsAndUsesExistingBackupPath() throws {
  func library(portHoppingRanges: [Hysteria2PortRange]?) -> ProfileLibrary {
    let port = portHoppingRanges?.first?.start ?? 443
    let connection = ManagedConnection(
      id: ProxyNodeID(rawValue: "node-hysteria2"),
      displayName: "Hysteria2",
      outbound: .hysteria2(
        Hysteria2Profile(
          server: "vpn.example.test",
          port: port,
          password: "test-password",
          serverName: "vpn.example.test",
          portHoppingRanges: portHoppingRanges
        )
      )
    )
    let profile = ManagedProfile(
      name: "Hysteria2",
      payload: .compatibility(VPNProfile(connections: [connection]))
    )
    return ProfileLibrary(profiles: [profile], selectedProfileID: nil)
  }

  let ordinary = library(portHoppingRanges: nil)
  let ordinaryData = try JSONEncoder().encode(ordinary)
  let ordinaryJSON = String(decoding: ordinaryData, as: UTF8.self)
  #expect(!ordinaryJSON.contains("portHoppingRanges"))
  #expect(try JSONDecoder().decode(ProfileLibrary.self, from: ordinaryData) == ordinary)

  let hopping = library(
    portHoppingRanges: [
      Hysteria2PortRange(start: 1234, end: 1234),
      Hysteria2PortRange(start: 5678, end: 9012),
    ]
  )
  let hoppingData = try JSONEncoder().encode(hopping)
  let hoppingRoot = try #require(JSONSerialization.jsonObject(with: hoppingData) as? [String: Any])
  #expect(hoppingRoot["schemaVersion"] as? Int == 11)
  #expect(String(decoding: hoppingData, as: UTF8.self).contains("portHoppingRanges"))
  #expect(try JSONDecoder().decode(ProfileLibrary.self, from: hoppingData) == hopping)

  let directory = try secureDirectory("BackupHysteria2Hopping")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("profiles.json")
  let backup = directory.appendingPathComponent("SBM-Profiles.json")
  let restoredURL = directory.appendingPathComponent("restored.json")
  try ProfileStore.saveProfileLibrary(hopping, to: source)
  try ProfileStore.exportProfileLibrary(from: source, to: backup)
  let restored = try ProfileStore.importProfileLibrary(from: backup, to: restoredURL)
  let persisted = try #require(try ProfileStore.loadProfileLibrary(from: restoredURL))
  #expect(restored == hopping)
  #expect(persisted == hopping)
}

@Test func managedDNSSettingsRoundTripAndRejectInvalidValues() throws {
  let custom = try ManagedDNSSettings(
    direct: .customDoH("  https://resolver.example.test:8443/dns-query  "),
    proxy: .yandex
  ).validated()
  #expect(custom.direct == .customDoH("https://resolver.example.test:8443/dns-query"))
  for choice in [
    ManagedDNSChoice.cloudflare, .google, .yandex, .quad9, .adguard,
  ] {
    let library = ProfileLibrary(
      profiles: [], selectedProfileID: nil,
      dnsSettings: ManagedDNSSettings(direct: choice, proxy: .cloudflare)
    )
    let decoded = try JSONDecoder().decode(
      ProfileLibrary.self,
      from: JSONEncoder().encode(library)
    )
    #expect(decoded.dnsSettings == library.dnsSettings)
  }
  var customLibrary = ProfileLibrary.empty
  customLibrary.dnsSettings = custom
  let decodedCustom = try JSONDecoder().decode(
    ProfileLibrary.self,
    from: JSONEncoder().encode(customLibrary)
  )
  #expect(decodedCustom.dnsSettings == custom)

  #expect(throws: DecodingError.self) {
    try ManagedDNSSettings(direct: .system, proxy: .system).validated()
  }
  for value in [
    "http://resolver.example.test/dns-query", "https:///dns-query",
    "https://user:secret@resolver.example.test/dns-query",
    "https://resolver.example.test/dns-query?x=1",
    "https://resolver.example.test/dns-query#fragment",
    "https://resolver.example.test:0/dns-query",
    "https://resolver.example.test:65536/dns-query",
    "https://resolver.example.test:bad/dns-query", "https://resolver.example.test:/dns-query",
  ] {
    #expect(throws: DecodingError.self) {
      try ManagedDNSSettings(direct: .customDoH(value), proxy: .cloudflare).validated()
    }
  }
  var invalidLibrary = ProfileLibrary.empty
  invalidLibrary.dnsSettings = ManagedDNSSettings(direct: .system, proxy: .system)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(
      ProfileLibrary.self,
      from: JSONEncoder().encode(invalidLibrary)
    )
  }
}

@Test func schema11AutoExclusionsDefaultRoundTripAndEncodeInConnectionOrder() throws {
  let firstID = ProxyNodeID(rawValue: "node-first")
  let secondID = ProxyNodeID(rawValue: "node-second")
  let outbound = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "proxy.example.test", port: 443, method: "aes-128-gcm", password: "test-password"
    ))
  let connections = [
    ManagedConnection(id: firstID, outbound: outbound),
    ManagedConnection(id: secondID, outbound: outbound),
  ]
  let profile = VPNProfile(
    connections: connections,
    autoExcludedNodeIDs: [firstID, secondID]
  )
  let data = try JSONEncoder().encode(profile)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["autoExcludedNodeIDs"] as? [String] == ["node-first", "node-second"])
  #expect(try JSONDecoder().decode(VPNProfile.self, from: data) == profile)

  var legacyProfileObject = object
  legacyProfileObject.removeValue(forKey: "autoExcludedNodeIDs")
  let withoutField = try JSONDecoder().decode(
    VPNProfile.self,
    from: JSONSerialization.data(withJSONObject: legacyProfileObject)
  )
  #expect(withoutField.autoExcludedNodeIDs.isEmpty)

  let reversed = VPNProfile(connections: connections, autoExcludedNodeIDs: [secondID, firstID])
  let reversedObject = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(reversed)) as? [String: Any]
  )
  #expect(reversedObject["autoExcludedNodeIDs"] as? [String] == ["node-first", "node-second"])
  #expect(ProfileLibrary.currentSchemaVersion == 11)
}

@Test func schema11AutoExclusionEncodingPreservesInvalidEntriesForValidation() throws {
  let nodeID = ProxyNodeID(rawValue: "node-one")
  let duplicateAndUnknown = [
    ProxyNodeID(rawValue: "unknown-node"), nodeID, nodeID,
  ]
  let profile = VPNProfile(
    connections: [
      ManagedConnection(
        id: nodeID,
        outbound: .shadowsocks(
          ShadowsocksProfile(
            server: "proxy.example.test", port: 443, method: "aes-128-gcm", password: "test"
          ))
      )
    ],
    autoExcludedNodeIDs: duplicateAndUnknown
  )
  let encoded = try JSONEncoder().encode(profile)
  let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  let expected = [nodeID, nodeID, ProxyNodeID(rawValue: "unknown-node")]
  #expect(object["autoExcludedNodeIDs"] as? [String] == ["node-one", "node-one", "unknown-node"])
  #expect(try JSONDecoder().decode(VPNProfile.self, from: encoded).autoExcludedNodeIDs == expected)
}

@Test func schema11SourceHeaderFieldsRoundTripWithoutBackfillingOldSources() throws {
  let legacySource = ManagedSource(
    name: "Legacy",
    headers: SubscriptionHeaders(
      userAgent: "Legacy Client/1.0",
      appVersion: nil,
      deviceOS: "iOS",
      deviceOSVersion: nil,
      deviceModel: nil,
      hardwareID: "legacy-hwid"
    )
  )
  let currentSource = ManagedSource(
    name: "Current",
    headers: SubscriptionHeaders(
      userAgent: "Current Client/1.0",
      appVersion: nil,
      deviceOS: "iOS",
      deviceOSVersion: "26.7",
      deviceModel: "iPhone",
      hardwareID: "current-hwid"
    )
  )
  let profile = ManagedProfile(name: "Sources", sources: [legacySource, currentSource])
  let library = ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  var root = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as? [String: Any]
  )
  var profiles = try #require(root["profiles"] as? [[String: Any]])
  var sources = try #require(profiles[0]["sources"] as? [[String: Any]])
  var legacyHeaders = try #require(sources[0]["headers"] as? [String: Any])
  legacyHeaders.removeValue(forKey: "deviceOSVersion")
  legacyHeaders.removeValue(forKey: "deviceModel")
  sources[0]["headers"] = legacyHeaders
  profiles[0]["sources"] = sources
  root["profiles"] = profiles

  let oldSchema11Data = try JSONSerialization.data(withJSONObject: root)
  let decoded = try JSONDecoder().decode(ProfileLibrary.self, from: oldSchema11Data)
  #expect(root["schemaVersion"] as? Int == 11)
  let decodedSources = try #require(decoded.profiles.first?.sources)
  #expect(decodedSources[0].headers.deviceOSVersion == nil)
  #expect(decodedSources[0].headers.deviceModel == nil)
  #expect(decodedSources[1].headers.deviceOSVersion == "26.7")
  #expect(decodedSources[1].headers.deviceModel == "iPhone")

  let reencoded = try JSONEncoder().encode(decoded)
  let reencodedRoot = try #require(
    JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
  )
  let reencodedProfiles = try #require(reencodedRoot["profiles"] as? [[String: Any]])
  let reencodedSources = try #require(reencodedProfiles[0]["sources"] as? [[String: Any]])
  let reencodedLegacyHeaders = try #require(reencodedSources[0]["headers"] as? [String: Any])
  #expect(reencodedLegacyHeaders["deviceOSVersion"] == nil)
  #expect(reencodedLegacyHeaders["deviceModel"] == nil)
  let reencodedCurrentHeaders = try #require(reencodedSources[1]["headers"] as? [String: Any])
  #expect(reencodedCurrentHeaders["deviceOSVersion"] as? String == "26.7")
  #expect(reencodedCurrentHeaders["deviceModel"] as? String == "iPhone")
}

@Test func profileStoreSaveAndLoadPreserveRoutingPreferences() throws {
  let directory = try secureDirectory("RoutingPreferences")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let library = profileLibrary(
    routingMode: .direct,
    selectedNodeID: ProxyNodeID(rawValue: "node-selected")
  )

  try ProfileStore.saveProfileLibrary(library, to: url)
  #expect(try filePermissions(url) == 0o600)
  let loadedLibrary = try ProfileStore.loadProfileLibrary(from: url)
  let loaded = try #require(loadedLibrary)
  #expect(loaded.routingMode == .direct)
  #expect(loaded.selectedNodeID == ProxyNodeID(rawValue: "node-selected"))
  #expect(try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: url)) == library)
}

@Test func profileStoreCanonicalSaveReplacesHardlinkWithoutChangingItsOtherName() throws {
  let directory = try secureDirectory("CanonicalHardlinkReplacement")
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("profiles.json")
  let secondLink = directory.appendingPathComponent("profiles-alias.json")
  let priorBytes = Data("prior canonical bytes".utf8)
  try writeSecureFile(priorBytes, to: destination)
  try FileManager.default.linkItem(at: destination, to: secondLink)

  let replacement = profileLibrary(routingMode: .direct)
  try ProfileStore.saveProfileLibrary(replacement, to: destination)

  #expect(try ProfileStore.loadProfileLibrary(from: destination) == replacement)
  #expect(try Data(contentsOf: secondLink) == priorBytes)
  var destinationInfo = stat()
  var secondLinkInfo = stat()
  #expect(lstat(destination.path, &destinationInfo) == 0)
  #expect(lstat(secondLink.path, &secondLinkInfo) == 0)
  #expect(destinationInfo.st_nlink == 1)
  #expect(secondLinkInfo.st_nlink == 1)
}

@Test func profileStoreCanonicalSaveRejectsDestinationSymlink() throws {
  let directory = try secureDirectory("CanonicalSymlinkDestination")
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appendingPathComponent("target.json")
  let targetBytes = Data("target remains unchanged".utf8)
  try writeSecureFile(targetBytes, to: target)
  let destination = directory.appendingPathComponent("profiles.json")
  try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

  do {
    try ProfileStore.saveProfileLibrary(.empty, to: destination)
    Issue.record("Canonical save must reject a symlink destination.")
  } catch {}

  #expect(try Data(contentsOf: target) == targetBytes)
  var destinationInfo = stat()
  #expect(lstat(destination.path, &destinationInfo) == 0)
  #expect((destinationInfo.st_mode & S_IFMT) == S_IFLNK)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .allSatisfy { !$0.hasPrefix(".profiles-") }
  )
}

@Test func profileStoreCanonicalSaveSyncsFileAndDirectoryInPublicationOrder() throws {
  let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Sources/SBM/ProfileStore.swift")
  let source = try String(contentsOf: sourceURL, encoding: .utf8)
  let saveStart = try #require(
    source.range(of: "static func saveProfileLibrary(_ library: ProfileLibrary, to url: URL)"))
  let backupStart = try #require(source.range(of: "private static func writeBackup"))
  let save = String(source[saveStart.lowerBound..<backupStart.lowerBound])

  let fileSync = try #require(save.range(of: "guard synchronizeDescriptor(descriptor)"))
  let fileClose = try #require(save.range(of: "let closeResult = close(descriptor)"))
  let rename = try #require(save.range(of: "Darwin.rename(temporaryURL.path, url.path)"))
  let renamed = try #require(save.range(of: "renamed = true"))
  let directorySync = try #require(
    save.range(of: "let directorySyncSucceeded = synchronizeDescriptor(directoryDescriptor)"))
  let directoryClose = try #require(
    save.range(of: "let directoryCloseResult = close(directoryDescriptor)"))

  #expect(fileSync.lowerBound < fileClose.lowerBound)
  #expect(fileClose.lowerBound < rename.lowerBound)
  #expect(rename.lowerBound < renamed.lowerBound)
  #expect(renamed.lowerBound < directorySync.lowerBound)
  #expect(directorySync.lowerBound < directoryClose.lowerBound)

  let storageStart = try #require(source.range(of: "private static func storageURL"))
  let directoryRequirement = try #require(
    source.range(of: "private static func requireSecureDirectory"))
  let storage = String(source[storageStart.lowerBound..<directoryRequirement.lowerBound])
  let parentExistenceCheck = try #require(
    storage.range(of: "if lstat(directory.path, &existingDirectoryInfo) != 0, errno != ENOENT"))
  let directoryCreation = try #require(storage.range(of: "FileManager.default.createDirectory"))
  let backupExclusion = try #require(storage.range(of: "setResourceValues(values)"))
  let parentDescriptor = try #require(
    storage.range(of: "let parentDescriptor = try openVerifiedDirectoryDescriptor("))
  let parentDescriptorSync = try #require(
    storage.range(of: "let parentSyncSucceeded = synchronizeDescriptor(parentDescriptor)"))
  let parentClose = try #require(
    storage.range(of: "let parentCloseResult = close(parentDescriptor)"))

  #expect(parentExistenceCheck.lowerBound < directoryCreation.lowerBound)
  #expect(directoryCreation.lowerBound < backupExclusion.lowerBound)
  #expect(backupExclusion.lowerBound < parentDescriptor.lowerBound)
  #expect(parentDescriptor.lowerBound < parentDescriptorSync.lowerBound)
  #expect(parentDescriptorSync.lowerBound < parentClose.lowerBound)
  #expect(!storage.contains("if !directoryExisted"))
}

@Test func profileStoreRejectsDuplicateProfileIDsOnLoad() throws {
  let directory = try secureDirectory("DuplicateProfileIDs")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let profileID = UUID()
  let library = ProfileLibrary(
    profiles: [
      ManagedProfile(id: profileID, name: "First"),
      ManagedProfile(id: profileID, name: "Second"),
    ],
    selectedProfileID: profileID
  )
  let original = try JSONEncoder().encode(library)
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url)
    Issue.record("Duplicate profile IDs must be rejected during load.")
  } catch let failure as ProfileStoreFailure {
    #expect(failure.isMalformedCurrentLibrary)
  }

  #expect(try Data(contentsOf: url) == original)
  #expect(try preservedCopies(in: directory).isEmpty)
}

@Test func profileStoreRejectsDuplicateProfileIDsBeforeImportReplacement() throws {
  let directory = try secureDirectory("DuplicateProfileImport")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("candidate.json")
  let destination = directory.appendingPathComponent("profiles.json")
  let profileID = UUID()
  let duplicateLibrary = ProfileLibrary(
    profiles: [
      ManagedProfile(id: profileID, name: "First"),
      ManagedProfile(id: profileID, name: "Second"),
    ],
    selectedProfileID: profileID
  )
  let destinationLibrary = profileLibrary()
  let originalDestination = try JSONEncoder().encode(destinationLibrary)
  try writeSecureFile(try JSONEncoder().encode(duplicateLibrary), to: source)
  try writeSecureFile(originalDestination, to: destination)

  do {
    _ = try ProfileStore.importProfileLibrary(from: source, to: destination)
    Issue.record("Duplicate profile IDs must be rejected before import replacement.")
  } catch let failure as ProfileStoreFailure {
    #expect(failure.isMalformedCurrentLibrary)
  }

  #expect(try Data(contentsOf: destination) == originalDestination)
  #expect(try ProfileStore.loadProfileLibrary(from: destination) == destinationLibrary)
}

@Test func profileStoreRejectsDuplicateSourceIDsWithinOneProfile() throws {
  let directory = try secureDirectory("DuplicateSourceIDs")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("candidate.json")
  let destination = directory.appendingPathComponent("profiles.json")
  let sourceID = UUID()
  let profileID = UUID()
  let library = ProfileLibrary(
    profiles: [
      ManagedProfile(
        id: profileID,
        name: "Duplicate sources",
        sources: [ManagedSource(id: sourceID), ManagedSource(id: sourceID)]
      )
    ],
    selectedProfileID: profileID
  )
  let original = try JSONEncoder().encode(library)
  let originalDestination = try JSONEncoder().encode(profileLibrary())
  try writeSecureFile(original, to: source)
  try writeSecureFile(originalDestination, to: destination)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: source)
    Issue.record("Duplicate source IDs within a profile must be rejected on load.")
  } catch let failure as ProfileStoreFailure {
    #expect(failure.isMalformedCurrentLibrary)
  }

  do {
    _ = try ProfileStore.importProfileLibrary(from: source, to: destination)
    Issue.record("Duplicate source IDs must be rejected before import replacement.")
  } catch let failure as ProfileStoreFailure {
    #expect(failure.isMalformedCurrentLibrary)
  }

  #expect(try Data(contentsOf: destination) == originalDestination)
}

@Test func profileStoreAllowsSameSourceIDAcrossDifferentProfiles() throws {
  let directory = try secureDirectory("SharedSourceID")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("candidate.json")
  let destination = directory.appendingPathComponent("restored.json")
  let sourceID = UUID()
  let firstProfile = ManagedProfile(
    name: "First",
    sources: [ManagedSource(id: sourceID)]
  )
  let secondProfile = ManagedProfile(
    name: "Second",
    sources: [ManagedSource(id: sourceID)]
  )
  let library = ProfileLibrary(
    profiles: [firstProfile, secondProfile],
    selectedProfileID: firstProfile.id
  )
  try ProfileStore.saveProfileLibrary(library, to: source)

  let imported = try ProfileStore.importProfileLibrary(from: source, to: destination)
  let restored = try #require(try ProfileStore.loadProfileLibrary(from: destination))
  #expect(imported == library)
  #expect(restored == library)
  #expect(restored.profiles.map { $0.sources.map(\.id) } == [[sourceID], [sourceID]])
}

@Test func profileStorePreservesValidUniqueLibraryOnLoadAndImport() throws {
  let directory = try secureDirectory("UniqueProfileIDs")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("candidate.json")
  let destination = directory.appendingPathComponent("restored.json")
  let library = profileLibrary(routingMode: .direct)
  try ProfileStore.saveProfileLibrary(library, to: source)

  #expect(try ProfileStore.loadProfileLibrary(from: source) == library)
  let imported = try ProfileStore.importProfileLibrary(from: source, to: destination)
  let restored = try #require(try ProfileStore.loadProfileLibrary(from: destination))
  #expect(imported == library)
  #expect(restored == library)
}

@Test func profileStorePreservesDuplicateIdentityThroughMalformedRecovery() throws {
  let directory = try secureDirectory("DuplicateIdentityRecovery")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let profileID = UUID()
  let library = ProfileLibrary(
    profiles: [
      ManagedProfile(id: profileID, name: "First"),
      ManagedProfile(id: profileID, name: "Second"),
    ],
    selectedProfileID: profileID
  )
  let original = try JSONEncoder().encode(library)
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
    Issue.record("Duplicate identities must enter malformed-current recovery.")
  } catch let failure as ProfileStoreFailure {
    #expect(failure.isMalformedCurrentLibrary)
  }

  #expect(try Data(contentsOf: url) == original)
  let copies = try preservedCopies(in: directory)
  #expect(copies.count == 1)
  #expect(try Data(contentsOf: try #require(copies.first)) == original)
}

@Test func profileStoreRejectsEncodedLibraryAboveItsReadLimitBeforeReplacement() throws {
  let directory = try secureDirectory("SaveLimit")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("candidate.json")
  let destination = directory.appendingPathComponent("profiles.json")
  let profile = ManagedProfile(
    name: "Large",
    sources: [ManagedSource(value: String(repeating: "/", count: 4_300_000))]
  )
  let candidate = ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  let importEncoder = JSONEncoder()
  importEncoder.outputFormatting = [.withoutEscapingSlashes]
  let importBytes = try importEncoder.encode(candidate)
  let savedBytes = try JSONEncoder().encode(candidate)
  #expect(importBytes.count <= 8 * 1_048_576)
  #expect(savedBytes.count > 8 * 1_048_576)
  try writeSecureFile(importBytes, to: source)

  let oldBytes = Data("existing canonical bytes".utf8)
  try writeSecureFile(oldBytes, to: destination)
  do {
    _ = try ProfileStore.importProfileLibrary(from: source, to: destination)
    Issue.record("An encoded profile library above the read limit must not be saved.")
  } catch let failure as ProfileStoreFailure {
    if case .tooLarge = failure {} else { Issue.record("Expected tooLarge, got \(failure).") }
  }
  #expect(try Data(contentsOf: destination) == oldBytes)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .allSatisfy { !$0.hasPrefix(".profiles-") }
  )

  let small = profileLibrary(routingMode: .direct)
  try ProfileStore.saveProfileLibrary(small, to: destination)
  #expect(try ProfileStore.loadProfileLibrary(from: destination) == small)
}

@Test func profileStoreBackupExportsExactBytesAndReplacesRegularDestination() throws {
  let directory = try secureDirectory("BackupExactBytes")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("profiles.json")
  let ordinaryParent = directory.appendingPathComponent("ordinary", isDirectory: true)
  try FileManager.default.createDirectory(
    at: ordinaryParent,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o755]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: ordinaryParent.path
  )
  let destination = ordinaryParent.appendingPathComponent("SBM-Profiles.json")
  let sourceBytes = try profileBackupSourceData()
  try writeSecureFile(sourceBytes, to: source)
  try writeSecureFile(Data("previous backup".utf8), to: destination)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)

  try ProfileStore.exportProfileLibrary(from: source, to: destination)

  #expect(try Data(contentsOf: source) == sourceBytes)
  #expect(try Data(contentsOf: destination) == sourceBytes)
  #expect(try filePermissions(destination) == 0o600)
  var info = stat()
  #expect(lstat(destination.path, &info) == 0)
  #expect((info.st_mode & S_IFMT) == S_IFREG)
  #expect(info.st_nlink == 1)
}

@Test func profileStoreBackupReplacementFailurePreservesDestinationAndLeavesNoTempFile() throws {
  let directory = try secureDirectory("BackupAtomicFailure")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("profiles.json")
  let sourceBytes = try profileBackupSourceData()
  try writeSecureFile(sourceBytes, to: source)
  let destination = directory.appendingPathComponent("SBM-Profiles.json", isDirectory: true)
  try FileManager.default.createDirectory(
    at: destination,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700]
  )
  let sentinel = destination.appendingPathComponent("keep.txt")
  let priorBytes = Data("destination remains intact".utf8)
  try priorBytes.write(to: sentinel)

  try expectProfileBackupFailure(from: source, to: destination)

  #expect(try Data(contentsOf: source) == sourceBytes)
  #expect(try Data(contentsOf: sentinel) == priorBytes)
  let siblings = try FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: nil
  )
  #expect(!siblings.contains { $0.lastPathComponent.hasPrefix(".SBM-Profiles.json.") })
}

@Test func profileStoreBackupAndRestorePreserveManagedDNSSettings() throws {
  let directory = try secureDirectory("BackupDNS")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("profiles.json")
  let backup = directory.appendingPathComponent("SBM-Profiles.json")
  let restoredURL = directory.appendingPathComponent("restored.json")
  let settings = try ManagedDNSSettings(
    direct: .customDoH("https://direct.example.test/query"),
    proxy: .quad9
  ).validated()
  var library = ProfileLibrary.empty
  library.dnsSettings = settings
  try ProfileStore.saveProfileLibrary(library, to: source)

  try ProfileStore.exportProfileLibrary(from: source, to: backup)
  let restored = try ProfileStore.importProfileLibrary(from: backup, to: restoredURL)
  let persisted = try #require(try ProfileStore.loadProfileLibrary(from: restoredURL))
  #expect(restored.dnsSettings == settings)
  #expect(persisted.dnsSettings == settings)
}

@Test func profileStoreBackupExportsEmptySchema11WhenCanonicalSourceIsAbsent() throws {
  let directory = try secureDirectory("BackupEmpty")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("profiles.json")
  let destination = directory.appendingPathComponent("SBM-Profiles.json")

  try ProfileStore.exportProfileLibrary(from: source, to: destination)

  let data = try Data(contentsOf: destination)
  let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(root["schemaVersion"] as? Int == 11)
  #expect(try JSONDecoder().decode(ProfileLibrary.self, from: data) == .empty)
  #expect(try filePermissions(destination) == 0o600)
  #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test func profileStoreBackupRejectsMalformedLegacyAndFutureSourcesWithoutReplacingBackup()
  throws
{
  let directory = try secureDirectory("BackupInvalidSources")
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("SBM-Profiles.json")
  let priorBackup = Data("keep existing backup".utf8)
  try writeSecureFile(priorBackup, to: destination)
  let inputs: [(String, Data)] = [
    ("malformed", Data("{not-json".utf8)),
    ("legacy", Data(#"{"schemaVersion":10}"#.utf8)),
    ("future", Data(#"{"schemaVersion":12}"#.utf8)),
  ]

  for (name, bytes) in inputs {
    let source = directory.appendingPathComponent("\(name).json")
    try writeSecureFile(bytes, to: source)

    try expectProfileBackupFailure(from: source, to: destination)

    #expect(try Data(contentsOf: source) == bytes)
    #expect(try Data(contentsOf: destination) == priorBackup)
  }
}

@Test func profileStoreBackupRejectsOversizedAndUnsafeCanonicalSources() throws {
  let directory = try secureDirectory("BackupUnsafeSources")
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("SBM-Profiles.json")
  let oversizedSource = directory.appendingPathComponent("oversized.json")
  let oversizedBytes = Data(repeating: 0x20, count: 8 * 1_048_576 + 1)
  try writeSecureFile(oversizedBytes, to: oversizedSource)

  try expectProfileBackupFailure(from: oversizedSource, to: destination)
  #expect(try Data(contentsOf: oversizedSource) == oversizedBytes)
  #expect(!FileManager.default.fileExists(atPath: destination.path))

  let unsafeSource = directory.appendingPathComponent("unsafe.json")
  let unsafeBytes = try profileBackupSourceData()
  try writeSecureFile(unsafeBytes, to: unsafeSource)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unsafeSource.path)

  try expectProfileBackupFailure(from: unsafeSource, to: destination)
  #expect(try Data(contentsOf: unsafeSource) == unsafeBytes)
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func profileStoreBackupRejectsDestinationSymlinkAndPreservesBothSources() throws {
  let directory = try secureDirectory("BackupSymlinkDestination")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("profiles.json")
  let sourceBytes = try profileBackupSourceData()
  try writeSecureFile(sourceBytes, to: source)
  let target = directory.appendingPathComponent("target.json")
  let targetBytes = Data("target remains unchanged".utf8)
  try writeSecureFile(targetBytes, to: target)
  let destination = directory.appendingPathComponent("SBM-Profiles.json")
  try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

  try expectProfileBackupFailure(from: source, to: destination)

  #expect(try Data(contentsOf: source) == sourceBytes)
  #expect(try Data(contentsOf: target) == targetBytes)
  var info = stat()
  #expect(lstat(destination.path, &info) == 0)
  #expect((info.st_mode & S_IFMT) == S_IFLNK)
}

@Test func profileStoreBackupRejectsNonregularDestinationWithoutBlocking() throws {
  let directory = try secureDirectory("BackupNonregularDestination")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("profiles.json")
  let sourceBytes = try profileBackupSourceData()
  try writeSecureFile(sourceBytes, to: source)
  let destination = directory.appendingPathComponent("backup.fifo")
  #expect(mkfifo(destination.path, mode_t(0o600)) == 0)

  try expectProfileBackupFailure(from: source, to: destination)

  #expect(try Data(contentsOf: source) == sourceBytes)
  var info = stat()
  #expect(lstat(destination.path, &info) == 0)
  #expect((info.st_mode & S_IFMT) == S_IFIFO)
}

@Test func profileStoreBackupRejectsHardlinkedDestinationBeforeReplacement() throws {
  let directory = try secureDirectory("BackupHardlinkedDestination")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("profiles.json")
  let sourceBytes = try profileBackupSourceData()
  try writeSecureFile(sourceBytes, to: source)
  let destination = directory.appendingPathComponent("backup.json")
  let secondLink = directory.appendingPathComponent("backup-link.json")
  let priorBackup = Data("linked backup remains unchanged".utf8)
  try writeSecureFile(priorBackup, to: destination)
  try FileManager.default.linkItem(at: destination, to: secondLink)

  try expectProfileBackupFailure(from: source, to: destination)

  #expect(try Data(contentsOf: source) == sourceBytes)
  #expect(try Data(contentsOf: destination) == priorBackup)
  #expect(try Data(contentsOf: secondLink) == priorBackup)
}

@Test func profileStoreBackupRejectsCanonicalSourceAsDestinationBeforeOpeningIt() throws {
  let directory = try secureDirectory("BackupSameSourceDestination")
  defer { try? FileManager.default.removeItem(at: directory) }
  let canonicalSource = directory.appendingPathComponent("profiles.json")
  let sourceBytes = try profileBackupSourceData()
  try writeSecureFile(sourceBytes, to: canonicalSource)

  try expectProfileBackupFailure(from: canonicalSource, to: canonicalSource)

  #expect(try Data(contentsOf: canonicalSource) == sourceBytes)
}

@Test func profileStoreBackupRejectsSymlinkedParentAliasToCanonicalStorage() throws {
  let directory = try secureDirectory("BackupSymlinkedParentAlias")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("profiles.json")
  let sourceBytes = try profileBackupSourceData()
  try writeSecureFile(sourceBytes, to: source)
  let aliasParent = directory.appendingPathComponent("alias-to-canonical", isDirectory: true)
  try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: directory)
  let destination = aliasParent.appendingPathComponent("profiles.json")

  #expect(source.standardizedFileURL != destination.standardizedFileURL)
  #expect(source.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath())
  try expectProfileBackupFailure(from: source, to: destination)
  #expect(try Data(contentsOf: source) == sourceBytes)
}

@Test @MainActor func appModelInitializesDesiredRoutingFromLoadedLibrary() {
  let stored = profileLibrary(
    routingMode: .global,
    selectedNodeID: ProxyNodeID(rawValue: "node-selected")
  )
  let model = AppModel(
    profileLibraryLoader: { stored },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  #expect(model.routingMode == .global)
  #expect(model.selectedNodeID == ProxyNodeID(rawValue: "node-selected"))
}

@Test func profileStoreRejectsUnsupportedLegacySchemasWithoutChangingBytes() throws {
  let directory = try secureDirectory("LegacySchemas")
  defer { try? FileManager.default.removeItem(at: directory) }

  for version in Array(1...5) + Array(7...10) {
    let url = directory.appendingPathComponent("profiles-\(version).json")
    let original = Data("{\"schemaVersion\":\(version)}".utf8)
    try writeSecureFile(original, to: url)

    do {
      _ = try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
      Issue.record("Unsupported schema \(version) should be rejected as legacy data.")
    } catch let failure as ProfileStoreFailure {
      if case .legacySchema = failure {
        #expect(!failure.isMalformedCurrentLibrary)
      } else {
        Issue.record("Unsupported schema \(version) must be classified as legacy.")
      }
    }

    #expect(try Data(contentsOf: url) == original)
  }
  #expect(try preservedCopies(in: directory).isEmpty)
}

@Test @MainActor
func profileStoreConvertsAuthenticV1115Schema6AfterPreservingOriginalBytes() throws {
  let directory = try secureDirectory("Schema6Upgrade")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let originalURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture")
  let original = try Data(contentsOf: originalURL)
  try writeSecureFile(original, to: url)

  var unexpectedSave = false
  let model = AppModel(
    profileLibraryLoader: { try ProfileStore.loadProfileLibrary(from: url) },
    profileLibrarySaver: { _ in unexpectedSave = true },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  #expect(model.profileLoadIssueMessage == nil)
  #expect(!model.profileRecoveryRequired)
  #expect(model.profiles.count == 1)
  #expect(!unexpectedSave)

  let library = try #require(try ProfileStore.loadProfileLibrary(from: url))
  #expect(library.profiles.count == 1)
  #expect(library.selectedProfileID == UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
  #expect(library.routingMode == .rule)
  #expect(library.selectedNodeID == .auto)
  #expect(library.dnsSettings == .defaults)
  #expect(library.localSOCKSEnabled)
  #expect(library.ipv6Enabled)
  let source = try #require(library.profiles.first?.sources.first)
  #expect(source.value == "https://user:SANITIZED@example.invalid/sub")
  #expect(source.headers.deviceOSVersion == nil)
  #expect(source.headers.deviceModel == nil)
  let payload = try #require(source.payload)
  guard case .compatibility(let vpn) = payload else {
    Issue.record("The v1.1.15 managed payload must remain managed.")
    return
  }
  #expect(vpn.connections.map { $0.outbound.kind } == [.shadowsocks, .vless, .vless, .hysteria2])
  #expect(vpn.connections.last?.outbound.semanticIdentity.contains("SANITIZED-OBFS") == true)
  #expect(vpn.routingPolicy?.configuration == Data("{\"route\":{\"rules\":[]}}".utf8))
  #expect(vpn.applicationRoutingRules.first?.target == .node(ProxyNodeID(rawValue: "ss-node")))
  #expect(vpn.websiteRoutingRules.first?.domain == "example.org")
  let backup = directory.appendingPathComponent("profiles.1.1.15.original.json")
  #expect(try Data(contentsOf: backup) == original)
  #expect(try Data(contentsOf: url) != original)
  #expect(try ProfileStore.loadProfileLibrary(from: url) == library)

  let builder = ConfigBuilder(
    cachePath: directory.appendingPathComponent("cache.db").path,
    apiSecret: "fixture-api-secret"
  )
  let built = try builder.makeConfiguration(
    profile: .compatibility(vpn),
    mode: .rule,
    selectedNode: .auto,
    localSOCKSPort: library.localSOCKSPort,
    ipv6Enabled: library.ipv6Enabled,
    dnsSettings: library.dnsSettings
  )
  let configURL = directory.appendingPathComponent("current-config.json")
  try built.data.write(to: configURL)
  let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".vendor/sing-box")
  #expect(FileManager.default.isExecutableFile(atPath: core.path))
  let check = try TestProcessSupport.run(
    executableURL: core,
    arguments: ["check", "-c", configURL.path]
  )
  #expect(check.status == 0, Comment(rawValue: check.output))
}

@Test func schema6WithoutSelectionPreservesNilSelectionAndCurrentDefaults() throws {
  let directory = try secureDirectory("Schema6NoSelection")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let fixture = try Data(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture"))
  var root = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
  root.removeValue(forKey: "selectedProfileID")
  let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  try writeSecureFile(original, to: url)

  let library = try #require(try ProfileStore.loadProfileLibrary(from: url))
  #expect(library.selectedProfileID == nil)
  #expect(library.routingMode == .rule)
  #expect(library.selectedNodeID == .auto)
  #expect(library.dnsSettings == .defaults)
  #expect(
    try Data(contentsOf: directory.appendingPathComponent("profiles.1.1.15.original.json"))
      == original)
}

@Test func schema6MultiProfileAndMultiSourceConversionPreservesEveryEntry() throws {
  let directory = try secureDirectory("Schema6MultipleEntries")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture")
  let fixture = try Data(contentsOf: fixtureURL)
  var root = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
  var profiles = try #require(root["profiles"] as? [[String: Any]])
  var second = try #require(profiles.first)
  second["id"] = "55555555-5555-4555-8555-555555555555"
  second["name"] = "Second profile"
  var sources = try #require(second["sources"] as? [[String: Any]])
  var secondSource = try #require(sources.first)
  secondSource["id"] = "66666666-6666-4666-8666-666666666666"
  secondSource["name"] = "Second source"
  sources.append(secondSource)
  second["sources"] = sources
  profiles.append(second)
  root["profiles"] = profiles
  let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  try writeSecureFile(original, to: url)

  let library = try #require(try ProfileStore.loadProfileLibrary(from: url))
  #expect(library.profiles.count == 2)
  #expect(library.profiles.map(\.sources.count) == [1, 2])
  #expect(library.profiles.map(\.name) == ["Fixture", "Second profile"])
  #expect(
    library.profiles[1].sources.map(\.name) == ["Source", "Second source"]
  )
  #expect(
    try Data(contentsOf: directory.appendingPathComponent("profiles.1.1.15.original.json"))
      == original)
}

@Test func schema6HardlinkedCanonicalInputFailsWithoutChangingEitherLink() throws {
  let directory = try secureDirectory("Schema6HardLink")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let other = directory.appendingPathComponent("other.json")
  let fixture = try Data(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture"))
  try writeSecureFile(fixture, to: url)
  #expect(link(url.path, other.path) == 0)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url)
    Issue.record("Hard-linked source data must fail closed.")
  } catch {}

  #expect(try Data(contentsOf: url) == fixture)
  #expect(try Data(contentsOf: other) == fixture)
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("profiles.1.1.15.original.json").path))
}

@Test func schema6NativePayloadFailsWithoutMutationOrPartialRecovery() throws {
  let directory = try secureDirectory("Schema6Native")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let fixture = try Data(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture"))
  var root = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
  var profiles = try #require(root["profiles"] as? [[String: Any]])
  var profile = try #require(profiles.first)
  profile["payload"] = ["native": ["_0": ["configuration": "SANITIZED"]]]
  profiles[0] = profile
  root["profiles"] = profiles
  let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url)
    Issue.record("Native sing-box data is not part of the legacy import contract.")
  } catch let failure as ProfileStoreFailure {
    if case .legacySchema = failure {} else { Issue.record("Unexpected failure: \(failure)") }
  }

  #expect(try Data(contentsOf: url) == original)
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("profiles.1.1.15.original.json").path))
}

@Test func schema6RejectsCurrentOnlyHeaderAndOutboundFieldsWithoutMutation() throws {
  let directory = try secureDirectory("Schema6CurrentOnlyFields")
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try Data(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture"))

  for divergence in ["header", "hysteria-hopping", "vless-websocket"] {
    let caseDirectory = directory.appendingPathComponent(divergence, isDirectory: true)
    try FileManager.default.createDirectory(
      at: caseDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let url = caseDirectory.appendingPathComponent("profiles.json")
    var root = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
    var profiles = try #require(root["profiles"] as? [[String: Any]])
    var profile = try #require(profiles.first)
    if divergence == "header" {
      var sources = try #require(profile["sources"] as? [[String: Any]])
      var source = try #require(sources.first)
      var headers = try #require(source["headers"] as? [String: Any])
      headers["deviceModel"] = "iPhone"
      source["headers"] = headers
      sources[0] = source
      profile["sources"] = sources
    } else {
      var payload = try #require(profile["payload"] as? [String: Any])
      var compatibility = try #require(payload["compatibility"] as? [String: Any])
      var associated = try #require(compatibility["_0"] as? [String: Any])
      var connections = try #require(associated["connections"] as? [[String: Any]])
      let connectionIndex = try #require(
        connections.firstIndex { connection in
          connection["displayName"] as? String
            == (divergence == "hysteria-hopping" ? "Hysteria 2" : "VLESS TLS gRPC")
        })
      var connection = connections[connectionIndex]
      var outbound = try #require(connection["outbound"] as? [String: Any])
      if divergence == "hysteria-hopping" {
        var value = try #require(outbound["hysteria2"] as? [String: Any])
        value["portHoppingRanges"] = [["start": 1000, "end": 2000]]
        outbound["hysteria2"] = value
      } else {
        var value = try #require(outbound["vless"] as? [String: Any])
        value.removeValue(forKey: "security")
        value.removeValue(forKey: "type")
        value.removeValue(forKey: "serviceName")
        value["security"] = "tls"
        value["type"] = "ws"
        value["host"] = "grpc.example.invalid"
        value["path"] = "/ws"
        outbound["vless"] = value
      }
      connection["outbound"] = outbound
      connections[connectionIndex] = connection
      associated["connections"] = connections
      compatibility["_0"] = associated
      payload["compatibility"] = compatibility
      profile["payload"] = payload
    }
    profiles[0] = profile
    root["profiles"] = profiles
    let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    try writeSecureFile(original, to: url)

    do {
      _ = try ProfileStore.loadProfileLibrary(from: url)
      Issue.record("Current-only schema fields must not be admitted as v1.1.15 data.")
    } catch let failure as ProfileStoreFailure {
      if case .legacySchema = failure {} else { Issue.record("Unexpected failure: \(failure)") }
    }

    #expect(try Data(contentsOf: url) == original)
    #expect(
      !FileManager.default.fileExists(
        atPath: caseDirectory.appendingPathComponent("profiles.1.1.15.original.json").path))
  }
}

@Test func schema6ConversionIsExclusiveToCanonicalLoad() throws {
  let directory = try secureDirectory("Schema6Boundaries")
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try Data(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture"))
  let canonical = directory.appendingPathComponent("profiles.json")
  let importSource = directory.appendingPathComponent("import.json")
  let exportDestination = directory.appendingPathComponent("export.json")
  try writeSecureFile(fixture, to: canonical)
  try writeSecureFile(fixture, to: importSource)

  do {
    _ = try ProfileStore.resetProfileLibrary(at: canonical)
    Issue.record("Reset must not convert legacy input.")
  } catch let failure as ProfileStoreFailure {
    if case .legacySchema = failure {} else { Issue.record("Unexpected reset failure: \(failure)") }
  }
  do {
    _ = try ProfileStore.importProfileLibrary(from: importSource, to: canonical)
    Issue.record("Manual import must not convert legacy input.")
  } catch let failure as ProfileStoreFailure {
    if case .legacySchema = failure {
    } else {
      Issue.record("Unexpected import failure: \(failure)")
    }
  }
  do {
    try ProfileStore.exportProfileLibrary(from: importSource, to: exportDestination)
    Issue.record("Export must not convert legacy input.")
  } catch let failure as ProfileStoreFailure {
    if case .legacySchema = failure {
    } else {
      Issue.record("Unexpected export failure: \(failure)")
    }
  }

  #expect(try Data(contentsOf: canonical) == fixture)
  #expect(try Data(contentsOf: importSource) == fixture)
  #expect(!FileManager.default.fileExists(atPath: exportDestination.path))
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("profiles.1.1.15.original.json").path))
}

@Test func schema6UnknownNestedFieldFailsWithoutChangingEitherFile() throws {
  let directory = try secureDirectory("Schema6Unknown")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let fixture = try Data(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture"))
  var root = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
  var profiles = try #require(root["profiles"] as? [[String: Any]])
  var profile = try #require(profiles.first)
  var payload = try #require(profile["payload"] as? [String: Any])
  var compatibility = try #require(payload["compatibility"] as? [String: Any])
  var associated = try #require(compatibility["_0"] as? [String: Any])
  var connections = try #require(associated["connections"] as? [[String: Any]])
  var connection = try #require(connections.first)
  var outbound = try #require(connection["outbound"] as? [String: Any])
  var shadowsocks = try #require(outbound["shadowsocks"] as? [String: Any])
  shadowsocks["futureField"] = "must not be discarded"
  outbound["shadowsocks"] = shadowsocks
  connection["outbound"] = outbound
  connections[0] = connection
  associated["connections"] = connections
  compatibility["_0"] = associated
  payload["compatibility"] = compatibility
  profile["payload"] = payload
  profiles[0] = profile
  root["profiles"] = profiles
  let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url)
    Issue.record("Unknown nested fields must not be discarded during conversion.")
  } catch let failure as ProfileStoreFailure {
    if case .legacySchema = failure {} else { Issue.record("Unexpected failure: \(failure)") }
  }

  #expect(try Data(contentsOf: url) == original)
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("profiles.1.1.15.original.json").path))
}

@Test func schema6RejectsDuplicateIDsAndUnresolvedRoutingReferences() throws {
  let directory = try secureDirectory("Schema6IdentityAndReferences")
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try Data(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture"))

  for invalidCase in [
    "duplicate-profile", "duplicate-source", "duplicate-group", "reserved-auto-node",
    "dangling-node",
  ] {
    let caseDirectory = directory.appendingPathComponent(invalidCase, isDirectory: true)
    try FileManager.default.createDirectory(
      at: caseDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let url = caseDirectory.appendingPathComponent("profiles.json")
    var root = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
    var profiles = try #require(root["profiles"] as? [[String: Any]])
    if invalidCase == "duplicate-profile" {
      profiles.append(try #require(profiles.first))
    } else if invalidCase == "duplicate-source" {
      var profile = try #require(profiles.first)
      var sources = try #require(profile["sources"] as? [[String: Any]])
      sources.append(try #require(sources.first))
      profile["sources"] = sources
      profiles[0] = profile
    } else {
      var profile = try #require(profiles.first)
      var payload = try #require(profile["payload"] as? [String: Any])
      var compatibility = try #require(payload["compatibility"] as? [String: Any])
      var associated = try #require(compatibility["_0"] as? [String: Any])
      if invalidCase == "duplicate-group" {
        var groups = try #require(associated["nodeGroups"] as? [[String: Any]])
        groups.append(try #require(groups.first))
        associated["nodeGroups"] = groups
      } else if invalidCase == "reserved-auto-node" {
        var connections = try #require(associated["connections"] as? [[String: Any]])
        var connection = try #require(connections.first)
        connection["id"] = "auto"
        connections[0] = connection
        associated["connections"] = connections
      } else {
        var rules = try #require(associated["applicationRoutingRules"] as? [[String: Any]])
        var rule = try #require(rules.first)
        rule["target"] = ["node": ["_0": "missing-node"]]
        rules[0] = rule
        associated["applicationRoutingRules"] = rules
      }
      compatibility["_0"] = associated
      payload["compatibility"] = compatibility
      profile["payload"] = payload
      profiles[0] = profile
    }
    root["profiles"] = profiles
    let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    try writeSecureFile(original, to: url)

    do {
      _ = try ProfileStore.loadProfileLibrary(from: url)
      Issue.record("Duplicate identities and unresolved references must fail closed.")
    } catch let failure as ProfileStoreFailure {
      if case .legacySchema = failure {} else { Issue.record("Unexpected failure: \(failure)") }
    }

    #expect(try Data(contentsOf: url) == original)
    #expect(
      !FileManager.default.fileExists(
        atPath: caseDirectory.appendingPathComponent("profiles.1.1.15.original.json").path))
  }
}

@Test func schema6RejectsDuplicateJSONKeysBeforeProjection() throws {
  let directory = try secureDirectory("Schema6DuplicateJSONKey")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture")
  let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
  let original = Data(
    fixture.replacingOccurrences(
      of: "  \"schemaVersion\" : 6,",
      with: "  \"schemaVersion\" : 6,\n  \"schemaVersion\" : 6,"
    ).utf8)
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url)
    Issue.record("Duplicate JSON keys must be rejected before JSON projection.")
  } catch let failure as ProfileStoreFailure {
    if case .legacySchema = failure {} else { Issue.record("Unexpected failure: \(failure)") }
  }

  #expect(try Data(contentsOf: url) == original)
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("profiles.1.1.15.original.json").path))
}

@Test func schema6RejectsMalformedRoutingPolicyWithoutChangingBytes() throws {
  let directory = try secureDirectory("Schema6MalformedPolicy")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture")
  let fixture = try Data(contentsOf: fixtureURL)
  var root = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
  var profiles = try #require(root["profiles"] as? [[String: Any]])
  var profile = try #require(profiles.first)
  var payload = try #require(profile["payload"] as? [String: Any])
  var compatibility = try #require(payload["compatibility"] as? [String: Any])
  var associated = try #require(compatibility["_0"] as? [String: Any])
  var policy = try #require(associated["routingPolicy"] as? [String: Any])
  policy["configuration"] = Data("{\"rules\":[]}".utf8).base64EncodedString()
  associated["routingPolicy"] = policy
  compatibility["_0"] = associated
  payload["compatibility"] = compatibility
  profile["payload"] = payload
  profiles[0] = profile
  root["profiles"] = profiles
  let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url)
    Issue.record("A malformed legacy routing policy must fail before conversion.")
  } catch let failure as ProfileStoreFailure {
    if case .legacySchema = failure {} else { Issue.record("Unexpected failure: \(failure)") }
  }

  #expect(try Data(contentsOf: url) == original)
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("profiles.1.1.15.original.json").path))
}

@Test func schema6ConflictingPreservationFileBlocksCanonicalReplacement() throws {
  let directory = try secureDirectory("Schema6BackupConflict")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let fixture = try Data(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture"))
  let conflict = directory.appendingPathComponent("profiles.1.1.15.original.json")
  let conflictBytes = Data("different prior contents".utf8)
  try writeSecureFile(fixture, to: url)
  try writeSecureFile(conflictBytes, to: conflict)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url)
    Issue.record("A conflicting preservation file must block conversion.")
  } catch let failure as ProfileStoreFailure {
    if case .legacySchema = failure {} else { Issue.record("Unexpected failure: \(failure)") }
  }

  #expect(try Data(contentsOf: url) == fixture)
  #expect(try Data(contentsOf: conflict) == conflictBytes)
}

@Test func schema6InterruptedAfterPreservationCanRetryWithoutDuplicateConversion() throws {
  let directory = try secureDirectory("Schema6Retry")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let fixture = try Data(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture"))
  try writeSecureFile(fixture, to: url)
  try writeSecureFile(
    fixture,
    to: directory.appendingPathComponent("profiles.1.1.15.original.json")
  )

  let first = try #require(try ProfileStore.loadProfileLibrary(from: url))
  let canonical = try Data(contentsOf: url)
  let second = try #require(try ProfileStore.loadProfileLibrary(from: url))
  #expect(first == second)
  #expect(try Data(contentsOf: url) == canonical)
  #expect(
    try Data(contentsOf: directory.appendingPathComponent("profiles.1.1.15.original.json"))
      == fixture)
}

@Test func profileStoreTreatsMissingSchemaAsLegacyAndDoesNotPreserveItAsCorrupt() throws {
  let directory = try secureDirectory("MissingSchema")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let original = Data(#"{"profiles":[],"selectedProfileID":null}"#.utf8)
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
    Issue.record("A profile library without schemaVersion should be rejected as legacy data.")
  } catch let failure as ProfileStoreFailure {
    switch failure {
    case .legacySchema:
      break
    default:
      Issue.record("A missing schema version must be classified as legacy.")
    }
  }

  #expect(try Data(contentsOf: url) == original)
  #expect(try preservedCopies(in: directory).isEmpty)
}

@Test func profileStoreRejectsFutureSchemaWithoutChangingBytes() throws {
  let directory = try secureDirectory("FutureSchema")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let original = Data(#"{"schemaVersion":12}"#.utf8)
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
    Issue.record("A future profile-library schema should be rejected.")
  } catch let failure as ProfileStoreFailure {
    switch failure {
    case .unsupportedFutureSchema(let version):
      #expect(version == 12)
    default:
      Issue.record("A future schema must have its own unsupported-schema classification.")
    }
    #expect(failure.localizedDescription.contains("12"))
    #expect(failure.localizedDescription.contains("newer unsupported schema"))
    #expect(
      failure.localizedDescription.contains("~/Library/Application Support/SBM/profiles.json"))
  }

  #expect(try Data(contentsOf: url) == original)
  #expect(try preservedCopies(in: directory).isEmpty)
}

@Test func profileStoreImportRejectsLegacySourceWithoutReplacingDestination() throws {
  let directory = try secureDirectory("LegacyImport")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("legacy.json")
  let destination = directory.appendingPathComponent("profiles.json")
  let originalSource = Data(#"{"schemaVersion":10}"#.utf8)
  try writeSecureFile(originalSource, to: source)
  try ProfileStore.saveProfileLibrary(.empty, to: destination)
  let originalDestination = try Data(contentsOf: destination)

  do {
    _ = try ProfileStore.importProfileLibrary(from: source, to: destination)
    Issue.record("Recovery import must reject pre-1.2 profile data.")
  } catch let failure as ProfileStoreFailure {
    switch failure {
    case .legacySchema:
      break
    default:
      Issue.record("Recovery import must classify pre-1.2 data as legacy.")
    }
  }

  #expect(try Data(contentsOf: source) == originalSource)
  #expect(try Data(contentsOf: destination) == originalDestination)
  #expect(try preservedCopies(in: directory).isEmpty)
}

@Test func profileStoreDoesNotResetOrPreserveLegacyDataAsInvalid() throws {
  let directory = try secureDirectory("LegacyReset")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let original = Data(#"{"schemaVersion":10}"#.utf8)
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.resetProfileLibrary(at: url)
    Issue.record("Reset must not overwrite a legacy profile library.")
  } catch let failure as ProfileStoreFailure {
    switch failure {
    case .legacySchema:
      break
    default:
      Issue.record("Reset must classify pre-1.2 data as legacy.")
    }
  }

  #expect(try Data(contentsOf: url) == original)
  #expect(try preservedCopies(in: directory).isEmpty)
}

@Test func profileStorePreservesMalformedCurrentSchemaForBoundedRecovery() throws {
  let directory = try secureDirectory("MalformedCurrent")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let original = Data(#"{"schemaVersion":11,"profiles":null}"#.utf8)
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
    Issue.record("Malformed current-schema data should be rejected.")
  } catch let failure as ProfileStoreFailure {
    #expect(failure.isMalformedCurrentLibrary)
  }

  #expect(try Data(contentsOf: url) == original)
  let copies = try preservedCopies(in: directory)
  #expect(copies.count == 1)
  #expect(try Data(contentsOf: try #require(copies.first)) == original)
}

@Test func profileStoreRejectsAmbiguousDuplicateKeysWithoutRecoveryOrReplacement() throws {
  let directory = try secureDirectory("DuplicateKeys")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let inputs: [Data] = [
    Data(#"{"schemaVersion":11,"schemaVersion":10}"#.utf8),
    Data(#"{"schemaVersion":10,"schemaVersion":11}"#.utf8),
    Data(#"{"schemaVersion":11,"routingMode":"Rule","routingMode":"Direct"}"#.utf8),
    Data(
      #"{"schemaVersion":11,"profiles":[{"id":"2B1F0E50-0D2B-4FD9-AD18-08BB09F6FA01","name":"A","name":"B"}]}"#
        .utf8
    ),
  ]

  for original in inputs {
    try writeSecureFile(original, to: url)
    expectUnclassifiedProfileStoreFailure {
      _ = try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try preservedCopies(in: directory).isEmpty)
    expectUnclassifiedProfileStoreFailure {
      _ = try ProfileStore.resetProfileLibrary(at: url)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try preservedCopies(in: directory).isEmpty)
  }
}

@Test func profileStoreKeepsUnknownGenerationCorruptionOutOfRecovery() throws {
  let directory = try secureDirectory("UnknownGeneration")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let inputs = [
    Data(#"{"schemaVersion":"10","profiles":null}"#.utf8),
    Data(#"{"schemaVersion":11.0,"profiles":null}"#.utf8),
    Data(#"{"schemaVersion":11,"profiles":["#.utf8),
  ]

  for original in inputs {
    try writeSecureFile(original, to: url)
    expectUnclassifiedProfileStoreFailure {
      _ = try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try preservedCopies(in: directory).isEmpty)
    expectUnclassifiedProfileStoreFailure {
      _ = try ProfileStore.resetProfileLibrary(at: url)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try preservedCopies(in: directory).isEmpty)
  }
}

@Test func profileStorePreservesRemovedNativeSchema11PayloadWithoutMigration() throws {
  let directory = try secureDirectory("RemovedNativeCurrent")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let original = Data(
    #"{"schemaVersion":11,"profiles":[{"id":"2B1F0E50-0D2B-4FD9-AD18-08BB09F6FA01","name":"Legacy native","sources":[],"payload":{"native":{"_0":{"configuration":"e30=","selectorTag":"proxy","nodes":[],"applicationRoutingRules":[],"websiteRoutingRules":[]}}}}],"selectedProfileID":null,"routingMode":"Rule","selectedNodeID":"auto","localSOCKSEnabled":false,"localSOCKSPort":1082,"latencyIntervalMinutes":10,"latencyTestURL":"https://www.gstatic.com/generate_204","ipv6Enabled":false}"#
      .utf8
  )
  try writeSecureFile(original, to: url)

  do {
    _ = try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
    Issue.record("A removed schema-11 native payload should use malformed-current recovery.")
  } catch let failure as ProfileStoreFailure {
    #expect(failure.isMalformedCurrentLibrary)
  }

  #expect(try Data(contentsOf: url) == original)
  let copies = try preservedCopies(in: directory)
  #expect(copies.count == 1)
  #expect(try Data(contentsOf: try #require(copies.first)) == original)
}

@Test func freshInstallProfileLibraryUsesMainSourceAndSchema11Defaults() throws {
  let library = ProfileLibrary.freshInstall()
  let profile = try #require(library.profiles.first)
  let source = try #require(profile.sources.first)

  #expect(library.profiles.count == 1)
  #expect(profile.name == SBMText.localized("Main"))
  #expect(profile.payload == nil)
  #expect(profile.sources.count == 1)
  #expect(source.name == SBMText.localized("Subscription"))
  #expect(source.value.isEmpty)
  #expect(source.payload == nil)
  #expect(library.selectedProfileID == profile.id)
  #expect(library.routingMode == .rule)
  #expect(library.selectedNodeID == .auto)
  #expect(!library.localSOCKSEnabled)
  #expect(library.localSOCKSPort == 1082)
  #expect(library.latencyIntervalMinutes == 10)
  #expect(library.latencyTestURL == LatencyTargetPolicy.defaultURL)
  #expect(!library.ipv6Enabled)
  #expect(library.dnsSettings == .defaults)

  let data = try JSONEncoder().encode(library)
  let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(root["schemaVersion"] as? Int == 11)
  #expect(try JSONDecoder().decode(ProfileLibrary.self, from: data) == library)
  #expect(ProfileLibrary.empty.profiles.isEmpty)
  #expect(ProfileLibrary.empty.selectedProfileID == nil)
}

@Test @MainActor func missingProfileLibrarySavesFreshMainBeforePublishingWithoutSideEffects()
  async
  throws
{
  var saves: [ProfileLibrary] = []
  let effects = FreshInstallEffectRecorder()
  let manager = SubscriptionManager { value, _ in
    await effects.recordSubscriptionFetch(value)
    throw ProfileLibraryPersistenceTestFailure.persistence
  }
  let model = AppModel(
    subscriptionManager: manager,
    runtimeSender: { request in await effects.send(request) },
    helperRequestSender: { request in await effects.send(request) },
    profileValidator: { _ in await effects.validate() },
    profileLibraryLoader: { nil },
    profileLibrarySaver: { saves.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  let saved = try #require(saves.first)
  let savedProfile = try #require(saved.profiles.first)
  #expect(saves.count == 1)
  #expect(saved.profiles.count == 1)
  #expect(savedProfile.name == "Main")
  #expect(savedProfile.sources.count == 1)
  #expect(savedProfile.sources[0].value.isEmpty)
  #expect(saved.selectedProfileID == savedProfile.id)
  #expect(model.profiles == saved.profiles)
  #expect(model.selectedProfileID == savedProfile.id)
  #expect(model.profileLoadIssueMessage == nil)

  let counts = await effects.counts()
  #expect(counts.subscriptionFetches == 0)
  #expect(counts.helperRequests == 0)
  #expect(counts.validations == 0)
}

@Test @MainActor func failedFreshInstallSaveKeepsEmptyStateAndReportsStorageFailure() {
  var saves = 0
  let model = AppModel(
    profileLibraryLoader: { nil },
    profileLibrarySaver: { _ in
      saves += 1
      throw ProfileLibraryPersistenceTestFailure.persistence
    },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  #expect(saves == 1)
  #expect(model.profiles.isEmpty)
  #expect(model.selectedProfileID == nil)
  #expect(model.profileLoadIssueMessage != nil)
  #expect(model.lastError != nil)
}

@Test @MainActor func existingEmptyAndNonemptyLibrariesAreAdoptedWithoutSaving() throws {
  var emptySaves = 0
  let emptyModel = AppModel(
    profileLibraryLoader: { .empty },
    profileLibrarySaver: { _ in emptySaves += 1 },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  #expect(emptyModel.profiles.isEmpty)
  #expect(emptyModel.selectedProfileID == nil)
  #expect(emptySaves == 0)

  let existing = profileLibrary(
    routingMode: .global,
    selectedNodeID: ProxyNodeID(rawValue: "node-selected")
  )
  var nonemptySaves = 0
  let existingModel = AppModel(
    profileLibraryLoader: { existing },
    profileLibrarySaver: { _ in nonemptySaves += 1 },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  #expect(existingModel.profiles == existing.profiles)
  #expect(existingModel.selectedProfileID == existing.selectedProfileID)
  #expect(existingModel.routingMode == existing.routingMode)
  #expect(existingModel.selectedNodeID == existing.selectedNodeID)
  #expect(nonemptySaves == 0)
}

@Test @MainActor func deletingLastProfileRemainsEmptyOnTheNextLaunch() throws {
  var persisted: ProfileLibrary? = profileLibrary()
  let firstLaunch = AppModel(
    profileLibraryLoader: { persisted },
    profileLibrarySaver: { persisted = $0 },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  firstLaunch.deleteSelectedProfile(profileID: try #require(firstLaunch.selectedProfileID))

  let savedEmpty = try #require(persisted)
  #expect(savedEmpty.profiles.isEmpty)
  #expect(savedEmpty.selectedProfileID == nil)
  let nextLaunch = AppModel(
    profileLibraryLoader: { persisted },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  #expect(nextLaunch.profiles.isEmpty)
  #expect(nextLaunch.selectedProfileID == nil)
}

@Test @MainActor func restoredEmptySchema11LibraryRemainsEmptyOnTheNextLaunch() throws {
  let directory = try secureDirectory("EmptyRestore")
  defer { try? FileManager.default.removeItem(at: directory) }
  let backupURL = directory.appendingPathComponent("empty-backup.json")
  let canonicalURL = directory.appendingPathComponent("profiles.json")
  try writeSecureFile(try JSONEncoder().encode(ProfileLibrary.empty), to: backupURL)

  let restored = try ProfileStore.importProfileLibrary(from: backupURL, to: canonicalURL)
  let reloaded = try #require(try ProfileStore.loadProfileLibrary(from: canonicalURL))
  let model = AppModel(
    profileLibraryLoader: { reloaded },
    profileLibrarySaver: { _ in Issue.record("An existing empty library must not be saved.") },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  #expect(restored == .empty)
  #expect(reloaded == .empty)
  #expect(model.profiles.isEmpty)
  #expect(model.selectedProfileID == nil)
}

@Test @MainActor
func unsupportedLegacyLibraryPresentationKeepsOriginalAndOffersNoDeletionInstructions() throws {
  let model = AppModel(
    profileLibraryLoader: { throw ProfileStoreFailure.legacySchema },
    profileLibrarySaver: { _ in Issue.record("A failed legacy load must not save a blank library.")
    },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  let message = try #require(model.profileLoadIssueMessage)

  #expect(!model.profileRecoveryRequired)
  #expect(message.contains("legacy profile library"))
  #expect(message.contains("~/Library/Application Support/SBM/profiles.json"))
  #expect(message.contains("contact support"))
  #expect(message.contains("original file was left unchanged"))
  #expect(!message.contains("move or delete"))
  #expect(!message.contains("recreate"))
  #expect(model.profiles.isEmpty)
  #expect(model.selectedProfileID == nil)
  #expect(model.profileRecoveryMessage == message)
}

@Test @MainActor func schema6MigrationFailureBlocksPublicationSaveAndStart() throws {
  let directory = try secureDirectory("Schema6AppModelFailure")
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/SBMTests/Fixtures/v1.1.15-profile-library-schema6.fixture")
  let fixture = try Data(contentsOf: fixtureURL)
  var root = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
  root["unknownFutureSetting"] = true
  let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  try writeSecureFile(original, to: url)

  let model = AppModel(
    runtimeSender: { _ in
      Issue.record("Failed migration must not submit Start.")
      throw ProfileLibraryPersistenceTestFailure.persistence
    },
    profileValidator: { _ in
      Issue.record("Failed migration must not validate or fetch a profile.")
      throw ProfileLibraryPersistenceTestFailure.persistence
    },
    profileLibraryLoader: { try ProfileStore.loadProfileLibrary(from: url) },
    profileLibrarySaver: { _ in Issue.record("Failed migration must not save a blank library.") },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.setCoreEnabled(true)

  #expect(model.profiles.isEmpty)
  #expect(model.selectedProfileID == nil)
  #expect(model.profileLoadIssueMessage?.contains("contact support") == true)
  #expect(try Data(contentsOf: url) == original)
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("profiles.1.1.15.original.json").path))
}

@Test @MainActor func unsupportedFutureLibraryUsesReadOnlyNotice() {
  let model = AppModel(
    profileLibraryLoader: { throw ProfileStoreFailure.unsupportedFutureSchema(12) },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  #expect(!model.profileRecoveryRequired)
  #expect(model.profileLoadIssueMessage?.contains("newer unsupported schema 12") == true)
}

@Test @MainActor func malformedLibraryUsesRecoveryPresentationOnly() {
  let model = AppModel(
    profileLibraryLoader: { throw ProfileStoreFailure.invalidJSON("profiles.invalid-test.json") },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  #expect(model.profileRecoveryRequired)
  #expect(model.profileLoadIssueMessage == nil)
}

@MainActor final class ProfileRestoreS2IsolatedHomeTests: XCTestCase {
  func testRestore() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SBM_S2_RESTORE_CHILD"] == "1" else {
      throw XCTSkip("This test runs only in its isolated HOME subprocess.")
    }
    let profileID = try XCTUnwrap(
      UUID(uuidString: environment["SBM_S2_RESTORE_PROFILE_ID"] ?? "")
    )
    let backupURL = URL(fileURLWithPath: environment["SBM_S2_RESTORE_BACKUP"] ?? "")
    let home = try XCTUnwrap(environment["CFFIXED_USER_HOME"])
    let supportDirectory = try XCTUnwrap(
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    )
    XCTAssertTrue(supportDirectory.path.hasPrefix(home))

    let template = try XCTUnwrap(profileLibrary().profiles.first)
    let currentProfile = ManagedProfile(
      id: profileID,
      name: "Current",
      sources: [ManagedSource(name: "Current source", value: "https://old.example.test/list")],
      payload: template.payload
    )
    try ProfileStore.saveProfileLibrary(
      ProfileLibrary(profiles: [currentProfile], selectedProfileID: profileID)
    )

    let defaults = UserDefaults.standard
    defaults.set(true, forKey: "RestoreLastVPNStateEnabled")
    defaults.set(true, forKey: "LastExplicitVPNIntentConnected")
    let runtimeResponse = HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: "Changes ready to apply"
    )
    let runtime = RuntimeRequestRecorder(response: runtimeResponse)
    let effects = FreshInstallEffectRecorder()
    let manager = SubscriptionManager { value, _ in
      await effects.recordSubscriptionFetch(value)
      throw ProfileLibraryPersistenceTestFailure.persistence
    }
    let model = AppModel(
      environment: .production,
      helperService: PersistenceReadyHelperService(),
      subscriptionManager: manager,
      helperLifecycleSender: { request, _ in await effects.send(request) },
      runtimeSender: { request in await runtime.send(request) },
      helperRequestSender: { request in await effects.send(request) },
      profileValidator: { _ in await effects.validate() },
      userDefaults: defaults,
      performStartup: false
    )
    model.helperEnabled = true
    model.helperReachable = true
    model.helperVersion = HelperConstants.helperVersion
    model.helperRevision = HelperConstants.helperRevision
    model.observedCoreState = .running
    model.setCoreEnabled(true)
    #expect(
      await waitForProfileLibraryCondition { !(model.runtimeApplyStatus != .reconnectRequired) })
    XCTAssertEqual(model.runtimeApplyStatus, .reconnectRequired)
    XCTAssertEqual(model.deferredRuntimeApplyPhase, .pending)

    model.routingInspectorInput = "example.com"
    model.inspectRouting()
    XCTAssertNotNil(model.routingInspectorState.snapshot)
    model.observedCoreState = .stopped

    let badBackup = URL(fileURLWithPath: "/tmp/SBM-S2-bad-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: badBackup) }
    try writeSecureFile(Data(#"{"schemaVersion":"11"}"#.utf8), to: badBackup)
    let preferencesBefore = (
      defaults.bool(forKey: "RestoreLastVPNStateEnabled"),
      defaults.bool(forKey: "LastExplicitVPNIntentConnected")
    )
    let requestsBeforeRestore = await runtime.recordedRequests().count

    model.restoreProfileLibrary(from: badBackup)
    XCTAssertEqual(model.profiles, [currentProfile])
    XCTAssertEqual(model.deferredRuntimeApplyPhase, .pending)
    XCTAssertNotNil(model.routingInspectorState.snapshot)

    model.restoreProfileLibrary(from: backupURL)
    let restored = try XCTUnwrap(try ProfileStore.loadProfileLibrary())
    let importedBackup = try JSONDecoder().decode(
      ProfileLibrary.self, from: Data(contentsOf: backupURL))
    XCTAssertEqual(restored, importedBackup)
    XCTAssertEqual(model.profiles, restored.profiles)
    XCTAssertEqual(model.routingMode, .direct)
    XCTAssertNil(model.selectedSourceID)
    XCTAssertTrue(model.subscriptionURL.isEmpty)
    XCTAssertEqual(model.deferredRuntimeApplyPhase, .idle)
    XCTAssertNil(model.deferredRuntimeApplyError)
    XCTAssertNil(model.deferredRuntimeApplyPresentation)
    XCTAssertEqual(model.runtimeApplyStatus, .saved)
    XCTAssertEqual(model.routingInspectorState, .idle)
    XCTAssertEqual(model.routingInspectorOutput, RoutingInspectorState.idleOutput)
    XCTAssertEqual(preferencesBefore.0, defaults.bool(forKey: "RestoreLastVPNStateEnabled"))
    XCTAssertEqual(preferencesBefore.1, defaults.bool(forKey: "LastExplicitVPNIntentConnected"))
    let requestsAfterRestore = await runtime.recordedRequests().count
    XCTAssertEqual(requestsAfterRestore, requestsBeforeRestore)
    let effectCounts = await effects.counts()
    XCTAssertEqual(effectCounts.helperRequests, 0)
    XCTAssertEqual(effectCounts.subscriptionFetches, 0)
    XCTAssertEqual(effectCounts.validations, 0)
  }
}

@Test func profileRestoreS2UsesIsolatedHomeAndRealProfileStore() throws {
  let root = URL(
    fileURLWithPath: "/tmp/SBM-S2-Restore-\(UUID().uuidString)",
    isDirectory: true
  )
  let home = root.appendingPathComponent("home", isDirectory: true)
  let backupDirectory = root.appendingPathComponent("backup", isDirectory: true)
  let moduleCache = root.appendingPathComponent("module-cache", isDirectory: true)
  for directory in [home, backupDirectory, moduleCache] {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }
  defer { try? FileManager.default.removeItem(at: root) }

  let profileID = UUID()
  let importedProfile = ManagedProfile(
    id: profileID,
    name: "Imported",
    payload: .compatibility(VPNProfile(connections: []))
  )
  let importedLibrary = ProfileLibrary(
    profiles: [importedProfile],
    selectedProfileID: profileID,
    routingMode: .direct
  )
  let backupURL = backupDirectory.appendingPathComponent("profiles.json")
  try writeSecureFile(try JSONEncoder().encode(importedLibrary), to: backupURL)

  var environment = ProcessInfo.processInfo.environment
  environment["HOME"] = home.path
  environment["CFFIXED_USER_HOME"] = home.path
  environment["SBM_S2_RESTORE_CHILD"] = "1"
  environment["SBM_S2_RESTORE_BACKUP"] = backupURL.path
  environment["SBM_S2_RESTORE_PROFILE_ID"] = profileID.uuidString
  environment["CLANG_MODULE_CACHE_PATH"] = moduleCache.path
  environment["SWIFT_MODULECACHE_PATH"] = moduleCache.path
  let testBundleURL = Bundle(for: ProfileRestoreS2IsolatedHomeTests.self).bundleURL
  var discoveryEnvironment = environment
  discoveryEnvironment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
  let xctestDiscovery = try TestProcessSupport.run(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: ["--find", "xctest"],
    timeoutSeconds: 10,
    environment: discoveryEnvironment
  )
  guard xctestDiscovery.status == 0 else {
    Issue.record("Could not resolve xctest executable: \(xctestDiscovery.output)")
    return
  }
  let xctestPath = xctestDiscovery.output.trimmingCharacters(in: .whitespacesAndNewlines)
  guard FileManager.default.isExecutableFile(atPath: xctestPath) else {
    Issue.record("xcrun --find xctest did not return an executable path.")
    return
  }

  let processHandle = try #require(dlopen(nil, RTLD_NOW))
  defer { dlclose(processHandle) }
  if let tsanRuntime = dlsym(processHandle, "__tsan_init") {
    var runtimeInfo = Dl_info()
    guard dladdr(tsanRuntime, &runtimeInfo) != 0, let runtimePath = runtimeInfo.dli_fname else {
      Issue.record("Could not resolve the loaded Thread Sanitizer runtime path.")
      return
    }
    let loadedRuntimePath = String(cString: runtimePath)
    if let inheritedLibraries = environment["DYLD_INSERT_LIBRARIES"], !inheritedLibraries.isEmpty {
      environment["DYLD_INSERT_LIBRARIES"] = "\(loadedRuntimePath):\(inheritedLibraries)"
    } else {
      environment["DYLD_INSERT_LIBRARIES"] = loadedRuntimePath
    }
  }
  let result = try TestProcessSupport.run(
    executableURL: URL(fileURLWithPath: xctestPath),
    arguments: [
      "-XCTest", "ProfileRestoreS2IsolatedHomeTests/testRestore",
      testBundleURL.path,
    ],
    timeoutSeconds: 30,
    currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    environment: environment
  )
  if result.status != 0 {
    Issue.record("Isolated restore subprocess failed: \(result.output)")
  }
  #expect(result.status == 0)
  #expect(result.output.contains("Executed 1 test, with 0 failures"))
}

@Test @MainActor func routingPreferencePersistenceFailureDoesNotSendHelperMutation() async {
  let sender = RuntimeRequestRecorder()
  let model = AppModel(
    runtimeSender: { request in await sender.send(request) },
    profileLibraryLoader: { profileLibrary() },
    profileLibrarySaver: { _ in throw ProfileLibraryPersistenceTestFailure.persistence },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  model.setRoutingMode(.global)
  #expect(model.routingMode == .rule)
  #expect(await sender.recordedActions().isEmpty)
  #expect(model.lastError != nil)
}

@Test @MainActor func selectedNodePersistenceFailureDoesNotSendHelperMutation() async {
  let sender = RuntimeRequestRecorder()
  let model = AppModel(
    runtimeSender: { request in await sender.send(request) },
    profileLibraryLoader: { profileLibrary() },
    profileLibrarySaver: { _ in throw ProfileLibraryPersistenceTestFailure.persistence },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  model.setSelectedNode(ProxyNodeID(rawValue: "node-selected"))
  #expect(model.selectedNodeID == .auto)
  #expect(await sender.recordedActions().isEmpty)
  #expect(model.lastError != nil)
}

@Test @MainActor func failedDNSSavePublishesNothingAndSendsNoRuntimeMutation() async {
  let invalidSender = RuntimeRequestRecorder()
  var invalidSaves = 0
  let invalidModel = AppModel(
    runtimeSender: { request in await invalidSender.send(request) },
    profileLibraryLoader: { profileLibrary() },
    profileLibrarySaver: { _ in invalidSaves += 1 },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  let invalid = ManagedDNSSettings(direct: .system, proxy: .system)
  #expect(!invalidModel.saveDNSSettings(invalid))
  #expect(invalidModel.dnsSettings == .defaults)
  #expect(invalidSaves == 0)
  #expect(await invalidSender.recordedActions().isEmpty)

  let failedSender = RuntimeRequestRecorder()
  let failedModel = AppModel(
    runtimeSender: { request in await failedSender.send(request) },
    profileLibraryLoader: { profileLibrary() },
    profileLibrarySaver: { _ in throw ProfileLibraryPersistenceTestFailure.persistence },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  let candidate = ManagedDNSSettings(direct: .google, proxy: .quad9)
  #expect(!failedModel.saveDNSSettings(candidate))
  #expect(failedModel.dnsSettings == .defaults)
  #expect(await failedSender.recordedActions().isEmpty)
}

@Test @MainActor func stoppedDNSSavePersistsWithoutStartingVPN() async {
  let sender = RuntimeRequestRecorder()
  let library = profileLibrary()
  var saves: [ProfileLibrary] = []
  let model = AppModel(
    runtimeSender: { request in await sender.send(request) },
    profileLibraryLoader: { library },
    profileLibrarySaver: { saves.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.observedCoreState = .stopped
  let candidate = ManagedDNSSettings(direct: .adguard, proxy: .google)

  #expect(model.saveDNSSettings(candidate))
  #expect(model.dnsSettings == candidate)
  #expect(saves.last?.dnsSettings == candidate)
  #expect(await sender.recordedActions().isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func connectedDNSSaveUsesExistingStartApplyWithoutRestartRequest() async {
  let response = HelperResponse(
    success: true,
    coreRunning: true,
    runtimeOutcome: .reconnectRequired,
    message: "Changes ready to apply"
  )
  let sender = RuntimeRequestRecorder(response: response)
  let profile = ManagedProfile(
    name: "DNS",
    payload: .compatibility(VPNProfile(connections: []))
  )
  let library = ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  var saves: [ProfileLibrary] = []
  let model = AppModel(
    runtimeSender: { request in await sender.send(request) },
    profileLibraryLoader: { library },
    profileLibrarySaver: { saves.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.observedCoreState = .running
  let candidate = ManagedDNSSettings(
    direct: .google, proxy: .customDoH("https://dns.example.test/dns"))

  #expect(model.saveDNSSettings(candidate))
  let requests = await sender.waitForActions(1)
  let captured = await sender.recordedRequests()
  #expect(requests == [HelperAction.start.rawValue])
  #expect(captured.first?.dnsSettings == candidate)
  #expect(saves.last?.dnsSettings == candidate)
  #expect(model.dnsSettings == candidate)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func savedRoutingPreferencesContinueThroughExistingRuntimeApplyPath() async {
  let node = ProxyNodeID(rawValue: "node-selected")
  let routingSender = RuntimeRequestRecorder()
  let routingStored = profileLibrary()
  var routingSaves: [ProfileLibrary] = []
  let routingModel = AppModel(
    runtimeSender: { request in await routingSender.send(request) },
    profileLibraryLoader: { routingStored },
    profileLibrarySaver: { routingSaves.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  routingModel.helperEnabled = true
  routingModel.helperReachable = true
  routingModel.helperVersion = HelperConstants.helperVersion
  routingModel.helperRevision = HelperConstants.helperRevision

  routingModel.setRoutingMode(.global)
  let routingActions = await routingSender.waitForActions(1)
  let savedRouting = routingSaves.last
  #expect(routingActions == [HelperAction.setMode.rawValue])
  #expect(savedRouting?.routingMode == .global)
  #expect(routingModel.routingMode == savedRouting?.routingMode)

  let nodeSender = RuntimeRequestRecorder()
  let nodeStored = profileLibrary(routingMode: .global)
  var nodeSaves: [ProfileLibrary] = []
  let nodeModel = AppModel(
    runtimeSender: { request in await nodeSender.send(request) },
    profileLibraryLoader: { nodeStored },
    profileLibrarySaver: { nodeSaves.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  nodeModel.helperEnabled = true
  nodeModel.helperReachable = true
  nodeModel.helperVersion = HelperConstants.helperVersion
  nodeModel.helperRevision = HelperConstants.helperRevision

  nodeModel.setSelectedNode(node)
  let nodeActions = await nodeSender.waitForActions(1)
  let savedNode = nodeSaves.last
  #expect(nodeActions == [HelperAction.setNode.rawValue])
  #expect(savedNode?.routingMode == .global)
  #expect(savedNode?.selectedNodeID == node)
  #expect(nodeModel.routingMode == savedNode?.routingMode)
  #expect(nodeModel.selectedNodeID == savedNode?.selectedNodeID)
}
