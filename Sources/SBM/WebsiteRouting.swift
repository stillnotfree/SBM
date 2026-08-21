import Foundation

enum WebsiteRoutingFailure: LocalizedError {
  case invalidDomain
  case unsupportedScheme
  case credentialsNotAllowed
  case duplicateDomain
  case tooManyRules

  var errorDescription: String? {
    switch self {
    case .invalidDomain: "Enter a valid hostname without wildcards, paths, or IP addresses."
    case .unsupportedScheme: "Only HTTP and HTTPS website URLs are accepted."
    case .credentialsNotAllowed: "Website URLs with embedded credentials are not accepted."
    case .duplicateDomain: "This website already has a routing rule."
    case .tooManyRules: "A profile may contain at most 128 website rules."
    }
  }
}

enum WebsiteDomainNormalizer {
  static func normalize(_ input: String) throws -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 2048,
      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw WebsiteRoutingFailure.invalidDomain }

    let rawHost: String
    if trimmed.contains("://") {
      guard let components = URLComponents(string: trimmed),
        let scheme = components.scheme?.lowercased()
      else { throw WebsiteRoutingFailure.invalidDomain }
      guard scheme == "http" || scheme == "https" else {
        throw WebsiteRoutingFailure.unsupportedScheme
      }
      guard components.user == nil, components.password == nil else {
        throw WebsiteRoutingFailure.credentialsNotAllowed
      }
      guard let host = components.host, !host.isEmpty else {
        throw WebsiteRoutingFailure.invalidDomain
      }
      rawHost = host
    } else {
      guard !trimmed.contains(where: { "*/\\/?#@[]".contains($0) }),
        !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }
        )
      else { throw WebsiteRoutingFailure.invalidDomain }
      rawHost = trimmed
    }

    var host = rawHost.precomposedStringWithCanonicalMapping.lowercased()
    if host.hasSuffix(".") {
      host.removeLast()
    }
    guard !host.hasSuffix("."), !host.hasPrefix("."), !host.isEmpty else {
      throw WebsiteRoutingFailure.invalidDomain
    }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count >= 2 else { throw WebsiteRoutingFailure.invalidDomain }
    try labels.forEach(validateLabel)
    let canonicalHost = labels.joined(separator: ".")
    guard let foundationURL = URL(string: "https://\(canonicalHost)/") else {
      throw WebsiteRoutingFailure.invalidDomain
    }
    let serialized = foundationURL.absoluteString
    guard serialized.hasPrefix("https://"), serialized.hasSuffix("/") else {
      throw WebsiteRoutingFailure.invalidDomain
    }
    let normalized = String(serialized.dropFirst("https://".count).dropLast())
    let asciiLabels = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard normalized.utf8.count <= 253,
      !normalized.contains("%"), !normalized.contains(":"), !normalized.contains("@"),
      asciiLabels.last?.allSatisfy({ $0.isNumber }) == false,
      asciiLabels.allSatisfy({ label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
          && label.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
          })
      })
    else { throw WebsiteRoutingFailure.invalidDomain }
    return normalized
  }

  private static func validateLabel(_ label: String) throws {
    guard !label.isEmpty else { throw WebsiteRoutingFailure.invalidDomain }
    let scalars = Array(label.unicodeScalars)
    guard scalars.first?.value != 45, scalars.last?.value != 45,
      scalars.allSatisfy({ scalar in
        scalar.value == 45
          || CharacterSet.letters.union(.decimalDigits).contains(scalar)
      })
    else { throw WebsiteRoutingFailure.invalidDomain }
  }
}
