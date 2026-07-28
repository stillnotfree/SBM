import Foundation
import SBMShared

private final class HTTPSOnlySessionDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
  }
}

enum SubscriptionClient {
  static let maximumProfileSize = 1_048_576
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(
      configuration: configuration,
      delegate: HTTPSOnlySessionDelegate(),
      delegateQueue: nil
    )
  }()

  static func fetch(from value: String) async throws -> CoreProfile {
    let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if isDirectSource(source) {
      guard source.utf8.count <= maximumProfileSize else {
        throw SubscriptionFailure.tooLarge
      }
      return try parsePayload(source)
    }
    guard value.utf8.count <= 4096,
      let url = URL(string: value),
      url.scheme?.lowercased() == "https",
      url.host != nil
    else { throw SubscriptionFailure.invalidURL }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(
      "sing-box/1.13 SBM/\(HelperConstants.helperVersion)",
      forHTTPHeaderField: "User-Agent"
    )
    let (temporaryURL, response) = try await session.download(for: request)
    guard let http = response as? HTTPURLResponse,
      http.statusCode == 200,
      http.url?.scheme?.lowercased() == "https"
    else {
      throw SubscriptionFailure.httpFailure
    }
    if http.expectedContentLength > Int64(maximumProfileSize) {
      throw SubscriptionFailure.tooLarge
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
    guard let size = attributes[.size] as? NSNumber,
      size.intValue <= maximumProfileSize
    else { throw SubscriptionFailure.tooLarge }
    let data = try Data(contentsOf: temporaryURL, options: [.mappedIfSafe])
    guard data.count <= maximumProfileSize else { throw SubscriptionFailure.tooLarge }

    let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return try parsePayload(body)
  }

  static func isRemoteSource(_ value: String) -> Bool {
    URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?
      .scheme?.lowercased() == "https"
  }

  private static func isDirectSource(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    return lowercased.hasPrefix("vless://")
      || lowercased.hasPrefix("hysteria2://")
      || lowercased.hasPrefix("hy2://")
  }

  static func parsePayload(_ body: String) throws -> CoreProfile {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.first == "{" {
      return .native(try NativeProfileParser.parse(Data(trimmed.utf8)))
    }

    let decoded = decodeSubscription(body)
    let decodedTrimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    if decodedTrimmed.first == "{" {
      return .native(try NativeProfileParser.parse(Data(decodedTrimmed.utf8)))
    }
    let links =
      decoded
      .split(whereSeparator: \Character.isNewline)
      .map(String.init)
      .filter { !$0.isEmpty }

    let vlessLink = links.first(where: { $0.lowercased().hasPrefix("vless://") })
    let hysteriaLink = links.first(where: {
      $0.lowercased().hasPrefix("hysteria2://") || $0.lowercased().hasPrefix("hy2://")
    })
    guard vlessLink != nil || hysteriaLink != nil else {
      throw SubscriptionFailure.missingProtocols
    }

    return .compatibility(
      VPNProfile(
        vless: try vlessLink.map(parseVLESS),
        hysteria2: try hysteriaLink.map(parseHysteria2)
      )
    )
  }

  private static func decodeSubscription(_ body: String) -> String {
    if body.contains("://") { return body }
    let compact = body.filter { !$0.isWhitespace }
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = String(repeating: "=", count: (4 - compact.count % 4) % 4)
    guard let data = Data(base64Encoded: compact + padding),
      let decoded = String(data: data, encoding: .utf8)
    else { return body }
    return decoded
  }

  private static func parseVLESS(_ link: String) throws -> VLESSProfile {
    guard let components = URLComponents(string: link),
      components.scheme?.lowercased() == "vless",
      let server = components.host,
      let uuid = components.user
    else { throw SubscriptionFailure.invalidVLESS }

    let query = queryMap(components.queryItems)
    guard query["security"]?.lowercased() == "reality",
      query["flow"]?.lowercased() == "xtls-rprx-vision",
      let serverName = query["sni"], !serverName.isEmpty,
      let publicKey = query["pbk"], !publicKey.isEmpty,
      let shortID = query["sid"], !shortID.isEmpty
    else { throw SubscriptionFailure.invalidVLESS }

    guard let port = UInt16(exactly: components.port ?? 443), port > 0 else {
      throw SubscriptionFailure.invalidVLESS
    }
    return VLESSProfile(
      server: server,
      port: port,
      uuid: uuid.removingPercentEncoding ?? uuid,
      serverName: serverName,
      fingerprint: query["fp"].flatMap { $0.isEmpty ? nil : $0 } ?? "chrome",
      publicKey: publicKey,
      shortID: shortID,
      displayName: try displayName(components.fragment, fallback: "Reality")
    )
  }

  private static func parseHysteria2(_ link: String) throws -> Hysteria2Profile {
    guard let components = URLComponents(string: link),
      ["hysteria2", "hy2"].contains(components.scheme?.lowercased() ?? ""),
      let server = components.host,
      let user = components.user
    else { throw SubscriptionFailure.invalidHysteria2 }

    let query = queryMap(components.queryItems)
    guard let serverName = query["sni"], !serverName.isEmpty else {
      throw SubscriptionFailure.invalidHysteria2
    }
    let obfsPassword: String?
    switch (query["obfs"]?.lowercased(), query["obfs-password"]) {
    case (nil, nil), ("", nil), (nil, ""):
      obfsPassword = nil
    case ("salamander", let password?) where !password.isEmpty:
      obfsPassword = password
    default:
      throw SubscriptionFailure.invalidHysteria2
    }

    let credential: String
    if let password = components.password {
      credential = "\(user):\(password)"
    } else {
      credential = user
    }
    guard let port = UInt16(exactly: components.port ?? 443), port > 0 else {
      throw SubscriptionFailure.invalidHysteria2
    }
    return Hysteria2Profile(
      server: server,
      port: port,
      password: credential.removingPercentEncoding ?? credential,
      serverName: serverName,
      obfsPassword: obfsPassword,
      displayName: try displayName(components.fragment, fallback: "Hysteria2")
    )
  }

  private static func displayName(_ fragment: String?, fallback: String) throws -> String {
    guard let fragment, !fragment.isEmpty else { return fallback }
    return try validateDisplayName(fragment.removingPercentEncoding ?? fragment)
  }

  static func validateDisplayName(_ value: String) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 96,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw SubscriptionFailure.invalidDisplayName }
    return value
  }

  private static func queryMap(_ items: [URLQueryItem]?) -> [String: String] {
    (items ?? []).reduce(into: [:]) { result, item in
      result[item.name.lowercased()] = item.value ?? ""
    }
  }
}

enum RoutingPolicyParser {
  static let maximumPolicySize = 262_144

  static func parse(_ data: Data) throws -> RoutingPolicy {
    guard !data.isEmpty, data.count <= maximumPolicySize,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(root.keys).isSubset(of: ["route"]),
      let route = root["route"] as? [String: Any],
      !route.isEmpty,
      Set(route.keys).isSubset(of: ["rules", "rule_set"])
    else {
      throw SubscriptionFailure.invalidRoutingPolicy
    }
    if let rules = route["rules"], !(rules is [[String: Any]]) {
      throw SubscriptionFailure.invalidRoutingPolicy
    }
    if let ruleSet = route["rule_set"], !(ruleSet is [[String: Any]]) {
      throw SubscriptionFailure.invalidRoutingPolicy
    }
    return RoutingPolicy(configuration: data)
  }
}

enum NativeProfileParser {
  static func parse(_ data: Data) throws -> NativeProfile {
    guard !data.isEmpty, data.count <= SubscriptionClient.maximumProfileSize else {
      throw SubscriptionFailure.tooLarge
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SubscriptionFailure.invalidNativeProfile
    }
    if let value = root["outbounds"], !(value is [[String: Any]]) {
      throw SubscriptionFailure.invalidNativeProfile
    }
    if let value = root["endpoints"], !(value is [[String: Any]]) {
      throw SubscriptionFailure.invalidNativeProfile
    }
    let outbounds = root["outbounds"] as? [[String: Any]] ?? []
    let endpoints = root["endpoints"] as? [[String: Any]] ?? []
    guard !outbounds.isEmpty || !endpoints.isEmpty else {
      throw SubscriptionFailure.invalidNativeProfile
    }

    var typeByTag: [String: String] = [:]
    for item in outbounds + endpoints {
      guard let tag = item["tag"] as? String, !tag.isEmpty, tag.utf8.count <= 128,
        !tag.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        let type = item["type"] as? String, !type.isEmpty
      else { throw SubscriptionFailure.invalidNativeProfile }
      guard typeByTag.updateValue(type, forKey: tag) == nil else {
        throw SubscriptionFailure.duplicateNativeTag(tag)
      }
    }

    let metadata = root["sbm"] as? [String: Any]
    let preferredSelector = metadata?["selector"] as? String
    let displayNames = metadata?["display_names"] as? [String: String] ?? [:]
    let selectors = outbounds.filter { ($0["type"] as? String) == "selector" }
    let selector =
      selectors.first(where: { ($0["tag"] as? String) == preferredSelector }) ?? selectors.first

    let selectorTag: String
    let tags: [String]
    if let selector,
      let tag = selector["tag"] as? String,
      !tag.isEmpty,
      let children = selector["outbounds"] as? [String],
      !children.isEmpty
    {
      selectorTag = tag
      tags = children
    } else {
      selectorTag = "sbm-selector"
      let outboundTags: [String] = outbounds.compactMap { outbound in
        guard let type = outbound["type"] as? String,
          !["direct", "block", "dns", "selector"].contains(type),
          let tag = outbound["tag"] as? String,
          !tag.isEmpty
        else { return nil }
        return tag
      }
      let endpointTags: [String] = endpoints.compactMap { endpoint in
        guard let tag = endpoint["tag"] as? String, !tag.isEmpty else { return nil }
        return tag
      }
      tags = outboundTags + endpointTags
    }
    guard !tags.isEmpty else { throw SubscriptionFailure.missingSelectableOutbounds }
    guard Set(tags).count == tags.count else {
      throw SubscriptionFailure.duplicateSelectableTag
    }
    var menuTags = tags
    if !tags.contains(where: { typeByTag[$0] == "urltest" }) {
      menuTags.insert("sbm-auto", at: 0)
    }
    guard menuTags.count <= 64 else { throw SubscriptionFailure.tooManySelectableOutbounds }
    let nodes = try menuTags.map { tag in
      ProxyNodeDescriptor(
        id: ProxyNodeID(rawValue: tag),
        name: try SubscriptionClient.validateDisplayName(
          displayNames[tag] ?? (tag == "sbm-auto" ? "Auto" : tag))
      )
    }
    return NativeProfile(
      configuration: data,
      selectorTag: selectorTag,
      nodes: nodes
    )
  }
}

enum SubscriptionFailure: LocalizedError {
  case invalidURL
  case httpFailure
  case tooLarge
  case missingProtocols
  case invalidVLESS
  case invalidHysteria2
  case invalidRoutingPolicy
  case invalidNativeProfile
  case missingSelectableOutbounds
  case tooManySelectableOutbounds
  case duplicateNativeTag(String)
  case duplicateSelectableTag
  case invalidDisplayName

  var errorDescription: String? {
    switch self {
    case .invalidURL: "Enter a valid HTTPS subscription URL."
    case .httpFailure: "The subscription server returned an error."
    case .tooLarge: "The subscription response is unexpectedly large."
    case .missingProtocols:
      "Enter an HTTPS subscription, VLESS + REALITY link, or Hysteria2 link."
    case .invalidVLESS: "The VLESS + REALITY link is invalid or unsupported."
    case .invalidHysteria2: "The Hysteria2 link is invalid or uses unsupported obfuscation."
    case .invalidRoutingPolicy:
      "The routing JSON may contain only route.rules and remote route.rule_set entries."
    case .invalidNativeProfile:
      "The JSON profile must contain at least one outbound or endpoint."
    case .missingSelectableOutbounds:
      "The JSON profile does not contain a selector or any selectable proxy outbounds."
    case .tooManySelectableOutbounds:
      "The JSON profile exposes more than 64 selectable outbounds."
    case .duplicateNativeTag(let tag):
      "The JSON profile contains a duplicate outbound or endpoint tag: \(tag)."
    case .duplicateSelectableTag:
      "The JSON profile selector contains the same outbound more than once."
    case .invalidDisplayName:
      "A server display name is empty, too long, or contains control characters."
    }
  }
}
