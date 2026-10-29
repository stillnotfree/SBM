import Foundation
import SBMShared

enum SecretRedactor {
  static let placeholder = "<redacted>"

  static func redact(_ input: String, secrets: [String]) -> String {
    var output = input
    let uniqueSecrets = Set(secrets.filter { $0.utf8.count >= 3 })
      .sorted { $0.utf8.count > $1.utf8.count }
    for secret in uniqueSecrets {
      output = output.replacingOccurrences(of: secret, with: placeholder)
    }
    for pattern in patterns {
      guard
        let expression = try? NSRegularExpression(
          pattern: pattern,
          options: [.caseInsensitive]
        )
      else { continue }
      let range = NSRange(output.startIndex..<output.endIndex, in: output)
      output = expression.stringByReplacingMatches(
        in: output,
        range: range,
        withTemplate: placeholder
      )
    }
    return output
  }

  private static let patterns = [
    #"\b(?:https?|vless|hysteria2|hy2|ss)://[^\s\]\[\)\(\}"']+"#,
    #"\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+"#,
    #"\b(?:password|pass|secret|token|hwid|x[-_]?hwid|uuid|public[-_]?key|private[-_]?key|short[-_]?id)\s*[:=]\s*[^\s,;]+"#,
    #"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"#,
  ]
}

enum DiagnosticSecrets {
  static func collect(from profiles: [ManagedProfile]) -> [String] {
    var values: [String] = []
    for profile in profiles {
      for source in profile.sources {
        values.append(source.value)
        values.append(source.headers.hardwareID)
      }
      if let payload = profile.payload {
        collect(from: payload, into: &values)
      }
    }
    return values
  }

  private static func collect(from profile: CoreProfile, into values: inout [String]) {
    let managedProfile: VPNProfile
    switch profile {
    case .compatibility(let profile): managedProfile = profile
    }
    for connection in managedProfile.connections {
      switch connection.outbound {
      case .vless(let value):
        values.append(contentsOf: [value.uuid, value.publicKey, value.shortID])
      case .hysteria2(let value):
        values.append(value.password)
        if let obfsPassword = value.obfsPassword { values.append(obfsPassword) }
      case .shadowsocks(let value):
        values.append(value.password)
      }
    }
  }
}

enum SafeDiagnosticError {
  static let redactedMessage = "Error details redacted."

  static func sanitize(_ value: String, secrets: [String]) -> String {
    guard !value.contains("{"), !value.contains("}"),
      !value.contains("["), !value.contains("]")
    else { return redactedMessage }
    let redacted = SecretRedactor.redact(value, secrets: secrets)
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    return redacted.count <= 512 ? redacted : String(redacted.prefix(512)) + "…"
  }
}
