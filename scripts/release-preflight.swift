#!/usr/bin/env swift
import CryptoKit
import Darwin
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

    try run("swift test --disable-sandbox --no-parallel", in: options.root)
    try run(
      "xcrun swift-format lint --recursive Sources Tests Package.swift scripts/release-manifest.swift scripts/release-preflight.swift scripts/update-core.swift",
      in: options.root
    )
    try run(
      "plutil -lint Resources/Info.plist Resources/com.stillnotfree.sbm.helper.plist",
      in: options.root
    )
    try run("git diff --check", in: options.root)
    let coreBuildInfoURL = options.root.appendingPathComponent(
      "Sources/SBMShared/CoreBuildInfo.swift")
    let checkpointedCoreBuildInfo = try Data(contentsOf: coreBuildInfoURL)
    var buildFailure: Error?
    do {
      try run("make dmg", in: options.root)
    } catch {
      buildFailure = error
    }
    try verifyCoreBuildInfoUnchanged(checkpointedCoreBuildInfo, at: coreBuildInfoURL)
    if let buildFailure { throw buildFailure }
    try verifyBuiltArtifacts(tag: options.tag, root: options.root)
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
    let coreFields = [
      "CORE_VERSION", "CORE_REVISION", "CORE_GO_DIRECTIVE", "CORE_GO_VERSION",
      "CORE_BUILD_TAGS", "CORE_CGO_ENABLED", "CORE_LDFLAGS",
    ]
    let coreAssignments = captures(#"^[ \t]*(CORE_[A-Z0-9_]+)[ \t]*:="#, in: lock)
      .compactMap(\.first)
    guard Set(coreAssignments) == Set(coreFields), coreAssignments.count == coreFields.count else {
      throw PreflightFailure.check("Core.lock must contain exactly the seven source recipe fields.")
    }
    var recipe: [String: String] = [:]
    for name in coreFields {
      recipe[name] = try oneAssignment(named: name, in: lock, file: "Core.lock")
    }
    let revision = try required(recipe, "CORE_REVISION")
    guard matches(revision, pattern: #"^[a-f0-9]{40}$"#) else {
      throw PreflightFailure.check(
        "Core.lock CORE_REVISION must be 40 lowercase hexadecimal characters.")
    }
    let goDirective = try required(recipe, "CORE_GO_DIRECTIVE")
    guard matches(goDirective, pattern: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#)
    else {
      throw PreflightFailure.check("Core.lock CORE_GO_DIRECTIVE must use major.minor.patch format.")
    }
    let goVersion = try required(recipe, "CORE_GO_VERSION")
    guard matches(goVersion, pattern: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#)
    else {
      throw PreflightFailure.check("Core.lock CORE_GO_VERSION must use major.minor.patch format.")
    }
    let buildTags = try required(recipe, "CORE_BUILD_TAGS")
    let tags = buildTags.split(separator: ",", omittingEmptySubsequences: false)
    guard !tags.isEmpty,
      tags.allSatisfy({
        !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
      }), Set(tags).count == tags.count
    else {
      throw PreflightFailure.check(
        "Core.lock CORE_BUILD_TAGS must be non-empty and contain unique tags.")
    }
    let cgoEnabled = try required(recipe, "CORE_CGO_ENABLED")
    guard cgoEnabled == "0" || cgoEnabled == "1" else {
      throw PreflightFailure.check("Core.lock CORE_CGO_ENABLED must be 0 or 1.")
    }
    let linkerFlags = try required(recipe, "CORE_LDFLAGS")
    guard !linkerFlags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PreflightFailure.check("Core.lock CORE_LDFLAGS must not be empty.")
    }
    print("Metadata OK: Core.lock has one valid seven-field source build recipe.")

    let buildInfo = try read("Sources/SBMShared/CoreBuildInfo.swift", from: root)
    let buildInfoVersion = try oneSwiftString(
      named: "version", in: buildInfo, file: "Sources/SBMShared/CoreBuildInfo.swift")
    guard buildInfoVersion == coreVersion else {
      throw PreflightFailure.check(
        "CoreBuildInfo version \(buildInfoVersion) does not match Core.lock CORE_VERSION \(coreVersion)."
      )
    }
    let buildInfoFields = [
      ("revision", revision), ("goVersion", "go\(goVersion)"),
      ("buildTags", buildTags), ("cgo", cgoEnabled == "1" ? "enabled" : "disabled"),
      ("linkerFlags", linkerFlags),
    ]
    for (name, expected) in buildInfoFields {
      let value = try oneSwiftString(
        named: name, in: buildInfo, file: "Sources/SBMShared/CoreBuildInfo.swift")
      guard value == expected else {
        throw PreflightFailure.check("CoreBuildInfo \(name) does not match Core.lock.")
      }
    }
    let unsignedDigest = try oneSwiftString(
      named: "unsignedSHA256", in: buildInfo, file: "Sources/SBMShared/CoreBuildInfo.swift")
    guard matches(unsignedDigest, pattern: #"^[a-f0-9]{64}$"#) else {
      throw PreflightFailure.check(
        "CoreBuildInfo unsignedSHA256 must be a lowercase 64-character SHA-256 digest.")
    }
    let signedDigest = try oneSwiftString(
      named: "signedSHA256", in: buildInfo, file: "Sources/SBMShared/CoreBuildInfo.swift")
    guard matches(signedDigest, pattern: #"^[a-f0-9]{64}$"#) else {
      throw PreflightFailure.check(
        "CoreBuildInfo signedSHA256 must be a lowercase 64-character SHA-256 digest.")
    }
    print("Metadata OK: CoreBuildInfo matches the recipe and both SHA-256 formats.")

    try verifyRepositoryScope(root: root)
    print("Metadata OK: .codex contains no tracked files.")

    try verifyBuildAndReleaseTrustInputs(makefile: makefile, root: root)
    print("Metadata OK: pinned core build and release trust inputs are valid.")
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
      #"^[ \t]*"# + NSRegularExpression.escapedPattern(for: name) + #"[ \t]*:=[ \t]*(.*?)[ \t]*$"#,
      in: text
    )
    guard values.count == 1, let value = values.first?.first else {
      throw PreflightFailure.check("\(file) must define \(name) exactly once.")
    }
    return value
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

  private static func verifyBuildAndReleaseTrustInputs(makefile: String, root: URL) throws {
    let package = try read("Package.swift", from: root)
    let requiredBuildInputs = [
      "test \"$$source_go\" = \"$(CORE_GO_DIRECTIVE)\"",
      "GOTOOLCHAIN=go$(CORE_GO_VERSION)",
      "-mod=readonly",
      "-trimpath",
      "-tags \"$(CORE_BUILD_TAGS)\"",
    ]
    let releaseTool = try read("scripts/release-manifest.swift", from: root)
    let signingStart = "    case \"sign-update-artifact\":"
    let verificationStart = "    case \"verify-update-artifact\":"
    let signingCase: String
    if let start = releaseTool.range(of: signingStart),
      let end = releaseTool.range(
        of: verificationStart, range: start.upperBound..<releaseTool.endIndex)
    {
      signingCase = String(releaseTool[start.upperBound..<end.lowerBound])
    } else {
      throw PreflightFailure.check("release trust tool is missing its update-proof commands.")
    }
    let requiredTrustSequence = [
      "let manifest = try verifyDMG(dmg: dmg, coreDigestFile: coreDigestFile)",
      "updateArtifactFacts(for: dmg, appVersion: manifest.appVersion)",
      "privateKey.publicKey.rawRepresentation == CurrentReleaseManifest.projectPublicKey",
      "UpdateArtifactProof.sign(payload, with: privateKey)",
      "try proof.write(",
      "try verifyUpdateArtifact(dmg: dmg, coreDigestFile: coreDigestFile)",
    ]
    let trustPositions = requiredTrustSequence.compactMap {
      signingCase.range(of: $0)?.lowerBound
    }
    guard package.contains("platforms: [.macOS"),
      requiredBuildInputs.allSatisfy(makefile.contains),
      trustPositions.count == requiredTrustSequence.count,
      trustPositions == trustPositions.sorted()
    else {
      throw PreflightFailure.check(
        "pinned core build and release proof inputs must match the current trust contract.")
    }
  }

  private static func required(_ values: [String: String], _ name: String) throws -> String {
    guard let value = values[name] else {
      throw PreflightFailure.check("Core.lock is missing \(name).")
    }
    return value
  }

  private static func verifyCoreBuildInfoUnchanged(_ expected: Data, at url: URL) throws {
    guard let current = try? Data(contentsOf: url), current == expected else {
      throw PreflightFailure.check(
        "full release build changed checkpointed CoreBuildInfo; review the rebuilt core before release."
      )
    }
    print("Build OK: full release build preserved checkpointed CoreBuildInfo.")
  }

  private static func verifyBuiltArtifacts(tag: String, root: URL) throws {
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

    let helperPlist = try propertyList(
      "dist/SBM.app/Contents/Library/LaunchDaemons/com.stillnotfree.sbm.helper.plist",
      root: root
    )
    if let abandonProcessGroup = helperPlist["AbandonProcessGroup"] {
      guard let value = abandonProcessGroup as? Bool, !value else {
        throw PreflightFailure.check(
          "built helper plist must omit AbandonProcessGroup or set it false.")
      }
    }
    print("Built artifact OK: helper plist does not abandon its process group.")
    try verifyFinalDMGPresentation(tag: tag, root: root)
  }

  private static func verifyFinalDMGPresentation(tag: String, root: URL) throws {
    let files = FileManager.default
    let mountpoint = files.temporaryDirectory.appendingPathComponent(
      "SBMReleaseDMG-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: mountpoint, withIntermediateDirectories: false)
    var needsDetach = true
    defer {
      if needsDetach {
        _ = try? process(["hdiutil", "detach", mountpoint.path], in: root, captureOutput: true)
      }
      try? files.removeItem(at: mountpoint)
    }
    let dmg = root.appendingPathComponent("dist/SBM-\(String(tag.dropFirst()))-arm64.dmg")
    let attach = try process(
      ["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mountpoint.path, dmg.path],
      in: root, captureOutput: true)
    guard attach.status == 0 else {
      throw PreflightFailure.command("hdiutil attach final DMG", attach.status)
    }
    guard files.fileExists(atPath: mountpoint.appendingPathComponent("SBM.app").path) else {
      throw PreflightFailure.check("final DMG is missing root SBM.app.")
    }
    let applications = mountpoint.appendingPathComponent("Applications")
    var linkStat = stat()
    guard lstat(applications.path, &linkStat) == 0, (linkStat.st_mode & S_IFMT) == S_IFLNK,
      (try? files.destinationOfSymbolicLink(atPath: applications.path)) == "/Applications"
    else {
      throw PreflightFailure.check("final DMG Applications must be a symlink to /Applications.")
    }
    let background = mountpoint.appendingPathComponent(".background/background.png")
    guard
      let tracked = try? Data(
        contentsOf: root.appendingPathComponent("Resources/DMG/background.png")),
      regularFileSize(background.path) == off_t(tracked.count),
      let mounted = try? Data(contentsOf: background),
      Data(SHA256.hash(data: tracked)) == Data(SHA256.hash(data: mounted))
    else {
      throw PreflightFailure.check("final DMG background digest does not match the tracked asset.")
    }
    guard let storeSize = regularFileSize(mountpoint.appendingPathComponent(".DS_Store").path),
      storeSize > 0
    else {
      throw PreflightFailure.check("final DMG root .DS_Store must be a non-empty regular file.")
    }
    let detach = try process(["hdiutil", "detach", mountpoint.path], in: root, captureOutput: true)
    guard detach.status == 0 else {
      throw PreflightFailure.command("hdiutil detach final DMG", detach.status)
    }
    needsDetach = false
    print(
      "Final DMG presentation OK: SBM.app, Applications link, tracked background, and non-empty .DS_Store."
    )
  }

  private static func regularFileSize(_ path: String) -> off_t? {
    var fileStat = stat()
    guard lstat(path, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG else { return nil }
    return fileStat.st_size
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
    let data = captureOutput ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
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
