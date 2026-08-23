import Foundation

struct ValidationFailure: Error, CustomStringConvertible {
  let message: String

  var description: String { message }
}

func argument(named name: String) throws -> String {
  let arguments = CommandLine.arguments
  guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
    throw ValidationFailure(message: "Missing argument \(name).")
  }
  return arguments[index + 1]
}

let appPath = try argument(named: "--app")
let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
guard let appBundle = Bundle(url: appURL),
  let resourcesURL = appBundle.resourceURL
else {
  throw ValidationFailure(message: "Packaged app bundle is unreadable: \(appPath)")
}

guard !appURL.path.contains("/.build/") else {
  throw ValidationFailure(message: "Packaged app path must not be under .build.")
}

let moduleBundleURL = resourcesURL.appendingPathComponent("SBM_SBM.bundle", isDirectory: true)
guard !FileManager.default.fileExists(atPath: moduleBundleURL.path) else {
  throw ValidationFailure(message: "Packaged app must not contain a second resource bundle.")
}

let expected: [(String, String, String)] = [
  ("en.lproj", "Settings", "Settings"),
  ("ru.lproj", "Settings", "Настройки"),
  ("zh-Hans.lproj", "Settings", "设置"),
]

for (localeDirectory, key, expectedValue) in expected {
  guard let stringsPath = appBundle.path(
    forResource: "Localizable",
    ofType: "strings",
    inDirectory: localeDirectory
  ) else {
    throw ValidationFailure(
      message: "Packaged app is missing \(localeDirectory)/Localizable.strings."
    )
  }
  guard stringsPath.hasPrefix(resourcesURL.path + "/") else {
    throw ValidationFailure(message: "Localization escaped the packaged app resources.")
  }
  guard let localeBundle = Bundle(
    path: URL(fileURLWithPath: stringsPath).deletingLastPathComponent().path
  ) else {
    throw ValidationFailure(message: "Cannot load packaged localization bundle: \(stringsPath)")
  }
  let value = localeBundle.localizedString(forKey: key, value: nil, table: "Localizable")
  guard value == expectedValue else {
    throw ValidationFailure(
      message: "Unexpected \(localeDirectory) value for \(key): \(value)"
    )
  }
}

print("Packaged localization OK: main app resources resolve en/ru/zh-Hans Settings.")
