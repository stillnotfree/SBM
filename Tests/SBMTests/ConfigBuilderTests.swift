import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

@Test func generatedConfigurationIsAcceptedByBundledCore() throws {
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let core = project.appendingPathComponent(".vendor/sing-box")
  #expect(FileManager.default.isExecutableFile(atPath: core.path))

  let profile = VPNProfile(
    vless: VLESSProfile(
      server: "203.0.113.10",
      port: 443,
      uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
      serverName: "www.debian.org",
      fingerprint: "chrome",
      publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
      shortID: "bb6b725b",
      displayName: "Reality"
    ),
    hysteria2: Hysteria2Profile(
      server: "vpn.example.com",
      port: 443,
      password: "test-password",
      serverName: "vpn.example.com",
      obfsPassword: "test-obfs-password",
      displayName: "Hysteria2"
    )
  )
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  let built = try ConfigBuilder(
    cachePath: temporary.appendingPathComponent("cache.db").path,
    apiSecret: "test-api-secret"
  ).makeConfiguration(
    profile: .compatibility(profile),
    mode: .rule,
    selectedNode: .auto,
    localSOCKSPort: 1082
  )
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let inbounds = try #require(root["inbounds"] as? [[String: Any]])
  let localSOCKS = try #require(inbounds.first { ($0["tag"] as? String) == "local-socks-in" })
  #expect(localSOCKS["listen"] as? String == "127.0.0.1")
  #expect(localSOCKS["listen_port"] as? Int == 1082)
  let tunnel = try #require(inbounds.first { ($0["tag"] as? String) == "tun-in" })
  #expect(tunnel["mtu"] as? Int == 1400)
  let outbounds = try #require(root["outbounds"] as? [[String: Any]])
  let reality = try #require(outbounds.first { ($0["tag"] as? String) == "reality" })
  #expect(reality["packet_encoding"] as? String == "xudp")
  let route = try #require(root["route"] as? [String: Any])
  let rules = try #require(route["rules"] as? [[String: Any]])
  let directModeIndex = try #require(
    rules.firstIndex { ($0["clash_mode"] as? String) == RoutingMode.direct.rawValue })
  let globalModeIndex = try #require(
    rules.firstIndex { ($0["clash_mode"] as? String) == RoutingMode.global.rawValue })
  #expect(directModeIndex < globalModeIndex)
  #expect(
    !rules.contains {
      ($0["protocol"] as? String) == "quic"
        && ($0["action"] as? String) == "reject"
    })
  let configURL = temporary.appendingPathComponent("config.json")
  try built.data.write(to: configURL)

  let process = Process()
  let output = Pipe()
  process.executableURL = core
  process.arguments = ["check", "-c", configURL.path]
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  let message =
    String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  #expect(process.terminationStatus == 0, Comment(rawValue: message))
}

@Test func singleProtocolConfigurationsAreAcceptedByBundledCore() throws {
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let core = project.appendingPathComponent(".vendor/sing-box")
  #expect(FileManager.default.isExecutableFile(atPath: core.path))

  let profiles: [(VPNProfile, String)] = [
    (
      VPNProfile(
        vless: VLESSProfile(
          server: "203.0.113.10",
          port: 443,
          uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
          serverName: "www.debian.org",
          fingerprint: "chrome",
          publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
          shortID: "bb6b725b",
          displayName: "Reality"
        )
      ),
      ProxyNodeID.reality.rawValue
    ),
    (
      VPNProfile(
        hysteria2: Hysteria2Profile(
          server: "vpn.example.com",
          port: 443,
          password: "test-password",
          serverName: "vpn.example.com",
          displayName: "Hysteria2"
        )
      ),
      ProxyNodeID.hysteria2.rawValue
    ),
  ]

  for (profile, expectedTag) in profiles {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("SBMSingleProtocol-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let built = try ConfigBuilder(
      cachePath: temporary.appendingPathComponent("cache.db").path,
      apiSecret: "test-api-secret"
    ).makeConfiguration(
      profile: .compatibility(profile),
      mode: .rule,
      selectedNode: ProxyNodeID(rawValue: expectedTag)
    )
    let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
    let outbounds = try #require(root["outbounds"] as? [[String: Any]])
    let selector = try #require(outbounds.first { ($0["tag"] as? String) == "proxy-selector" })
    #expect(selector["outbounds"] as? [String] == ["auto", expectedTag])
    let automatic = try #require(outbounds.first { ($0["tag"] as? String) == "auto" })
    #expect(automatic["outbounds"] as? [String] == [expectedTag])
    #expect(outbounds.contains { ($0["tag"] as? String) == expectedTag })

    let configURL = temporary.appendingPathComponent("config.json")
    try built.data.write(to: configURL)
    let process = Process()
    let output = Pipe()
    process.executableURL = core
    process.arguments = ["check", "-c", configURL.path]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let message =
      String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, Comment(rawValue: message))
  }
}

@Test func compatibilityConfigurationSupportsUserRoutingAndPlainHysteria2() throws {
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let core = project.appendingPathComponent(".vendor/sing-box")
  let routing = RoutingPolicy(
    configuration: Data(
      """
      {
        "route": {
          "rules": [
            {
              "domain_suffix": ["google.ru"],
              "action": "route",
              "outbound": "proxy-selector"
            },
            {
              "rule_set": ["ru-domains", "ru-ip"],
              "action": "route",
              "outbound": "direct"
            }
          ],
          "rule_set": [
            {
              "type": "remote",
              "tag": "ru-domains",
              "format": "binary",
              "url": "https://example.com/geosite-ru.srs",
              "download_detour": "proxy-selector",
              "update_interval": "1d"
            },
            {
              "type": "remote",
              "tag": "ru-ip",
              "format": "binary",
              "url": "https://example.com/geoip-ru.srs",
              "download_detour": "proxy-selector",
              "update_interval": "1d"
            }
          ]
        }
      }
      """.utf8)
  )
  let profile = VPNProfile(
    vless: VLESSProfile(
      server: "203.0.113.10",
      port: 443,
      uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
      serverName: "www.debian.org",
      fingerprint: "firefox",
      publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
      shortID: "bb6b725b",
      displayName: "Reality"
    ),
    hysteria2: Hysteria2Profile(
      server: "vpn.example.com",
      port: 443,
      password: "test-password",
      serverName: "vpn.example.com",
      displayName: "Hysteria2"
    ),
    routingPolicy: routing
  )
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMRoutingTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  let built = try ConfigBuilder(
    cachePath: temporary.appendingPathComponent("cache.db").path,
    apiSecret: "test-api-secret"
  ).makeConfiguration(
    profile: .compatibility(profile),
    mode: .rule,
    selectedNode: .auto
  )
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let outbounds = try #require(root["outbounds"] as? [[String: Any]])
  let hysteria2 = try #require(outbounds.first { ($0["tag"] as? String) == "hysteria2" })
  #expect(hysteria2["obfs"] == nil)

  let route = try #require(root["route"] as? [String: Any])
  let rules = try #require(route["rules"] as? [[String: Any]])
  #expect(
    rules.contains {
      ($0["outbound"] as? String) == "proxy-selector"
        && ($0["domain_suffix"] as? [String]) == ["google.ru"]
    })
  #expect(
    rules.contains {
      ($0["outbound"] as? String) == "direct"
        && ($0["rule_set"] as? [String]) == ["ru-domains", "ru-ip"]
    })

  let dns = try #require(root["dns"] as? [String: Any])
  let dnsRules = try #require(dns["rules"] as? [[String: Any]])
  #expect(
    !dnsRules.contains {
      ($0["server"] as? String) == "dns-local"
        && $0["rule_set"] != nil
    })
  let lastDNSRule = try #require(dnsRules.last)
  #expect(
    lastDNSRule["server"] as? String == "dns-remote"
      && Set(lastDNSRule.keys) == ["action", "server"])

  let configURL = temporary.appendingPathComponent("config.json")
  try built.data.write(to: configURL)
  let process = Process()
  let output = Pipe()
  process.executableURL = core
  process.arguments = ["check", "-c", configURL.path]
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  let message =
    String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  #expect(process.terminationStatus == 0, Comment(rawValue: message))
}

@Test func routingPolicyRejectsUnmanagedOutbounds() throws {
  let policy = RoutingPolicy(
    configuration: Data(
      """
      {
        "route": {
          "rules": [
            {
              "domain_suffix": ["example.ru"],
              "action": "route",
              "outbound": "block"
            }
          ]
        }
      }
      """.utf8)
  )
  let profile = VPNProfile(
    vless: VLESSProfile(
      server: "203.0.113.10",
      port: 443,
      uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
      serverName: "www.debian.org",
      fingerprint: "firefox",
      publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
      shortID: "bb6b725b",
      displayName: "Reality"
    ),
    hysteria2: Hysteria2Profile(
      server: "vpn.example.com",
      port: 443,
      password: "test-password",
      serverName: "vpn.example.com",
      displayName: "Hysteria2"
    ),
    routingPolicy: policy
  )
  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  }
}

@Test func nativeProfileBuildsDynamicSelectorAndPassesCoreCheck() throws {
  let source = Data(
    """
    {
      "outbounds": [
        {
          "type": "socks",
          "tag": "office-proxy",
          "server": "203.0.113.20",
          "server_port": 1080
        }
      ],
      "route": {
        "rules": [
          { "domain_suffix": ["example.org"], "action": "route", "outbound": "office-proxy" }
        ]
      },
      "sbm": {
        "display_names": { "office-proxy": "Office" }
      }
    }
    """.utf8)
  let native = try NativeProfileParser.parse(source)
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMNativeTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  let built = try ConfigBuilder(
    cachePath: temporary.appendingPathComponent("cache.db").path,
    apiSecret: "test-api-secret"
  ).makeConfiguration(
    profile: .native(native),
    mode: .rule,
    selectedNode: ProxyNodeID(rawValue: "office-proxy")
  )
  #expect(built.selectorTag == "sbm-selector")
  #expect(built.nodes.map(\.name) == ["Auto", "Office"])

  let configURL = temporary.appendingPathComponent("config.json")
  try built.data.write(to: configURL)
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let process = Process()
  let output = Pipe()
  process.executableURL = project.appendingPathComponent(".vendor/sing-box")
  process.arguments = ["check", "-c", configURL.path]
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  let message =
    String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  #expect(process.terminationStatus == 0, Comment(rawValue: message))
}

@Test func nativeProfileExposesUserspaceEndpointAndPassesCoreCheck() throws {
  let source = Data(
    """
    {
      "endpoints": [
        {
          "type": "wireguard",
          "tag": "office-wg",
          "system": false,
          "address": ["10.7.0.2/32"],
          "private_key": "0FIAKxthxpx09BQ1j7xDTzbppW7bjlF6tHW6VjQkDE0=",
          "peers": [
            {
              "address": "203.0.113.30",
              "port": 51820,
              "public_key": "7MKWPSI3/VH/xHe01nC7HhvyGwYj8393kKDrbIilphM=",
              "allowed_ips": ["0.0.0.0/0"]
            }
          ]
        }
      ],
      "sbm": {
        "display_names": { "office-wg": "Office WireGuard" }
      }
    }
    """.utf8)
  let native = try NativeProfileParser.parse(source)
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMEndpointTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  let built = try ConfigBuilder(
    cachePath: temporary.appendingPathComponent("cache.db").path,
    apiSecret: "test-api-secret"
  ).makeConfiguration(
    profile: .native(native),
    mode: .rule,
    selectedNode: ProxyNodeID(rawValue: "office-wg")
  )
  #expect(built.nodes.map(\.name) == ["Auto", "Office WireGuard"])
  #expect(built.selectedNode.rawValue == "office-wg")

  let configURL = temporary.appendingPathComponent("config.json")
  try built.data.write(to: configURL)
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let process = Process()
  let output = Pipe()
  process.executableURL = project.appendingPathComponent(".vendor/sing-box")
  process.arguments = ["check", "-c", configURL.path]
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  let message =
    String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  #expect(process.terminationStatus == 0, Comment(rawValue: message))
}

@Test func nativeProfileRejectsPrivilegedLocalPaths() throws {
  let source = Data(
    """
    {
      "outbounds": [
        {
          "type": "ssh",
          "tag": "unsafe",
          "server": "203.0.113.20",
          "server_port": 22,
          "user": "root",
          "private_key_path": "/etc/shadow"
        }
      ]
    }
    """.utf8)
  let native = try NativeProfileParser.parse(source)
  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .native(native), mode: .rule, selectedNode: .auto)
  }
}

@Test func nativeProfileAllowsProtocolTransportPath() throws {
  let source = Data(
    """
    {
      "outbounds": [
        {
          "type": "vless",
          "tag": "websocket-proxy",
          "server": "203.0.113.20",
          "server_port": 443,
          "uuid": "5efab93b-90d0-4904-93d6-44b4f0b00000",
          "transport": { "type": "ws", "path": "/gateway" }
        }
      ]
    }
    """.utf8)
  let native = try NativeProfileParser.parse(source)
  let built = try ConfigBuilder(
    cachePath: "/safe/cache",
    apiSecret: "secret"
  ).makeConfiguration(profile: .native(native), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let outbounds = try #require(root["outbounds"] as? [[String: Any]])
  let outbound = try #require(
    outbounds.first { ($0["tag"] as? String) == "websocket-proxy" })
  let transport = try #require(outbound["transport"] as? [String: Any])
  #expect(transport["path"] as? String == "/gateway")
}

@Test func nativeProfileRejectsTailscaleEndpointState() throws {
  let source = Data(
    """
    {
      "endpoints": [
        {
          "type": "tailscale",
          "tag": "unsafe-tailnet",
          "auth_key": "tskey-auth-example",
          "state_directory": "/tmp/untrusted-state"
        }
      ]
    }
    """.utf8)
  let native = try NativeProfileParser.parse(source)
  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .native(native), mode: .rule, selectedNode: .auto)
  }
}

@Test func nativeProfileRejectsImportedHTTPClients() throws {
  let source = Data(
    """
    {
      "outbounds": [
        { "type": "socks", "tag": "proxy", "server": "203.0.113.20", "server_port": 1080 }
      ],
      "http_clients": {
        "unsafe": {
          "tls": {
            "enabled": true,
            "acme": { "data_directory": "/tmp/acme" }
          }
        }
      }
    }
    """.utf8)
  let native = try NativeProfileParser.parse(source)
  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .native(native), mode: .rule, selectedNode: .auto)
  }
}

@Test func nativeProfileRejectsLocalRuleSetPath() throws {
  let source = Data(
    """
    {
      "outbounds": [
        { "type": "socks", "tag": "proxy", "server": "203.0.113.20", "server_port": 1080 }
      ],
      "route": {
        "rule_set": [
          { "type": "local", "tag": "unsafe", "format": "binary", "path": "/etc/passwd" }
        ]
      }
    }
    """.utf8)
  let native = try NativeProfileParser.parse(source)
  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .native(native), mode: .rule, selectedNode: .auto)
  }
}
