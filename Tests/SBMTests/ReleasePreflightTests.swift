import Foundation
import Testing

@Suite(.serialized)
struct ReleasePreflightTests {
  @Test func releasePreflightMetadataSucceedsForConsistentFixture() throws {
    let fixture = try ReleasePreflightFixture()
    let result = try fixture.run(tag: "v1.1.11")

    #expect(result.status == 0)
    #expect(result.output.contains("Metadata OK: .codex contains no tracked files."))
    #expect(
      result.output.contains("Metadata OK: Package and Make packaging inputs are arm64-only."))
  }

  @Test func releasePreflightRejectsInvalidTag() throws {
    let fixture = try ReleasePreflightFixture()
    let result = try fixture.run(tag: "1.1.11")

    #expect(result.status != 0)
    #expect(result.output.contains("release tag must use vMAJOR.MINOR.PATCH"))
  }

  @Test func releasePreflightRejectsTagThatDiffersFromMakefile() throws {
    let fixture = try ReleasePreflightFixture()
    let result = try fixture.run(tag: "v1.1.12")

    #expect(result.status != 0)
    #expect(result.output.contains("does not match Makefile APP_VERSION 1.1.11"))
  }

  @Test func releasePreflightRejectsMakefileVersionMismatch() throws {
    let fixture = try ReleasePreflightFixture()
    try fixture.write("APP_VERSION := 1.1.12\n" + fixture.packagingInputs, to: "Makefile")
    let result = try fixture.run(tag: "v1.1.11")

    #expect(result.status != 0)
    #expect(result.output.contains("does not match Makefile APP_VERSION 1.1.12"))
  }

  @Test func releasePreflightRejectsPlistVersionMismatch() throws {
    let fixture = try ReleasePreflightFixture()
    try fixture.write(fixture.infoPlist(version: "1.1.12"), to: "Resources/Info.plist")
    let result = try fixture.run(tag: "v1.1.11")

    #expect(result.status != 0)
    #expect(
      result.output.contains(
        "does not match Resources/Info.plist CFBundleShortVersionString 1.1.12"))
  }

  @Test func releasePreflightRejectsCoreBuildInfoMismatch() throws {
    let fixture = try ReleasePreflightFixture()
    try fixture.write(
      fixture.coreBuildInfo(version: "1.13.19"), to: "Sources/SBMShared/CoreBuildInfo.swift")
    let result = try fixture.run(tag: "v1.1.11")

    #expect(result.status != 0)
    #expect(
      result.output.contains(
        "CoreBuildInfo version 1.13.19 does not match Core.lock CORE_VERSION 1.13.18"))
  }

  @Test func releasePreflightRejectsMalformedCoreDigest() throws {
    let fixture = try ReleasePreflightFixture()
    try fixture.write(
      """
      CORE_VERSION := 1.13.18
      CORE_ARCHIVE_SHA256 := NOT-A-DIGEST
      CORE_BINARY_SHA256 := 020ecf20d3faa9ec3e917762085f0581aafbd3dd87a69573ae7345fc66fabc7f
      """,
      to: "Core.lock"
    )
    let result = try fixture.run(tag: "v1.1.11")

    #expect(result.status != 0)
    #expect(result.output.contains("Core.lock CORE_ARCHIVE_SHA256 must be a lowercase"))
  }

  @Test func releasePreflightRejectsTrackedCodexFiles() throws {
    let fixture = try ReleasePreflightFixture()
    try fixture.write("role = \"test\"\n", to: ".codex/agent.toml")
    try fixture.git(["add", "--", ".codex/agent.toml"])
    let result = try fixture.run(tag: "v1.1.11")

    #expect(result.status != 0)
    #expect(result.output.contains("tracked .codex files are forbidden"))
  }

  @Test func fullReleasePreflightChecksBuiltVersionsAndArchitectures() throws {
    let fixture = try ReleasePreflightFixture()
    let environment = try fixture.installFullModeTools()
    let result = try fixture.run(tag: "v1.1.11", metadataOnly: false, environment: environment)

    #expect(result.status == 0)
    #expect(
      result.output.contains(
        "Built artifact OK: Info.plist marketing and build versions match the release."))
    #expect(result.output.contains("Built artifact OK: app executable is arm64-only."))
    #expect(result.output.contains("Built artifact OK: helper executable is arm64-only."))
    #expect(result.output.contains("Built artifact OK: bundled sing-box is arm64-only."))
  }

  @Test func fullReleasePreflightRejectsNonArm64BuiltArtifact() throws {
    let fixture = try ReleasePreflightFixture()
    var environment = try fixture.installFullModeTools()
    environment["PREFLIGHT_LIPO_ARCHS"] = "x86_64"
    let result = try fixture.run(tag: "v1.1.11", metadataOnly: false, environment: environment)

    #expect(result.status != 0)
    #expect(result.output.contains("built app executable must be arm64-only"))
  }

  @Test func fullReleasePreflightRejectsBuiltVersionMismatch() throws {
    let fixture = try ReleasePreflightFixture()
    var environment = try fixture.installFullModeTools()
    environment["PREFLIGHT_BUILT_VERSION"] = "1.1.12"
    let result = try fixture.run(tag: "v1.1.11", metadataOnly: false, environment: environment)

    #expect(result.status != 0)
    #expect(
      result.output.contains("built app CFBundleShortVersionString must match release tag v1.1.11"))
  }

  @Test func fullReleasePreflightRejectsBuiltBuildNumberMismatch() throws {
    let fixture = try ReleasePreflightFixture()
    var environment = try fixture.installFullModeTools()
    environment["PREFLIGHT_BUILT_BUILD"] = "50"
    let result = try fixture.run(tag: "v1.1.11", metadataOnly: false, environment: environment)

    #expect(result.status != 0)
    #expect(
      result.output.contains(
        "built app CFBundleVersion must match Resources/Info.plist CFBundleVersion 49"))
  }
}

private final class ReleasePreflightFixture {
  let root: URL
  let packagingInputs = """
    CORE_ARCHIVE := .vendor/sing-box-$(CORE_VERSION)-darwin-arm64.tar.gz
    BUILD_DIR := .build/arm64-apple-macosx/release
    DMG := $(DIST_DIR)/$(APP_NAME)-$(APP_VERSION)-arm64.dmg
    build:
    \tswift build -c release --arch arm64
    """

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SBMReleasePreflight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try write("APP_VERSION := 1.1.11\n" + packagingInputs, to: "Makefile")
    try write(
      """
      CORE_VERSION := 1.13.18
      CORE_ARCHIVE_SHA256 := 9fbc05946b584423457a2778035e0cee2d9b239a4af5ae1932d9b79991149107
      CORE_BINARY_SHA256 := 020ecf20d3faa9ec3e917762085f0581aafbd3dd87a69573ae7345fc66fabc7f
      """,
      to: "Core.lock"
    )
    try write(infoPlist(version: "1.1.11"), to: "Resources/Info.plist")
    try write(coreBuildInfo(version: "1.13.18"), to: "Sources/SBMShared/CoreBuildInfo.swift")
    try write(
      "enum NativeCapabilityPolicy { static let reviewedCoreVersion = \"1.13.18\" }\n",
      to: "Sources/SBMHelper/NativeCapabilityPolicy.swift"
    )
    try write("let package = Package(platforms: [.macOS(.v26)])\n", to: "Package.swift")
    try git(["init", "-q"])
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func run(
    tag: String,
    metadataOnly: Bool = true,
    environment: [String: String]? = nil
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [
      FileManager.default.currentDirectoryPath + "/scripts/release-preflight.swift",
      "--root",
      root.path,
      "--tag",
      tag,
    ]
    if metadataOnly {
      process.arguments?.append("--metadata-only")
    }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
  }

  func write(_ contents: String, to relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
  }

  func git(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = root
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  func installFullModeTools() throws -> [String: String] {
    let tools = root.appendingPathComponent(".preflight-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try writeTool("swift", contents: "#!/bin/sh\nexit 0\n")
    try writeTool("plutil", contents: "#!/bin/sh\nexit 0\n")
    try writeTool("git", contents: "#!/bin/sh\nexit 0\n")
    try writeTool("codesign", contents: "#!/bin/sh\nexit 0\n")
    try writeTool(
      "xcrun",
      contents: """
        #!/bin/sh
        if [ "$1" = "lipo" ]; then
          printf '%s\\n' "${PREFLIGHT_LIPO_ARCHS:-arm64}"
        fi
        exit 0
        """
    )
    try writeTool(
      "make",
      contents: """
        #!/bin/sh
        mkdir -p dist/SBM.app/Contents/MacOS dist/SBM.app/Contents/Resources
        cp Resources/Info.plist dist/SBM.app/Contents/Info.plist
        if [ -n "${PREFLIGHT_BUILT_VERSION:-}" ]; then
          /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PREFLIGHT_BUILT_VERSION" dist/SBM.app/Contents/Info.plist
        fi
        if [ -n "${PREFLIGHT_BUILT_BUILD:-}" ]; then
          /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PREFLIGHT_BUILT_BUILD" dist/SBM.app/Contents/Info.plist
        fi
        : > dist/SBM.app/Contents/MacOS/SBM
        : > dist/SBM.app/Contents/Resources/SBMHelper
        : > dist/SBM.app/Contents/Resources/sing-box
        exit 0
        """
    )
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = tools.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
    return environment
  }

  private func writeTool(_ name: String, contents: String) throws {
    let url = root.appendingPathComponent(".preflight-bin/\(name)")
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  func infoPlist(version: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleShortVersionString</key><string>\(version)</string>
      <key>CFBundleVersion</key><string>49</string>
    </dict></plist>
    """
  }

  func coreBuildInfo(version: String) -> String {
    """
    public enum CoreBuildInfo {
      public static let version = "\(version)"
      public static let signedSHA256 =
        "0c93ecb8f627955c221eef8b2acb93abf53a7eab56ab9592ac3d5796335f3611"
    }
    """
  }
}
