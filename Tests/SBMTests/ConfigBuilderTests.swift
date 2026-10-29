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
    vless: [
      VLESSProfile(
        server: "203.0.113.10",
        port: 443,
        uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
        serverName: "www.debian.org",
        fingerprint: "chrome",
        publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
        shortID: "",
        displayName: "Reality"
      )
    ],
    hysteria2: [
      Hysteria2Profile(
        server: "vpn.example.com",
        port: 443,
        password: "test-password",
        serverName: "vpn.example.com",
        obfsPassword: "test-obfs-password",
        displayName: "Hysteria2"
      )
    ],
    shadowsocks: [
      ShadowsocksProfile(
        server: "ss.example.com",
        port: 443,
        method: "aes-256-gcm",
        password: "test-password",
        displayName: "Shadowsocks"
      )
    ]
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
  #expect(tunnel["dns_mode"] as? String == "disabled")
  #expect(
    Set(tunnel.keys)
      == [
        "type", "tag", "address", "mtu", "auto_route", "strict_route", "dns_mode", "stack",
        "udp_timeout",
      ]
  )
  let tunnelAddresses = try #require(tunnel["address"] as? [String])
  #expect(tunnelAddresses.contains("172.19.0.1/30"))
  #expect(tunnelAddresses.contains("fdfe:dcba:9876::1/126"))
  let outbounds = try #require(root["outbounds"] as? [[String: Any]])
  let reality = try #require(outbounds.first { ($0["tag"] as? String) == "vless-1" })
  #expect(reality["packet_encoding"] as? String == "xudp")
  let hysteria2 = try #require(outbounds.first { ($0["tag"] as? String) == "hysteria2-1" })
  #expect(hysteria2["disable_chrome_parrot"] as? Bool == true)
  #expect(
    Set(hysteria2.keys)
      == [
        "type", "tag", "server", "server_port", "password", "tls", "domain_resolver", "obfs",
        "disable_chrome_parrot",
      ]
  )
  let obfs = try #require(hysteria2["obfs"] as? [String: Any])
  #expect(Set(obfs.keys) == ["type", "password"])
  #expect(obfs["type"] as? String == "salamander")
  let route = try #require(root["route"] as? [String: Any])
  let rules = try #require(route["rules"] as? [[String: Any]])
  #expect(
    rules.contains {
      ($0["protocol"] as? String) == "dns"
        && ($0["action"] as? String) == "hijack-dns"
    })
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

  let result = try TestProcessSupport.run(
    executableURL: core,
    arguments: ["check", "-c", configURL.path]
  )
  #expect(result.status == 0, Comment(rawValue: result.output))
}

@Test func managedDNSChoicesKeepStableTagsAndBuildOnlyRequiredBootstrap() throws {
  let profile = CoreProfile.compatibility(
    VPNProfile(connections: [
      ManagedConnection(
        id: ProxyNodeID(rawValue: "node-dns"),
        outbound: .shadowsocks(
          ShadowsocksProfile(
            server: "proxy.example.test", port: 443, method: "aes-128-gcm", password: "secret"
          )
        )
      )
    ]))
  let builder = ConfigBuilder(cachePath: "/tmp/dns-cache.db", apiSecret: "dns-test")
  func root(_ settings: ManagedDNSSettings) throws -> [String: Any] {
    let built = try builder.makeConfiguration(
      profile: profile, mode: .rule, selectedNode: .auto, dnsSettings: settings
    )
    return try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  }
  func server(_ root: [String: Any], tag: String) throws -> [String: Any] {
    let dns = try #require(root["dns"] as? [String: Any])
    let servers = try #require(dns["servers"] as? [[String: Any]])
    return try #require(servers.first { ($0["tag"] as? String) == tag })
  }
  let builtIns: [(ManagedDNSChoice, String, String)] = [
    (.cloudflare, "1.1.1.1", "cloudflare-dns.com"),
    (.google, "8.8.8.8", "dns.google"),
    (.yandex, "77.88.8.8", "common.dot.dns.yandex.net"),
    (.quad9, "9.9.9.9", "dns.quad9.net"),
    (.adguard, "94.140.14.140", "unfiltered.adguard-dns.com"),
  ]
  let defaultRoot = try root(.defaults)
  let defaultLocal = try server(defaultRoot, tag: "dns-local")
  let defaultRemote = try server(defaultRoot, tag: "dns-remote")
  #expect(defaultLocal["type"] as? String == "local")
  #expect(defaultRemote["server"] as? String == "1.1.1.1")
  #expect(defaultRemote["detour"] as? String == "proxy-selector")
  #expect(Set(defaultRemote.keys) == ["type", "tag", "server", "detour", "tls"])
  let defaultTLS = try #require(defaultRemote["tls"] as? [String: Any])
  #expect(defaultTLS["server_name"] as? String == "cloudflare-dns.com")

  for (choice, address, name) in builtIns {
    let direct = try server(root(.init(direct: choice)), tag: "dns-local")
    let directTLS = try #require(direct["tls"] as? [String: Any])
    #expect(direct["server"] as? String == address)
    #expect(direct["detour"] as? String == "direct")
    #expect(directTLS["enabled"] as? Bool == true)
    #expect(directTLS["server_name"] as? String == name)
    #expect(direct["domain_resolver"] == nil)

    let proxy = try server(root(.init(proxy: choice)), tag: "dns-remote")
    let proxyTLS = try #require(proxy["tls"] as? [String: Any])
    #expect(proxy["server"] as? String == address)
    #expect(proxy["detour"] as? String == "proxy-selector")
    #expect(proxyTLS["server_name"] as? String == name)
    #expect(proxy["domain_resolver"] == nil)
  }

  let directIP = try root(.init(direct: .customDoH("https://203.0.113.53")))
  let directIPServer = try server(directIP, tag: "dns-local")
  let directIPTLS = try #require(directIPServer["tls"] as? [String: Any])
  #expect(directIPServer["server"] as? String == "203.0.113.53")
  #expect(directIPServer["server_port"] as? Int == 443)
  #expect(directIPServer["path"] as? String == "/dns-query")
  #expect(directIPServer["detour"] as? String == "direct")
  #expect(directIPServer["domain_resolver"] == nil)
  #expect(directIPTLS["server_name"] == nil)

  let directHost = try root(
    .init(direct: .customDoH("https://direct-doh.example.test:8443/resolve"))
  )
  let directHostServer = try server(directHost, tag: "dns-local")
  let directHostTLS = try #require(directHostServer["tls"] as? [String: Any])
  #expect(directHostServer["server"] as? String == "direct-doh.example.test")
  #expect(directHostServer["server_port"] as? Int == 8443)
  #expect(directHostServer["path"] as? String == "/resolve")
  #expect(directHostServer["domain_resolver"] as? String == "dns-bootstrap")
  #expect(directHostTLS["server_name"] as? String == "direct-doh.example.test")
  let hostDNS = try #require(directHost["dns"] as? [String: Any])
  let hostServers = try #require(hostDNS["servers"] as? [[String: Any]])
  #expect(hostServers.first?["tag"] as? String == "dns-bootstrap")
  #expect(hostServers.first?["type"] as? String == "local")

  for settings in [
    ManagedDNSSettings(proxy: .customDoH("https://203.0.113.54")),
    ManagedDNSSettings(proxy: .customDoH("https://proxy-doh.example.test/query")),
  ] {
    let generated = try root(settings)
    let proxy = try server(generated, tag: "dns-remote")
    let dns = try #require(generated["dns"] as? [String: Any])
    let servers = try #require(dns["servers"] as? [[String: Any]])
    let rules = try #require(dns["rules"] as? [[String: Any]])
    #expect(!servers.contains { ($0["tag"] as? String) == "dns-bootstrap" })
    #expect(!rules.contains { ($0["server"] as? String) == "dns-bootstrap" })
    if proxy["server"] as? String == "proxy-doh.example.test" {
      #expect(proxy["domain_resolver"] as? String == "dns-local")
    } else {
      #expect(proxy["domain_resolver"] == nil)
      let tls = try #require(proxy["tls"] as? [String: Any])
      #expect(tls["server_name"] == nil)
    }
  }

  let dns = try #require(defaultRoot["dns"] as? [String: Any])
  let rules = try #require(dns["rules"] as? [[String: Any]])
  #expect(dns["final"] as? String == "dns-remote")
  #expect(rules.last?["server"] as? String == "dns-remote")
  #expect(!rules.contains { ($0["server"] as? String) == "dns-bootstrap" })
  let tun = try #require((defaultRoot["inbounds"] as? [[String: Any]])?.first)
  #expect(tun["dns_mode"] as? String == "disabled")
  let routeRules = try #require(
    (defaultRoot["route"] as? [String: Any])?["rules"] as? [[String: Any]])
  #expect(
    routeRules.contains {
      ($0["protocol"] as? String) == "dns" && ($0["action"] as? String) == "hijack-dns"
    })
  let outbounds = try #require(defaultRoot["outbounds"] as? [[String: Any]])
  let proxyOutbound = try #require(outbounds.first { ($0["tag"] as? String) == "node-dns" })
  #expect(proxyOutbound["domain_resolver"] as? String == "dns-local")
}

@Test func managedDNSMatrixPassesExactPinnedCore() throws {
  let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".vendor/sing-box")
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMManagedDNS-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let profile = CoreProfile.compatibility(
    VPNProfile(connections: [
      ManagedConnection(
        id: ProxyNodeID(rawValue: "node-dns"),
        outbound: .shadowsocks(
          ShadowsocksProfile(
            server: "proxy.example.test", port: 443, method: "aes-128-gcm", password: "secret"
          )
        )
      )
    ]))
  let direct: [(String, ManagedDNSChoice)] = [
    ("direct-system", .system), ("direct-cloudflare", .cloudflare),
    ("direct-google", .google), ("direct-yandex", .yandex),
    ("direct-quad9", .quad9), ("direct-adguard", .adguard),
    ("direct-custom-ip", .customDoH("https://203.0.113.53/dns-query")),
    ("direct-custom-host", .customDoH("https://direct-doh.example.test:8443/query")),
    (
      "direct-custom-unicode-path",
      .customDoH(
        "https://direct-doh.example.test/" + String(repeating: "é", count: 10)
      )
    ),
  ]
  let proxy: [(String, ManagedDNSChoice)] = [
    ("proxy-cloudflare", .cloudflare), ("proxy-google", .google),
    ("proxy-yandex", .yandex), ("proxy-quad9", .quad9), ("proxy-adguard", .adguard),
    ("proxy-custom-ip", .customDoH("https://203.0.113.54/dns-query")),
    ("proxy-custom-host", .customDoH("https://proxy-doh.example.test:9443/query")),
  ]
  var cases = direct.map { (name: $0.0, settings: ManagedDNSSettings(direct: $0.1)) }
  cases += proxy.map { (name: $0.0, settings: ManagedDNSSettings(proxy: $0.1)) }
  #expect(cases.count == 16)

  for (name, settings) in cases {
    let built = try ConfigBuilder(
      cachePath: temporary.appendingPathComponent("cache.db").path,
      apiSecret: "dns-matrix"
    ).makeConfiguration(
      profile: profile, mode: .rule, selectedNode: .auto, dnsSettings: settings
    )
    let configuration = temporary.appendingPathComponent("\(name).json")
    try built.data.write(to: configuration)
    let result = try TestProcessSupport.run(
      executableURL: core,
      arguments: ["check", "-c", configuration.path]
    )
    #expect(result.status == 0, Comment(rawValue: "\(name): \(result.output)"))
  }
}

@Test func managedCustomDoHValidationPreservesExplicitPortsAndBoundsURLBytes() throws {
  for value in [
    "https://resolver.example.test/dns-query",
    "https://203.0.113.53/dns-query",
    "https://[2001:db8::53]:8443/dns-query",
  ] {
    let settings = try ManagedDNSSettings(
      direct: .customDoH(value), proxy: .cloudflare
    ).validated()
    #expect(settings.direct == .customDoH(value))
  }

  let maximumLengthPrefix = "https://resolver.example.test/"
  let maximumLengthURL =
    maximumLengthPrefix
    + String(repeating: "x", count: 4096 - maximumLengthPrefix.utf8.count)
  #expect(maximumLengthURL.utf8.count == 4096)
  #expect(
    try ManagedDNSSettings(direct: .customDoH(maximumLengthURL), proxy: .cloudflare)
      .validated().direct == .customDoH(maximumLengthURL)
  )
  let oversizedURL = maximumLengthURL + "x"
  #expect(throws: DecodingError.self) {
    try ManagedDNSSettings(direct: .customDoH(oversizedURL), proxy: .cloudflare).validated()
  }

  let expandedUnicodeURL = "https://resolver.example.test/" + String(repeating: "é", count: 1000)
  let expandedSource = try #require(URLComponents(string: expandedUnicodeURL)?.string)
  #expect(expandedUnicodeURL.utf8.count <= 4096)
  #expect(expandedSource.utf8.count > 4096)
  #expect(throws: DecodingError.self) {
    try ManagedDNSSettings(direct: .customDoH(expandedUnicodeURL), proxy: .cloudflare).validated()
  }

  let smallUnicodeURL = "https://direct-doh.example.test/" + String(repeating: "é", count: 10)
  let smallUnicodeSource = try #require(URLComponents(string: smallUnicodeURL)?.string)
  #expect(smallUnicodeURL.utf8.count <= 4096)
  #expect(smallUnicodeSource.utf8.count <= 4096)
  #expect(
    try ManagedDNSSettings(direct: .customDoH(smallUnicodeURL), proxy: .cloudflare)
      .validated().direct == .customDoH(smallUnicodeURL)
  )

  let invalid = [
    "https://resolver.example.test:0/dns-query",
    "https://resolver.example.test:65536/dns-query",
    "https://resolver.example.test:bad/dns-query",
    "https://resolver.example.test:/dns-query",
    "https://resolver.example.test:\(String(repeating: "9", count: 1000))/dns-query",
    "https://user:secret@resolver.example.test/dns-query",
    "https://resolver.example.test/dns-query?name=value",
    "https://resolver.example.test/dns-query#fragment",
  ]
  for value in invalid {
    #expect(throws: DecodingError.self) {
      try ManagedDNSSettings(direct: .customDoH(value), proxy: .cloudflare).validated()
    }
  }
  #expect(throws: DecodingError.self) {
    try ManagedDNSSettings(direct: .system, proxy: .system).validated()
  }
}

@Test func managedShadowsocksConfigurationUsesStableTagAndExactOutbound() throws {
  let profile = VPNProfile(connections: [
    ManagedConnection(
      id: ProxyNodeID(rawValue: "node-stable-ss"),
      outbound: .shadowsocks(
        ShadowsocksProfile(
          server: "ss.example.com", port: 8443, method: "aes-256-gcm",
          password: "test-password", displayName: "SS"
        ))
    )
  ])
  let built = try ConfigBuilder(cachePath: "/tmp/cache.db", apiSecret: "test-secret")
    .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let outbounds = try #require(root["outbounds"] as? [[String: Any]])
  let shadowsocks = try #require(outbounds.first { ($0["tag"] as? String) == "node-stable-ss" })
  #expect(shadowsocks["type"] as? String == "shadowsocks")
  #expect(shadowsocks["tag"] as? String == "node-stable-ss")
  #expect(shadowsocks["server"] as? String == "ss.example.com")
  #expect(shadowsocks["server_port"] as? Int == 8443)
  #expect(shadowsocks["method"] as? String == "aes-256-gcm")
  #expect(shadowsocks["password"] as? String == "test-password")
  #expect(shadowsocks["domain_resolver"] as? String == "dns-local")
  let selector = try #require(outbounds.first { ($0["tag"] as? String) == "proxy-selector" })
  #expect(selector["outbounds"] as? [String] == ["auto", "node-stable-ss"])
  #expect(built.nodes.map(\.id.rawValue) == ["auto", "node-stable-ss"])
  #expect(built.nodes.map(\.kind) == [.automatic, .shadowsocks])
}

@Test func shadowsocksCipherValidityRemainsWithThePinnedCore() throws {
  let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".vendor/sing-box")
  #expect(FileManager.default.isExecutableFile(atPath: core.path))
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMTests-SS-Cipher-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  func configuration(method: String, password: String) throws -> BuiltConfiguration {
    let parsed = try SubscriptionClient.parsePayload(
      "ss://\(method):\(password)@ss.example.test:443/#Cipher"
    )
    guard case .compatibility(let profile) = parsed else {
      throw SubscriptionFailure.invalidShadowsocks
    }
    return try ConfigBuilder(
      cachePath: temporary.appendingPathComponent("cache.db").path,
      apiSecret: "test-secret"
    ).makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  }

  for (method, password, expectedStatus) in [
    ("aes-192-gcm", "password", 0),
    ("definitely-not-a-cipher", "password", 1),
    ("2022-blake3-aes-128-gcm", "c2hvcnQ=", 1),
  ] {
    let built = try configuration(method: method, password: password)
    let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
    let outbounds = try #require(root["outbounds"] as? [[String: Any]])
    let shadowsocks = try #require(outbounds.first { ($0["type"] as? String) == "shadowsocks" })
    #expect(shadowsocks["method"] as? String == method)
    let config = temporary.appendingPathComponent("\(method).json")
    try built.data.write(to: config)
    let result = try TestProcessSupport.run(
      executableURL: core,
      arguments: ["check", "-c", config.path]
    )
    #expect(result.status == expectedStatus, Comment(rawValue: result.output))
  }
}

@Test func autoExclusionsOnlyNarrowAutoAndAllExcludedUsesValidatedBlockOutbound() throws {
  let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".vendor/sing-box")
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-AutoExclusions-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let firstID = ProxyNodeID(rawValue: "node-first")
  let secondID = ProxyNodeID(rawValue: "node-second")
  let connections = [
    ManagedConnection(
      id: firstID,
      outbound: .shadowsocks(
        ShadowsocksProfile(
          server: "first.example.test", port: 443, method: "aes-128-gcm", password: "first"
        ))
    ),
    ManagedConnection(
      id: secondID,
      outbound: .shadowsocks(
        ShadowsocksProfile(
          server: "second.example.test", port: 443, method: "aes-256-gcm", password: "second"
        ))
    ),
  ]
  func build(_ excluded: [ProxyNodeID], selected: ProxyNodeID = .auto) throws -> BuiltConfiguration
  {
    try ConfigBuilder(
      cachePath: temporary.appendingPathComponent("cache.db").path,
      apiSecret: "test-secret"
    ).makeConfiguration(
      profile: .compatibility(
        VPNProfile(connections: connections, autoExcludedNodeIDs: excluded)
      ),
      mode: .rule,
      selectedNode: selected
    )
  }
  func checkWithPinnedCore(_ built: BuiltConfiguration, name: String) throws {
    let configurationURL = temporary.appendingPathComponent("\(name).json")
    try built.data.write(to: configurationURL)
    let result = try TestProcessSupport.run(
      executableURL: core,
      arguments: ["check", "-c", configurationURL.path]
    )
    #expect(result.status == 0, Comment(rawValue: result.output))
  }

  let partial = try build([firstID])
  let partialRoot = try #require(JSONSerialization.jsonObject(with: partial.data) as? [String: Any])
  let partialOutbounds = try #require(partialRoot["outbounds"] as? [[String: Any]])
  let selector = try #require(partialOutbounds.first { ($0["tag"] as? String) == "proxy-selector" })
  let auto = try #require(partialOutbounds.first { ($0["tag"] as? String) == "auto" })
  #expect(selector["outbounds"] as? [String] == ["auto", "node-first", "node-second"])
  #expect(auto["type"] as? String == "urltest")
  #expect(auto["outbounds"] as? [String] == ["node-second"])
  #expect(partialOutbounds.contains { ($0["tag"] as? String) == "node-first" })
  try checkWithPinnedCore(partial, name: "partial")

  let allExcluded = try build([firstID, secondID], selected: firstID)
  let blockedRoot = try #require(
    JSONSerialization.jsonObject(with: allExcluded.data) as? [String: Any]
  )
  let blockedOutbounds = try #require(blockedRoot["outbounds"] as? [[String: Any]])
  let manualSelector = try #require(
    blockedOutbounds.first { ($0["tag"] as? String) == "proxy-selector" }
  )
  let blockedAuto = try #require(blockedOutbounds.first { ($0["tag"] as? String) == "auto" })
  #expect(manualSelector["outbounds"] as? [String] == ["auto", "node-first", "node-second"])
  #expect(manualSelector["default"] as? String == "node-first")
  #expect(blockedAuto["type"] as? String == "block")
  #expect(blockedOutbounds.contains { ($0["tag"] as? String) == "node-first" })
  #expect(blockedOutbounds.contains { ($0["tag"] as? String) == "node-second" })
  try checkWithPinnedCore(allExcluded, name: "all-excluded")

  #expect(throws: CoreFailure.self) { try build([firstID, firstID]) }
  #expect(throws: CoreFailure.self) { try build([ProxyNodeID(rawValue: "unknown")]) }
  #expect(throws: CoreFailure.self) { try build([.auto]) }
}

@Test func managedConfigurationRejectsUnsafeIDsAndGroups() {
  func build(_ profile: VPNProfile) throws {
    _ = try ConfigBuilder(cachePath: "/tmp/cache.db", apiSecret: "test-secret")
      .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  }
  let validOutbound = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "ss.example.com", port: 443, method: "aes-128-gcm", password: "password",
      displayName: "SS"
    ))
  #expect(throws: CoreFailure.self) {
    try build(
      VPNProfile(connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "node-кириллица"), outbound: validOutbound
        )
      ]))
  }
  #expect(throws: CoreFailure.self) {
    try build(
      VPNProfile(
        connections: [
          ManagedConnection(id: ProxyNodeID(rawValue: "node-one"), outbound: validOutbound)
        ],
        nodeGroups: [
          ProxyNodeGroup(
            id: "group-two", name: "Invalid nodes",
            nodes: [ProxyNodeID(rawValue: "node-one"), ProxyNodeID(rawValue: "node-one")]
          )
        ]
      ))
  }
  #expect(throws: CoreFailure.self) {
    try build(
      VPNProfile(
        connections: [
          ManagedConnection(id: ProxyNodeID(rawValue: "node-one"), outbound: validOutbound)
        ],
        nodeGroups: [
          ProxyNodeGroup(id: "group", name: "One", nodes: [ProxyNodeID(rawValue: "node-one")]),
          ProxyNodeGroup(id: "group", name: "Two", nodes: [ProxyNodeID(rawValue: "node-one")]),
        ]
      ))
  }
}

@Test func singleProtocolConfigurationsAreAcceptedByBundledCore() throws {
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let core = project.appendingPathComponent(".vendor/sing-box")
  #expect(FileManager.default.isExecutableFile(atPath: core.path))

  let profiles: [(VPNProfile, String)] = [
    (
      VPNProfile(
        vless: [
          VLESSProfile(
            server: "203.0.113.10",
            port: 443,
            uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
            serverName: "www.debian.org",
            fingerprint: "chrome",
            publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
            shortID: "bb6b725b",
            displayName: "Reality"
          )
        ]
      ),
      "vless-1"
    ),
    (
      VPNProfile(
        hysteria2: [
          Hysteria2Profile(
            server: "vpn.example.com",
            port: 443,
            password: "test-password",
            serverName: "vpn.example.com",
            displayName: "Hysteria2"
          )
        ]
      ),
      "hysteria2-1"
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
    let result = try TestProcessSupport.run(
      executableURL: core,
      arguments: ["check", "-c", configURL.path]
    )
    #expect(result.status == 0, Comment(rawValue: result.output))
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
            },
            {
              "domain_suffix": ["inverted.example"],
              "invert": true,
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
    vless: [
      VLESSProfile(
        server: "203.0.113.10",
        port: 443,
        uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
        serverName: "www.debian.org",
        fingerprint: "firefox",
        publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
        shortID: "bb6b725b",
        displayName: "Reality"
      )
    ],
    hysteria2: [
      Hysteria2Profile(
        server: "vpn.example.com",
        port: 443,
        password: "test-password",
        serverName: "vpn.example.com",
        displayName: "Hysteria2"
      )
    ],
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
  let hysteria2 = try #require(outbounds.first { ($0["tag"] as? String) == "hysteria2-1" })
  #expect(hysteria2["obfs"] == nil)
  #expect(hysteria2["disable_chrome_parrot"] as? Bool == true)
  #expect(
    Set(hysteria2.keys)
      == [
        "type", "tag", "server", "server_port", "password", "tls", "domain_resolver",
        "disable_chrome_parrot",
      ]
  )

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
  #expect(
    !dnsRules.contains {
      ($0["server"] as? String) == "dns-local"
        && ($0["domain_suffix"] as? [String]) == ["inverted.example"]
    })
  let lastDNSRule = try #require(dnsRules.last)
  #expect(
    lastDNSRule["server"] as? String == "dns-remote"
      && Set(lastDNSRule.keys) == ["action", "server"])

  let configURL = temporary.appendingPathComponent("config.json")
  try built.data.write(to: configURL)
  let result = try TestProcessSupport.run(
    executableURL: core,
    arguments: ["check", "-c", configURL.path]
  )
  #expect(result.status == 0, Comment(rawValue: result.output))
}

@Test func hysteria2PortHoppingMapsExactFieldsAndPassesPinnedCore() throws {
  let cases: [(tag: String, server: String, ranges: [Hysteria2PortRange], obfsPassword: String?)] =
    [
      (
        "h2-range", "vpn.example.test", [Hysteria2PortRange(start: 20000, end: 50000)], nil
      ),
      (
        "h2-discrete", "vpn.example.test",
        [
          Hysteria2PortRange(start: 1234, end: 1234),
          Hysteria2PortRange(start: 5678, end: 5678),
        ], nil
      ),
      (
        "h2-ipv6", "[2001:db8::2]", [Hysteria2PortRange(start: 443, end: 8443)], nil
      ),
      (
        "h2-salamander", "vpn.example.test",
        [Hysteria2PortRange(start: 443, end: 8443)], "test-obfs-password"
      ),
    ]
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMHysteria2Hopping-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let builder = ConfigBuilder(
    cachePath: temporary.appendingPathComponent("cache.db").path,
    apiSecret: "test-api-secret"
  )
  let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".vendor/sing-box")
  #expect(FileManager.default.isExecutableFile(atPath: core.path))

  for item in cases {
    let profile = VPNProfile(connections: [
      ManagedConnection(
        id: ProxyNodeID(rawValue: item.tag),
        displayName: "Hysteria2",
        outbound: .hysteria2(
          Hysteria2Profile(
            server: item.server,
            port: item.ranges[0].start,
            password: "test-password",
            serverName: "vpn.example.test",
            obfsPassword: item.obfsPassword,
            portHoppingRanges: item.ranges
          )
        )
      )
    ])
    let built = try builder.makeConfiguration(
      profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
    let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
    let outbounds = try #require(root["outbounds"] as? [[String: Any]])
    let outbound = try #require(outbounds.first { ($0["tag"] as? String) == item.tag })
    var expectedKeys: Set<String> = [
      "type", "tag", "server", "server_ports", "password", "tls", "domain_resolver",
      "disable_chrome_parrot",
    ]
    if item.obfsPassword != nil { expectedKeys.insert("obfs") }
    #expect(Set(outbound.keys) == expectedKeys)
    #expect(outbound["server"] as? String == item.server)
    #expect(outbound["server_port"] == nil)
    #expect(outbound["server_ports"] as? [String] == item.ranges.map { "\($0.start):\($0.end)" })
    #expect(outbound["hop_interval"] == nil)
    #expect(outbound["hop_interval_max"] == nil)
    #expect(outbound["disable_chrome_parrot"] as? Bool == true)
    let tls = try #require(outbound["tls"] as? [String: Any])
    #expect(tls["server_name"] as? String == "vpn.example.test")
    if let password = item.obfsPassword {
      let obfs = try #require(outbound["obfs"] as? [String: Any])
      #expect(obfs["type"] as? String == "salamander")
      #expect(obfs["password"] as? String == password)
    }

    let configURL = temporary.appendingPathComponent("\(item.tag).json")
    try built.data.write(to: configURL)
    let result = try TestProcessSupport.run(
      executableURL: core,
      arguments: ["check", "-c", configURL.path]
    )
    #expect(result.status == 0, Comment(rawValue: result.output))
  }
}

@Test func helperRejectsNoncanonicalHysteria2PortHoppingProfiles() throws {
  let noncanonical: [(port: UInt16, ranges: [Hysteria2PortRange])] = [
    (1000, []),
    (443, [Hysteria2PortRange(start: 443, end: 443)]),
    (1001, [Hysteria2PortRange(start: 1000, end: 1000)]),
    (
      2000,
      [Hysteria2PortRange(start: 2000, end: 2000), Hysteria2PortRange(start: 1000, end: 1000)]
    ),
    (
      1000,
      [Hysteria2PortRange(start: 1000, end: 2000), Hysteria2PortRange(start: 1500, end: 3000)]
    ),
    (
      1000,
      [Hysteria2PortRange(start: 1000, end: 2000), Hysteria2PortRange(start: 2001, end: 3000)]
    ),
    (
      0,
      [Hysteria2PortRange(start: 0, end: 1000), Hysteria2PortRange(start: 2000, end: 2000)]
    ),
    (
      1000,
      (0..<65).map { offset in
        let port = UInt16(1000 + offset * 2)
        return Hysteria2PortRange(start: port, end: port)
      }
    ),
  ]
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMHysteria2Invalid-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let builder = ConfigBuilder(
    cachePath: temporary.appendingPathComponent("cache.db").path,
    apiSecret: "test-api-secret"
  )

  for (index, value) in noncanonical.enumerated() {
    let profile = VPNProfile(connections: [
      ManagedConnection(
        id: ProxyNodeID(rawValue: "invalid-h2-\(index)"),
        displayName: "Invalid Hysteria2",
        outbound: .hysteria2(
          Hysteria2Profile(
            server: "vpn.example.test",
            port: value.port,
            password: "test-password",
            serverName: "vpn.example.test",
            portHoppingRanges: value.ranges
          )
        )
      )
    ])
    #expect(throws: CoreFailure.self) {
      try builder.makeConfiguration(
        profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
    }
  }
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
    vless: [
      VLESSProfile(
        server: "203.0.113.10",
        port: 443,
        uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
        serverName: "www.debian.org",
        fingerprint: "firefox",
        publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
        shortID: "bb6b725b",
        displayName: "Reality"
      )
    ],
    hysteria2: [
      Hysteria2Profile(
        server: "vpn.example.com",
        port: 443,
        password: "test-password",
        serverName: "vpn.example.com",
        displayName: "Hysteria2"
      )
    ],
    routingPolicy: policy
  )
  #expect(throws: (any Error).self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  }
}

@Test func managedURLTestGroupsUseTheConfiguredLatencyTarget() throws {
  let target = "https://latency.example.test:8443/check?region=eu"
  let compatibility = VPNProfile(
    vless: [
      VLESSProfile(
        server: "203.0.113.10",
        port: 443,
        uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
        serverName: "www.debian.org",
        fingerprint: "chrome",
        publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
        shortID: "",
        displayName: "Reality"
      )
    ]
  )
  let compatibilityBuilt = try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
    .makeConfiguration(
      profile: .compatibility(compatibility),
      mode: .rule,
      selectedNode: .auto,
      latencyTestURL: target
    )
  let compatibilityRoot = try #require(
    JSONSerialization.jsonObject(with: compatibilityBuilt.data) as? [String: Any])
  let compatibilityOutbounds = try #require(compatibilityRoot["outbounds"] as? [[String: Any]])
  let compatibilityAuto = try #require(
    compatibilityOutbounds.first { ($0["tag"] as? String) == "auto" })
  #expect(compatibilityAuto["url"] as? String == target)

}

@Test func managedVLESSMatrixBuildsExactTransportsAndPassesBundledCore() throws {
  let publicKey = "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU"
  let variants: [(String, VLESSProfileVariant)] = [
    ("reality-tcp", .reality(publicKey: publicKey, shortID: "bb6b725b")),
    (
      "reality-grpc",
      .realityGRPC(publicKey: publicKey, shortID: "bb6b725b", serviceName: "reality-service")
    ),
    ("tls-tcp", .tlsTCP),
    ("tls-http", .tlsHTTP(host: "http.example.test", path: "/api")),
    ("tls-grpc", .tlsGRPC(serviceName: "edge-service")),
    ("tls-ws", .tlsWebSocket(host: "ws.example.test", path: "/socket")),
    ("tls-quic", .tlsQUIC),
    ("tls-httpupgrade", .tlsHTTPUpgrade(host: "upgrade.example.test", path: "/upgrade")),
  ]
  let profile = VPNProfile(
    connections: variants.enumerated().map { index, item in
      let (name, variant) = item
      return ManagedConnection(
        id: ProxyNodeID(rawValue: "node-\(name)"),
        displayName: name,
        outbound: .vless(
          VLESSProfile(
            server: "198.51.100.\(index + 1)",
            port: 443,
            uuid: String(format: "00000000-0000-4000-8000-%012x", index + 1),
            serverName: "\(name).example.test",
            fingerprint: "chrome",
            variant: variant
          )
        )
      )
    })
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMVLESSMatrix-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  let built = try ConfigBuilder(
    cachePath: temporary.appendingPathComponent("cache.db").path,
    apiSecret: "test-api-secret"
  ).makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let allOutbounds = try #require(root["outbounds"] as? [[String: Any]])
  var vless: [String: [String: Any]] = [:]
  for outbound in allOutbounds where outbound["type"] as? String == "vless" {
    guard let tag = outbound["tag"] as? String else { continue }
    vless[tag] = outbound
  }
  #expect(vless.count == 8)

  let reality = try #require(vless["node-reality-tcp"])
  #expect(reality["flow"] as? String == "xtls-rprx-vision")
  #expect(reality["network"] as? String == "tcp")
  #expect(reality["packet_encoding"] as? String == "xudp")
  #expect(reality["transport"] == nil)
  let realityTLS = try #require(reality["tls"] as? [String: Any])
  #expect(realityTLS["enabled"] as? Bool == true)
  #expect(realityTLS["server_name"] as? String == "reality-tcp.example.test")
  let realityUTLS = try #require(realityTLS["utls"] as? [String: Any])
  #expect(realityUTLS["enabled"] as? Bool == true)
  #expect(realityUTLS["fingerprint"] as? String == "chrome")
  let realityOptions = try #require(realityTLS["reality"] as? [String: Any])
  #expect(realityOptions["enabled"] as? Bool == true)
  #expect(realityOptions["public_key"] as? String == publicKey)
  #expect(realityOptions["short_id"] as? String == "bb6b725b")
  let realityGRPC = try #require(vless["node-reality-grpc"])
  #expect(realityGRPC["flow"] == nil)
  let realityGRPCTLS = try #require(realityGRPC["tls"] as? [String: Any])
  #expect(realityGRPCTLS["reality"] != nil)
  let realityTransport = try #require(realityGRPC["transport"] as? [String: Any])
  #expect(realityTransport["type"] as? String == "grpc")
  #expect(realityTransport["service_name"] as? String == "reality-service")

  let tcp = try #require(vless["node-tls-tcp"])
  #expect(tcp["transport"] == nil)
  #expect(tcp["domain_resolver"] as? String == "dns-local")
  #expect(tcp["flow"] == nil)
  #expect(tcp["network"] == nil)
  #expect(tcp["packet_encoding"] == nil)
  let tcpTLS = try #require(tcp["tls"] as? [String: Any])
  #expect(tcpTLS["enabled"] as? Bool == true)
  #expect(tcpTLS["server_name"] as? String == "tls-tcp.example.test")
  #expect(tcpTLS["reality"] == nil)
  let tcpUTLS = try #require(tcpTLS["utls"] as? [String: Any])
  #expect(tcpUTLS["enabled"] as? Bool == true)
  #expect(tcpUTLS["fingerprint"] as? String == "chrome")
  let httpOutbound = try #require(vless["node-tls-http"])
  let http = try #require(httpOutbound["transport"] as? [String: Any])
  #expect(http["type"] as? String == "http")
  #expect(http["host"] as? String == "http.example.test")
  #expect(http["path"] as? String == "/api")
  let grpcOutbound = try #require(vless["node-tls-grpc"])
  #expect(grpcOutbound["domain_resolver"] as? String == "dns-local")
  #expect(grpcOutbound["flow"] == nil)
  #expect(grpcOutbound["network"] == nil)
  #expect(grpcOutbound["packet_encoding"] == nil)
  let grpcTLS = try #require(grpcOutbound["tls"] as? [String: Any])
  #expect(grpcTLS["enabled"] as? Bool == true)
  #expect(grpcTLS["server_name"] as? String == "tls-grpc.example.test")
  #expect(grpcTLS["reality"] == nil)
  let grpcUTLS = try #require(grpcTLS["utls"] as? [String: Any])
  #expect(grpcUTLS["enabled"] as? Bool == true)
  #expect(grpcUTLS["fingerprint"] as? String == "chrome")
  let grpc = try #require(grpcOutbound["transport"] as? [String: Any])
  #expect(grpc["type"] as? String == "grpc")
  #expect(grpc["service_name"] as? String == "edge-service")
  #expect(grpc["mode"] == nil)
  let websocketOutbound = try #require(vless["node-tls-ws"])
  let websocket = try #require(websocketOutbound["transport"] as? [String: Any])
  #expect(websocket["type"] as? String == "ws")
  #expect(websocket["host"] == nil)
  #expect(websocket["path"] as? String == "/socket")
  #expect((websocket["headers"] as? [String: String]) == ["Host": "ws.example.test"])
  let quicOutbound = try #require(vless["node-tls-quic"])
  let quic = try #require(quicOutbound["transport"] as? [String: Any])
  #expect(Set(quic.keys) == ["type"])
  #expect(quic["type"] as? String == "quic")
  let upgradeOutbound = try #require(vless["node-tls-httpupgrade"])
  let upgrade = try #require(upgradeOutbound["transport"] as? [String: Any])
  #expect(upgrade["type"] as? String == "httpupgrade")
  #expect(upgrade["host"] as? String == "upgrade.example.test")
  #expect(upgrade["path"] as? String == "/upgrade")

  let configURL = temporary.appendingPathComponent("config.json")
  try built.data.write(to: configURL)
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let result = try TestProcessSupport.run(
    executableURL: project.appendingPathComponent(".vendor/sing-box"),
    arguments: ["check", "-c", configURL.path]
  )
  #expect(result.status == 0, Comment(rawValue: result.output))
}

@Test func emptyManagedVLESSGRPCServiceNamesPassBundledCore() throws {
  let publicKey = "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU"
  let profile = VPNProfile(connections: [
    ManagedConnection(
      id: ProxyNodeID(rawValue: "node-empty-tls-grpc"),
      displayName: "TLS gRPC",
      outbound: .vless(
        VLESSProfile(
          server: "198.51.100.10",
          port: 443,
          uuid: "00000000-0000-4000-8000-000000000101",
          serverName: "tls-grpc.example.test",
          fingerprint: "chrome",
          variant: .tlsGRPC(serviceName: "")
        )
      )
    ),
    ManagedConnection(
      id: ProxyNodeID(rawValue: "node-empty-reality-grpc"),
      displayName: "REALITY gRPC",
      outbound: .vless(
        VLESSProfile(
          server: "198.51.100.11",
          port: 443,
          uuid: "00000000-0000-4000-8000-000000000102",
          serverName: "reality-grpc.example.test",
          fingerprint: "chrome",
          variant: .realityGRPC(publicKey: publicKey, shortID: "bb6b725b", serviceName: "")
        )
      )
    ),
  ])
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMEmptyGRPC-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  let built = try ConfigBuilder(
    cachePath: temporary.appendingPathComponent("cache.db").path,
    apiSecret: "test-api-secret"
  ).makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let outbounds = try #require(root["outbounds"] as? [[String: Any]])
  let grpcOutbounds = outbounds.filter { ($0["type"] as? String) == "vless" }
  #expect(grpcOutbounds.count == 2)
  for outbound in grpcOutbounds {
    let transport = try #require(outbound["transport"] as? [String: Any])
    #expect(transport["type"] as? String == "grpc")
    #expect(transport["service_name"] as? String == "")
  }

  let configURL = temporary.appendingPathComponent("config.json")
  try built.data.write(to: configURL)
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let result = try TestProcessSupport.run(
    executableURL: project.appendingPathComponent(".vendor/sing-box"),
    arguments: ["check", "-c", configURL.path]
  )
  #expect(result.status == 0, Comment(rawValue: result.output))
}

@Test func bracketedIPv6ManagedServersPassBundledCoreWithoutNormalization() throws {
  let profile = VPNProfile(connections: [
    ManagedConnection(
      id: ProxyNodeID(rawValue: "node-bracketed-vless"),
      displayName: "Bracketed VLESS",
      outbound: .vless(
        VLESSProfile(
          server: "[2001:db8::1]",
          port: 443,
          uuid: "00000000-0000-4000-8000-000000000111",
          serverName: "vless.example.test",
          fingerprint: "chrome",
          variant: .tlsTCP
        )
      )
    ),
    ManagedConnection(
      id: ProxyNodeID(rawValue: "node-bracketed-hysteria2"),
      displayName: "Bracketed Hysteria2",
      outbound: .hysteria2(
        Hysteria2Profile(
          server: "[2001:db8::2]",
          port: 443,
          password: "hysteria-password",
          serverName: "hysteria.example.test"
        )
      )
    ),
  ])
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMBracketedIPv6-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  let built = try ConfigBuilder(
    cachePath: temporary.appendingPathComponent("cache.db").path,
    apiSecret: "test-api-secret"
  ).makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let outbounds = try #require(root["outbounds"] as? [[String: Any]])
  let vless = try #require(outbounds.first { ($0["tag"] as? String) == "node-bracketed-vless" })
  let hysteria = try #require(
    outbounds.first { ($0["tag"] as? String) == "node-bracketed-hysteria2" })
  #expect(vless["server"] as? String == "[2001:db8::1]")
  #expect(hysteria["server"] as? String == "[2001:db8::2]")

  let configURL = temporary.appendingPathComponent("config.json")
  try built.data.write(to: configURL)
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let result = try TestProcessSupport.run(
    executableURL: project.appendingPathComponent(".vendor/sing-box"),
    arguments: ["check", "-c", configURL.path]
  )
  #expect(result.status == 0, Comment(rawValue: result.output))
}

@Test func profileValidationKeepsGRPCServiceNameByteAndControlBounds() {
  let invalidNames = [String(repeating: "s", count: 257), "bad\u{0001}name"]
  let publicKey = "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU"
  var index = 0
  for name in invalidNames {
    let variants: [VLESSProfileVariant] = [
      .tlsGRPC(serviceName: name),
      .realityGRPC(publicKey: publicKey, shortID: "bb6b725b", serviceName: name),
    ]
    for variant in variants {
      let profile = VPNProfile(connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "node-invalid-grpc-\(index)"),
          outbound: .vless(
            VLESSProfile(
              server: "198.51.100.10",
              port: 443,
              uuid: String(format: "00000000-0000-4000-8000-%012x", index + 200),
              serverName: "grpc.example.test",
              fingerprint: "chrome",
              variant: variant
            )
          )
        )
      ])
      #expect(throws: CoreFailure.self) {
        try ConfigBuilder(cachePath: "/tmp/cache.db", apiSecret: "test")
          .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
      }
      index += 1
    }
  }
}

@Test func profileValidationRejectsInvalidVLESSTransportFields() {
  let invalidVariants: [VLESSProfileVariant] = [
    .tlsHTTP(host: "host.example.test:443", path: "/api"),
    .tlsWebSocket(host: "ws.example.test", path: "relative"),
    .tlsHTTPUpgrade(host: nil, path: "/" + String(repeating: "p", count: 1024)),
  ]
  for (index, variant) in invalidVariants.enumerated() {
    let profile = VPNProfile(connections: [
      ManagedConnection(
        id: ProxyNodeID(rawValue: "node-invalid-\(index)"),
        outbound: .vless(
          VLESSProfile(
            server: "198.51.100.10", port: 443,
            uuid: String(format: "00000000-0000-4000-8000-%012x", index + 100),
            serverName: "sni.example.test", fingerprint: "chrome", variant: variant
          )
        )
      )
    ])
    #expect(throws: CoreFailure.self) {
      try ConfigBuilder(cachePath: "/tmp/cache.db", apiSecret: "test")
        .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
    }
  }
}

@Test func privilegedRoutingComposerRejectsNestedDuplicateKeys() {
  let policy = RoutingPolicy(
    configuration: Data(
      #"{"route":{"rules":[{"domain_suffix":["example.test"],"domain_suffix":["other.test"],"action":"route","outbound":"direct"}]}}"#
        .utf8
    )
  )
  let profile = VPNProfile(
    vless: [
      VLESSProfile(
        server: "203.0.113.10",
        port: 443,
        uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
        serverName: "www.debian.org",
        fingerprint: "chrome",
        publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
        shortID: "",
        displayName: "Reality"
      )
    ],
    routingPolicy: policy
  )

  #expect(throws: CoreFailure.self) {
    try ConfigBuilder(cachePath: "/tmp/cache.db", apiSecret: "test")
      .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  }
}
