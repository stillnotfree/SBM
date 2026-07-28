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
  #expect(compatibility.vless?.server == "203.0.113.10")
  #expect(compatibility.vless?.serverName == "www.debian.org")
  #expect(compatibility.vless?.displayName == "🇩🇪 Reality")
  #expect(compatibility.hysteria2?.server == "vpn.example.com")
  #expect(compatibility.hysteria2?.password == "test-password")
  #expect(compatibility.hysteria2?.obfsPassword == "test-obfs")
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
  #expect(compatibility.hysteria2?.password == "test-password")
  #expect(compatibility.hysteria2?.obfsPassword == nil)
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

  #expect(throws: SubscriptionFailure.self) {
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
  #expect(compatibility.vless?.server == "203.0.113.10")
}

@Test func directVLESSLinkCreatesSingleNodeProfile() throws {
  let link =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b&type=tcp#Reality"
  let profile = try SubscriptionClient.parsePayload(link)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(compatibility.vless != nil)
  #expect(compatibility.hysteria2 == nil)
}

@Test func directHysteria2LinkCreatesSingleNodeProfile() throws {
  let link =
    "hysteria2://test-password@vpn.example.com:443/?sni=vpn.example.com#Hysteria2"
  let profile = try SubscriptionClient.parsePayload(link)
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(compatibility.vless == nil)
  #expect(compatibility.hysteria2 != nil)
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
