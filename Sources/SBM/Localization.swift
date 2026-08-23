import Foundation

enum SBMText {
  private static let table = "Localizable"
  private static let localizationBundle = resolvedBundle()

  static func localized(_ key: String) -> String {
    localizationBundle.localizedString(forKey: key, value: key, table: table)
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: Locale.current, arguments: arguments)
  }

  private static func resolvedBundle() -> Bundle {
    guard !containsLocalization(in: Bundle.main) else { return Bundle.main }
    return Bundle.module
  }

  private static func containsLocalization(in bundle: Bundle) -> Bool {
    ["en.lproj", "ru.lproj", "zh-Hans.lproj", "zh-hans.lproj"].contains {
      bundle.path(forResource: table, ofType: "strings", inDirectory: $0) != nil
    }
  }
}
