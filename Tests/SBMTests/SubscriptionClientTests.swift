import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

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
  #expect(compatibility.vless.first?.displayName == "🇩🇪 Reality")
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
  #expect(compatibility.vless.map(\.displayName) == ["Reality 1", "Reality 2"])
  #expect(compatibility.hysteria2.map(\.displayName) == ["Hysteria2 1", "Hysteria2 2"])
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
  #expect(result.skippedTransports == ["xhttp": 1])
  #expect(result.warningDescription?.contains("2 connections imported") == true)
  #expect(result.warningDescription?.contains("1 XHTTP connection skipped") == true)
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
  #expect(compatibility.vless.map(\.displayName) == ["Netherlands"])
  #expect(compatibility.hysteria2.isEmpty)
  #expect(compatibility.nodeGroups?.first?.nodes == [compatibility.connections[0].id])
}

@Test func sourceExcludeRegexRejectsInvalidPatterns() {
  #expect(throws: SubscriptionFailure.invalidExcludeRegex) {
    try SourceNameFilter.normalized("(?i)(")
  }
}

@Test func proxyNodeSectionsPreserveSourcesAndSortMeasuredNodesByLatency() {
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
  #expect(sections[0].nodes.map(\.name) == ["Hysteria2", "Reality"])
  #expect(sections[1].nodes.map(\.name) == ["Sweden", "Netherlands"])
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
