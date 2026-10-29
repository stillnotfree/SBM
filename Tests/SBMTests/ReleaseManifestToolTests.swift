import CryptoKit
import Foundation
import SBMShared
import Testing

@Test func realHelperTemplateUsesBundleProgramWithoutAssociatedBundleIdentifiers() throws {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let template = packageRoot.appendingPathComponent(
    "Resources/com.stillnotfree.sbm.helper.plist")
  let plist = try #require(
    PropertyListSerialization.propertyList(
      from: Data(contentsOf: template), options: [], format: nil
    ) as? [String: Any]
  )

  #expect(plist["Label"] as? String == "com.stillnotfree.sbm.helper")
  #expect(plist["BundleProgram"] as? String == "Contents/Resources/SBMHelper")
  #expect(plist["Sockets"] == nil)
  let legacyEnvironment = try #require(plist["EnvironmentVariables"] as? [String: String])
  #expect(
    legacyEnvironment[HelperConstants.serviceLabelEnvironmentKey]
      == HelperConstants.legacyServiceLabel)
  #expect(plist["AssociatedBundleIdentifiers"] == nil)
}

@Test func releaseTemplatesSeparateLegacyTombstoneFromCurrentV12Listener() throws {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let directory = packageRoot.appendingPathComponent("Resources", isDirectory: true)
  let legacy = try #require(
    PropertyListSerialization.propertyList(
      from: Data(contentsOf: directory.appendingPathComponent("com.stillnotfree.sbm.helper.plist")),
      format: nil
    ) as? [String: Any]
  )
  let current = try #require(
    PropertyListSerialization.propertyList(
      from: Data(
        contentsOf: directory.appendingPathComponent("com.stillnotfree.sbm.helper.v12.plist")),
      format: nil
    ) as? [String: Any]
  )
  #expect(legacy["Label"] as? String == HelperConstants.legacyServiceLabel)
  #expect(legacy["Sockets"] == nil)
  #expect(current["Label"] as? String == HelperConstants.currentServiceLabel)
  #expect(
    (current["Sockets"] as? [String: Any])?["Listener"] as? [String: Any] != nil
  )
}

@Test func releaseManifestToolPinsAndVerifiesExactSpawnConstraint() throws {
  let fixture = try ReleaseManifestToolFixture()
  let generated = try fixture.run([
    "helper-plist",
    "--helper", fixture.helper.path,
    "--template", fixture.template.path,
    "--output", fixture.plist.path,
  ])
  #expect(generated.status == 0)

  var plist = try fixture.readPlist()
  let constraint = try #require(plist["SpawnConstraint"] as? [String: Any])
  #expect(Set(constraint.keys) == Set(["cdhash", "signing-identifier"]))
  #expect(constraint["signing-identifier"] as? String == "com.stillnotfree.sbm.helper")

  let accepted = try fixture.run([
    "verify-helper-plist",
    "--helper", fixture.helper.path,
    "--plist", fixture.plist.path,
  ])
  #expect(accepted.status == 0)

  let mismatchedTemplate = try fixture.run([
    "helper-plist",
    "--helper", fixture.helper.path,
    "--template", fixture.template.path,
    "--output", fixture.currentPlist.path,
  ])
  #expect(mismatchedTemplate.status != 0)

  let generatedCurrent = try fixture.run([
    "helper-plist",
    "--helper", fixture.helper.path,
    "--template", fixture.currentTemplate.path,
    "--output", fixture.currentPlist.path,
  ])
  #expect(generatedCurrent.status == 0)
  let acceptedCurrent = try fixture.run([
    "verify-helper-plist",
    "--helper", fixture.helper.path,
    "--plist", fixture.currentPlist.path,
  ])
  #expect(acceptedCurrent.status == 0)
  let currentGeneratedPlist = try fixture.readPlist(at: fixture.currentPlist)

  try fixture.writePlist(try fixture.readPlist(), to: fixture.currentPlist)
  let duplicateLegacyAtCurrentPath = try fixture.run([
    "verify-helper-plist",
    "--helper", fixture.helper.path,
    "--plist", fixture.currentPlist.path,
  ])
  #expect(duplicateLegacyAtCurrentPath.status != 0)
  #expect(
    duplicateLegacyAtCurrentPath.output.contains(
      "service label and execution marker are invalid"
    )
  )

  try fixture.writePlist(currentGeneratedPlist, to: fixture.plist)
  let currentAtLegacyPath = try fixture.run([
    "verify-helper-plist",
    "--helper", fixture.helper.path,
    "--plist", fixture.plist.path,
  ])
  #expect(currentAtLegacyPath.status != 0)
  #expect(
    currentAtLegacyPath.output.contains("service label and execution marker are invalid")
  )

  let restoredLegacy = try fixture.run([
    "helper-plist",
    "--helper", fixture.helper.path,
    "--template", fixture.template.path,
    "--output", fixture.plist.path,
  ])
  #expect(restoredLegacy.status == 0)

  var extraCategory = constraint
  extraCategory["validation-category"] = 5
  var staleCDHash = constraint
  staleCDHash["cdhash"] = Data(repeating: 0xff, count: 20)
  var wrongIdentifier = constraint
  wrongIdentifier["signing-identifier"] = "com.example.other-helper"

  for mutated in [extraCategory, staleCDHash, wrongIdentifier] {
    plist["SpawnConstraint"] = mutated
    try fixture.writePlist(plist)
    let rejected = try fixture.run([
      "verify-helper-plist",
      "--helper", fixture.helper.path,
      "--plist", fixture.plist.path,
    ])
    #expect(rejected.status != 0)
    #expect(rejected.output.contains("SpawnConstraint does not match the current helper signature"))
  }
}

@Test func releaseManifestToolFailureIncludesChildDiagnostic() throws {
  let fixture = try ReleaseManifestToolFixture()
  try fixture.writePlist(["Label": "com.stillnotfree.sbm.helper"])

  let rejected = try fixture.run([
    "verify-helper-plist",
    "--helper", fixture.directory.appendingPathComponent("missing helper").path,
    "--plist", fixture.plist.path,
  ])
  #expect(rejected.status != 0)
  #expect(rejected.output.contains("release trust: codesign failed with status "))
  #expect(rejected.output.localizedCaseInsensitiveContains("no such file or directory"))
}

@Test func releaseToolDerivesUpdateProofFactsAndRejectsDuplicateCliFacts() throws {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let source = try String(
    contentsOf: packageRoot.appendingPathComponent("scripts/release-manifest.swift"),
    encoding: .utf8
  )
  #expect(source.contains("let manifest = try verifyDMG(dmg: dmg, coreDigestFile: coreDigestFile)"))
  #expect(source.contains("dmg.lastPathComponent == expectedName"))
  #expect(source.contains("sha256(of: dmg)"))
  #expect(source.contains("options: .atomic"))
  #expect(source.contains("SBM-\\(appVersion)-arm64.update.json"))

  let fixture = try ReleaseManifestToolFixture()
  let rejected = try fixture.run([
    "sign-update-artifact",
    "--dmg", fixture.directory.appendingPathComponent("SBM-2.0.0-arm64.dmg").path,
    "--core-digest-file", fixture.directory.appendingPathComponent("CoreBuildInfo.swift").path,
    "--asset-sha256", String(repeating: "a", count: 64),
  ])
  #expect(rejected.status != 0)
  #expect(rejected.output.contains("update artifact facts are derived from the verified DMG"))
}

@Test func releaseManifestVerifyDMGRequiresOwnedMountCleanup() throws {
  let probe = try ReleaseDMGProbe()

  let attachFailure = try probe.run(mode: .attachFailure)
  #expect(attachFailure.status != 0)
  #expect(attachFailure.events == ["attach"])
  #expect(!attachFailure.mountDirectoryExists)

  let verificationAndCleanupFailure = try probe.run(
    mode: .detachFailure, bundleFailure: true)
  #expect(verificationAndCleanupFailure.status != 0)
  #expect(verificationAndCleanupFailure.events == ["attach", "detach"])
  #expect(verificationAndCleanupFailure.output.contains("synthetic bundle verification failure"))
  #expect(verificationAndCleanupFailure.output.contains("detach cleanup failed"))
  #expect(verificationAndCleanupFailure.mountStillAttached)

  let verificationDetachFailure = try probe.run(mode: .detachFailure)
  #expect(verificationDetachFailure.status != 0)
  #expect(verificationDetachFailure.events == ["attach", "detach"])
  #expect(verificationDetachFailure.output.contains("detach failed"))
  #expect(verificationDetachFailure.mountStillAttached)

  let success = try probe.run(mode: .success)
  #expect(success.status == 0)
  #expect(success.events == ["attach", "detach"])
  #expect(!success.mountDirectoryExists)
  #expect(success.output.contains("DMG preserves the bounded signed manifest xattr."))

  let verifyBundleFailure = try probe.run(mode: .success, bundleFailure: true)
  #expect(verifyBundleFailure.status != 0)
  #expect(verifyBundleFailure.events == ["attach", "detach"])
  #expect(verifyBundleFailure.output.contains("synthetic bundle verification failure"))
  #expect(!verifyBundleFailure.mountDirectoryExists)
}

@Test func releaseManifestToolUsesSignedDigestWhenUnsignedDigestIsPresent() throws {
  let fixture = try ReleaseManifestToolFixture()
  let app = fixture.directory.appendingPathComponent("SBM.app", isDirectory: true)
  let executableDirectory = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
  let resourcesDirectory = app.appendingPathComponent("Contents/Resources", isDirectory: true)
  try FileManager.default.createDirectory(
    at: executableDirectory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: resourcesDirectory, withIntermediateDirectories: true)
  let appExecutable = executableDirectory.appendingPathComponent("SBM")
  try FileManager.default.copyItem(
    at: fixture.helper,
    to: appExecutable
  )
  let appSign = try TestProcessSupport.run(
    executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
    arguments: [
      "--force", "--sign", "-", "--identifier", "com.stillnotfree.sbm",
      "--options", "runtime", "--timestamp=none", appExecutable.path,
    ]
  )
  #expect(appSign.status == 0)

  let embeddedHelper = resourcesDirectory.appendingPathComponent("SBMHelper")
  try FileManager.default.copyItem(at: fixture.helper, to: embeddedHelper)
  let core = resourcesDirectory.appendingPathComponent("sing-box")
  try Data("custom core".utf8).write(to: core)
  let info = [
    "CFBundleIdentifier": "com.stillnotfree.sbm",
    "CFBundleShortVersionString": "1.1.15",
    "CFBundleVersion": "49",
  ]
  let infoData = try PropertyListSerialization.data(
    fromPropertyList: info,
    format: .xml,
    options: 0
  )
  try infoData.write(to: app.appendingPathComponent("Contents/Info.plist"))

  let coreDigest = SHA256.hash(data: try Data(contentsOf: core))
    .map { String(format: "%02x", $0) }
    .joined()
  let coreBuildInfo = fixture.directory.appendingPathComponent("CoreBuildInfo.swift")
  try """
  public enum CoreBuildInfo {
    public static let unsignedSHA256 = "\(String(repeating: "0", count: 64))"
    public static let signedSHA256 =
      "\(coreDigest)"
  }
  """.write(to: coreBuildInfo, atomically: true, encoding: .utf8)

  let rejected = try fixture.run([
    "verify-bundle",
    "--app", app.path,
    "--core-digest-file", coreBuildInfo.path,
  ])
  #expect(rejected.status != 0)
  #expect(rejected.output.contains("CurrentReleaseManifestFailure"))
  #expect(!rejected.output.contains("the packaged core digest is not the pinned digest"))

  let arbitraryPaths = try fixture.run([
    "verify-bundle",
    "--app", app.path,
    "--helper", fixture.helper.path,
    "--core", core.path,
    "--core-digest-file", coreBuildInfo.path,
  ])
  #expect(arbitraryPaths.status != 0)
  #expect(arbitraryPaths.output.contains("helper and core paths are derived"))

  let signingPaths = try fixture.run([
    "sign-attach-verify",
    "--app", app.path,
    "--helper", fixture.helper.path,
    "--core", core.path,
    "--core-digest-file", coreBuildInfo.path,
  ])
  #expect(signingPaths.status != 0)
  #expect(signingPaths.output.contains("helper and core paths are derived"))
}

private final class ReleaseManifestToolFixture {
  let directory: URL
  let tool: URL
  let helper: URL
  let template: URL
  let plist: URL
  let currentTemplate: URL
  let currentPlist: URL

  init() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("SBM-ReleaseManifestTool-\(UUID().uuidString)", isDirectory: true)
    tool = directory.appendingPathComponent("SBMReleaseManifestTool")
    helper = directory.appendingPathComponent("SBMHelper")
    template = directory.appendingPathComponent("legacy-template.plist")
    plist = directory.appendingPathComponent(HelperConstants.legacyDaemonPlistName)
    currentTemplate = directory.appendingPathComponent("current-template.plist")
    currentPlist = directory.appendingPathComponent(HelperConstants.daemonPlistName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let moduleCache = directory.appendingPathComponent("module-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: moduleCache, withIntermediateDirectories: true)
    let compile = try TestProcessSupport.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/swiftc"),
      arguments: [
        "-O",
        "-module-cache-path", moduleCache.path,
        packageRoot.appendingPathComponent("Sources/SBMShared/Protocol.swift").path,
        packageRoot.appendingPathComponent("Sources/SBMShared/ReleaseManifest.swift").path,
        packageRoot.appendingPathComponent("scripts/release-manifest.swift").path,
        "-o", tool.path,
      ],
      timeoutSeconds: 60
    )
    guard compile.status == 0 else { throw ReleaseManifestToolTestFailure.command(compile.output) }

    let runningTest = URL(fileURLWithPath: CommandLine.arguments[0])
    try FileManager.default.copyItem(at: runningTest, to: helper)
    let sign = try TestProcessSupport.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: [
        "--force", "--sign", "-",
        "--identifier", "com.stillnotfree.sbm.helper",
        "--options", "runtime",
        "--timestamp=none",
        helper.path,
      ]
    )
    guard sign.status == 0 else { throw ReleaseManifestToolTestFailure.command(sign.output) }

    let templateData = try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": "com.stillnotfree.sbm.helper",
        "BundleProgram": "Contents/Resources/SBMHelper",
        "EnvironmentVariables": ["SBM_HELPER_SERVICE_LABEL": "com.stillnotfree.sbm.helper"],
      ],
      format: .xml,
      options: 0
    )
    try templateData.write(to: template)

    let currentTemplateData = try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": HelperConstants.currentServiceLabel,
        "BundleProgram": "Contents/Resources/SBMHelper",
        "EnvironmentVariables": [
          HelperConstants.serviceLabelEnvironmentKey: HelperConstants.currentServiceLabel
        ],
        "Sockets": [
          "Listener": [
            "SockPathName": HelperConstants.socketPath,
            "SockPathOwner": 0,
            "SockPathGroup": 80,
            "SockPathMode": 0o660,
          ]
        ],
      ],
      format: .xml,
      options: 0
    )
    try currentTemplateData.write(to: currentTemplate)
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  func run(_ arguments: [String]) throws -> TestProcessResult {
    try TestProcessSupport.run(executableURL: tool, arguments: arguments)
  }

  func readPlist() throws -> [String: Any] {
    try readPlist(at: plist)
  }

  func readPlist(at url: URL) throws -> [String: Any] {
    guard
      let value = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url),
        format: nil
      ) as? [String: Any]
    else {
      throw ReleaseManifestToolTestFailure.invalidPlist
    }
    return value
  }

  func writePlist(_ value: [String: Any], to url: URL? = nil) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    try data.write(to: url ?? plist, options: .atomic)
  }

}

private enum ReleaseManifestToolTestFailure: Error {
  case command(String)
  case invalidPlist
}

private final class ReleaseDMGProbe {
  enum Mode: String {
    case success
    case attachFailure = "attach-failure"
    case detachFailure = "detach-failure"
  }

  struct Result {
    let status: Int32
    let output: String
    let events: [String]
    let mountDirectoryExists: Bool
    let mountStillAttached: Bool
  }

  private let root, tool, hdiutil, log, mountPathFile, dmg, coreDigest: URL

  init() throws {
    let files = FileManager.default
    root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("SBM-VerifyDMG-\(UUID().uuidString)", isDirectory: true)
    tool = root.appendingPathComponent("SBMReleaseManifestTool")
    hdiutil = root.appendingPathComponent("hdiutil")
    log = root.appendingPathComponent("hdiutil.log")
    mountPathFile = root.appendingPathComponent("mount-path.txt")
    dmg = root.appendingPathComponent("SBM-1.2.0-arm64.dmg")
    coreDigest = root.appendingPathComponent("CoreBuildInfo.swift")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("fixture dmg".utf8).write(to: dmg)
    try Data("fixture core digest".utf8).write(to: coreDigest)
    try writeTool(
      "hdiutil", at: hdiutil,
      contents: """
        #!/bin/sh
        set -eu
        case "$1" in
          attach)
            mountpoint=""
            shift
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-mountpoint" ]; then mountpoint="$2"; shift 2; else shift; fi
            done
            printf 'attach\\n' >> "$VERIFY_DMG_LOG"
            printf '%s' "$mountpoint" > "$VERIFY_DMG_MOUNT_PATH_FILE"
            if [ "$VERIFY_DMG_MODE" = "attach-failure" ]; then exit 51; fi
            printf 'attached\\n' > "$mountpoint/.attached"
            ;;
          detach)
            printf 'detach\\n' >> "$VERIFY_DMG_LOG"
            if [ "$VERIFY_DMG_MODE" = "detach-failure" ]; then
              echo 'synthetic detach failure' >&2
              exit 52
            fi
            rm -f "$3/.attached"
            ;;
          *) exit 53 ;;
        esac
        """)
    try compileTool()
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func run(mode: Mode, bundleFailure: Bool = false) throws -> Result {
    try? FileManager.default.removeItem(at: log)
    try? FileManager.default.removeItem(at: mountPathFile)
    var environment = ProcessInfo.processInfo.environment
    environment["VERIFY_DMG_LOG"] = log.path
    environment["VERIFY_DMG_MOUNT_PATH_FILE"] = mountPathFile.path
    environment["VERIFY_DMG_MODE"] = mode.rawValue
    environment["VERIFY_DMG_BUNDLE_FAILURE"] = bundleFailure ? "1" : "0"
    let run = try TestProcessSupport.run(
      executableURL: tool,
      arguments: ["verify-dmg", "--dmg", dmg.path, "--core-digest-file", coreDigest.path],
      currentDirectoryURL: root,
      environment: environment)
    let events =
      (try? String(contentsOf: log, encoding: .utf8))?
      .split(whereSeparator: \.isNewline).map(String.init) ?? []
    let mountURL = (try? String(contentsOf: mountPathFile, encoding: .utf8))
      .map { URL(fileURLWithPath: $0) }
    let path = mountURL ?? root.appendingPathComponent("mount-not-created")
    return Result(
      status: run.status,
      output: run.output,
      events: events,
      mountDirectoryExists: FileManager.default.fileExists(atPath: path.path),
      mountStillAttached: FileManager.default.fileExists(
        atPath: path.appendingPathComponent(".attached").path))
  }

  private func compileTool() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = packageRoot.appendingPathComponent("scripts/release-manifest.swift")
    var source = try String(contentsOf: sourceURL, encoding: .utf8)
    let bundleStart = try #require(source.range(of: "  private static func verifyBundle("))
    let dmgStart = try #require(
      source.range(
        of: "  private static func verifyDMG(", range: bundleStart.lowerBound..<source.endIndex))
    let replacement = """
        private static func verifyBundle(
          app: URL,
          helper: URL,
          core: URL,
          coreDigestFile: URL
        ) throws -> CurrentReleaseManifestPayload {
          if ProcessInfo.processInfo.environment["VERIFY_DMG_BUNDLE_FAILURE"] == "1" {
            throw ReleaseToolFailure.check("synthetic bundle verification failure.")
          }
          return CurrentReleaseManifestPayload(
            keyID: "probe",
            appVersion: "1.2.0",
            appBuild: "54",
            appBundleIdentifier: "com.stillnotfree.sbm",
            appCDHash: "0000000000000000000000000000000000000000",
            helperSigningIdentifier: "com.stillnotfree.sbm.helper",
            helperCDHash: "0000000000000000000000000000000000000000",
            helperRevision: HelperConstants.helperRevision,
            ipcProtocolVersion: HelperConstants.protocolVersion,
            coreSHA256: "\\(String(repeating: \"0\", count: 64))"
          )
        }

      """
    source.replaceSubrange(bundleStart.lowerBound..<dmgStart.lowerBound, with: replacement)
    source = source.replacingOccurrences(
      of: "FileManager.default.temporaryDirectory",
      with: "URL(fileURLWithPath: \"\(root.path)\", isDirectory: true)")
    source = source.replacingOccurrences(
      of: "\"/usr/bin/hdiutil\"", with: "\"\(hdiutil.path)\"")
    let transformedSource = root.appendingPathComponent("release-manifest-probe.swift")
    try Data(source.utf8).write(to: transformedSource)
    let moduleCache = root.appendingPathComponent("module-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: moduleCache, withIntermediateDirectories: true)
    let result = try TestProcessSupport.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/swiftc"),
      arguments: [
        "-O", "-module-cache-path", moduleCache.path,
        packageRoot.appendingPathComponent("Sources/SBMShared/Protocol.swift").path,
        packageRoot.appendingPathComponent("Sources/SBMShared/ReleaseManifest.swift").path,
        transformedSource.path, "-o", tool.path,
      ],
      timeoutSeconds: 60,
      currentDirectoryURL: packageRoot
    )
    guard result.status == 0 else {
      throw ReleaseManifestToolTestFailure.command(result.output)
    }
  }

  private func writeTool(_ name: String, at url: URL, contents: String) throws {
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

}
