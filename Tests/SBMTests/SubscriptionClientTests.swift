import Foundation
import Testing

@testable import SBM

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

@Test func duplicateQueryKeysDoNotCrashParser() throws {
  let links = """
    vless://5efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?flow=wrong&flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=chrome&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b
    hysteria2://test-password@vpn.example.com:443/?sni=vpn.example.com&obfs=salamander&obfs-password=test-obfs
    """
  let profile = try SubscriptionClient.parsePayload(links)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility subscription")
    return
  }
  #expect(compatibility.vless.first?.server == "203.0.113.10")
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
      deviceOS: "macOS",
      hardwareID: "test-hwid"
    )
  )
  #expect(request.value(forHTTPHeaderField: "User-Agent") == "Custom Client/1.0")
  #expect(request.value(forHTTPHeaderField: "X-Device-OS") == "macOS")
  #expect(request.value(forHTTPHeaderField: "X-HWID") == "test-hwid")
}

@Test func subscriptionRedirectDoesNotLeakPrivateHeadersAcrossOrigins() throws {
  let source = URL(string: "https://example.com/subscription")!
  let original = try SubscriptionClient.makeRequest(
    for: source,
    headers: SubscriptionHeaders(
      userAgent: "Custom Client/1.0",
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
  let crossOrigin = try #require(
    SubscriptionClient.sanitizedRedirectRequest(
      crossOriginRequest,
      from: source
    )
  )
  #expect(crossOrigin.value(forHTTPHeaderField: "X-HWID") == nil)
  #expect(crossOrigin.value(forHTTPHeaderField: "X-Device-OS") == nil)
  #expect(crossOrigin.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("SBM/") == true)

  #expect(
    SubscriptionClient.sanitizedRedirectRequest(
      URLRequest(url: URL(string: "http://example.com/insecure")!),
      from: source
    ) == nil
  )
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
