import CryptoKit
import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

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

@Test func persistentHelperStateDefaultsRecoveryMarkerForOlderStores() throws {
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

@Test func resettingRequestPresetPreservesHWID() {
  let original = SubscriptionHeaders(
    userAgent: "Custom/1.0",
    deviceOS: "CustomOS",
    hardwareID: "stable-device-id"
  )

  let reset = original.resettingRequestPreset()

  #expect(reset.userAgent == SubscriptionHeaders.defaultUserAgent)
  #expect(reset.deviceOS == SubscriptionHeaders.defaultDeviceOS)
  #expect(reset.hardwareID == "stable-device-id")
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
