import Foundation
import SBMShared

private final class SubscriptionSessionDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let sourceURL: URL
  private let lock = NSLock()
  private var redirectCount = 0
  private var strippedSensitiveHeaders = false

  init(sourceURL: URL) {
    self.sourceURL = sourceURL
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    lock.lock()
    redirectCount += 1
    let exceedsLimit = redirectCount > SubscriptionClient.maximumRedirects
    let crossesOrigin =
      request.url.map {
        SubscriptionOrigin(url: $0) != SubscriptionOrigin(url: sourceURL)
      } ?? true
    strippedSensitiveHeaders = strippedSensitiveHeaders || crossesOrigin
    let mustStrip = strippedSensitiveHeaders
    lock.unlock()
    guard !exceedsLimit else {
      completionHandler(nil)
      return
    }
    completionHandler(
      SubscriptionClient.sanitizedRedirectRequest(
        request,
        from: sourceURL,
        sensitiveHeadersWereStripped: mustStrip
      )
    )
  }
}

private struct SubscriptionOrigin: Equatable, Sendable {
  let scheme: String
  let host: String
  let port: Int

  init(url: URL) {
    scheme = url.scheme?.lowercased() ?? ""
    host = url.host?.lowercased() ?? ""
    port = url.port ?? (scheme == "https" ? 443 : -1)
  }
}

enum SubscriptionConnectionKind: String, Hashable, Sendable {
  case vless = "VLESS"
  case hysteria2 = "Hysteria2"
  case shadowsocks = "Shadowsocks"
}

enum SubscriptionSkipReason: String, Hashable, Sendable {
  case unsupportedVLESSGRPCMode
  case unsupportedVLESSParameter
  case malformedVLESS
  case malformedHysteria2FM
  case malformedHysteria2

  var connectionKind: SubscriptionConnectionKind {
    switch self {
    case .unsupportedVLESSGRPCMode, .unsupportedVLESSParameter, .malformedVLESS:
      .vless
    case .malformedHysteria2FM, .malformedHysteria2:
      .hysteria2
    }
  }
}

struct SubscriptionFetchResult: Sendable {
  let profile: CoreProfile
  let skippedTransports: [String: Int]
  let skippedInvalidConnections: [SubscriptionConnectionKind: Int]
  let skippedReasons: [SubscriptionSkipReason: Int]

  init(
    profile: CoreProfile,
    skippedTransports: [String: Int],
    skippedInvalidConnections: [SubscriptionConnectionKind: Int] = [:],
    skippedReasons: [SubscriptionSkipReason: Int] = [:]
  ) {
    self.profile = profile
    self.skippedTransports = skippedTransports
    self.skippedInvalidConnections = skippedInvalidConnections
    self.skippedReasons = skippedReasons
  }

  var warningDescription: String? {
    guard
      !skippedTransports.isEmpty || !skippedInvalidConnections.isEmpty
        || !skippedReasons.isEmpty
    else { return nil }
    let importedCount: Int
    switch profile {
    case .compatibility(let profile):
      importedCount = profile.connections.count
    case .native:
      importedCount = 1
    }
    var details = skippedTransports.keys.sorted().map { transport in
      let count = skippedTransports[transport, default: 0]
      if transport == "xhttp" {
        return SBMText.format(
          count == 1
            ? "%@ XHTTP connection skipped (unsupported by pinned sing-box core)"
            : "%@ XHTTP connections skipped (unsupported by pinned sing-box core)",
          String(count)
        )
      }
      return SBMText.format(
        count == 1
          ? "%@ %@ connection skipped (unsupported transport)"
          : "%@ %@ connections skipped (unsupported transport)",
        String(count), transport.uppercased()
      )
    }
    details += skippedReasons.keys.sorted { $0.rawValue < $1.rawValue }.map { reason in
      let count = skippedReasons[reason, default: 0]
      switch reason {
      case .unsupportedVLESSGRPCMode:
        return SBMText.format(
          count == 1
            ? "%@ VLESS gRPC connection skipped (unsupported mode)"
            : "%@ VLESS gRPC connections skipped (unsupported mode)",
          String(count)
        )
      case .unsupportedVLESSParameter:
        return SBMText.format(
          count == 1
            ? "%@ VLESS connection skipped (unsupported parameter)"
            : "%@ VLESS connections skipped (unsupported parameter)",
          String(count)
        )
      case .malformedVLESS:
        return SBMText.format(
          count == 1
            ? "%@ VLESS connection skipped (malformed link)"
            : "%@ VLESS connections skipped (malformed link)",
          String(count)
        )
      case .malformedHysteria2FM:
        return SBMText.format(
          count == 1
            ? "%@ Hysteria2 connection skipped (unsupported or malformed fm)"
            : "%@ Hysteria2 connections skipped (unsupported or malformed fm)",
          String(count)
        )
      case .malformedHysteria2:
        return SBMText.format(
          count == 1
            ? "%@ Hysteria2 connection skipped (malformed link)"
            : "%@ Hysteria2 connections skipped (malformed link)",
          String(count)
        )
      }
    }
    let reasonedKinds = Set(skippedReasons.keys.map(\.connectionKind))
    details += skippedInvalidConnections.keys.sorted { $0.rawValue < $1.rawValue }
      .filter { !reasonedKinds.contains($0) }
      .map { kind in
        let count = skippedInvalidConnections[kind, default: 0]
        return SBMText.format(
          count == 1
            ? "%@ %@ connection skipped (invalid or unsupported)"
            : "%@ %@ connections skipped (invalid or unsupported)",
          String(count), kind.rawValue
        )
      }
    return
      SBMText.format(
        importedCount == 1 ? "%@ connection imported; %@" : "%@ connections imported; %@",
        String(importedCount), details.joined(separator: "; ")
      )
  }
}

enum SubscriptionClient {
  static let maximumProfileSize = 1_048_576
  static let maximumConnections = 63
  static let maximumRedirects = 5

  static func fetch(
    from value: String,
    headers: SubscriptionHeaders = SubscriptionHeaders()
  ) async throws -> SubscriptionFetchResult {
    try validate(headers: headers)
    let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if isDirectSource(source) {
      guard source.utf8.count <= maximumProfileSize else {
        throw SubscriptionFailure.tooLarge
      }
      return try parsePayloadResult(source)
    }
    guard source.utf8.count <= 4096,
      let url = URL(string: source),
      url.scheme?.lowercased() == "https",
      url.host != nil
    else { throw SubscriptionFailure.invalidURL }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(
      configuration: configuration,
      delegate: SubscriptionSessionDelegate(sourceURL: url),
      delegateQueue: nil
    )
    defer { session.finishTasksAndInvalidate() }

    let request = try makeRequest(for: url, headers: headers)
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

    let body = try decodeBody(data)
    return try parsePayloadResult(body)
  }

  static func decodeBody(_ data: Data) throws -> String {
    guard let body = String(data: data, encoding: .utf8) else {
      throw SubscriptionFailure.invalidEncoding
    }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func validate(headers: SubscriptionHeaders) throws {
    try validateHeader(headers.userAgent, name: "User-Agent", maximum: 512)
    if let appVersion = headers.appVersion {
      try validateHeader(appVersion, name: "X-App-Version", maximum: 64)
    }
    try validateHeader(headers.deviceOS, name: "X-Device-OS", maximum: 64)
    try validateHeader(headers.hardwareID, name: "X-HWID", maximum: 128)
  }

  private static func validateHeader(_ value: String, name: String, maximum: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximum,
      !value.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw SubscriptionFailure.invalidHeader(name)
    }
  }

  static func makeRequest(
    for url: URL,
    headers: SubscriptionHeaders
  ) throws -> URLRequest {
    try validate(headers: headers)
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(headers.userAgent, forHTTPHeaderField: "User-Agent")
    if let appVersion = headers.appVersion {
      request.setValue(appVersion, forHTTPHeaderField: "X-App-Version")
    }
    request.setValue(headers.deviceOS, forHTTPHeaderField: "X-Device-OS")
    request.setValue(headers.hardwareID, forHTTPHeaderField: "X-HWID")
    return request
  }

  static func sanitizedRedirectRequest(
    _ request: URLRequest,
    from sourceURL: URL,
    sensitiveHeadersWereStripped: Bool = false
  ) -> URLRequest? {
    guard let destination = request.url,
      destination.scheme?.lowercased() == "https"
    else { return nil }
    guard
      sensitiveHeadersWereStripped
        || SubscriptionOrigin(url: destination) != SubscriptionOrigin(url: sourceURL)
    else {
      return request
    }
    var sanitized = request
    sanitized.setValue(nil, forHTTPHeaderField: "X-HWID")
    sanitized.setValue(nil, forHTTPHeaderField: "X-App-Version")
    sanitized.setValue(nil, forHTTPHeaderField: "X-Device-OS")
    sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
    sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
    sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
    sanitized.setValue(
      applicationUserAgent,
      forHTTPHeaderField: "User-Agent"
    )
    return sanitized
  }

  private static var applicationUserAgent: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
    return "SBM/\(version)"
  }

  static func isRemoteSource(_ value: String) -> Bool {
    URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?
      .scheme?.lowercased() == "https"
  }

  static func validateSourceValue(_ value: String) throws -> String {
    let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty, source.utf8.count <= 4096,
      !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw SubscriptionFailure.invalidURL }
    if isDirectSource(source) { return source }
    guard let url = URL(string: source),
      url.scheme?.lowercased() == "https",
      url.host != nil
    else { throw SubscriptionFailure.invalidURL }
    return source
  }

  private static func isDirectSource(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    return lowercased.hasPrefix("vless://")
      || lowercased.hasPrefix("hysteria2://")
      || lowercased.hasPrefix("hy2://")
      || lowercased.hasPrefix("ss://")
  }

  static func parsePayload(_ body: String) throws -> CoreProfile {
    try parsePayloadResult(body).profile
  }

  static func parsePayloadResult(_ body: String) throws -> SubscriptionFetchResult {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.first == "{" {
      return SubscriptionFetchResult(
        profile: .native(try NativeProfileParser.parse(Data(trimmed.utf8))),
        skippedTransports: [:]
      )
    }

    let decoded = decodeSubscription(body)
    let decodedTrimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    if decodedTrimmed.first == "{" {
      return SubscriptionFetchResult(
        profile: .native(try NativeProfileParser.parse(Data(decodedTrimmed.utf8))),
        skippedTransports: [:]
      )
    }
    let links =
      decoded
      .split(whereSeparator: \Character.isNewline)
      .map(String.init)
      .filter { !$0.isEmpty }

    let recognizedConnectionCount = links.reduce(into: 0) { count, link in
      let lowercased = link.lowercased()
      if lowercased.hasPrefix("vless://")
        || lowercased.hasPrefix("hysteria2://")
        || lowercased.hasPrefix("hy2://")
        || lowercased.hasPrefix("ss://")
      {
        count += 1
      }
    }
    guard recognizedConnectionCount > 0 else {
      throw SubscriptionFailure.missingProtocols
    }
    guard recognizedConnectionCount <= maximumConnections
    else {
      throw SubscriptionFailure.tooManyConnections
    }

    var connections: [ManagedConnection] = []
    var skippedTransports: [String: Int] = [:]
    var skippedInvalidConnections: [SubscriptionConnectionKind: Int] = [:]
    var skippedReasons: [SubscriptionSkipReason: Int] = [:]
    var firstFailure: SubscriptionFailure?

    for link in links {
      let lowercased = link.lowercased()
      if lowercased.hasPrefix("vless://") {
        do {
          let transport = try vlessTransport(link)
          guard transport == "tcp" || transport == "grpc" else {
            skippedTransports[transport, default: 0] += 1
            firstFailure = firstFailure ?? .unsupportedVLESSTransport(transport)
            continue
          }
          connections.append(try parseVLESS(link))
        } catch let error as SubscriptionFailure {
          skippedInvalidConnections[.vless, default: 0] += 1
          if let reason = error.skipReason {
            skippedReasons[reason, default: 0] += 1
          }
          firstFailure = firstFailure ?? error
        }
      } else if lowercased.hasPrefix("hysteria2://") || lowercased.hasPrefix("hy2://") {
        do {
          connections.append(try parseHysteria2(link))
        } catch let error as SubscriptionFailure {
          skippedInvalidConnections[.hysteria2, default: 0] += 1
          if let reason = error.skipReason {
            skippedReasons[reason, default: 0] += 1
          }
          firstFailure = firstFailure ?? error
        }
      } else if lowercased.hasPrefix("ss://") {
        do {
          connections.append(try parseShadowsocks(link))
        } catch let error as SubscriptionFailure {
          skippedInvalidConnections[.shadowsocks, default: 0] += 1
          firstFailure = firstFailure ?? error
        }
      }
    }
    guard !connections.isEmpty else {
      throw firstFailure ?? SubscriptionFailure.missingProtocols
    }

    return SubscriptionFetchResult(
      profile: .compatibility(
        VPNProfile(
          connections: connections
        )
      ),
      skippedTransports: skippedTransports,
      skippedInvalidConnections: skippedInvalidConnections,
      skippedReasons: skippedReasons
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

  private static func parseVLESS(_ link: String) throws -> ManagedConnection {
    guard let components = URLComponents(string: link),
      components.scheme?.lowercased() == "vless",
      let server = components.host,
      let encodedUUID = components.user,
      components.password == nil,
      components.path.isEmpty || components.path == "/"
    else { throw SubscriptionFailure.invalidVLESS }

    let query = try strictVLESSQuery(components.queryItems)
    let allowedParameters: Set<String> = [
      "encryption", "flow", "security", "type", "sni", "fp", "pbk", "sid", "headerType",
      "spx", "serviceName", "mode",
    ]
    guard Set(query.keys).isSubset(of: allowedParameters) else {
      throw SubscriptionFailure.unsupportedVLESSParameter
    }
    let encryption = query["encryption"] ?? "none"
    guard !encryption.isEmpty else { throw SubscriptionFailure.invalidVLESS }
    guard encryption == "none" else {
      throw SubscriptionFailure.unsupportedVLESSEncryption
    }
    let uuid = encodedUUID.removingPercentEncoding ?? encodedUUID
    guard UUID(uuidString: uuid) != nil else { throw SubscriptionFailure.invalidVLESS }

    guard let port = UInt16(exactly: components.port ?? 443), port > 0 else {
      throw SubscriptionFailure.invalidVLESS
    }

    let transport = try vlessTransport(link)
    guard let serverName = query["sni"], validServerName(serverName) else {
      throw SubscriptionFailure.invalidVLESS
    }
    switch transport {
    case "tcp":
      guard query["security"] == "reality",
        query["flow"] == "xtls-rprx-vision",
        query["type"] == nil || query["type"] == "tcp",
        query["headerType"] == nil || query["headerType"] == "none",
        query["serviceName"] == nil,
        query["mode"] == nil,
        let publicKey = query["pbk"], validRealityPublicKey(publicKey)
      else { throw SubscriptionFailure.invalidVLESS }
      let shortID = query["sid"] ?? ""
      guard validRealityShortID(shortID) else { throw SubscriptionFailure.invalidVLESS }
      if let spx = query["spx"], !validRealitySpiderX(spx) {
        throw SubscriptionFailure.invalidVLESS
      }
      let fingerprint = query["fp"].flatMap { $0.isEmpty ? nil : $0 } ?? "chrome"
      guard VLESSProfile.supportedFingerprints.contains(fingerprint) else {
        throw SubscriptionFailure.invalidVLESS
      }
      return ManagedConnection(
        displayName: try displayName(components.fragment, fallback: "Reality"),
        outbound: .vless(
          VLESSProfile(
            server: server,
            port: port,
            uuid: uuid.lowercased(),
            serverName: serverName,
            fingerprint: fingerprint,
            publicKey: publicKey,
            shortID: shortID
          )
        )
      )
    case "grpc":
      if let mode = query["mode"], mode != "gun" {
        throw SubscriptionFailure.unsupportedVLESSGRPCMode
      }
      guard query["security"] == "tls",
        query["flow"] == nil || query["flow"]?.isEmpty == true,
        query["pbk"] == nil,
        query["sid"] == nil,
        query["spx"] == nil,
        query["headerType"] == nil,
        let serviceName = query["serviceName"], validGRPCServiceName(serviceName)
      else {
        throw SubscriptionFailure.unsupportedVLESSParameter
      }
      let fingerprint: String
      if let requested = query["fp"] {
        guard VLESSProfile.supportedFingerprints.contains(requested) else {
          throw SubscriptionFailure.invalidVLESS
        }
        fingerprint = requested
      } else {
        fingerprint = "chrome"
      }
      return ManagedConnection(
        displayName: try displayName(components.fragment, fallback: "VLESS gRPC"),
        outbound: .vless(
          VLESSProfile(
            server: server,
            port: port,
            uuid: uuid.lowercased(),
            serverName: serverName,
            fingerprint: fingerprint,
            variant: .tlsGRPC(serviceName: serviceName)
          )
        )
      )
    default:
      throw SubscriptionFailure.unsupportedVLESSTransport(transport)
    }
  }

  private static func vlessTransport(_ link: String) throws -> String {
    guard let components = URLComponents(string: link),
      components.scheme?.lowercased() == "vless"
    else { throw SubscriptionFailure.invalidVLESS }
    let query = try strictVLESSQuery(components.queryItems)
    let transport =
      query["type"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? "tcp"
    guard !transport.isEmpty,
      transport.utf8.count <= 32,
      transport.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
      })
    else { throw SubscriptionFailure.invalidVLESS }
    return transport
  }

  private static func strictVLESSQuery(_ items: [URLQueryItem]?) throws -> [String: String] {
    var result: [String: String] = [:]
    var caseInsensitiveNames: [String: String] = [:]
    for item in items ?? [] {
      guard item.name.utf8.count <= 64, !item.name.isEmpty else {
        throw SubscriptionFailure.invalidVLESS
      }
      guard result[item.name] == nil else {
        throw SubscriptionFailure.ambiguousVLESSParameters
      }
      let folded = item.name.lowercased()
      if let previous = caseInsensitiveNames[folded], previous != item.name {
        throw SubscriptionFailure.ambiguousVLESSParameters
      }
      caseInsensitiveNames[folded] = item.name
      result[item.name] = item.value ?? ""
    }
    return result
  }

  private static func validServerName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 253
      && !value.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
      })
      && !value.contains(where: { "/\\?#@".contains($0) })
  }

  private static func validRealityPublicKey(_ value: String) -> Bool {
    guard value.utf8.count == 43,
      value.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
      })
    else { return false }
    let base64 =
      value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/") + "="
    return Data(base64Encoded: base64)?.count == 32
  }

  private static func validRealityShortID(_ value: String) -> Bool {
    value.utf8.count <= 16 && value.utf8.count.isMultiple(of: 2)
      && value.unicodeScalars.allSatisfy({
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      })
  }

  private static func validRealitySpiderX(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1024 && value.hasPrefix("/")
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  private static func validGRPCServiceName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  private enum Hysteria2FM {
    case salamander(password: String)
    // Recognized provider-specific Xray tuning. The pinned sing-box schema has
    // no faithful field for it, so it is validated and intentionally discarded.
    case quicParams(maxIncomingStreams: Int)
  }

  private static func parseHysteria2(_ link: String) throws -> ManagedConnection {
    guard let components = URLComponents(string: link),
      ["hysteria2", "hy2"].contains(components.scheme?.lowercased() ?? ""),
      let server = components.host,
      let user = components.user
    else { throw SubscriptionFailure.invalidHysteria2 }

    let query = try strictHysteria2Query(components.queryItems)
    guard let serverName = query["sni"], validServerName(serverName) else {
      throw SubscriptionFailure.invalidHysteria2
    }
    let fm = try parseHysteria2FM(query["fm"])
    let standardObfsPassword: String?
    switch (query["obfs"]?.lowercased(), query["obfs-password"]) {
    case (nil, nil):
      standardObfsPassword = nil
    case ("salamander", let password?)
    where validHysteria2Secret(password):
      standardObfsPassword = password
    default:
      throw SubscriptionFailure.invalidHysteria2
    }
    let obfsPassword: String?
    switch fm {
    case .some(.salamander(let fmPassword)):
      if let standardObfsPassword {
        guard standardObfsPassword == fmPassword else {
          throw SubscriptionFailure.ambiguousHysteria2FM
        }
        obfsPassword = standardObfsPassword
      } else {
        guard query["obfs"] == nil, query["obfs-password"] == nil else {
          throw SubscriptionFailure.invalidHysteria2
        }
        obfsPassword = fmPassword
      }
    case .some(.quicParams):
      obfsPassword = standardObfsPassword
    case nil:
      obfsPassword = standardObfsPassword
    }

    let credential: String
    if let password = components.password {
      credential = "\(user):\(password)"
    } else {
      credential = user
    }
    let decodedCredential = credential.removingPercentEncoding ?? credential
    guard !decodedCredential.isEmpty, decodedCredential.utf8.count <= 1024,
      !decodedCredential.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else { throw SubscriptionFailure.invalidHysteria2 }
    guard let port = UInt16(exactly: components.port ?? 443), port > 0 else {
      throw SubscriptionFailure.invalidHysteria2
    }
    return ManagedConnection(
      displayName: try displayName(components.fragment, fallback: "Hysteria2"),
      outbound: .hysteria2(
        Hysteria2Profile(
          server: server,
          port: port,
          password: decodedCredential,
          serverName: serverName,
          obfsPassword: obfsPassword
        )
      )
    )
  }

  private static func strictHysteria2Query(_ items: [URLQueryItem]?) throws -> [String: String] {
    let allowed: Set<String> = ["sni", "obfs", "obfs-password", "fm"]
    var result: [String: String] = [:]
    var foldedNames: Set<String> = []
    for item in items ?? [] {
      let folded = item.name.lowercased()
      guard item.name == folded, allowed.contains(item.name),
        result[item.name] == nil, foldedNames.insert(folded).inserted
      else { throw SubscriptionFailure.invalidHysteria2 }
      result[item.name] = item.value ?? ""
    }
    return result
  }

  private static func validHysteria2Secret(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1024
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  private static func parseHysteria2FM(_ value: String?) throws -> Hysteria2FM? {
    guard let value else { return nil }
    guard value.utf8.count <= 4096,
      let data = value.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let root = object as? [String: Any]
    else { throw SubscriptionFailure.invalidHysteria2FM }

    if Set(root.keys) == ["quicParams"],
      let quicParams = root["quicParams"] as? [String: Any],
      Set(quicParams.keys) == ["maxIncomingStreams"],
      let number = quicParams["maxIncomingStreams"] as? NSNumber,
      !(quicParams["maxIncomingStreams"] is Bool),
      number.doubleValue.isFinite,
      number.doubleValue.rounded() == number.doubleValue,
      (0...1_000_000).contains(number.intValue)
    {
      return .quicParams(maxIncomingStreams: number.intValue)
    }

    guard Set(root.keys) == ["udp"],
      let entries = root["udp"] as? [Any], entries.count == 1,
      let entry = entries.first as? [String: Any], Set(entry.keys) == ["type", "settings"],
      entry["type"] as? String == "salamander",
      let settings = entry["settings"] as? [String: Any], Set(settings.keys) == ["password"],
      let password = settings["password"] as? String,
      validHysteria2Secret(password)
    else { throw SubscriptionFailure.invalidHysteria2FM }
    return .salamander(password: password)
  }

  private static let shadowsocksMethods: Set<String> = [
    "aes-128-gcm",
    "aes-256-gcm",
    "chacha20-ietf-poly1305",
    "2022-blake3-aes-128-gcm",
    "2022-blake3-aes-256-gcm",
    "2022-blake3-chacha20-poly1305",
  ]

  /// Strict SIP002 without plugin support. In particular, this deliberately
  /// rejects the pre-SIP002 whole-URI Base64 form and every query parameter.
  private static func parseShadowsocks(_ link: String) throws -> ManagedConnection {
    guard link.utf8.count <= 4096,
      let components = URLComponents(string: link),
      components.scheme?.lowercased() == "ss",
      components.query == nil,
      components.path.isEmpty || components.path == "/",
      let host = components.host,
      let port = UInt16(exactly: components.port ?? 0), port > 0
    else { throw SubscriptionFailure.invalidShadowsocks }
    try validateShadowsocksHost(host)

    let withoutFragment = link.split(
      separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    guard let schemeRange = withoutFragment.range(of: "://") else {
      throw SubscriptionFailure.invalidShadowsocks
    }
    let afterScheme = withoutFragment[schemeRange.upperBound...]
    let authorityEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
    let authority = afterScheme[..<authorityEnd]
    guard authority.filter({ $0 == "@" }).count == 1,
      let at = authority.firstIndex(of: "@")
    else { throw SubscriptionFailure.invalidShadowsocks }
    let rawUserInfo = String(authority[..<at])
    guard !rawUserInfo.isEmpty,
      rawUserInfo.utf8.count <= 1024,
      let percentDecoded = rawUserInfo.removingPercentEncoding
    else { throw SubscriptionFailure.invalidShadowsocks }

    let credential: String
    let encoded: Bool
    if percentDecoded.contains(":") {
      credential = percentDecoded
      encoded = false
    } else {
      guard let decoded = decodeBase64URL(percentDecoded) else {
        throw SubscriptionFailure.invalidShadowsocks
      }
      credential = decoded
      encoded = true
    }
    guard let separator = credential.firstIndex(of: ":") else {
      throw SubscriptionFailure.invalidShadowsocks
    }
    let method = String(credential[..<separator]).lowercased()
    let password = String(credential[credential.index(after: separator)...])
    guard shadowsocksMethods.contains(method), !password.isEmpty,
      credential.utf8.count <= 1024,
      !credential.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !(encoded && method.hasPrefix("2022-")),
      validShadowsocks2022PSK(method: method, password: password)
    else { throw SubscriptionFailure.invalidShadowsocks }
    return ManagedConnection(
      displayName: try displayName(components.fragment, fallback: "Shadowsocks"),
      outbound: .shadowsocks(
        ShadowsocksProfile(
          server: host,
          port: port,
          method: method,
          password: password
        )
      )
    )
  }

  private static func decodeBase64URL(_ value: String) -> String? {
    guard !value.isEmpty,
      value.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_=")).contains($0)
      })
    else { return nil }
    let base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64 + padding),
      let decoded = String(data: data, encoding: .utf8)
    else { return nil }
    return decoded
  }

  private static func validateShadowsocksHost(_ value: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:"))
    guard !value.isEmpty, value.utf8.count <= 253,
      value.unicodeScalars.allSatisfy(allowed.contains),
      !value.hasPrefix("."), !value.hasSuffix(".")
    else { throw SubscriptionFailure.invalidShadowsocks }
  }

  private static func validShadowsocks2022PSK(method: String, password: String) -> Bool {
    let expectedBytes: Int
    switch method {
    case "2022-blake3-aes-128-gcm": expectedBytes = 16
    case "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305": expectedBytes = 32
    default: return true
    }
    guard let data = Data(base64Encoded: password), data.count == expectedBytes else {
      return false
    }
    return data.base64EncodedString() == password
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
          displayNames[tag] ?? (tag == "sbm-auto" ? SBMText.localized("Auto") : tag)),
        kind: tag == "sbm-auto" || typeByTag[tag] == "urltest" ? .automatic : .native
      )
    }
    return NativeProfile(
      configuration: data,
      selectorTag: selectorTag,
      nodes: nodes
    )
  }
}

enum SubscriptionFailure: Equatable, LocalizedError {
  case invalidURL
  case httpFailure
  case invalidEncoding
  case tooLarge
  case missingProtocols
  case invalidVLESS
  case ambiguousVLESSParameters
  case unsupportedVLESSParameter
  case unsupportedVLESSEncryption
  case unsupportedVLESSGRPCMode
  case unsupportedVLESSTransport(String)
  case invalidHysteria2
  case invalidHysteria2FM
  case ambiguousHysteria2FM
  case invalidShadowsocks
  case invalidRoutingPolicy
  case invalidNativeProfile
  case missingSelectableOutbounds
  case tooManySelectableOutbounds
  case duplicateNativeTag(String)
  case duplicateSelectableTag
  case invalidDisplayName
  case invalidHeader(String)
  case invalidExcludeRegex
  case tooManyConnections
  case nativeProfileCannotBeMerged

  var skipReason: SubscriptionSkipReason? {
    switch self {
    case .ambiguousVLESSParameters, .unsupportedVLESSParameter, .unsupportedVLESSEncryption:
      .unsupportedVLESSParameter
    case .unsupportedVLESSGRPCMode:
      .unsupportedVLESSGRPCMode
    case .invalidVLESS:
      .malformedVLESS
    case .invalidHysteria2FM, .ambiguousHysteria2FM:
      .malformedHysteria2FM
    case .invalidHysteria2:
      .malformedHysteria2
    default:
      nil
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidURL: SBMText.localized("Enter a valid HTTPS subscription URL.")
    case .httpFailure: SBMText.localized("The subscription server returned an error.")
    case .invalidEncoding: SBMText.localized("The subscription response is not valid UTF-8.")
    case .tooLarge: SBMText.localized("The subscription response is unexpectedly large.")
    case .missingProtocols:
      SBMText.localized(
        "Enter an HTTPS subscription, VLESS + REALITY, Hysteria2, or strict SIP002 Shadowsocks link."
      )
    case .invalidVLESS: SBMText.localized("The VLESS + REALITY link is invalid or unsupported.")
    case .ambiguousVLESSParameters:
      SBMText.localized(
        "The VLESS link repeats a query parameter or uses ambiguous parameter casing.")
    case .unsupportedVLESSParameter:
      SBMText.localized("The VLESS link contains a parameter that SBM does not support.")
    case .unsupportedVLESSEncryption:
      SBMText.localized("VLESS Encryption is not supported by SBM compact links.")
    case .unsupportedVLESSGRPCMode:
      SBMText.localized("The VLESS gRPC mode is not supported by SBM compact links.")
    case .unsupportedVLESSTransport(let transport):
      SBMText.format(
        "VLESS transport %@ is not supported by sing-box.", transport.uppercased()
      )
    case .invalidHysteria2:
      SBMText.localized("The Hysteria2 link is invalid or uses unsupported obfuscation.")
    case .invalidHysteria2FM:
      SBMText.localized("The Hysteria2 fm parameter is unsupported or malformed.")
    case .ambiguousHysteria2FM:
      SBMText.localized("The Hysteria2 fm parameter conflicts with standard obfuscation fields.")
    case .invalidShadowsocks:
      SBMText.localized(
        "The Shadowsocks link must be a plugin-free SIP002 URI with an approved modern cipher."
      )
    case .invalidRoutingPolicy:
      SBMText.localized(
        "The routing JSON may contain only route.rules and remote route.rule_set entries."
      )
    case .invalidNativeProfile:
      SBMText.localized("The JSON profile must contain at least one outbound or endpoint.")
    case .missingSelectableOutbounds:
      SBMText.localized(
        "The JSON profile does not contain a selector or any selectable proxy outbounds."
      )
    case .tooManySelectableOutbounds:
      SBMText.localized("The JSON profile exposes more than 64 selectable outbounds.")
    case .duplicateNativeTag(let tag):
      SBMText.format("The JSON profile contains a duplicate outbound or endpoint tag: %@.", tag)
    case .duplicateSelectableTag:
      SBMText.localized("The JSON profile selector contains the same outbound more than once.")
    case .invalidDisplayName:
      SBMText.localized("A server display name is empty, too long, or contains control characters.")
    case .invalidHeader(let name):
      SBMText.format("%@ is empty, too long, or contains control characters.", name)
    case .invalidExcludeRegex:
      SBMText.localized("The exclude regex is invalid or longer than 512 bytes.")
    case .tooManyConnections:
      SBMText.localized("A profile may contain at most 63 proxy connections.")
    case .nativeProfileCannotBeMerged:
      SBMText.localized(
        "Full sing-box JSON cannot be merged with subscription sources. Import it as a separate profile."
      )
    }
  }
}
