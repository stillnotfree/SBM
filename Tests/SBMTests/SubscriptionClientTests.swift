import Darwin
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
  #expect(throws: SubscriptionFailure.invalidRoutingPolicy) {
    try RoutingPolicyParser.parse(
      Data(#"{"route":{"rules":[],"rules":[]}}"#.utf8)
    )
  }
}

@Test func selectedRoutingPolicyReadIsBoundedAndRejectsNonregularFilesPromptly() throws {
  let directory = URL(
    fileURLWithPath: "/tmp/SBM-RoutingPolicyProbe-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }

  let valid = Data(#"{"route":{"rules":[]}}"#.utf8)
  let regular = directory.appendingPathComponent("regular.json")
  try valid.write(to: regular)
  #expect(try RoutingPolicyParser.parse(contentsOf: regular).configuration == valid)

  let exactSizeURL = directory.appendingPathComponent("exact-bound.json")
  var exactSize = valid
  exactSize.append(
    Data(repeating: 0x20, count: RoutingPolicyParser.maximumPolicySize - valid.count))
  try exactSize.write(to: exactSizeURL)
  #expect(exactSize.count == RoutingPolicyParser.maximumPolicySize)
  #expect(try RoutingPolicyParser.parse(contentsOf: exactSizeURL).configuration == exactSize)

  let oversized = directory.appendingPathComponent("oversized.json")
  try Data(repeating: 0x20, count: RoutingPolicyParser.maximumPolicySize + 1).write(to: oversized)
  #expect(throws: SubscriptionFailure.invalidRoutingPolicy) {
    try RoutingPolicyParser.parse(contentsOf: oversized)
  }

  let nonregular = directory.appendingPathComponent("directory", isDirectory: true)
  try FileManager.default.createDirectory(at: nonregular, withIntermediateDirectories: false)
  #expect(throws: SubscriptionFailure.invalidRoutingPolicy) {
    try RoutingPolicyParser.parse(contentsOf: nonregular)
  }

  let fifo = directory.appendingPathComponent("waiting.fifo")
  let fifoResult = fifo.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
  #expect(fifoResult == 0)
  let started = ContinuousClock.now
  #expect(throws: SubscriptionFailure.invalidRoutingPolicy) {
    try RoutingPolicyParser.parse(contentsOf: fifo)
  }
  #expect(started.duration(to: .now) < .seconds(1))
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

@Test func hysteria2PortHoppingCanonicalizesOfficialAuthoritySyntax() throws {
  func parse(_ authority: String) throws -> Hysteria2Profile {
    try parseManagedHysteria2(
      "hysteria2://secret@vpn.example.test:\(authority)/?sni=vpn.example.test#Hop")
  }

  let discrete = try parse("1234,5678,9012")
  #expect(discrete.port == 1234)
  #expect(
    discrete.portHoppingRanges
      == [
        Hysteria2PortRange(start: 1234, end: 1234),
        Hysteria2PortRange(start: 5678, end: 5678),
        Hysteria2PortRange(start: 9012, end: 9012),
      ])

  let interval = try parse("20000-50000")
  #expect(interval.port == 20000)
  #expect(interval.portHoppingRanges == [Hysteria2PortRange(start: 20000, end: 50000)])

  let mixed = try parse("8000-8001,1234,1235,9000-9002")
  #expect(
    mixed.portHoppingRanges
      == [
        Hysteria2PortRange(start: 1234, end: 1235),
        Hysteria2PortRange(start: 8000, end: 8001),
        Hysteria2PortRange(start: 9000, end: 9002),
      ])

  let ipv6 = try parseManagedHysteria2(
    "hy2://p%2520x@[2001:db8::2]:443,8443-8444/?sni=hy.example.test#IPv6")
  #expect(ipv6.server == "[2001:db8::2]")
  #expect(ipv6.password == "p%20x")
  #expect(
    ipv6.portHoppingRanges
      == [
        Hysteria2PortRange(start: 443, end: 443),
        Hysteria2PortRange(start: 8443, end: 8444),
      ])
}

@Test func hysteria2PortHoppingIdentityUsesCanonicalPortSetAndPreservesSinglePortIdentity()
  throws
{
  let first = try SubscriptionClient.parsePayload(
    "hysteria2://password@vpn.example.test:9012,1234,5678/?sni=vpn.example.test#Stable")
  let reordered = try SubscriptionClient.parsePayload(
    "hysteria2://password@vpn.example.test:5678,9012,1234/?sni=vpn.example.test#Stable")
  let changed = try SubscriptionClient.parsePayload(
    "hysteria2://password@vpn.example.test:1234,5678,9013/?sni=vpn.example.test#Stable")
  guard case .compatibility(let firstProfile) = first,
    case .compatibility(let reorderedProfile) = reordered,
    case .compatibility(let changedProfile) = changed,
    let firstConnection = firstProfile.connections.first,
    let reorderedConnection = reorderedProfile.connections.first,
    let changedConnection = changedProfile.connections.first
  else {
    Issue.record("Expected managed Hysteria2 port hopping profiles")
    return
  }
  #expect(firstConnection.id == reorderedConnection.id)
  #expect(firstConnection.semanticIdentity == reorderedConnection.semanticIdentity)
  #expect(firstConnection.id != changedConnection.id)
  #expect(firstConnection.semanticIdentity != changedConnection.semanticIdentity)

  let ordinary = ManagedOutbound.hysteria2(
    Hysteria2Profile(
      server: "vpn.example.com",
      port: 443,
      password: "password",
      serverName: "vpn.example.com"
    )
  )
  #expect(
    ordinary.semanticIdentity
      == "9:hysteria215:vpn.example.com3:4438:password15:vpn.example.com0:"
  )
}

@Test func hysteria2PortHoppingRejectsMalformedAuthoritiesAndAliases() throws {
  let invalidAuthorities = [
    "", ",1234", "1234,", "1234,,5678", "0,1234", "65536,1234",
    "999999999999999999999999999999999999999999,1234", "5000-4999", "1234,1234",
    "1234-5678,5678", " 1234,5678", "1234 ,5678", "+1234,5678",
    "1234--5678", "1234-5678-9000", "١٢٣٤,5678",
  ]
  for authority in invalidAuthorities {
    #expect(throws: SubscriptionFailure.invalidHysteria2) {
      try SubscriptionClient.parsePayload(
        "hysteria2://secret@vpn.example.test:\(authority)/?sni=vpn.example.test#Invalid")
    }
  }
  #expect(throws: SubscriptionFailure.invalidHysteria2) {
    try SubscriptionClient.parsePayload(
      "hysteria2://secret@[2001:db8::1:1234,5678/?sni=vpn.example.test#Invalid")
  }
  #expect(throws: SubscriptionFailure.invalidHysteria2) {
    try SubscriptionClient.parsePayload(
      "hysteria2://secret@vpn.example.test:1234,5678/?sni=vpn.example.test&mport=8443#Invalid")
  }

  let onePort = try parseManagedHysteria2(
    "hysteria2://secret@vpn.example.test:443-443/?sni=vpn.example.test#Single")
  #expect(onePort.port == 443)
  #expect(onePort.portHoppingRanges == nil)
  let omittedPort = try parseManagedHysteria2(
    "hysteria2://secret@vpn.example.test/?sni=vpn.example.test#Default")
  #expect(omittedPort.port == 443)
  #expect(omittedPort.portHoppingRanges == nil)

  let sixtyFourTerms = stride(from: 1000, through: 1126, by: 2).map { String($0) }.joined(
    separator: ",")
  #expect(
    try parseManagedHysteria2(
      "hysteria2://secret@vpn.example.test:\(sixtyFourTerms)/?sni=vpn.example.test#Count"
    ).portHoppingRanges?.count == 64
  )
  let sixtyFiveTerms = stride(from: 1000, through: 1128, by: 2).map { String($0) }.joined(
    separator: ",")
  #expect(throws: SubscriptionFailure.invalidHysteria2) {
    try parseManagedHysteria2(
      "hysteria2://secret@vpn.example.test:\(sixtyFiveTerms)/?sni=vpn.example.test#Count"
    )
  }
  #expect(
    try parseManagedHysteria2(
      "hysteria2://secret@vpn.example.test:1000-1001,1002-1003/?sni=vpn.example.test#Merged"
    ).portHoppingRanges == [Hysteria2PortRange(start: 1000, end: 1003)]
  )
}

@Test func strictSIP002ShadowsocksAcceptsPlainAndBase64UserInfo() throws {
  let plain = "ss://aes-256-gcm:plain-password@ss.example.com:443/#Plain"
  let expandedCipher = "ss://aes-192-gcm:other-password@ss.example.com:443/#Expanded"
  let encodedCredential = Data("chacha20-ietf-poly1305:encoded-password".utf8)
    .base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  let profile = try SubscriptionClient.parsePayload(
    "\(plain)\n\(expandedCipher)\nss://\(encodedCredential)@198.51.100.2:8443/#Encoded")
  guard case .compatibility(let compatibility) = profile else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(compatibility.connections.count == 3)
  #expect(compatibility.connections.allSatisfy { $0.id.rawValue.hasPrefix("node-") })
  #expect(
    compatibility.shadowsocks.map(\.method)
      == ["aes-256-gcm", "aes-192-gcm", "chacha20-ietf-poly1305"]
  )
  #expect(
    compatibility.shadowsocks.map(\.password)
      == ["plain-password", "other-password", "encoded-password"]
  )
}

@Test func strictSIP002ShadowsocksAllowsGenericCipherSyntaxButRejectsMalformedForms() throws {
  let psk = Data(repeating: 7, count: 16).base64EncodedString()
  let valid = "ss://2022-blake3-aes-128-gcm:\(psk)@ss.example.com:443/#2022"
  let encoded2022 = Data("2022-blake3-aes-128-gcm:\(psk)".utf8).base64EncodedString()
  _ = try SubscriptionClient.parsePayload(valid)
  _ = try SubscriptionClient.parsePayload(
    "ss://2022-blake3-aes-128-gcm:c2hvcnQ=@ss.example.com:443/"
  )
  let unknownCipher = try SubscriptionClient.parsePayload(
    "ss://unknown-cipher:password@ss.example.com:443/"
  )
  guard case .compatibility(let unknownCipherProfile) = unknownCipher else {
    Issue.record("Expected unknown cipher syntax to reach pinned-core validation")
    return
  }
  #expect(unknownCipherProfile.shadowsocks.first?.method == "unknown-cipher")
  for invalid in [
    "ss://\(encoded2022)@ss.example.com:443/",
    "ss://aes-128-gcm:password@ss.example.com:443/?plugin=obfs-local",
    "ss://YWVzLTEyOC1nY206cGFzc3dvcmRAc3MuZXhhbXBsZS5jb206NDQz",
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
  let httpQuery = managedVLESSMatrixCases()[3].query
  let links = [
    makeVLESSLink(uuid: syntheticUUID(300), queryItems: realityQuery, fragment: "VLESS A"),
    makeHysteria2Link(host: "hy-a.example.test", fragment: "Hysteria B"),
    makeVLESSLink(uuid: syntheticUUID(301), queryItems: httpQuery, fragment: "VLESS C"),
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
  guard case .vless(let vlessHTTP) = compatibility.connections[2].outbound else {
    Issue.record("Expected the third connection to be managed VLESS HTTP")
    return
  }
  #expect(vlessHTTP.variant == .tlsHTTP(host: "http.example.test", path: "/api"))
}

@Test func subscriptionLinesTrimEdgesAndDecodeWrappedDocuments() throws {
  let vless = makeVLESSLink(queryItems: managedVLESSMatrixCases()[2].query, fragment: "VLESS")
  let hysteria = makeHysteria2Link(fragment: "Hysteria2")
  let shadowsocks = "ss://aes-128-gcm:secret@ss.example.test:443/#Shadowsocks"
  let document = "\r\n  \(vless) \t\r\n\n\t\(hysteria)  \r\n \(shadowsocks) \n"

  func names(_ body: String) throws -> [String] {
    guard case .compatibility(let profile) = try SubscriptionClient.parsePayloadResult(body).profile
    else { return [] }
    return profile.connections.map(\.displayName)
  }

  #expect(try names(document) == ["VLESS", "Hysteria2", "Shadowsocks"])
  let padded = Data(document.utf8).base64EncodedString()
  let unpadded = padded.trimmingCharacters(in: CharacterSet(charactersIn: "="))
  #expect(try names(padded) == ["VLESS", "Hysteria2", "Shadowsocks"])
  #expect(try names(unpadded) == ["VLESS", "Hysteria2", "Shadowsocks"])

  let bannerAndNode = try SubscriptionClient.parsePayloadResult("provider banner\n\(vless)")
  #expect(bannerAndNode.warningDescription == nil)
}

@Test func subscriptionUserInfoDecodesExactlyOnce() throws {
  let first = try SubscriptionClient.parsePayload(
    "hysteria2://p%20x@hy.example.test:443/?sni=hy.example.test#Space"
  )
  let second = try SubscriptionClient.parsePayload(
    "hysteria2://p%2520x@hy.example.test:443/?sni=hy.example.test#Literal"
  )
  let newlineEscape = try SubscriptionClient.parsePayload(
    "hysteria2://p%250Aq@hy.example.test:443/?sni=hy.example.test#LiteralEscape"
  )
  let literalPlus = try SubscriptionClient.parsePayload(
    "hysteria2://p+x@hy.example.test:443/?sni=hy.example.test#Plus"
  )
  guard case .compatibility(let firstProfile) = first,
    case .compatibility(let secondProfile) = second,
    case .compatibility(let newlineEscapeProfile) = newlineEscape,
    case .compatibility(let plusProfile) = literalPlus,
    case .hysteria2(let firstValue) = firstProfile.connections[0].outbound,
    case .hysteria2(let secondValue) = secondProfile.connections[0].outbound,
    case .hysteria2(let newlineEscapeValue) = newlineEscapeProfile.connections[0].outbound,
    case .hysteria2(let plusValue) = plusProfile.connections[0].outbound
  else {
    Issue.record("Expected managed Hysteria2 credentials")
    return
  }
  #expect(firstValue.password == "p x")
  #expect(secondValue.password == "p%20x")
  #expect(newlineEscapeValue.password == "p%0Aq")
  #expect(plusValue.password == "p+x")
  #expect(
    firstProfile.connections[0].semanticIdentity != secondProfile.connections[0].semanticIdentity)

  #expect(throws: SubscriptionFailure.invalidVLESS) {
    try SubscriptionClient.parsePayload(
      "vless://%2535efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?security=tls&sni=example.test"
    )
  }
}

@Test func managedServerPortsDistinguishOmittedFromMalformedExplicitPorts() throws {
  let query = managedVLESSMatrixCases()[2].query
  let vless = makeVLESSLink(queryItems: query)
  let vlessWithoutPort = vless.replacingOccurrences(of: ":443?", with: "?")
  for link in [vless, vlessWithoutPort] {
    guard case .compatibility(let profile) = try SubscriptionClient.parsePayload(link),
      case .vless(let value) = profile.connections[0].outbound
    else {
      Issue.record("Expected managed VLESS")
      return
    }
    #expect(value.port == 443)
  }

  let hysteria = makeHysteria2Link()
  let hysteriaWithoutPort = hysteria.replacingOccurrences(of: ":443/?", with: "/?")
  for link in [hysteria, hysteriaWithoutPort] {
    guard case .compatibility(let profile) = try SubscriptionClient.parsePayload(link),
      case .hysteria2(let value) = profile.connections[0].outbound
    else {
      Issue.record("Expected managed Hysteria2")
      return
    }
    #expect(value.port == 443)
  }

  for port in ["0", "65536", "999999999999999999999999999999999999999999"] {
    #expect(throws: SubscriptionFailure.invalidVLESS) {
      try SubscriptionClient.parsePayload(
        vless.replacingOccurrences(of: ":443?", with: ":\(port)?"))
    }
    #expect(throws: SubscriptionFailure.invalidHysteria2) {
      try SubscriptionClient.parsePayload(
        hysteria.replacingOccurrences(of: ":443?", with: ":\(port)?")
      )
    }
  }

  let bracketedVLESS = makeVLESSLink(host: "[2001:db8::1]", queryItems: query)
  let bracketedVLESSComponents = try #require(URLComponents(string: bracketedVLESS))
  #expect(bracketedVLESSComponents.rangeOfPort != nil)
  #expect(bracketedVLESSComponents.port == 443)
  #expect(throws: SubscriptionFailure.invalidVLESS) {
    try SubscriptionClient.parsePayload(
      bracketedVLESS.replacingOccurrences(of: "]:443?", with: "]:65536?")
    )
  }
  let bracketedHysteria = hysteria.replacingOccurrences(
    of: "@hy.example.test:443?", with: "@[2001:db8::1]:443?"
  )
  let bracketedHysteriaComponents = try #require(URLComponents(string: bracketedHysteria))
  #expect(bracketedHysteriaComponents.rangeOfPort != nil)
  #expect(bracketedHysteriaComponents.port == 443)
  #expect(throws: SubscriptionFailure.invalidHysteria2) {
    try SubscriptionClient.parsePayload(
      bracketedHysteria.replacingOccurrences(of: "]:443?", with: "]:65536?")
    )
  }
}

@Test func managedEndpointAndSecretBoundsIsolateInvalidSubscriptionRows() throws {
  let longHost = String(repeating: "h", count: 254)
  let longSecret = String(repeating: "p", count: 513)
  let valid = "ss://aes-128-gcm:valid@ss.example.test:443/#Valid"
  let invalidRows = [
    "hysteria2://\(longSecret)@hy.example.test:443/?sni=hy.example.test#LongPassword",
    makeHysteria2Link(obfsPassword: longSecret),
    "ss://aes-128-gcm:\(longSecret)@ss.example.test:443/#LongPassword",
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00000@:443?security=tls&sni=example.test#EmptyHost",
    "hysteria2://password@:443/?sni=example.test#EmptyHost",
    makeVLESSLink(host: longHost, queryItems: managedVLESSMatrixCases()[2].query),
    "hysteria2://password@\(longHost):443/?sni=example.test#LongHost",
  ]
  let result = try SubscriptionClient.parsePayloadResult(
    ([valid] + invalidRows).joined(separator: "\n"))
  guard case .compatibility(let profile) = result.profile else {
    Issue.record("Expected the valid neighbor to survive")
    return
  }
  #expect(profile.connections.map(\.displayName) == ["Valid"])
  #expect(result.skippedInvalidConnections[.hysteria2] == 4)
  #expect(result.skippedInvalidConnections[.shadowsocks] == 1)
  #expect(result.skippedInvalidConnections[.vless] == 2)
  #expect(result.warningDescription?.contains("4 Hysteria2 connections skipped") == true)
}

@Test func managedVLESSFingerprintsNormalizeLegacyAliasesAndExplicitEmpty() throws {
  let aliases = [
    "chrome_psk",
    "chrome_psk_shuffle",
    "chrome_padding_psk_shuffle",
    "chrome_pq",
    "chrome_pq_psk",
  ]
  let tlsQuery = managedVLESSMatrixCases()[2].query
  var referenceNodeID: ProxyNodeID?
  var referenceConfig: Data?
  let builder = ConfigBuilder(cachePath: "/tmp/cache.db", apiSecret: "test")

  for alias in aliases {
    let connection = try parseManagedVLESS(
      replacingVLESSQueryValue("fp", with: alias, in: tlsQuery), uuid: 6200
    )
    guard case .vless(let vless) = connection.outbound else {
      Issue.record("Expected a managed VLESS connection")
      return
    }
    #expect(vless.fingerprint == "chrome")
    if let referenceNodeID {
      #expect(connection.id == referenceNodeID)
    } else {
      referenceNodeID = connection.id
    }

    let built = try builder.makeConfiguration(
      profile: .compatibility(VPNProfile(connections: [connection])),
      mode: .rule,
      selectedNode: .auto
    )
    let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
    let outbounds = try #require(root["outbounds"] as? [[String: Any]])
    let outbound = try #require(
      outbounds.first { ($0["tag"] as? String) == connection.id.rawValue })
    let tls = try #require(outbound["tls"] as? [String: Any])
    let utls = try #require(tls["utls"] as? [String: Any])
    #expect(utls["fingerprint"] as? String == "chrome")
    if let referenceConfig {
      #expect(built.data == referenceConfig)
    } else {
      referenceConfig = built.data
    }
  }

  for query in [tlsQuery, managedVLESSMatrixCases()[0].query] {
    let emptyFingerprint = replacingVLESSQueryValue("fp", with: "", in: query)
    let connection = try parseManagedVLESS(emptyFingerprint, uuid: 6201)
    guard case .vless(let vless) = connection.outbound else {
      Issue.record("Expected a managed VLESS connection")
      return
    }
    #expect(vless.fingerprint == "chrome")
  }

  let canonical = try parseManagedVLESS(
    replacingVLESSQueryValue("fp", with: "firefox", in: tlsQuery), uuid: 6202
  )
  guard case .vless(let canonicalVLESS) = canonical.outbound else {
    Issue.record("Expected a managed VLESS connection")
    return
  }
  #expect(canonicalVLESS.fingerprint == "firefox")
  #expect(throws: SubscriptionFailure.self) {
    try parseManagedVLESS(
      replacingVLESSQueryValue("fp", with: "unsupported-fingerprint", in: tlsQuery)
    )
  }
}

@Test func managedVLESSAndHysteria2DefaultSNIFromEndpoints() throws {
  func parsedVLESS(_ query: [URLQueryItem], host: String = "203.0.113.10") throws -> VLESSProfile {
    let connection = try parseManagedVLESS(query, host: host)
    guard case .vless(let value) = connection.outbound else {
      throw SubscriptionFailure.invalidVLESS
    }
    return value
  }

  let variants = managedVLESSMatrixCases()
  let tls = try parsedVLESS(variants[2].query.filter { $0.name != "sni" })
  #expect(tls.serverName == "203.0.113.10")
  let realityOmitted = try parsedVLESS(variants[0].query.filter { $0.name != "sni" })
  #expect(realityOmitted.serverName == "203.0.113.10")
  let realityEmpty = try parsedVLESS(
    replacingVLESSQueryValue("sni", with: "", in: variants[0].query)
  )
  #expect(realityEmpty.serverName == "203.0.113.10")

  let vlessIPv6 = try parsedVLESS(
    variants[2].query.filter { $0.name != "sni" }, host: "[2001:db8::1]"
  )
  #expect(vlessIPv6.server == "[2001:db8::1]")
  #expect(vlessIPv6.serverName == "2001:db8::1")

  let hysteriaOmitted = try parseManagedHysteria2(makeHysteria2Link(includeSNI: false))
  #expect(hysteriaOmitted.serverName == "hy.example.test")
  let hysteriaEmpty = try parseManagedHysteria2(makeHysteria2Link(serverName: ""))
  #expect(hysteriaEmpty.serverName == "hy.example.test")
  let hysteriaIPv6 = try parseManagedHysteria2(
    makeHysteria2Link(host: "[2001:db8::2]", includeSNI: false)
  )
  #expect(hysteriaIPv6.server == "[2001:db8::2]")
  #expect(hysteriaIPv6.serverName == "2001:db8::2")

  let explicitVLESS = try parsedVLESS(
    replacingVLESSQueryValue("sni", with: "chosen.example.test", in: variants[2].query)
  )
  #expect(explicitVLESS.serverName == "chosen.example.test")
  let explicitHysteria = try parseManagedHysteria2(
    makeHysteria2Link(serverName: "chosen.example.test")
  )
  #expect(explicitHysteria.serverName == "chosen.example.test")
}

@Test func managedVLESSGRPCAcceptsOmittedAndEmptyServiceNamesButKeepsBounds() throws {
  let grpcQueries = [managedVLESSMatrixCases()[1].query, managedVLESSMatrixCases()[4].query]
  func serviceName(_ connection: ManagedConnection) -> String? {
    guard case .vless(let value) = connection.outbound else { return nil }
    switch value.variant {
    case .realityGRPC(_, _, let name), .tlsGRPC(let name): return name
    default: return nil
    }
  }

  for query in grpcQueries {
    let omitted = try parseManagedVLESS(query.filter { $0.name != "serviceName" })
    #expect(serviceName(omitted) == "")
    let empty = try parseManagedVLESS(
      replacingVLESSQueryValue("serviceName", with: "", in: query)
    )
    #expect(serviceName(empty) == "")
    for invalid in [String(repeating: "s", count: 257), "bad\u{0001}name"] {
      #expect(throws: SubscriptionFailure.self) {
        try parseManagedVLESS(
          replacingVLESSQueryValue("serviceName", with: invalid, in: query)
        )
      }
    }
  }
}

@Test func managedVLESSAndHysteria2RejectMalformedOrNonIPv6Brackets() {
  let invalidHosts = [
    "[2001:db8::1",
    "2001:db8::1]",
    "[[2001:db8::1]]",
    "[not-an-ip]",
    "[192.0.2.1]",
  ]
  for host in invalidHosts {
    let vless =
      "vless://\(syntheticUUID(6203))@\(host):443?security=tls&type=tcp&fp=chrome#Invalid"
    #expect(throws: SubscriptionFailure.self) {
      try SubscriptionClient.parsePayload(vless)
    }
    let hysteria = "hysteria2://password@\(host):443/?#Invalid"
    #expect(throws: SubscriptionFailure.self) {
      try SubscriptionClient.parsePayload(hysteria)
    }
  }
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

@Test func autoExclusionsFollowStableIDsPruneRemovedNodesAndIncludeNewNodes() {
  let nodeOne = ProxyNodeID(rawValue: "node-one")
  let nodeTwo = ProxyNodeID(rawValue: "node-two")
  let outboundOne = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "one.example.test", port: 443, method: "aes-128-gcm", password: "one"
    ))
  let outboundTwo = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "two.example.test", port: 443, method: "aes-128-gcm", password: "two"
    ))
  let previous = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(id: nodeOne, outbound: outboundOne),
        ManagedConnection(id: nodeTwo, outbound: outboundTwo),
      ],
      autoExcludedNodeIDs: [nodeOne, nodeTwo]
    ))
  let fetched = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(outbound: outboundOne),
        ManagedConnection(
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "three.example.test", port: 443, method: "aes-256-gcm", password: "three"
            )
          )),
      ]
    ))

  guard
    case .compatibility(let result) = ManagedConnectionReconciler.reconcile(
      existing: previous,
      fetched: fetched
    )
  else { return }
  #expect(result.connections[0].id == nodeOne)
  #expect(result.autoExcludedNodeIDs == [nodeOne])
  #expect(result.connections[1].id != nodeTwo)
  #expect(!result.autoExcludedNodeIDs.contains(result.connections[1].id))
}

@Test func autoExclusionActivationUsesSetMembershipRatherThanArrayOrder() {
  let firstID = ProxyNodeID(rawValue: "node-one")
  let secondID = ProxyNodeID(rawValue: "node-two")
  let outbound = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "same.example.test", port: 443, method: "aes-128-gcm", password: "same"
    ))
  let connections = [
    ManagedConnection(id: firstID, outbound: outbound),
    ManagedConnection(id: secondID, outbound: outbound),
  ]
  let previous = CoreProfile.compatibility(
    VPNProfile(connections: connections, autoExcludedNodeIDs: [firstID, secondID])
  )
  let reordered = CoreProfile.compatibility(
    VPNProfile(connections: connections, autoExcludedNodeIDs: [secondID, firstID])
  )
  let changed = CoreProfile.compatibility(
    VPNProfile(connections: connections, autoExcludedNodeIDs: [secondID])
  )
  #expect(!ManagedConnectionReconciler.requiresActivation(previous: previous, next: reordered))
  #expect(ManagedConnectionReconciler.requiresActivation(previous: previous, next: changed))
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
  #expect(result.skippedInvalidConnections[.vless] == nil)
  #expect(result.skippedReasons.isEmpty)
  #expect(result.warningDescription?.contains("2 connections imported") == true)
  #expect(result.warningDescription?.contains("1 XHTTP connection skipped") == true)
}

@Test func subscriptionLimitsRecognizedConnectionCountTo63() throws {
  let validShadowsocks = "ss://aes-128-gcm:password@ss.example.test:443/#Shadowsocks"
  let unsupportedXHTTP = "vless://vpn.example.test?type=xhttp"
  let atLimit = [validShadowsocks] + Array(repeating: unsupportedXHTTP, count: 62)

  let result = try SubscriptionClient.parsePayloadResult(atLimit.joined(separator: "\n"))
  guard case .compatibility(let profile) = result.profile else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(profile.connections.count == 1)
  #expect(result.skippedTransports == ["xhttp": 62])

  let overLimit = [validShadowsocks] + Array(repeating: unsupportedXHTTP, count: 63)
  #expect(throws: SubscriptionFailure.tooManyConnections) {
    try SubscriptionClient.parsePayloadResult(overLimit.joined(separator: "\n"))
  }
}

@Test func mixedSubscriptionSkipsInvalidRecognizedLinksWithoutLeakingSecrets() throws {
  let validVLESS =
    "vless://5efab93b-90d0-4904-93d6-44b4f0b00001@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=www.debian.org&fp=firefox&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=bb6b725b&type=tcp#Reality"
  let invalidVLESS =
    "vless://11111111-2222-3333-4444-555555555555@198.51.100.10:443?flow=xtls-rprx-vision&security=reality&sni=secret-vless.example&fp=firefox&pbk=bad&type=tcp#Invalid"
  let invalidHysteria =
    "hysteria2://super-secret-password@secret-hy.example:443/?sni=secret-hy.example&obfs=unsupported#Invalid"
  let invalidShadowsocks =
    "ss://aes-128-gcm:another-secret@secret-ss.example:443/?plugin=obfs-local#Invalid"

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

  for shortID in ["ABCDEF12", "aBcDeF12"] {
    let caseLink =
      "vless://5efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=example.test&fp=chrome&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=\(shortID)&type=tcp"
    guard case .compatibility(let caseProfile) = try SubscriptionClient.parsePayload(caseLink),
      case .vless(let caseValue) = caseProfile.connections[0].outbound,
      case .reality(_, let parsedShortID) = caseValue.variant
    else {
      Issue.record("Expected a REALITY VLESS connection")
      return
    }
    #expect(parsedShortID == shortID)
  }

  for shortID in ["ABC", "GG", "0123456789ABCDEF00"] {
    let invalid =
      "vless://5efab93b-90d0-4904-93d6-44b4f0b00000@203.0.113.10:443?flow=xtls-rprx-vision&security=reality&sni=example.test&fp=chrome&pbk=Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU&sid=\(shortID)&type=tcp"
    #expect(throws: SubscriptionFailure.invalidVLESS) {
      try SubscriptionClient.parsePayload(invalid)
    }
  }
}

@Test func directUnsupportedXHTTPLinkReportsTransport() {
  let link = "vless://vpn.example.test?type=xhttp"
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
      deviceOSVersion: "26.7",
      deviceModel: "iPhone",
      hardwareID: "test-hwid"
    )
  )
  #expect(request.value(forHTTPHeaderField: "User-Agent") == "Custom Client/1.0")
  #expect(request.value(forHTTPHeaderField: "X-App-Version") == "5.4.0")
  #expect(request.value(forHTTPHeaderField: "X-Device-OS") == "macOS")
  #expect(request.value(forHTTPHeaderField: "X-Ver-OS") == "26.7")
  #expect(request.value(forHTTPHeaderField: "X-Device-Model") == "iPhone")
  #expect(request.value(forHTTPHeaderField: "X-HWID") == "test-hwid")
}

@Test func subscriptionRequestOmitsAbsentOptionalIdentityHeaders() throws {
  let request = try SubscriptionClient.makeRequest(
    for: URL(string: "https://example.com/subscription")!,
    headers: SubscriptionHeaders(
      userAgent: "Legacy Client/1.0",
      appVersion: nil,
      deviceOS: "iOS",
      deviceOSVersion: nil,
      deviceModel: nil,
      hardwareID: "test-hwid"
    )
  )
  #expect(request.value(forHTTPHeaderField: "X-App-Version") == nil)
  #expect(request.value(forHTTPHeaderField: "X-Ver-OS") == nil)
  #expect(request.value(forHTTPHeaderField: "X-Device-Model") == nil)
}

@Test func subscriptionPlatformHeaderValidationEnforcesBoundsAndControls() {
  #expect(throws: SubscriptionFailure.invalidHeader("X-Ver-OS")) {
    try SubscriptionClient.validate(headers: SubscriptionHeaders(deviceOSVersion: ""))
  }
  #expect(throws: SubscriptionFailure.invalidHeader("X-Ver-OS")) {
    try SubscriptionClient.validate(
      headers: SubscriptionHeaders(deviceOSVersion: String(repeating: "v", count: 65))
    )
  }
  #expect(throws: SubscriptionFailure.invalidHeader("X-Ver-OS")) {
    try SubscriptionClient.validate(headers: SubscriptionHeaders(deviceOSVersion: "26.7\n"))
  }
  #expect(throws: SubscriptionFailure.invalidHeader("X-Device-Model")) {
    try SubscriptionClient.validate(headers: SubscriptionHeaders(deviceModel: ""))
  }
  #expect(throws: SubscriptionFailure.invalidHeader("X-Device-Model")) {
    try SubscriptionClient.validate(
      headers: SubscriptionHeaders(deviceModel: String(repeating: "m", count: 129))
    )
  }
  #expect(throws: SubscriptionFailure.invalidHeader("X-Device-Model")) {
    try SubscriptionClient.validate(headers: SubscriptionHeaders(deviceModel: "iPhone\t"))
  }
}

@Test func subscriptionRedirectDoesNotLeakPrivateHeadersAcrossOrigins() throws {
  let source = URL(string: "https://example.com/subscription")!
  let original = try SubscriptionClient.makeRequest(
    for: source,
    headers: SubscriptionHeaders(
      userAgent: "Custom Client/1.0",
      appVersion: "5.4.0",
      deviceOS: "macOS",
      deviceOSVersion: "26.7",
      deviceModel: "iPhone",
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
  #expect(sameOrigin.value(forHTTPHeaderField: "X-Ver-OS") == "26.7")
  #expect(sameOrigin.value(forHTTPHeaderField: "X-Device-Model") == "iPhone")

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
  #expect(crossOrigin.value(forHTTPHeaderField: "X-Ver-OS") == nil)
  #expect(crossOrigin.value(forHTTPHeaderField: "X-Device-Model") == nil)
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
  #expect(returnToOrigin.value(forHTTPHeaderField: "X-Ver-OS") == nil)
  #expect(returnToOrigin.value(forHTTPHeaderField: "X-Device-Model") == nil)

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
  #expect(throws: SubscriptionFailure.invalidExcludeRegex) {
    try SourceNameFilter.matcher(for: "(?i)(")
  }
}

@Test func sourceExcludeRegexReturnsNilForNilOrBlank() throws {
  #expect(try SourceNameFilter.normalized(" \t\n") == nil)
  #expect(try SourceNameFilter.matcher(for: nil) == nil)
  #expect(try SourceNameFilter.matcher(for: " \t\n") == nil)
}

@Test func sourceExcludeRegexTrimsAndMatchesUnicode() throws {
  let value = "  café  "
  #expect(try SourceNameFilter.normalized(value) == "café")
  let matcher = try SourceNameFilter.matcher(for: value)
  #expect(SourceNameFilter.excludes("café", using: matcher))
  #expect(!SourceNameFilter.excludes("cafe", using: matcher))
}

@Test func sourceExcludeRegexUsesUTF8ByteLimit() throws {
  let asciiAtLimit = String(repeating: "a", count: 512)
  #expect(asciiAtLimit.utf8.count == 512)
  #expect(try SourceNameFilter.normalized(asciiAtLimit) == asciiAtLimit)

  let multibyteAtLimit = String(repeating: "é", count: 256)
  #expect(multibyteAtLimit.utf8.count == 512)
  #expect(try SourceNameFilter.normalized(multibyteAtLimit) == multibyteAtLimit)

  let multibyteOverLimit = String(repeating: "é", count: 257)
  #expect(multibyteOverLimit.utf8.count == 514)
  #expect(throws: SubscriptionFailure.invalidExcludeRegex) {
    try SourceNameFilter.normalized(multibyteOverLimit)
  }
  #expect(throws: SubscriptionFailure.invalidExcludeRegex) {
    try SourceNameFilter.matcher(for: multibyteOverLimit)
  }
}

@Test func sourceExcludeRegexRejectsEmbeddedControlCharacters() {
  let pattern = "before\u{0007}after"
  #expect(throws: SubscriptionFailure.invalidExcludeRegex) {
    try SourceNameFilter.normalized(pattern)
  }
  #expect(throws: SubscriptionFailure.invalidExcludeRegex) {
    try SourceNameFilter.matcher(for: pattern)
  }
}

@Test func proxyNodeSectionsPreserveSubscriptionOrderRegardlessOfLatency() {
  let nodes = [
    ProxyNode(
      id: .auto,
      name: "Auto",
      groupID: nil,
      groupName: nil,
      groupOrder: nil,
      nodeOrder: nil,
      delay: 30
    ),
    ProxyNode(
      id: ProxyNodeID(rawValue: "vless-1"),
      name: "Reality",
      groupID: "personal",
      groupName: "My VPS",
      groupOrder: 0,
      nodeOrder: 0,
      delay: 70
    ),
    ProxyNode(
      id: ProxyNodeID(rawValue: "hysteria2-1"),
      name: "Hysteria2",
      groupID: "personal",
      groupName: "My VPS",
      groupOrder: 0,
      nodeOrder: 1,
      delay: 40
    ),
    ProxyNode(
      id: ProxyNodeID(rawValue: "vless-2"),
      name: "Netherlands",
      groupID: "aid",
      groupName: "AID",
      groupOrder: 1,
      nodeOrder: 0,
      delay: nil
    ),
    ProxyNode(
      id: ProxyNodeID(rawValue: "hysteria2-2"),
      name: "Sweden",
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

@Test func rawJSONSubscriptionIsRejectedAsUnsupported() {
  #expect(throws: SubscriptionFailure.unsupportedJSONProfile) {
    try SubscriptionClient.parsePayload("{\"outbounds\":[]}")
  }
}

@Test func base64DecodedJSONSubscriptionIsRejectedAsUnsupported() {
  let json = "{\"outbounds\":[]}"
  let encoded = Data(json.utf8).base64EncodedString()
  #expect(throws: SubscriptionFailure.unsupportedJSONProfile) {
    try SubscriptionClient.parsePayload(encoded)
  }
}

@Test func subscriptionByteAndDisplayNameEnvelopeIsExplicit() throws {
  let hysteria = makeHysteria2Link(fragment: "Привет 🌍")
  guard case .compatibility(let unicodeProfile) = try SubscriptionClient.parsePayload(hysteria)
  else {
    Issue.record("Expected a Unicode display name")
    return
  }
  #expect(unicodeProfile.connections[0].displayName == "Привет 🌍")

  let emptyFragment = makeHysteria2Link(fragment: "")
  guard
    case .compatibility(let fallbackProfile) = try SubscriptionClient.parsePayload(emptyFragment)
  else {
    Issue.record("Expected the fallback display name")
    return
  }
  #expect(fallbackProfile.connections[0].displayName == "Hysteria2")

  let plus = try SubscriptionClient.parsePayload(
    "ss://aes-128-gcm:password@ss.example.test:443/#A+B"
  )
  let space = try SubscriptionClient.parsePayload(
    "ss://aes-128-gcm:password@ss.example.test:443/#A%20B"
  )
  guard case .compatibility(let plusProfile) = plus,
    case .compatibility(let spaceProfile) = space
  else {
    Issue.record("Expected managed Shadowsocks display names")
    return
  }
  #expect(plusProfile.connections[0].displayName == "A+B")
  #expect(spaceProfile.connections[0].displayName == "A B")

  let valid = makeHysteria2Link()
  let bomBody = try SubscriptionClient.decodeBody(
    Data([0xEF, 0xBB, 0xBF] + Array(valid.utf8))
  )
  #expect(!bomBody.hasPrefix("\u{FEFF}"))
  guard case .compatibility(let bomProfile) = try SubscriptionClient.parsePayload(bomBody)
  else {
    Issue.record("Expected a UTF-8 BOM to be removed by the production byte decode path")
    return
  }
  #expect(bomProfile.connections.count == 1)
}

@Test func subscriptionDataTaskBoundsRemoteBodyWithoutTestHooks() throws {
  let sourceFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../Sources/SBM/SubscriptionClient.swift")
    .standardizedFileURL
  let source = try String(contentsOf: sourceFile, encoding: .utf8)
  #expect(source.contains("URLSessionDataDelegate"))
  #expect(source.contains("session.dataTask(with: request)"))
  #expect(source.contains("didReceive response: URLResponse"))
  #expect(source.contains("didReceive data: Data"))
  #expect(
    source.contains(
      "data.count > SubscriptionClient.maximumProfileSize - responseData.count"))
  #expect(source.contains("cancelledForSizeLimit = true"))
  #expect(source.contains("taskToCancel?.cancel()"))
  #expect(source.contains("withTaskCancellationHandler"))
  #expect(source.contains("withCheckedThrowingContinuation"))
  #expect(source.contains("if Task.isCancelled { task.cancel() }"))
  #expect(source.contains("try Task.checkCancellation()"))
  #expect(source.contains("continuation.resume(throwing: SubscriptionFailure.tooLarge)"))
  #expect(source.contains("guard data.count <= maximumProfileSize"))
  #expect(!source.contains("URLSessionDownloadDelegate"))
  #expect(!source.contains("didWriteData"))
  #expect(!source.contains("download(for:"))
  #expect(!source.contains("AsyncBytes"))
  #expect(!source.contains("temporaryURL"))
  #expect(!source.contains("attributesOfItem(atPath:"))
  #expect(!source.contains("Data(contentsOf: temporaryURL"))
}

@Test func subscriptionWarningsAndShadowsocksErrorsExistInEveryLocale() throws {
  let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../Sources/SBM/Resources", isDirectory: true)
    .standardizedFileURL
  let staleMessage =
    "The Shadowsocks link must be a plugin-free SIP002 URI with an "
    + "approved modern cipher."
  let message = "The Shadowsocks link must be a valid plugin-free SIP002 URI."
  let warningKey = "Additional source warnings: %@"
  let sourceFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../Sources/SBM/SubscriptionClient.swift")
    .standardizedFileURL
  let source = try String(contentsOf: sourceFile, encoding: .utf8)
  #expect(source.contains(message))
  #expect(!source.contains(staleMessage))
  let expected: [(String, String, String)] = [
    (
      "en.lproj",
      "The Shadowsocks link must be a valid plugin-free SIP002 URI.",
      "Additional source warnings: %@"
    ),
    (
      "ru.lproj",
      "Ссылка Shadowsocks должна быть корректным URI SIP002 без плагинов.",
      "Дополнительных предупреждений источников: %@"
    ),
    (
      "zh-Hans.lproj",
      "Shadowsocks 链接必须是有效且不带插件的 SIP002 URI。",
      "其他源警告：%@"
    ),
  ]

  for (locale, translatedMessage, translatedWarning) in expected {
    let file = resources.appendingPathComponent(locale)
      .appendingPathComponent("Localizable.strings")
    let propertyList = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: file), options: [], format: nil
    )
    let strings = try #require(propertyList as? [String: String])
    #expect(strings[staleMessage] == nil)
    #expect(strings[message] == translatedMessage)
    #expect(strings[warningKey] == translatedWarning)
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
    #"{"quicParams":{"maxIncomingStreams":32},"quicParams":{"maxIncomingStreams":32}}"#,
    #"{"quicParams":{"maxIncomingStreams":1.5}}"#,
    #"{"udp":[{"type":"salamander","settings":{"password":"x"}},{"type":"other","settings":{}}]}"#,
    #"{"udp":[{"type":"salamander","settings":{"password":"one","password":"two"}}]}"#,
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

@Test func strictSIP002ShadowsocksAcceptsBracketedIPv6AndRejectsMalformedBrackets() throws {
  let parsed = try SubscriptionClient.parsePayload(
    "ss://aes-128-gcm:password@[2001:db8::1]:443/#IPv6"
  )
  guard case .compatibility(let profile) = parsed else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(profile.shadowsocks.first?.server == "2001:db8::1")

  for link in [
    "ss://aes-128-gcm:password@[2001:db8::zz]:443/#BadIPv6",
    "ss://aes-128-gcm:password@[2001:db8::1:443/#MissingClose",
    "ss://aes-128-gcm:password@2001:db8::1]:443/#MissingOpen",
    "ss://aes-128-gcm:password@[[2001:db8::1]]:443/#DoubleBrackets",
  ] {
    #expect(throws: SubscriptionFailure.invalidShadowsocks) {
      try SubscriptionClient.parsePayload(link)
    }
  }
}

@Test func subscriptionDisplayNamesDecodeFragmentsExactlyOnceForEveryManagedKind() throws {
  let query = [
    URLQueryItem(name: "flow", value: "xtls-rprx-vision"),
    URLQueryItem(name: "security", value: "reality"),
    URLQueryItem(name: "sni", value: "example.test"),
    URLQueryItem(name: "fp", value: "chrome"),
    URLQueryItem(name: "pbk", value: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU"),
    URLQueryItem(name: "sid", value: "bb6b725b"),
    URLQueryItem(name: "type", value: "tcp"),
  ]
  let vlessBase = try #require(
    makeVLESSLink(uuid: syntheticUUID(700), queryItems: query)
      .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
  )
  let doubleEncodedVLESS = try SubscriptionClient.parsePayload(
    String(vlessBase) + "#Double%2520Encoded"
  )
  guard case .compatibility(let doubleEncodedVLESSProfile) = doubleEncodedVLESS else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(doubleEncodedVLESSProfile.connections.first?.displayName == "Double%20Encoded")
  let normalVLESS = try SubscriptionClient.parsePayload(
    String(vlessBase) + "#Normal%20Name"
  )
  guard case .compatibility(let normalVLESSProfile) = normalVLESS else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(normalVLESSProfile.connections.first?.displayName == "Normal Name")

  let doubleEncodedShadowsocks = try SubscriptionClient.parsePayload(
    "ss://aes-128-gcm:password@ss.example.test:443/#Double%2520Encoded"
  )
  guard case .compatibility(let doubleEncodedSSProfile) = doubleEncodedShadowsocks else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(doubleEncodedSSProfile.connections.first?.displayName == "Double%20Encoded")
  let doubleEncodedHysteria2 = try SubscriptionClient.parsePayload(
    "hysteria2://password@hy.example.test:443/?sni=hy.example.test#Double%2520Encoded"
  )
  guard case .compatibility(let doubleEncodedHYProfile) = doubleEncodedHysteria2 else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(doubleEncodedHYProfile.connections.first?.displayName == "Double%20Encoded")
  #expect(throws: SubscriptionFailure.invalidDisplayName) {
    try SubscriptionClient.parsePayload(String(vlessBase) + "#Bad%0AName")
  }
}

@Test func hysteria2FMNumericZeroAndOneAreNotBridgedAsBooleans() throws {
  for value in ["0", "1"] {
    let fm = "{\"quicParams\":{\"maxIncomingStreams\":\(value)}}"
    let parsed = try SubscriptionClient.parsePayload(makeHysteria2Link(fm: fm))
    guard case .compatibility(let profile) = parsed else {
      Issue.record("Expected a compatibility profile")
      return
    }
    #expect(profile.connections.count == 1)
  }
  for value in ["true", "false"] {
    let fm = "{\"quicParams\":{\"maxIncomingStreams\":\(value)}}"
    #expect(throws: SubscriptionFailure.invalidHysteria2FM) {
      try SubscriptionClient.parsePayload(makeHysteria2Link(fm: fm))
    }
  }
}

@Test func subscriptionWarningRetainsGenericFailuresAlongsideReasonSpecificRows() throws {
  let query = [
    URLQueryItem(name: "flow", value: "xtls-rprx-vision"),
    URLQueryItem(name: "security", value: "reality"),
    URLQueryItem(name: "sni", value: "example.test"),
    URLQueryItem(name: "fp", value: "chrome"),
    URLQueryItem(name: "pbk", value: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU"),
    URLQueryItem(name: "sid", value: "bb6b725b"),
    URLQueryItem(name: "type", value: "tcp"),
  ]
  let valid = makeVLESSLink(uuid: syntheticUUID(701), queryItems: query, fragment: "Valid")
  let malformed = "vless://not-a-uuid@203.0.113.10:443?flow=xtls-rprx-vision#Malformed"
  let invalidNameBase = makeVLESSLink(
    uuid: syntheticUUID(702), queryItems: query, fragment: "valid"
  ).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
  let invalidName = String(invalidNameBase) + "#Bad%0AName"
  let result = try SubscriptionClient.parsePayloadResult(
    [valid, malformed, invalidName].joined(separator: "\n")
  )
  let warning = try #require(result.warningDescription)
  #expect(result.skippedInvalidConnections[.vless] == 2)
  #expect(result.skippedReasons[.malformedVLESS] == 1)
  #expect(warning.contains("1 VLESS connection skipped (malformed link)"))
  #expect(warning.contains("1 VLESS connection skipped (invalid or unsupported)"))
}

@Test func realitySpiderXAllowsOnlyRootAndDoesNotChangeRuntimeSemantics() throws {
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
  let withRootSpiderX = makeVLESSLink(
    queryItems: common + [URLQueryItem(name: "spx", value: "/")]
  )
  let withoutProfile = try SubscriptionClient.parsePayload(without)
  let withProfile = try SubscriptionClient.parsePayload(withRootSpiderX)
  #expect(withoutProfile == withProfile)

  let withoutBuilt = try ConfigBuilder(cachePath: "/tmp/sbm-spx-cache", apiSecret: "test-secret")
    .makeConfiguration(profile: withoutProfile, mode: .rule, selectedNode: .auto)
  let withBuilt = try ConfigBuilder(cachePath: "/tmp/sbm-spx-cache", apiSecret: "test-secret")
    .makeConfiguration(profile: withProfile, mode: .rule, selectedNode: .auto)
  #expect(withoutBuilt.data == withBuilt.data)

  for invalid in ["/fallback", "fallback", "", "\n/fallback"] {
    #expect(throws: SubscriptionFailure.invalidVLESS) {
      try SubscriptionClient.parsePayload(
        makeVLESSLink(queryItems: common + [URLQueryItem(name: "spx", value: invalid)])
      )
    }
  }
}

@Test func vlessTLSGRPCSupportsGunAndEmptyServiceName() throws {
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

  for query in [
    base.filter { $0.name != "serviceName" },
    replacingVLESSQueryValue("serviceName", with: "", in: base),
  ] {
    let parsed = try SubscriptionClient.parsePayload(makeVLESSLink(queryItems: query))
    guard case .compatibility(let profile) = parsed,
      case .vless(let value) = try #require(profile.connections.first?.outbound)
    else {
      Issue.record("Expected an empty-name TLS gRPC VLESS connection")
      return
    }
    #expect(value.variant == .tlsGRPC(serviceName: ""))
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
          ? [URLQueryItem(name: "spx", value: "/")]
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

@Test func managedVLESSParserSupportsAllEightVariantsAndExactFlow() throws {
  let cases = managedVLESSMatrixCases()
  for (index, item) in cases.enumerated() {
    let connection = try parseManagedVLESS(item.query, uuid: 4000 + index)
    guard case .vless(let value) = connection.outbound else {
      Issue.record("Expected a managed VLESS connection")
      return
    }
    #expect(value.variant == item.variant)
    if index > 0 {
      let emptyFlow = try parseManagedVLESS(
        item.query + [URLQueryItem(name: "flow", value: "")], uuid: 4000 + index
      )
      #expect(emptyFlow.semanticIdentity == connection.semanticIdentity)
      for flow in ["xtls-rprx-vision", "unsupported-flow"] {
        #expect(throws: SubscriptionFailure.self) {
          try parseManagedVLESS(
            item.query + [URLQueryItem(name: "flow", value: flow)], uuid: 4000 + index
          )
        }
      }
    }
  }

  let realityTCP = cases[0].query.filter { $0.name != "flow" }
  for flow: String? in [nil, "", "xtls-rprx-vision-udp443"] {
    var query = realityTCP
    if let flow { query.append(URLQueryItem(name: "flow", value: flow)) }
    #expect(throws: SubscriptionFailure.self) {
      try parseManagedVLESS(query, uuid: 4100)
    }
  }
}

@Test func managedVLESSRejectsExcludedSecurityAndTransportPairs() throws {
  let cases = managedVLESSMatrixCases()
  let invalidQueries = [
    replacingVLESSQueryValue("security", with: "none", in: cases[2].query),
    replacingVLESSQueryValue("type", with: "xhttp", in: cases[2].query),
    replacingVLESSQueryValue("type", with: "mkcp", in: cases[2].query),
    replacingVLESSQueryValue("security", with: "reality", in: cases[3].query),
    replacingVLESSQueryValue("security", with: "tls", in: cases[0].query),
    replacingVLESSQueryValue("type", with: "quic", in: cases[1].query),
  ]
  for query in invalidQueries {
    #expect(throws: SubscriptionFailure.self) {
      try parseManagedVLESS(query)
    }
  }
}

@Test func managedVLESSCompatibilityMarkersNormalizeOrFailClosed() throws {
  let cases = managedVLESSMatrixCases()
  for index in [0, 1] {
    let withoutSpx = try parseManagedVLESS(cases[index].query, uuid: 4200 + index)
    let rootSpx = try parseManagedVLESS(
      cases[index].query + [URLQueryItem(name: "spx", value: "/")], uuid: 4200 + index
    )
    #expect(rootSpx.semanticIdentity == withoutSpx.semanticIdentity)
    #expect(throws: SubscriptionFailure.self) {
      try parseManagedVLESS(
        cases[index].query + [URLQueryItem(name: "spx", value: "/not-root")],
        uuid: 4200 + index
      )
    }
  }
  for index in [1, 4] {
    let withoutMode = try parseManagedVLESS(cases[index].query, uuid: 4300 + index)
    let gunMode = try parseManagedVLESS(
      cases[index].query + [URLQueryItem(name: "mode", value: "gun")], uuid: 4300 + index
    )
    #expect(gunMode.semanticIdentity == withoutMode.semanticIdentity)
    for mode in ["", "multi"] {
      #expect(throws: SubscriptionFailure.self) {
        try parseManagedVLESS(
          cases[index].query + [URLQueryItem(name: "mode", value: mode)], uuid: 4300 + index
        )
      }
    }
  }
  for index in [0, 2] {
    let withoutHeaderType = try parseManagedVLESS(cases[index].query, uuid: 4400 + index)
    let none = try parseManagedVLESS(
      cases[index].query + [URLQueryItem(name: "headerType", value: "none")],
      uuid: 4400 + index
    )
    #expect(none.semanticIdentity == withoutHeaderType.semanticIdentity)
    for headerType in ["http", "None"] {
      #expect(throws: SubscriptionFailure.self) {
        try parseManagedVLESS(
          cases[index].query + [URLQueryItem(name: "headerType", value: headerType)],
          uuid: 4400 + index
        )
      }
    }
  }
  for index in [0, 2] {
    #expect(throws: SubscriptionFailure.self) {
      try parseManagedVLESS(
        cases[index].query + [URLQueryItem(name: "mode", value: "gun")], uuid: 4500 + index
      )
    }
  }
  for index in [1, 4] {
    #expect(throws: SubscriptionFailure.self) {
      try parseManagedVLESS(
        cases[index].query + [URLQueryItem(name: "headerType", value: "none")],
        uuid: 4600 + index
      )
    }
  }
  for index in [3, 5, 6, 7] {
    for marker in [
      URLQueryItem(name: "mode", value: "gun"),
      URLQueryItem(name: "headerType", value: "none"),
    ] {
      #expect(throws: SubscriptionFailure.self) {
        try parseManagedVLESS(cases[index].query + [marker], uuid: 4700 + index)
      }
    }
  }
}

@Test func managedVLESSTransportHostAndPathBoundsAreEnforced() throws {
  let cases = managedVLESSMatrixCases()
  let query = cases[3].query
  let invalidQueries = [
    replacingVLESSQueryValue("host", with: String(repeating: "h", count: 254), in: query),
    replacingVLESSQueryValue("host", with: "host.example.test:443", in: query),
    replacingVLESSQueryValue("host", with: "host,other.example.test", in: query),
    replacingVLESSQueryValue("host", with: "host;other.example.test", in: query),
    replacingVLESSQueryValue("host", with: "host name.example.test", in: query),
    replacingVLESSQueryValue("host", with: "bad\u{0001}host.example.test", in: query),
    replacingVLESSQueryValue("path", with: "relative", in: query),
    replacingVLESSQueryValue("path", with: "/" + String(repeating: "p", count: 1024), in: query),
    replacingVLESSQueryValue("path", with: "/bad\u{0001}path", in: query),
  ]
  for invalid in invalidQueries {
    #expect(throws: SubscriptionFailure.self) {
      try parseManagedVLESS(invalid)
    }
  }

  let atLimit = replacingVLESSQueryValue(
    "path", with: "/" + String(repeating: "p", count: 1023),
    in: replacingVLESSQueryValue("host", with: String(repeating: "h", count: 253), in: query)
  )
  let accepted = try parseManagedVLESS(atLimit)
  guard case .vless(let value) = accepted.outbound,
    case .tlsHTTP(let host, let path) = value.variant
  else {
    Issue.record("Expected bounded TLS/HTTP values")
    return
  }
  #expect(host?.utf8.count == 253)
  #expect(path?.utf8.count == 1024)

  for index in [3, 5, 7] {
    let omitted = cases[index].query.filter { $0.name != "host" && $0.name != "path" }
    let connection = try parseManagedVLESS(omitted, uuid: 5200 + index)
    guard case .vless(let profile) = connection.outbound else {
      Issue.record("Expected managed VLESS")
      return
    }
    switch profile.variant {
    case .tlsHTTP(let host, let path), .tlsWebSocket(let host, let path),
      .tlsHTTPUpgrade(let host, let path):
      #expect(host == nil)
      #expect(path == nil)
    default:
      Issue.record("Expected an optional host/path transport variant")
    }
  }
}

@Test func managedVLESSCodableAndIdentityPreserveOldVariantsAndIncludeNewSemantics() throws {
  let reality = ManagedOutbound.vless(
    VLESSProfile(
      server: "203.0.113.10",
      port: 443,
      uuid: syntheticUUID(0),
      serverName: "reality.example.test",
      fingerprint: "chrome",
      variant: .reality(
        publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU", shortID: "bb6b725b"
      )
    )
  )
  let grpc = ManagedOutbound.vless(
    VLESSProfile(
      server: "grpc.example.test",
      port: 443,
      uuid: syntheticUUID(1),
      serverName: "grpc.example.test",
      fingerprint: "firefox",
      variant: .tlsGRPC(serviceName: "edge-service")
    )
  )
  #expect(
    reality.stableNodeID.rawValue
      == "node-v1-5bddd794c0f0b473e660ac5bf1fe889d8bdb459838673c07d216e8e2dc98d42e")
  #expect(
    grpc.stableNodeID.rawValue
      == "node-v1-a6372565d6c8b700e0836be4b965db2ec2649ff65cf9b35ea76dd442eca89bc6")

  let variants = managedVLESSMatrixCases()
  let identities = variants.map { item in
    ManagedOutbound.vless(
      VLESSProfile(
        server: "same.example.test", port: 443, uuid: syntheticUUID(4900),
        serverName: "sni.example.test", fingerprint: "chrome", variant: item.variant
      )
    ).semanticIdentity
  }
  #expect(Set(identities).count == 8)

  for (index, item) in variants.enumerated() {
    let profile = VLESSProfile(
      server: "node-\(index).example.test",
      port: 443,
      uuid: syntheticUUID(5000 + index),
      serverName: "sni.example.test",
      fingerprint: "chrome",
      variant: item.variant
    )
    let data = try JSONEncoder().encode(profile)
    #expect(try JSONDecoder().decode(VLESSProfile.self, from: data) == profile)
  }

  let realityGRPC = ManagedOutbound.vless(
    VLESSProfile(
      server: "same.example.test", port: 443, uuid: syntheticUUID(4901),
      serverName: "sni.example.test", fingerprint: "chrome",
      variant: .realityGRPC(
        publicKey: managedVLESSPublicKey, shortID: "bb6b725b", serviceName: "one"
      )
    )
  )
  let realityGRPCServiceChanged = ManagedOutbound.vless(
    VLESSProfile(
      server: "same.example.test", port: 443, uuid: syntheticUUID(4901),
      serverName: "sni.example.test", fingerprint: "chrome",
      variant: .realityGRPC(
        publicKey: managedVLESSPublicKey, shortID: "bb6b725b", serviceName: "two"
      )
    )
  )
  #expect(realityGRPC.stableNodeID != realityGRPCServiceChanged.stableNodeID)

  let baseline = ManagedOutbound.vless(
    VLESSProfile(
      server: "transport.example.test", port: 443, uuid: syntheticUUID(6000),
      serverName: "sni.example.test", fingerprint: "chrome",
      variant: .tlsHTTP(host: "one.example.test", path: "/one")
    )
  )
  let hostChanged = ManagedOutbound.vless(
    VLESSProfile(
      server: "transport.example.test", port: 443, uuid: syntheticUUID(6000),
      serverName: "sni.example.test", fingerprint: "chrome",
      variant: .tlsHTTP(host: "two.example.test", path: "/one")
    )
  )
  let pathChanged = ManagedOutbound.vless(
    VLESSProfile(
      server: "transport.example.test", port: 443, uuid: syntheticUUID(6000),
      serverName: "sni.example.test", fingerprint: "chrome",
      variant: .tlsHTTP(host: "one.example.test", path: "/two")
    )
  )
  #expect(baseline.stableNodeID != hostChanged.stableNodeID)
  #expect(baseline.stableNodeID != pathChanged.stableNodeID)
  #expect(
    baseline.semanticIdentity
      == ManagedConnection(
        id: baseline.stableNodeID, displayName: "Renamed", outbound: baseline
      ).semanticIdentity)
}

private let managedVLESSPublicKey = "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU"

private func managedVLESSMatrixCases() -> [(query: [URLQueryItem], variant: VLESSProfileVariant)] {
  func common(_ security: String, _ type: String) -> [URLQueryItem] {
    [
      URLQueryItem(name: "security", value: security),
      URLQueryItem(name: "sni", value: "server.example.test"),
      URLQueryItem(name: "fp", value: "chrome"),
      URLQueryItem(name: "type", value: type),
    ]
  }
  let reality =
    common("reality", "tcp")
    + [
      URLQueryItem(name: "flow", value: "xtls-rprx-vision"),
      URLQueryItem(name: "pbk", value: managedVLESSPublicKey),
      URLQueryItem(name: "sid", value: "bb6b725b"),
    ]
  let realityGRPC =
    common("reality", "grpc")
    + [
      URLQueryItem(name: "pbk", value: managedVLESSPublicKey),
      URLQueryItem(name: "sid", value: "bb6b725b"),
      URLQueryItem(name: "serviceName", value: "reality-service"),
    ]
  return [
    (reality, .reality(publicKey: managedVLESSPublicKey, shortID: "bb6b725b")),
    (
      realityGRPC,
      .realityGRPC(
        publicKey: managedVLESSPublicKey, shortID: "bb6b725b", serviceName: "reality-service"
      )
    ),
    (common("tls", "tcp"), .tlsTCP),
    (
      common("tls", "http") + [
        URLQueryItem(name: "host", value: "http.example.test"),
        URLQueryItem(name: "path", value: "/api"),
      ],
      .tlsHTTP(host: "http.example.test", path: "/api")
    ),
    (
      common("tls", "grpc") + [URLQueryItem(name: "serviceName", value: "edge-service")],
      .tlsGRPC(serviceName: "edge-service")
    ),
    (
      common("tls", "ws") + [
        URLQueryItem(name: "host", value: "ws.example.test"),
        URLQueryItem(name: "path", value: "/socket"),
      ],
      .tlsWebSocket(host: "ws.example.test", path: "/socket")
    ),
    (common("tls", "quic"), .tlsQUIC),
    (
      common("tls", "httpupgrade") + [
        URLQueryItem(name: "host", value: "upgrade.example.test"),
        URLQueryItem(name: "path", value: "/upgrade"),
      ],
      .tlsHTTPUpgrade(host: "upgrade.example.test", path: "/upgrade")
    ),
  ]
}

private func parseManagedVLESS(
  _ query: [URLQueryItem],
  uuid: Int = 9999,
  host: String = "203.0.113.10"
) throws -> ManagedConnection {
  guard
    case .compatibility(let profile) = try SubscriptionClient.parsePayload(
      makeVLESSLink(uuid: syntheticUUID(uuid), host: host, queryItems: query)
    ), profile.connections.count == 1, let connection = profile.connections.first
  else {
    throw SubscriptionFailure.invalidVLESS
  }
  return connection
}

private func parseManagedHysteria2(_ link: String) throws -> Hysteria2Profile {
  guard case .compatibility(let profile) = try SubscriptionClient.parsePayload(link),
    let connection = profile.connections.first,
    case .hysteria2(let value) = connection.outbound
  else {
    throw SubscriptionFailure.invalidHysteria2
  }
  return value
}

private func replacingVLESSQueryValue(
  _ name: String,
  with value: String,
  in query: [URLQueryItem]
) -> [URLQueryItem] {
  query.filter { $0.name != name } + [URLQueryItem(name: name, value: value)]
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
  fragment: String = "Synthetic Hysteria2",
  serverName: String? = nil,
  includeSNI: Bool = true
) -> String {
  var components = URLComponents()
  components.scheme = "hysteria2"
  components.user = "hy-password"
  components.host = host
  components.port = 443
  var queryItems: [URLQueryItem] = []
  if includeSNI {
    queryItems.append(URLQueryItem(name: "sni", value: serverName ?? host))
  }
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
