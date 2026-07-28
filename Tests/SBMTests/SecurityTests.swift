import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

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
        subscriptionURL: "https://user:secret@example.com/subscription"
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
        "metadata": nested,
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
        "metadata": Array(repeating: 0, count: 5_000),
      ]
    ]
  ])
  let profile = try NativeProfileParser.parse(source)

  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .native(profile), mode: .rule, selectedNode: .auto)
  }
}
