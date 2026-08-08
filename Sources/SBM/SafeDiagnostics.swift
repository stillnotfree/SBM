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
    #"\b(?:https?|vless|hysteria2|hy2)://[^\s\]\[\)\(\}"']+"#,
    #"\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+"#,
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
    switch profile {
    case .compatibility(let profile):
      for connection in profile.vless {
        values.append(contentsOf: [connection.uuid, connection.publicKey, connection.shortID])
      }
      for connection in profile.hysteria2 {
        values.append(connection.password)
        if let obfsPassword = connection.obfsPassword { values.append(obfsPassword) }
      }
    case .native(let profile):
      guard let object = try? JSONSerialization.jsonObject(with: profile.configuration) else {
        return
      }
      collectSensitiveJSONValues(object, key: nil, into: &values)
    }
  }

  private static func collectSensitiveJSONValues(
    _ value: Any,
    key: String?,
    into values: inout [String]
  ) {
    let sensitive = key.map(isSensitiveKey) ?? false
    if sensitive {
      collectStrings(value, into: &values)
      return
    }
    if let object = value as? [String: Any] {
      for (childKey, child) in object {
        collectSensitiveJSONValues(child, key: childKey, into: &values)
      }
    } else if let array = value as? [Any] {
      for child in array {
        collectSensitiveJSONValues(child, key: key, into: &values)
      }
    }
  }

  private static func collectStrings(_ value: Any, into values: inout [String]) {
    if let string = value as? String {
      values.append(string)
    } else if let object = value as? [String: Any] {
      for child in object.values { collectStrings(child, into: &values) }
    } else if let array = value as? [Any] {
      for child in array { collectStrings(child, into: &values) }
    }
  }

  private static func isSensitiveKey(_ key: String) -> Bool {
    let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
    return normalized.contains("password")
      || normalized.contains("secret")
      || normalized.contains("token")
      || normalized == "uuid"
      || normalized == "auth"
      || normalized == "auth_str"
      || normalized == "authorization"
      || normalized == "private_key"
      || normalized == "pre_shared_key"
      || normalized == "public_key"
      || normalized == "short_id"
      || normalized == "cookie"
      || normalized == "x_hwid"
  }
}
