import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

@Test func strictHysteria2QueryRejectsDuplicatesCaseVariantsAndUnknownParameters() throws {
  let invalid = [
    "hysteria2://password@vpn.example.com:443/?sni=a.example&sni=b.example#HY2",
    "hysteria2://password@vpn.example.com:443/?sni=a.example&SNI=b.example#HY2",
    "hysteria2://password@vpn.example.com:443/?sni=a.example&unknown=x#HY2",
    "hysteria2://password@vpn.example.com:443/?sni=a.example&obfs=salamander&obfs=salamander&obfs-password=secret#HY2",
    "hysteria2://password@vpn.example.com:443/?sni=a.example&obfs=salamander&obfs-password=one&obfs-password=two#HY2",
  ]
  for link in invalid {
    #expect(throws: SubscriptionFailure.self) {
      _ = try SubscriptionClient.parsePayload(link)
    }
  }

  for scheme in ["hysteria2", "hy2"] {
    let parsed = try SubscriptionClient.parsePayload(
      "\(scheme)://password@vpn.example.com:443/?sni=vpn.example.com&obfs=salamander&obfs-password=secret#HY2"
    )
    guard case .compatibility(let profile) = parsed else {
      Issue.record("Expected a compatibility profile")
      return
    }
    #expect(profile.hysteria2.count == 1)
  }
}

@Test func serverSubscriptionParsesBothSupportedProtocols() throws {
  let links = """
    vless://5efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=chrome&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b&type=tcp#%F0%9F%87%A9%F0%9F%87%AA%20Reality
    hysteria2://test-password@vpn.example.com:443/?sni=vpn.example.com&obfs=salamander&obfs-password=test-obfs#%F0%9F%87%A9%F0%9F%87%AA%20Hysteria2
    """
  let encoded = Data(links.utf8).base64EncodedString()
  let profile = try SubscriptionClient.parsePayload(encoded)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility subscription")
    return
  }
  #expect(compatibility.vless.first?.server == "203.0.113.10")
  #expect(compatibility.vless.first?.serverName == "www.debian.org")
  #expect(compatibility.connections.first?.displayName == "🇩🇪 Reality")
  #expect(compatibility.hysteria2.first?.server == "vpn.example.com")
  #expect(compatibility.hysteria2.first?.password == "test-password")
  #expect(compatibility.hysteria2.first?.obfsPassword == "test-obfs")
}

@Test func serverSubscriptionParsesHysteria2WithoutObfuscation() throws {
  let links = """
    vless://5efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b&type=tcp#Reality
    hysteria2://test-password@vpn.example.com:443/?sni=vpn.example.com#Hysteria2
    """
  let profile = try SubscriptionClient.parsePayload(links)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility subscription")
    return
  }
  #expect(compatibility.hysteria2.first?.password == "test-password")
  #expect(compatibility.hysteria2.first?.obfsPassword == nil)
}

@Test func routingPolicyParserAcceptsOnlyRoutingSections() throws {
  let policy = try RoutingPolicyParser.parse(
    Data(
      """
      {
        "route": {
          "rules": [
            {
              "domain_suffix": ["example.ru"],
              "action": "route",
              "outbound": "direct"
            }
          ]
        }
      }
      """.utf8)
  )
  #expect(!policy.configuration.isEmpty)

  #expect(throws: SubscriptionFailure.invalidRoutingPolicy) {
    try RoutingPolicyParser.parse(
      Data(
        """
        {
          "outbounds": [
            { "type": "direct", "tag": "unsafe" }
          ]
        }
        """.utf8)
    )
  }
}

@Test func duplicateAndCaseVariantVLESSQueryKeysFailClosed() {
  let prefix =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?"
  let suffix =
    "&security=reality&sni=www.debian.org&fp=chrome&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b"
  for query in [
    "flow=wrong&flow=xtls-rprx-vision",
    "flow=xtls-rprx-vision&Flow=wrong",
    "type=xhttp&type=tcp&flow=xtls-rprx-vision",
  ] {
    #expect(throws: SubscriptionFailure.ambiguousVLESSParameters) {
      try SubscriptionClient.parsePayload(prefix + query + suffix)
    }
  }
}

@Test func vlessEncryptionDefaultsToNoneAndRejectsAmbiguousOrUnsupportedValues() throws {
  let base =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=chrome&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b&type=tcp"
  _ = try SubscriptionClient.parsePayload(base + "#MissingDefaultsToNone")
  _ = try SubscriptionClient.parsePayload(base + "&encryption=none#ExplicitNone")

  #expect(throws: SubscriptionFailure.invalidVLESS) {
    try SubscriptionClient.parsePayload(base + "&encryption=#Empty")
  }
  #expect(throws: SubscriptionFailure.unsupportedVLESSEncryption) {
    try SubscriptionClient.parsePayload(base + "&encryption=mlkem768x25519plus.native#Unsupported")
  }
  #expect(throws: SubscriptionFailure.ambiguousVLESSParameters) {
    try SubscriptionClient.parsePayload(base + "&encryption=none&encryption=none#Duplicate")
  }
}

@Test func vlessCompactLinkRejectsIgnoredSemanticsAndInvalidRealityFields() {
  let prefix =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=chrome&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b&type=tcp"
  #expect(throws: SubscriptionFailure.unsupportedVLESSParameter) {
    try SubscriptionClient.parsePayload(prefix + "&packetEncoding=packetaddr#Unsupported")
  }
  #expect(throws: SubscriptionFailure.invalidVLESS) {
    try SubscriptionClient.parsePayload(
      prefix.replacingOccurrences(of: "fp=chrome", with: "fp=unknown"))
  }
  #expect(throws: SubscriptionFailure.invalidVLESS) {
    try SubscriptionClient.parsePayload(
      prefix.replacingOccurrences(
        of: "pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
        with: "pbk=not-a-reality-key"
      )
    )
  }
  #expect(throws: SubscriptionFailure.invalidVLESS) {
    try SubscriptionClient.parsePayload(
      prefix.replacingOccurrences(of: "sid=bb6b725b", with: "sid=ABC")
    )
  }
}

@Test func directVLESSLinkCreatesSingleNodeProfile() throws {
  let link =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b&type=tcp#Reality"
  let profile = try SubscriptionClient.parsePayload(link)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(compatibility.vless.count == 1)
  #expect(compatibility.hysteria2.isEmpty)
}

@Test func directHysteria2LinkCreatesSingleNodeProfile() throws {
  let link =
    "hysteria2://test-password@vpn.example.com:443/?sni=vpn.example.com#Hysteria2"
  let profile = try SubscriptionClient.parsePayload(link)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(compatibility.vless.isEmpty)
  #expect(compatibility.hysteria2.count == 1)
}

@Test func strictSIP002ShadowsocksAcceptsPlainAndBase64UserInfo() throws {
  let plain = "ss://aes-256-gcm:plain-password@ss.example.com:443/#Plain"
  let encodedCredential = Data("chacha20-ietf-poly1305:encoded-password".utf8)
    .base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  let profile = try SubscriptionClient.parsePayload(
    "\(plain)\nss://\(encodedCredential)@198.51.100.2:8443/#Encoded")
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(compatibility.connections.count == 2)
  #expect(compatibility.connections.allSatisfy { $0.id.rawValue.hasPrefix("node-") })
  #expect(compatibility.shadowsocks.map(\.method) == ["aes-256-gcm", "chacha20-ietf-poly1305"])
  #expect(compatibility.shadowsocks.map(\.password) == ["plain-password", "encoded-password"])
}

@Test func strictSIP002ShadowsocksAllows2022PlainButRejectsEncodedAndUnsupportedForms() throws {
  let psk = Data(repeating: 7, count: 16).base64EncodedString()
  let valid = "ss://2022-blake3-aes-128-gcm:\(psk)@ss.example.com:443/#2022"
  let encoded2022 = Data("2022-blake3-aes-128-gcm:\(psk)".utf8).base64EncodedString()
  _ = try SubscriptionClient.parsePayload(valid)
  for invalid in [
    "ss://\(encoded2022)@ss.example.com:443/",
    "ss://2022-blake3-aes-128-gcm:c2hvcnQ=@ss.example.com:443/",
    "ss://aes-128-gcm:password@ss.example.com:443/?plugin=obfs-local",
    "ss://YWVzLTEyOC1nY206cGFzc3dvcmRAc3MuZXhhbXBsZS5jb206NDQz",
    "ss://rc4-md5:password@ss.example.com:443/",
    "ss://none:password@ss.example.com:443/",
  ] {
    #expect(throws: SubscriptionFailure.invalidShadowsocks) {
      try SubscriptionClient.parsePayload(invalid)
    }
  }
}

@Test func mixedSubscriptionIncludesVLESSHysteria2AndShadowsocks() throws {
  let links = """
    vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&type=tcp#Reality
    hysteria2://password@vpn.example.com:443/?sni=vpn.example.com#Hysteria2
    ss://aes-128-gcm:password@ss.example.com:443/#Shadowsocks
    """
  let profile = try SubscriptionClient.parsePayload(links)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(compatibility.connections.map(\.kind) == [.vless, .hysteria2, .shadowsocks])
}

@Test func interleavedSubscriptionPreservesRecognizedSourceOrder() throws {
  let realityQuery = [
    URLQueryItem(name: "flow", value: "xtls-rprx-vision"),
    URLQueryItem(name: "security", value: "reality"),
    URLQueryItem(name: "sni", value: "reality.example.test"),
    URLQueryItem(name: "fp", value: "chrome"),
    URLQueryItem(
      name: "pbk",
      value: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU"
    ),
    URLQueryItem(name: "sid", value: "bb6b725b"),
    URLQueryItem(name: "type", value: "tcp"),
  ]
  let links = [
    makeVLESSLink(uuid: syntheticUUID(300), queryItems: realityQuery, fragment: "VLESS A"),
    makeHysteria2Link(host: "hy-a.example.test", fragment: "Hysteria B"),
    makeVLESSLink(uuid: syntheticUUID(301), queryItems: realityQuery, fragment: "VLESS C"),
    "ss://aes-128-gcm:password@ss.example.test:443/#Shadowsocks D",
  ].joined(separator: "\n")

  let profile = try SubscriptionClient.parsePayload(links)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility subscription")
    return
  }
  #expect(compatibility.connections.map(\.kind) == [.vless, .hysteria2, .vless, .shadowsocks])
  #expect(
    compatibility.connections.map(\.displayName)
      == ["VLESS A", "Hysteria B", "VLESS C", "Shadowsocks D"]
  )
}

@Test func reconciliationPreservesStableIDsAcrossRenameReorderAndDuplicates() throws {
  let outbound = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "ss.example.com", port: 443, method: "aes-128-gcm", password: "same",
      displayName: "Old"
    ))
  let previous = CoreProfile.compatibility(
    VPNProfile(connections: [
      ManagedConnection(id: ProxyNodeID(rawValue: "node-one"), outbound: outbound),
      ManagedConnection(id: ProxyNodeID(rawValue: "node-two"), outbound: outbound),
    ]))
  let renamed = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "ss.example.com", port: 443, method: "aes-128-gcm", password: "same",
      displayName: "Renamed"
    ))
  let fresh = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "new.example.com", port: 443, method: "aes-256-gcm", password: "new",
      displayName: "New"
    ))
  let reconciled = ManagedConnectionReconciler.reconcile(
    existing: previous,
    fetched: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(outbound: renamed),
        ManagedConnection(outbound: fresh),
        ManagedConnection(outbound: renamed),
      ]))
  )
  guard case .compatibility(let result) = reconciled else { return }
  #expect(result.connections[0].id == ProxyNodeID(rawValue: "node-one"))
  #expect(result.connections[2].id == ProxyNodeID(rawValue: "node-two"))
  #expect(result.connections[1].id.rawValue.hasPrefix("node-"))
  #expect(ManagedConnectionReconciler.requiresActivation(previous: previous, next: reconciled))
  let renamedOnly = ManagedConnectionReconciler.reconcile(
    existing: previous,
    fetched: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(outbound: renamed),
        ManagedConnection(outbound: renamed),
      ]))
  )
  #expect(!ManagedConnectionReconciler.requiresActivation(previous: previous, next: renamedOnly))
}

@Test func aggregateReconciliationPreservesIDWhenDuplicateMovesBetweenSources() throws {
  let outbound = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "shared.example.com",
      port: 443,
      method: "aes-128-gcm",
      password: "shared-password",
      displayName: "Shared"
    ))
  let firstID = ProxyNodeID(rawValue: "node-first")
  let secondID = ProxyNodeID(rawValue: "node-second")
  let firstSource = ManagedSource(
    name: "First",
    value: "ss://first",
    payload: .compatibility(
      VPNProfile(connections: [ManagedConnection(id: firstID, outbound: outbound)]))
  )
  let secondSource = ManagedSource(
    name: "Second",
    value: "ss://second",
    payload: .compatibility(
      VPNProfile(connections: [ManagedConnection(id: secondID, outbound: outbound)]))
  )
  let previous = try ProfileAggregator.merge(
    sources: [firstSource, secondSource],
    routingPolicy: nil
  )
  let fetched = try ProfileAggregator.merge(
    sources: [
      ManagedSource(
        id: firstSource.id,
        name: firstSource.name,
        value: firstSource.value,
        payload: .compatibility(VPNProfile())
      ),
      secondSource,
    ],
    routingPolicy: nil
  )

  let reconciled = ManagedConnectionReconciler.reconcile(
    existing: previous,
    fetched: fetched
  )
  guard case .compatibility(let profile) = reconciled else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(profile.connections.map(\.id) == [firstID])
  #expect(profile.nodeGroups?.map(\.nodes) == [[firstID]])
  #expect(!ManagedConnectionReconciler.requiresActivation(previous: previous, next: reconciled))
}

@Test func semanticIdentityIsUnambiguousWhenSecretsContainDelimiters() {
  let left = ManagedOutbound.hysteria2(
    Hysteria2Profile(
      server: "hy.example.com", port: 443, password: "one|two", serverName: "three",
      displayName: "Left"
    ))
  let right = ManagedOutbound.hysteria2(
    Hysteria2Profile(
      server: "hy.example.com", port: 443, password: "one", serverName: "two|three",
      displayName: "Right"
    ))
  #expect(left.semanticIdentity != right.semanticIdentity)
}

@Test func newManagedConnectionIDIsDeterministicNameAndOrderIndependent() {
  let oldName = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "Proxy.Example.COM.",
      port: 443,
      method: "AES-128-GCM",
      password: "synthetic-secret",
      displayName: "Old name"
    )
  )
  let renamed = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "proxy.example.com",
      port: 443,
      method: "aes-128-gcm",
      password: "synthetic-secret",
      displayName: "Renamed"
    )
  )
  let first = ManagedConnection(outbound: oldName)
  let second = ManagedConnection(outbound: renamed)

  #expect(first.id == second.id)
  #expect(first.id.rawValue.hasPrefix("node-v1-"))
  #expect(first.id.rawValue.count == 72)
  #expect(first.id.rawValue.allSatisfy { $0.isASCII })
  #expect(!first.id.rawValue.contains("synthetic-secret"))
  #expect(!first.id.rawValue.contains("proxy.example.com"))

  let reversed = [second, first].reversed().map(\.id)
  #expect(Set(reversed) == Set([first.id]))
}

@Test func managedConnectionIDChangesWithEndpointOrCredentials() {
  func connection(server: String = "proxy.example.com", password: String = "secret-one")
    -> ManagedConnection
  {
    ManagedConnection(
      outbound: .shadowsocks(
        ShadowsocksProfile(
          server: server,
          port: 443,
          method: "aes-128-gcm",
          password: password,
          displayName: "Node"
        )
      )
    )
  }

  let baseline = connection()
  #expect(connection(server: "other.example.com").id != baseline.id)
  #expect(connection(password: "secret-two").id != baseline.id)
}

@Test func explicitLegacyManagedConnectionIDSurvivesDeterministicDefault() throws {
  let legacyID = ProxyNodeID(rawValue: "vless-1")
  let connection = ManagedConnection(
    id: legacyID,
    outbound: .vless(
      VLESSProfile(
        server: "203.0.113.10",
        port: 443,
        uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
        serverName: "example.test",
        fingerprint: "chrome",
        publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
        shortID: "",
        displayName: "Legacy"
      )
    )
  )
  let decoded = try JSONDecoder().decode(
    ManagedConnection.self,
    from: JSONEncoder().encode(connection)
  )
  #expect(decoded.id == legacyID)
}

@Test func compatibilitySubscriptionKeepsEverySupportedConnection() throws {
  let links = """
    vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b#Reality%201
    vless://5efab93b-90d0-4904-93d6-44b4f0b00002@203.0.113.11:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725c#Reality%202
    hysteria2://password-one@vpn-one.example.com:443/?sni=vpn-one.example.com#Hysteria2%201
    hysteria2://password-two@vpn-two.example.com:443/?sni=vpn-two.example.com#Hysteria2%202
    """
  let profile = try SubscriptionClient.parsePayload(links)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility subscription")
    return
  }
  #expect(
    compatibility.connections.map(\.displayName)
      == ["Reality 1", "Reality 2", "Hysteria2 1", "Hysteria2 2"]
  )
}

@Test func mixedSubscriptionSkipsUnsupportedXHTTPConnections() throws {
  let links = """
    vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b&type=tcp#Reality
    vless://5efab93b-90d0-4904-93d6-44b4f0b00002@203.0.113.11:443?security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&type=xhttp&mode=stream-one&path=%2Ftest#XHTTP
    hysteria2://password@vpn.example.com:443/?sni=vpn.example.com#Hysteria2
    """
  let result = try SubscriptionClient.parsePayloadResult(
    Data(links.utf8).base64EncodedString()
  )
  guard case .compatibility(let profile) = result.profile else {
    Issue.record("Expected a compatibility subscription")
    return
  }
  #expect(profile.vless.count == 1)
  #expect(profile.hysteria2.count == 1)
  #expect(profile.connections.map(\.kind) == [.vless, .hysteria2])
  #expect(result.skippedTransports == ["xhttp": 1])
  #expect(result.warningDescription?.contains("2 connections imported") == true)
  #expect(result.warningDescription?.contains("1 XHTTP connection skipped") == true)
}

@Test func mixedSubscriptionSkipsInvalidRecognizedLinksWithoutLeakingSecrets() throws {
  let validVLESS =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b&type=tcp#Reality"
  let invalidVLESS =
    "vless://11111111-2222-3333-4444-555555555555@198.51.100.10:443?flow=xtls-rprx-vision&security=reality&sni=secret-vless.example&fp=firefox&pbk=bad&type=tcp#Invalid"
  let invalidHysteria =
    "hysteria2://super-secret-password@secret-hy.example:443/?sni=secret-hy.example&obfs=unsupported#Invalid"
  let invalidShadowsocks =
    "ss://rc4-md5:another-secret@secret-ss.example:443/#Invalid"

  let result = try SubscriptionClient.parsePayloadResult(
    [validVLESS, invalidVLESS, invalidHysteria, invalidShadowsocks].joined(separator: "\n")
  )
  guard case .compatibility(let profile) = result.profile else {
    Issue.record("Expected a compatibility subscription")
    return
  }

  #expect(profile.connections.count == 1)
  #expect(result.skippedInvalidConnections[.vless] == 1)
  #expect(result.skippedInvalidConnections[.hysteria2] == 1)
  #expect(result.skippedInvalidConnections[.shadowsocks] == 1)
  let warning = try #require(result.warningDescription)
  #expect(warning.contains("1 connection imported"))
  #expect(warning.contains("1 VLESS connection skipped"))
  #expect(warning.contains("1 Hysteria2 connection skipped"))
  #expect(warning.contains("1 Shadowsocks connection skipped"))
  for secret in [
    "11111111-2222-3333-4444-555555555555", "secret-vless.example",
    "super-secret-password", "secret-hy.example", "another-secret", "secret-ss.example",
  ] {
    #expect(!warning.contains(secret))
  }
}

@Test func invalidRecognizedSubscriptionLineDoesNotDisturbNeighboringOrder() throws {
  let validVLESS =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b&type=tcp#VLESS"
  let invalidHysteria =
    "hysteria2://password@invalid.example.test:443/?sni=invalid.example.test&obfs=unsupported#Invalid"
  let validShadowsocks = "ss://aes-128-gcm:password@ss.example.test:443/#Shadowsocks"

  let result = try SubscriptionClient.parsePayloadResult(
    [validVLESS, invalidHysteria, validShadowsocks].joined(separator: "\n")
  )
  guard case .compatibility(let profile) = result.profile else {
    Issue.record("Expected a compatibility subscription")
    return
  }
  #expect(profile.connections.map(\.kind) == [.vless, .shadowsocks])
  #expect(profile.connections.map(\.displayName) == ["VLESS", "Shadowsocks"])
  #expect(result.skippedInvalidConnections[.hysteria2] == 1)
}

@Test func allInvalidRecognizedLinksStillFailClosed() {
  let first =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=bad&type=tcp#Invalid"
  let second = "hysteria2://password@vpn.example.com:443/?sni=vpn.example.com&obfs=unsupported"

  #expect(throws: SubscriptionFailure.invalidVLESS) {
    try SubscriptionClient.parsePayload(first + "\n" + second)
  }
}

@Test func realityShortIDMayBeEmpty() throws {
  let link =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&type=tcp#Reality"
  let profile = try SubscriptionClient.parsePayload(link)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility subscription")
    return
  }
  #expect(compatibility.vless.first?.shortID == "")
}

@Test func directUnsupportedXHTTPLinkReportsTransport() {
  let link =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&type=xhttp&mode=stream-one&path=%2Ftest#XHTTP"
  #expect(throws: SubscriptionFailure.unsupportedVLESSTransport("xhttp")) {
    try SubscriptionClient.parsePayload(link)
  }
}

@Test func subscriptionRequestUsesConfiguredHeaders() throws {
  let request = try SubscriptionClient.makeRequest(
    for: URL(string: "https://example.com/subscription")!,
    headers: SubscriptionHeaders(
      userAgent: "Custom Client/1.0",
      appVersion: "5.4.0",
      deviceOS: "macOS",
      hardwareID: "test-hwid"
    )
  )
  #expect(request.value(forHTTPHeaderField: "User-Agent") == "Custom Client/1.0")
  #expect(request.value(forHTTPHeaderField: "X-App-Version") == "5.4.0")
  #expect(request.value(forHTTPHeaderField: "X-Device-OS") == "macOS")
  #expect(request.value(forHTTPHeaderField: "X-HWID") == "test-hwid")
}

@Test func subscriptionRedirectDoesNotLeakPrivateHeadersAcrossOrigins() throws {
  let source = URL(string: "https://example.com/subscription")!
  let original = try SubscriptionClient.makeRequest(
    for: source,
    headers: SubscriptionHeaders(
      userAgent: "Custom Client/1.0",
      appVersion: "5.4.0",
      deviceOS: "macOS",
      hardwareID: "test-hwid"
    )
  )
  var sameOriginRequest = original
  sameOriginRequest.url = URL(string: "https://example.com/moved")!
  let sameOrigin = try #require(
    SubscriptionClient.sanitizedRedirectRequest(
      sameOriginRequest,
      from: source
    )
  )
  #expect(sameOrigin.value(forHTTPHeaderField: "X-HWID") == "test-hwid")

  var crossOriginRequest = original
  crossOriginRequest.url = URL(string: "https://cdn.example.net/moved")!
  crossOriginRequest.setValue("Bearer private-token", forHTTPHeaderField: "Authorization")
  crossOriginRequest.setValue("Basic proxy-secret", forHTTPHeaderField: "Proxy-Authorization")
  crossOriginRequest.setValue("session=private", forHTTPHeaderField: "Cookie")
  let crossOrigin = try #require(
    SubscriptionClient.sanitizedRedirectRequest(
      crossOriginRequest,
      from: source
    )
  )
  #expect(crossOrigin.value(forHTTPHeaderField: "X-HWID") == nil)
  #expect(crossOrigin.value(forHTTPHeaderField: "X-App-Version") == nil)
  #expect(crossOrigin.value(forHTTPHeaderField: "X-Device-OS") == nil)
  #expect(crossOrigin.value(forHTTPHeaderField: "Authorization") == nil)
  #expect(crossOrigin.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
  #expect(crossOrigin.value(forHTTPHeaderField: "Cookie") == nil)
  #expect(crossOrigin.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("SBM/") == true)

  var returnToOriginRequest = original
  returnToOriginRequest.url = URL(string: "https://example.com/final")!
  let returnToOrigin = try #require(
    SubscriptionClient.sanitizedRedirectRequest(
      returnToOriginRequest,
      from: source,
      sensitiveHeadersWereStripped: true
    )
  )
  #expect(returnToOrigin.value(forHTTPHeaderField: "X-HWID") == nil)
  #expect(returnToOrigin.value(forHTTPHeaderField: "X-App-Version") == nil)
  #expect(returnToOrigin.value(forHTTPHeaderField: "X-Device-OS") == nil)

  #expect(
    SubscriptionClient.sanitizedRedirectRequest(
      URLRequest(url: URL(string: "http://example.com/insecure")!),
      from: source
    ) == nil
  )
}

@Test func subscriptionRejectsMalformedUTF8() {
  #expect(throws: SubscriptionFailure.invalidEncoding) {
    try SubscriptionClient.decodeBody(Data([0xC3, 0x28]))
  }
}

@Test func oneSubscriptionSynchronizationPerformsOneFetch() async throws {
  let counter = SubscriptionFetchCounter()
  let profile = try SubscriptionClient.parsePayload(
    "hysteria2://password@vpn.example.com:443/?sni=vpn.example.com#Hysteria2"
  )
  let manager = SubscriptionManager { _, _ in
    await counter.record()
    return SubscriptionFetchResult(profile: profile, skippedTransports: [:])
  }
  let source = ManagedSource(
    name: "Remote",
    value: "https://user:secret@example.com/subscription"
  )

  _ = try await manager.synchronize(source)

  #expect(await counter.value == 1)
}

@Test func generatedManagedConfigurationOmitsSubscriptionURL() throws {
  let privateURL = "https://user:private-token@example.com/subscription"
  let payload = try SubscriptionClient.parsePayload(
    "hysteria2://password@vpn.example.com:443/?sni=vpn.example.com#Hysteria2"
  )
  let merged = try ProfileAggregator.merge(
    sources: [ManagedSource(name: "Remote", value: privateURL, payload: payload)],
    routingPolicy: nil
  )
  let built = try ConfigBuilder(cachePath: "/tmp/sbm-cache", apiSecret: "api-secret")
    .makeConfiguration(profile: merged, mode: .rule, selectedNode: .auto)
  let configuration = try #require(String(data: built.data, encoding: .utf8))
  #expect(!configuration.contains(privateURL))
  #expect(!configuration.contains("private-token"))
}

private actor SubscriptionFetchCounter {
  private(set) var value = 0

  func record() {
    value += 1
  }
}

@Test func profileAggregatorMergesSourcesAndRemovesExactDuplicates() throws {
  let first = try SubscriptionClient.parsePayload(
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b#Reality"
  )
  let second = try SubscriptionClient.parsePayload(
    """
    vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b#Reality
    hysteria2://password@vpn.example.com:443/?sni=vpn.example.com#Hysteria2
    """
  )
  let merged = try ProfileAggregator.merge(
    sources: [
      ManagedSource(name: "First", value: "vless://first", payload: first),
      ManagedSource(name: "Second", value: "https://example.com/sub", payload: second),
    ],
    routingPolicy: nil
  )
  guard case .compatibility(let compatibility) = merged else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(compatibility.vless.count == 1)
  #expect(compatibility.hysteria2.count == 1)
  let groups = compatibility.nodeGroups ?? []
  #expect(groups.count == 2)
  #expect(groups[0].name == "First")
  #expect(groups[0].nodes == [compatibility.connections[0].id])
  #expect(groups[1].name == "Second")
  #expect(groups[1].nodes == [compatibility.connections[1].id])
}

@Test func profileAggregatorPreservesParsedOrderWithinAndAcrossSources() throws {
  let realityQuery = [
    URLQueryItem(name: "flow", value: "xtls-rprx-vision"),
    URLQueryItem(name: "security", value: "reality"),
    URLQueryItem(name: "sni", value: "reality.example.test"),
    URLQueryItem(name: "fp", value: "chrome"),
    URLQueryItem(
      name: "pbk",
      value: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU"
    ),
    URLQueryItem(name: "sid", value: "bb6b725b"),
    URLQueryItem(name: "type", value: "tcp"),
  ]
  let first = try SubscriptionClient.parsePayload(
    [
      makeVLESSLink(uuid: syntheticUUID(302), queryItems: realityQuery, fragment: "First VLESS"),
      makeHysteria2Link(host: "first-hy.example.test", fragment: "First HY2"),
    ].joined(separator: "\n")
  )
  let second = try SubscriptionClient.parsePayload(
    [
      "ss://aes-128-gcm:password@second-ss.example.test:443/#Second SS",
      makeVLESSLink(uuid: syntheticUUID(303), queryItems: realityQuery, fragment: "Second VLESS"),
    ].joined(separator: "\n")
  )

  let merged = try ProfileAggregator.merge(
    sources: [
      ManagedSource(name: "First", value: "ss://first", payload: first),
      ManagedSource(name: "Second", value: "ss://second", payload: second),
    ],
    routingPolicy: nil
  )
  guard case .compatibility(let compatibility) = merged else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(
    compatibility.connections.map(\.displayName)
      == ["First VLESS", "First HY2", "Second SS", "Second VLESS"]
  )
  #expect(
    compatibility.nodeGroups?.map(\.nodes)
      == [
        Array(compatibility.connections[0..<2].map(\.id)),
        Array(compatibility.connections[2..<4].map(\.id)),
      ]
  )
}

@Test func profileAggregatorAppliesPerSourceExcludeRegex() throws {
  let payload = try SubscriptionClient.parsePayload(
    """
    vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b#Netherlands
    vless://5efab93b-90d0-4904-93d6-44b4f0b00002@203.0.113.11:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b#LTE%20Whitelist
    hysteria2://password@vpn.example.com:443/?sni=vpn.example.com#Russia
    """
  )
  let merged = try ProfileAggregator.merge(
    sources: [
      ManagedSource(
        name: "AID",
        value: "https://example.com/sub",
        excludeRegex: "(?i)lte|russia",
        payload: payload
      )
    ],
    routingPolicy: nil
  )
  guard case .compatibility(let compatibility) = merged else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(compatibility.connections.map(\.displayName) == ["Netherlands"])
  #expect(compatibility.hysteria2.isEmpty)
  #expect(compatibility.nodeGroups?.first?.nodes == [compatibility.connections[0].id])
}

@Test func sourceExcludeRegexRejectsInvalidPatterns() {
  #expect(throws: SubscriptionFailure.invalidExcludeRegex) {
    try SourceNameFilter.normalized("(?i)(")
  }
}

@Test func proxyNodeSectionsPreserveSubscriptionOrderRegardlessOfLatency() {
  let nodes = [
    ProxyNode(
      id: .auto,
      name: "Auto",
      symbol: "wand.and.stars",
      groupID: nil,
      groupName: nil,
      groupOrder: nil,
      nodeOrder: nil,
      delay: 30
    ),
    ProxyNode(
      id: ProxyNodeID(rawValue: "vless-1"),
      name: "Reality",
      symbol: "network",
      groupID: "personal",
      groupName: "My VPS",
      groupOrder: 0,
      nodeOrder: 0,
      delay: 70
    ),
    ProxyNode(
      id: ProxyNodeID(rawValue: "hysteria2-1"),
      name: "Hysteria2",
      symbol: "network",
      groupID: "personal",
      groupName: "My VPS",
      groupOrder: 0,
      nodeOrder: 1,
      delay: 40
    ),
    ProxyNode(
      id: ProxyNodeID(rawValue: "vless-2"),
      name: "Netherlands",
      symbol: "network",
      groupID: "aid",
      groupName: "AID",
      groupOrder: 1,
      nodeOrder: 0,
      delay: nil
    ),
    ProxyNode(
      id: ProxyNodeID(rawValue: "hysteria2-2"),
      name: "Sweden",
      symbol: "network",
      groupID: "aid",
      groupName: "AID",
      groupOrder: 1,
      nodeOrder: 1,
      delay: 35
    ),
  ]

  let sections = ProxyNodeSectionBuilder.make(from: nodes)
  #expect(sections.map(\.name) == ["My VPS", "AID"])
  #expect(sections[0].nodes.map(\.name) == ["Reality", "Hysteria2"])
  #expect(sections[1].nodes.map(\.name) == ["Netherlands", "Sweden"])
}

@Test func profileAggregatorRejectsNativeJSONSource() throws {
  let native = try SubscriptionClient.parsePayload(
    """
    {
      "outbounds": [
        { "type": "selector", "tag": "proxy", "outbounds": ["manual"] },
        { "type": "socks", "tag": "manual", "server": "203.0.113.10", "server_port": 1080 }
      ],
      "sbm": { "selector": "proxy" }
    }
    """
  )

  #expect(throws: SubscriptionFailure.nativeProfileCannotBeMerged) {
    try ProfileAggregator.merge(
      sources: [
        ManagedSource(
          name: "Native",
          value: "https://example.com/native.json",
          payload: native
        )
      ],
      routingPolicy: nil
    )
  }
}

@Test func nativeJSONDiscoversExistingSelector() throws {
  let profile = try SubscriptionClient.parsePayload(
    """
    {
      "outbounds": [
        { "type": "selector", "tag": "proxy", "outbounds": ["auto", "manual"] },
        { "type": "urltest", "tag": "auto", "outbounds": ["manual"] },
        { "type": "socks", "tag": "manual", "server": "203.0.113.10", "server_port": 1080 }
      ],
      "sbm": {
        "selector": "proxy",
        "display_names": { "manual": "Manual server" }
      }
    }
    """
  )
  guard case .native(let native) = profile else {
    Issue.record("Expected a native profile")
    return
  }
  #expect(native.selectorTag == "proxy")
  #expect(native.nodes.map(\.id.rawValue) == ["auto", "manual"])
  #expect(native.nodes.map(\.name) == ["auto", "Manual server"])
}

@Test func nativeJSONRejectsDuplicateTagsWithoutCrashing() {
  let body =
    """
    {
      "outbounds": [
        { "type": "socks", "tag": "duplicate", "server": "203.0.113.10", "server_port": 1080 },
        { "type": "http", "tag": "duplicate", "server": "203.0.113.11", "server_port": 8080 }
      ]
    }
    """

  #expect(throws: SubscriptionFailure.self) {
    try SubscriptionClient.parsePayload(body)
  }
}

@Test func nativeJSONRejectsOversizedRemoteDisplayName() {
  let oversized = String(repeating: "x", count: 97)
  let body =
    """
    {
      "sbm": { "display_names": { "proxy": "\(oversized)" } },
      "outbounds": [
        { "type": "socks", "tag": "proxy", "server": "203.0.113.10", "server_port": 1080 }
      ]
    }
    """

  #expect(throws: SubscriptionFailure.self) {
    try SubscriptionClient.parsePayload(body)
  }
}

@Test func hysteria2FMCompatibilityMapsOnlyTheConfirmedShapes() throws {
  let fmSalamander = #"{"udp":[{"type":"salamander","settings":{"password":"fm-salamander"}}]}"#
  let fmLink = makeHysteria2Link(fm: fmSalamander)
  let parsed = try SubscriptionClient.parsePayload(fmLink)
  guard case .compatibility(let profile) = parsed else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(profile.hysteria2.first?.obfsPassword == "fm-salamander")

  let matching = makeHysteria2Link(
    fm: fmSalamander,
    obfsPassword: "fm-salamander"
  )
  let matchingProfile = try SubscriptionClient.parsePayload(matching)
  guard case .compatibility(let matchingCompatibility) = matchingProfile else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(matchingCompatibility.hysteria2.first?.obfsPassword == "fm-salamander")

  let conflicting = makeHysteria2Link(
    fm: fmSalamander,
    obfsPassword: "different-salamander"
  )
  #expect(throws: SubscriptionFailure.ambiguousHysteria2FM) {
    try SubscriptionClient.parsePayload(conflicting)
  }

  let fmQuic = #"{"quicParams":{"maxIncomingStreams":32}}"#
  let quicProfile = try SubscriptionClient.parsePayload(makeHysteria2Link(fm: fmQuic))
  let built = try ConfigBuilder(cachePath: "/tmp/sbm-fm-cache", apiSecret: "test-secret")
    .makeConfiguration(profile: quicProfile, mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let outbounds = try #require(root["outbounds"] as? [[String: Any]])
  let hysteria = try #require(outbounds.first { ($0["type"] as? String) == "hysteria2" })
  #expect(hysteria["obfs"] == nil)
  #expect(!String(data: built.data, encoding: .utf8)!.contains("maxIncomingStreams"))

  for invalid in [
    #"{"quicParams":{"maxIncomingStreams":1,"extra":true}}"#,
    #"{"quicParams":{"maxIncomingStreams":1.5}}"#,
    #"{"udp":[{"type":"salamander","settings":{"password":"x"}},{"type":"other","settings":{}}]}"#,
    #"{"unknown":{"password":"fm-secret"}}"#,
  ] {
    #expect(throws: SubscriptionFailure.invalidHysteria2FM) {
      try SubscriptionClient.parsePayload(makeHysteria2Link(fm: invalid))
    }
  }
}

@Test func hysteria2FMDiagnosticsNeverExposeRawSecrets() throws {
  let secret = "fm-diagnostic-secret"
  let invalid = makeHysteria2Link(
    fm: #"{"unknown":{"password":"fm-diagnostic-secret"}}"#
  )
  let valid = makeHysteria2Link(host: "valid-hy.example.test")
  let result = try SubscriptionClient.parsePayloadResult(valid + "\n" + invalid)
  let warning = try #require(result.warningDescription)
  #expect(warning.contains("unsupported or malformed fm"))
  #expect(!warning.contains(secret))
}

@Test func realitySpiderXIsValidatedAndDoesNotChangeRuntimeSemantics() throws {
  let common = [
    URLQueryItem(name: "flow", value: "xtls-rprx-vision"),
    URLQueryItem(name: "security", value: "reality"),
    URLQueryItem(name: "sni", value: "reality.example.test"),
    URLQueryItem(name: "fp", value: "chrome"),
    URLQueryItem(name: "pbk", value: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU"),
    URLQueryItem(name: "sid", value: "bb6b725b"),
    URLQueryItem(name: "type", value: "tcp"),
  ]
  let without = makeVLESSLink(queryItems: common)
  let withSpiderX = makeVLESSLink(
    queryItems: common + [URLQueryItem(name: "spx", value: "/fallback")]
  )
  let withoutProfile = try SubscriptionClient.parsePayload(without)
  let withProfile = try SubscriptionClient.parsePayload(withSpiderX)
  #expect(withoutProfile == withProfile)

  let withoutBuilt = try ConfigBuilder(cachePath: "/tmp/sbm-spx-cache", apiSecret: "test-secret")
    .makeConfiguration(profile: withoutProfile, mode: .rule, selectedNode: .auto)
  let withBuilt = try ConfigBuilder(cachePath: "/tmp/sbm-spx-cache", apiSecret: "test-secret")
    .makeConfiguration(profile: withProfile, mode: .rule, selectedNode: .auto)
  #expect(withoutBuilt.data == withBuilt.data)

  for invalid in ["fallback", "", "\n/fallback"] {
    #expect(throws: SubscriptionFailure.invalidVLESS) {
      try SubscriptionClient.parsePayload(
        makeVLESSLink(queryItems: common + [URLQueryItem(name: "spx", value: invalid)])
      )
    }
  }
}

@Test func vlessTLSGRPCSupportsGunAndRejectsXrayOnlyModes() throws {
  let base = [
    URLQueryItem(name: "encryption", value: "none"),
    URLQueryItem(name: "security", value: "tls"),
    URLQueryItem(name: "type", value: "grpc"),
    URLQueryItem(name: "serviceName", value: "edge-service"),
    URLQueryItem(name: "sni", value: "grpc.example.test"),
    URLQueryItem(name: "fp", value: "firefox"),
  ]
  let omittedMode = try SubscriptionClient.parsePayload(makeVLESSLink(queryItems: base))
  guard case .compatibility(let compatibility) = omittedMode,
    case .vless(let vless) = try #require(compatibility.connections.first?.outbound)
  else {
    Issue.record("Expected a VLESS compatibility connection")
    return
  }
  #expect(vless.variant == .tlsGRPC(serviceName: "edge-service"))
  #expect(vless.grpcServiceName == "edge-service")
  #expect(vless.publicKey.isEmpty)

  _ = try SubscriptionClient.parsePayload(
    makeVLESSLink(queryItems: base + [URLQueryItem(name: "mode", value: "gun")])
  )
  for mode in ["multi", "guna"] {
    let link = makeVLESSLink(queryItems: base + [URLQueryItem(name: "mode", value: mode)])
    #expect(throws: SubscriptionFailure.unsupportedVLESSGRPCMode) {
      try SubscriptionClient.parsePayload(link)
    }
    let result = try SubscriptionClient.parsePayloadResult(
      makeVLESSLink(queryItems: base) + "\n" + link
    )
    #expect(result.skippedReasons[.unsupportedVLESSGRPCMode] == 1)
    #expect(result.warningDescription?.contains("unsupported mode") == true)
  }

  #expect(throws: SubscriptionFailure.unsupportedVLESSParameter) {
    try SubscriptionClient.parsePayload(
      makeVLESSLink(
        queryItems: base.filter { $0.name != "serviceName" }
      )
    )
  }
  #expect(throws: SubscriptionFailure.unsupportedVLESSParameter) {
    try SubscriptionClient.parsePayload(
      makeVLESSLink(
        queryItems: base + [URLQueryItem(name: "flow", value: "xtls-rprx-vision")]
      )
    )
  }
}

@Test func observedMixedSubscriptionTopologyImportsThirteenAndSkipsTwentyXHTTP() throws {
  let realityBase = [
    URLQueryItem(name: "flow", value: "xtls-rprx-vision"),
    URLQueryItem(name: "security", value: "reality"),
    URLQueryItem(name: "sni", value: "reality.example.test"),
    URLQueryItem(name: "fp", value: "chrome"),
    URLQueryItem(name: "pbk", value: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU"),
    URLQueryItem(name: "sid", value: "bb6b725b"),
    URLQueryItem(name: "type", value: "tcp"),
  ]
  let realities = (0..<3).map { index in
    makeVLESSLink(
      uuid: syntheticUUID(index),
      host: "203.0.113.\(10 + index)",
      queryItems: realityBase
        + (index < 2
          ? [URLQueryItem(name: "spx", value: "/fallback")]
          : [])
    )
  }
  let grpc = makeVLESSLink(
    uuid: syntheticUUID(3),
    host: "203.0.113.20",
    queryItems: [
      URLQueryItem(name: "encryption", value: "none"),
      URLQueryItem(name: "security", value: "tls"),
      URLQueryItem(name: "type", value: "grpc"),
      URLQueryItem(name: "serviceName", value: "edge-service"),
      URLQueryItem(name: "sni", value: "grpc.example.test"),
      URLQueryItem(name: "fp", value: "chrome"),
      URLQueryItem(name: "mode", value: "gun"),
    ]
  )
  let hysteria = (0..<7).map { index in
    makeHysteria2Link(host: "hy\(index).example.test")
  }
  let salamander = makeHysteria2Link(
    host: "hy-salamander.example.test",
    fm: #"{"udp":[{"type":"salamander","settings":{"password":"fm-salamander"}}]}"#
  )
  let quic = makeHysteria2Link(
    host: "hy-quic.example.test",
    fm: #"{"quicParams":{"maxIncomingStreams":32}}"#
  )
  let xhttp = (0..<20).map { index in
    makeVLESSLink(
      uuid: syntheticUUID(100 + index),
      host: "198.51.100.\(index + 1)",
      queryItems: [URLQueryItem(name: "type", value: "xhttp")]
    )
  }

  let result = try SubscriptionClient.parsePayloadResult(
    (realities + [grpc] + hysteria + [salamander, quic] + xhttp).joined(separator: "\n")
  )
  guard case .compatibility(let profile) = result.profile else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(profile.connections.count == 13)
  #expect(result.skippedTransports == ["xhttp": 20])
  #expect(result.warningDescription?.contains("20 XHTTP connections skipped") == true)
}

@Test func managedVLESSVariantsPreserveLegacyRealityAndRoundTripGRPC() throws {
  let reality = VLESSProfile(
    server: "203.0.113.10",
    port: 443,
    uuid: syntheticUUID(200),
    serverName: "reality.example.test",
    fingerprint: "chrome",
    publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
    shortID: "bb6b725b"
  )
  let realityObject = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(reality)) as? [String: Any]
  )
  #expect(realityObject["security"] == nil)
  #expect(realityObject["publicKey"] as? String == reality.publicKey)
  #expect(
    try JSONDecoder().decode(VLESSProfile.self, from: JSONEncoder().encode(reality)) == reality)

  let grpc = VLESSProfile(
    server: "grpc.example.test",
    port: 443,
    uuid: syntheticUUID(201),
    serverName: "grpc.example.test",
    fingerprint: "firefox",
    variant: .tlsGRPC(serviceName: "edge-service")
  )
  let connection = ManagedConnection(
    id: ProxyNodeID(rawValue: "legacy-node"), displayName: "gRPC", outbound: .vless(grpc))
  let profile = CoreProfile.compatibility(VPNProfile(connections: [connection]))
  let roundTripped = try JSONDecoder().decode(
    CoreProfile.self,
    from: JSONEncoder().encode(profile)
  )
  #expect(roundTripped == profile)
  #expect(
    connection.semanticIdentity
      == ManagedConnection(id: connection.id, displayName: "Renamed", outbound: .vless(grpc))
      .semanticIdentity)
  let grpcObject = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(grpc)) as? [String: Any]
  )
  #expect(grpcObject["security"] as? String == "tls")
  #expect(grpcObject["type"] as? String == "grpc")
  #expect(grpcObject["publicKey"] == nil)
  #expect(grpcObject["shortID"] == nil)
}

private func syntheticUUID(_ index: Int) -> String {
  String(format: "00000000-0000-4000-8000-%012x", index + 1)
}

private func makeVLESSLink(
  uuid: String = syntheticUUID(999),
  host: String = "203.0.113.10",
  queryItems: [URLQueryItem],
  fragment: String = "Synthetic"
) -> String {
  var components = URLComponents()
  components.scheme = "vless"
  components.user = uuid
  components.host = host
  components.port = 443
  components.queryItems = queryItems
  components.fragment = fragment
  return components.string!
}

private func makeHysteria2Link(
  host: String = "hy.example.test",
  fm: String? = nil,
  obfsPassword: String? = nil,
  fragment: String = "Synthetic Hysteria2"
) -> String {
  var components = URLComponents()
  components.scheme = "hysteria2"
  components.user = "hy-password"
  components.host = host
  components.port = 443
  var queryItems = [URLQueryItem(name: "sni", value: host)]
  if let obfsPassword {
    queryItems += [
      URLQueryItem(name: "obfs", value: "salamander"),
      URLQueryItem(name: "obfs-password", value: obfsPassword),
    ]
  }
  if let fm {
    queryItems.append(URLQueryItem(name: "fm", value: fm))
  }
  components.queryItems = queryItems
  components.fragment = fragment
  return components.string!
}
