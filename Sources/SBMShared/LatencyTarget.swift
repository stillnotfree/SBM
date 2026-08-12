import Foundation

public enum LatencyTargetPolicy {
  public static let defaultURL = "https://www.gstatic.com/generate_204"
  public static let maximumUTF8Length = 2_048

  public static func normalized(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.utf8.count <= maximumUTF8Length,
      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      var components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "https",
      let host = components.host,
      !host.isEmpty,
      components.port.map({ (1...65_535).contains($0) }) ?? true,
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      let url = components.url,
      url.isFileURL == false
    else {
      throw LatencyTargetFailure.invalidURL
    }
    components.scheme = "https"
    guard let normalizedURL = components.url else { throw LatencyTargetFailure.invalidURL }
    return normalizedURL.absoluteString
  }
}

public enum LatencyTargetFailure: LocalizedError, Equatable, Sendable {
  case invalidURL

  public var errorDescription: String? {
    "Enter an absolute HTTPS latency target without credentials, fragments, or control characters."
  }
}
