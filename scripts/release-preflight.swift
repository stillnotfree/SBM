#!/usr/bin/env swift
import Foundation

private enum PreflightFailure: LocalizedError {
  case usage(String)
  case check(String)
  case command(String, Int32)

  var errorDescription: String? {
    switch self {
    case .usage(let message), .check(let message):
      "release preflight: \(message)"
    case .command(let command, let status):
      "release preflight: command failed with status \(status): \(command)"
    }
  }
}

private struct Options {
  let tag: String
  let root: URL
  let metadataOnly: Bool

  init(arguments: [String]) throws {
    var tag: String?
    var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var metadataOnly = false
    var index = 0

    while index < arguments.count {
      switch arguments[index] {
      case "--tag":
        index += 1
        guard index < arguments.count, tag == nil else {
          throw PreflightFailure.usage("--tag is required exactly once.")
        }
        tag = arguments[index]
      case "--root":
        index += 1
        guard index < arguments.count else {
          throw PreflightFailure.usage("--root requires a directory path.")
        }
        root = URL(fileURLWithPath: arguments[index], relativeTo: root)
      case "--metadata-only":
        guard !metadataOnly else {
          throw PreflightFailure.usage("--metadata-only may be specified once.")
        }
        metadataOnly = true
      default:
        throw PreflightFailure.usage("unknown argument: \(arguments[index])")
      }
      index += 1
    }

    guard let tag else {
      throw PreflightFailure.usage("--tag is required.")
    }
    self.tag = tag
    self.root = root.standardizedFileURL
    self.metadataOnly = metadataOnly
  }
}

private enum ReleasePreflight {
  static func run(options: Options) throws {
    try verifyMetadata(tag: options.tag, root: options.root)
    guard !options.metadataOnly else { return }

    try run("swift test", in: options.root)
    try run("xcrun swift-format lint --recursive Sources Tests Package.swift", in: options.root)
    try run(
      "plutil -lint Resources/Info.plist Resources/com.stillnotfree.sbm.helper.plist",
      in: options.root
    )
    try run("git diff --check", in: options.root)
    try run("make app", in: options.root)
    try verifyBuiltArtifacts(tag: options.tag, root: options.root)
    try run("codesign --verify --strict --verbose=2 dist/SBM.app", in: options.root)
    try run(
      "codesign --verify --strict --verbose=2 dist/SBM.app/Contents/Resources/SBMHelper",
      in: options.root
    )
    try run(
      "codesign --verify --strict --verbose=2 dist/SBM.app/Contents/Resources/sing-box",
      in: options.root
    )
  }

  private static func verifyMetadata(tag: String, root: URL) throws {
    guard matches(tag, pattern: #"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#) else {
      throw PreflightFailure.check(
        "release tag must use vMAJOR.MINOR.PATCH with numeric components.")
    }
    let tagVersion = String(tag.dropFirst())
    print("Metadata OK: release tag \(tag) is strict semver.")

    let makefile = try read("Makefile", from: root)
    let appVersion = try oneAssignment(named: "APP_VERSION", in: makefile, file: "Makefile")
    guard appVersion == tagVersion else {
      throw PreflightFailure.check(
        "release tag version \(tag) does not match Makefile APP_VERSION \(appVersion).")
    }
    print("Metadata OK: release tag matches Makefile APP_VERSION.")

    let info = try propertyList("Resources/Info.plist", root: root)
    guard let plistVersion = info["CFBundleShortVersionString"] as? String else {
      throw PreflightFailure.check("Resources/Info.plist is missing CFBundleShortVersionString.")
    }
    guard plistVersion == tagVersion else {
      throw PreflightFailure.check(
        "release tag version \(tag) does not match Resources/Info.plist CFBundleShortVersionString \(plistVersion)."
      )
    }
    guard let bundleVersion = info["CFBundleVersion"] as? String,
      matches(bundleVersion, pattern: #"^[1-9][0-9]*$"#)
    else {
      throw PreflightFailure.check(
        "Resources/Info.plist CFBundleVersion must be a positive decimal integer.")
    }
    print("Metadata OK: Info.plist version and build number match the release.")

    let lock = try read("Core.lock", from: root)
    let coreVersion = try oneAssignment(named: "CORE_VERSION", in: lock, file: "Core.lock")
    guard matches(coreVersion, pattern: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#)
    else {
      throw PreflightFailure.check("Core.lock CORE_VERSION must be a stable semantic version.")
    }
    let digests = try digestAssignments(in: lock)
    guard digests.count == 2 else {
      throw PreflightFailure.check(
        "Core.lock must contain exactly two lowercase 64-character SHA-256 digests; found \(digests.count)."
      )
    }
    print("Metadata OK: Core.lock has a stable version and two SHA-256 digests.")

    let buildInfo = try read("Sources/SBMShared/CoreBuildInfo.swift", from: root)
    let buildInfoVersion = try oneSwiftString(
      named: "version", in: buildInfo, file: "Sources/SBMShared/CoreBuildInfo.swift")
    guard buildInfoVersion == coreVersion else {
      throw PreflightFailure.check(
        "CoreBuildInfo version \(buildInfoVersion) does not match Core.lock CORE_VERSION \(coreVersion)."
      )
    }
    let signedDigest = try oneSwiftString(
      named: "signedSHA256", in: buildInfo, file: "Sources/SBMShared/CoreBuildInfo.swift")
    guard matches(signedDigest, pattern: #"^[a-f0-9]{64}$"#) else {
      throw PreflightFailure.check(
        "CoreBuildInfo signedSHA256 must be a lowercase 64-character SHA-256 digest.")
    }
    print("Metadata OK: CoreBuildInfo matches the pinned core version and signed digest format.")

    let policy = try read("Sources/SBMHelper/NativeCapabilityPolicy.swift", from: root)
    let reviewedVersion = try oneSwiftString(
      named: "reviewedCoreVersion", in: policy,
      file: "Sources/SBMHelper/NativeCapabilityPolicy.swift")
    guard reviewedVersion == coreVersion else {
      throw PreflightFailure.check(
        "NativeCapabilityPolicy reviewedCoreVersion \(reviewedVersion) does not match Core.lock CORE_VERSION \(coreVersion)."
      )
    }
    print("Metadata OK: NativeCapabilityPolicy is reviewed for the pinned core.")

    try verifyRepositoryScope(root: root)
    print("Metadata OK: .codex contains no tracked files.")

    try verifyArm64Packaging(makefile: makefile, root: root)
    print("Metadata OK: Package and Make packaging inputs are arm64-only.")
  }

  private static func read(_ path: String, from root: URL) throws -> String {
    let url = root.appendingPathComponent(path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PreflightFailure.check("missing required file: \(path)")
    }
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw PreflightFailure.check("could not read required UTF-8 file: \(path)")
    }
  }

  private static func propertyList(_ path: String, root: URL) throws -> [String: Any] {
    let url = root.appendingPathComponent(path)
    do {
      let data = try Data(contentsOf: url)
      let value = try PropertyListSerialization.propertyList(from: data, format: nil)
      guard let dictionary = value as? [String: Any] else {
        throw PreflightFailure.check("\(path) must contain a dictionary plist.")
      }
      return dictionary
    } catch let failure as PreflightFailure {
      throw failure
    } catch {
      throw PreflightFailure.check("\(path) is not a valid property list.")
    }
  }

  private static func oneAssignment(named name: String, in text: String, file: String) throws
    -> String
  {
    let values = captures(
      #"^\s*"# + NSRegularExpression.escapedPattern(for: name) + #"\s*:=\s*([^\s#]+)\s*(?:#.*)?$"#,
      in: text
    )
    guard values.count == 1, let value = values.first?.first else {
      throw PreflightFailure.check("\(file) must define \(name) exactly once.")
    }
    return value
  }

  private static func digestAssignments(in text: String) throws -> [(String, String)] {
    let assignments = captures(#"^\s*([A-Z0-9_]*SHA256)\s*:=\s*([^\s#]+)\s*(?:#.*)?$"#, in: text)
    for match in assignments {
      guard match.count == 2, matches(match[1], pattern: #"^[a-f0-9]{64}$"#) else {
        let name = match.first ?? "SHA256 value"
        throw PreflightFailure.check(
          "Core.lock \(name) must be a lowercase 64-character SHA-256 digest.")
      }
    }
    return assignments.compactMap { values in
      guard values.count == 2 else { return nil }
      return (values[0], values[1])
    }
  }

  private static func oneSwiftString(named name: String, in text: String, file: String) throws
    -> String
  {
    let values = captures(
      #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*"([^"]+)""#,
      in: text
    )
    guard values.count == 1, let value = values.first?.first else {
      throw PreflightFailure.check("\(file) must define \(name) as one string value.")
    }
    return value
  }

  private static func verifyRepositoryScope(root: URL) throws {
    let result = try process(["git", "ls-files", "--", ".codex"], in: root, captureOutput: true)
    guard result.status == 0 else {
      throw PreflightFailure.check("repository scope cannot be checked with git ls-files.")
    }
    guard result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PreflightFailure.check("tracked .codex files are forbidden in a release tree.")
    }
  }

  private static func verifyArm64Packaging(makefile: String, root: URL) throws {
    let package = try read("Package.swift", from: root)
    let requiredMakeInputs = [
      "darwin-arm64.tar.gz",
      "--arch arm64",
      "arm64-apple-macosx",
      "-arm64.dmg",
    ]
    guard package.contains("platforms: [.macOS"),
      requiredMakeInputs.allSatisfy(makefile.contains),
      !makefile.localizedCaseInsensitiveContains("x86_64"),
      !makefile.localizedCaseInsensitiveContains("universal"),
      !package.localizedCaseInsensitiveContains("x86_64"),
      !package.localizedCaseInsensitiveContains("universal")
    else {
      throw PreflightFailure.check("Package and Make packaging inputs must be arm64-only.")
    }
  }

  private static func verifyBuiltArtifacts(tag: String, root: URL) throws {
    let app = root.appendingPathComponent("dist/SBM.app", isDirectory: true)
    let info = try propertyList("dist/SBM.app/Contents/Info.plist", root: root)
    let sourceInfo = try propertyList("Resources/Info.plist", root: root)
    let expectedVersion = String(tag.dropFirst())
    guard let version = info["CFBundleShortVersionString"] as? String, version == expectedVersion
    else {
      throw PreflightFailure.check(
        "built app CFBundleShortVersionString must match release tag \(tag).")
    }
    guard let expectedBuild = sourceInfo["CFBundleVersion"] as? String,
      matches(expectedBuild, pattern: #"^[1-9][0-9]*$"#)
    else {
      throw PreflightFailure.check(
        "Resources/Info.plist CFBundleVersion must be a positive decimal integer.")
    }
    guard let build = info["CFBundleVersion"] as? String, build == expectedBuild else {
      throw PreflightFailure.check(
        "built app CFBundleVersion must match Resources/Info.plist CFBundleVersion \(expectedBuild)."
      )
    }
    print("Built artifact OK: Info.plist marketing and build versions match the release.")

    try verifyArm64Artifact(
      app.appendingPathComponent("Contents/MacOS/SBM"), name: "app executable")
    try verifyArm64Artifact(
      app.appendingPathComponent("Contents/Resources/SBMHelper"), name: "helper executable")
    try verifyArm64Artifact(
      app.appendingPathComponent("Contents/Resources/sing-box"), name: "bundled sing-box")
  }

  private static func verifyArm64Artifact(_ url: URL, name: String) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PreflightFailure.check("built \(name) is missing from dist/SBM.app.")
    }
    print("Running: xcrun lipo -archs \(url.path)")
    let result = try process(
      ["xcrun", "lipo", "-archs", url.path],
      in: url.deletingLastPathComponent(),
      captureOutput: true
    )
    guard result.status == 0 else {
      throw PreflightFailure.check("could not inspect the architecture of built \(name).")
    }
    guard result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" else {
      throw PreflightFailure.check("built \(name) must be arm64-only.")
    }
    print("Built artifact OK: \(name) is arm64-only.")
  }

  private static func run(_ command: String, in root: URL) throws {
    print("Running: \(command)")
    let result = try process(
      command.split(separator: " ").map(String.init), in: root, captureOutput: false)
    guard result.status == 0 else {
      throw PreflightFailure.command(command, result.status)
    }
  }

  private static func process(
    _ arguments: [String],
    in root: URL,
    captureOutput: Bool
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    if captureOutput {
      process.standardOutput = output
      process.standardError = output
    } else {
      process.standardOutput = FileHandle.standardOutput
      process.standardError = FileHandle.standardError
    }
    do {
      try process.run()
    } catch {
      throw PreflightFailure.check("could not start command: \(arguments.joined(separator: " "))")
    }
    process.waitUntilExit()
    let data = captureOutput ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private static func captures(_ pattern: String, in text: String) -> [[String]] {
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern,
        options: [.anchorsMatchLines]
      )
    else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).map { match in
      (1..<match.numberOfRanges).compactMap { index in
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
      }
    }
  }

  private static func matches(_ value: String, pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
  }
}

do {
  try ReleasePreflight.run(
    options: try Options(arguments: Array(CommandLine.arguments.dropFirst())))
} catch {
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  exit(EXIT_FAILURE)
}
