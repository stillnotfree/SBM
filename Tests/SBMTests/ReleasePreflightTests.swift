import AppKit
import Foundation
import ImageIO
import Testing

@Suite(.serialized)
struct ReleasePreflightTests {
  @Test func releasePreflightMetadataSucceedsForConsistentFixture() throws {
    let fixture = try ReleasePreflightFixture()
    let result = try fixture.run(tag: "v1.1.11")

    #expect(result.status == 0)
    #expect(result.output.contains("Metadata OK: .codex contains no tracked files."))
    #expect(
      result.output.contains("Metadata OK: pinned core build and release trust inputs are valid."))
  }

  @Test func releasePreflightBindsBuildInfoToCompilerNotSourceDirective() throws {
    let fixture = try ReleasePreflightFixture()
    #expect(fixture.coreLock.contains("CORE_GO_DIRECTIVE := 1.24.1"))
    #expect(fixture.coreLock.contains("CORE_GO_VERSION := 1.24.2"))
    #expect(try fixture.run(tag: "v1.1.11").status == 0)

    try fixture.write(
      fixture.coreBuildInfo(version: "1.13.18", overrides: ["goVersion": "go1.24.1"]),
      to: "Sources/SBMShared/CoreBuildInfo.swift")
    let result = try fixture.run(tag: "v1.1.11")

    #expect(result.status != 0)
    #expect(result.output.contains("CoreBuildInfo goVersion does not match Core.lock."))
  }

  @Test func releasePreflightRequiresLockedSourceAndBuildRecipeInputs() throws {
    let checks = [
      (
        "test \"$$source_go\" = \"$(CORE_GO_DIRECTIVE)\"",
        "test \"$$source_go\" = \"$(CORE_GO_VERSION)\""
      ),
      ("GOTOOLCHAIN=go$(CORE_GO_VERSION)", "GOTOOLCHAIN=go$(CORE_GO_DIRECTIVE)"),
      ("-mod=readonly", "-mod=mod"),
      ("-trimpath", "-buildvcs=false"),
      ("-tags \"$(CORE_BUILD_TAGS)\"", "-tags with_quic"),
    ]
    for (required, replacement) in checks {
      let fixture = try ReleasePreflightFixture()
      let makefile = "APP_VERSION := 1.1.11\n" + fixture.packagingInputs
      try fixture.write(
        makefile.replacingOccurrences(of: required, with: replacement), to: "Makefile")
      let result = try fixture.run(tag: "v1.1.11")

      #expect(result.status != 0)
      #expect(
        result.output.contains(
          "pinned core build and release proof inputs must match the current trust contract."))
    }
  }

  @Test func checkedInDMGPresentationUsesCompactRetinaGeometryAndBackgroundMetadata() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let appleScript = try String(
      contentsOf: root.appendingPathComponent("scripts/configure-dmg.applescript"),
      encoding: .utf8)
    #expect(appleScript.contains("set bounds of targetWindow to {200, 80, 550, 615}"))
    #expect(
      appleScript.contains(
        "if (bounds of targetWindow) is not {200, 80, 550, 615} then error"))
    #expect(appleScript.contains("set icon size of icon view options of targetWindow to 88"))
    #expect(appleScript.contains("set text size of icon view options of targetWindow to 12"))
    #expect(appleScript.contains("set position of item \"SBM.app\" of targetDisk to {175, 112}"))
    #expect(
      appleScript.contains("set position of item \"Applications\" of targetDisk to {175, 346}"))

    let backgroundURL = root.appendingPathComponent("Resources/DMG/background.png")
    guard let source = CGImageSourceCreateWithURL(backgroundURL as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      Issue.record("ImageIO could not read the checked-in DMG background properties.")
      return
    }
    #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 700)
    #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 950)
    let dpiWidth = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
    let dpiHeight = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 0
    #expect(abs(dpiWidth - 144) < 0.5)
    #expect(abs(dpiHeight - 144) < 0.5)
    let logicalBackgroundWidth = 700.0 / (dpiWidth / 72)
    let logicalBackgroundHeight = 950.0 / (dpiHeight / 72)
    let conservativeChromeAllowance = 60.0  // 36 pt title area plus 24 pt path bar.
    let estimatedIconViewportHeight = 535.0 - conservativeChromeAllowance
    #expect(abs(logicalBackgroundWidth - 350) < 0.5)
    #expect(abs(logicalBackgroundHeight - 475) < 0.5)
    // macOS Finder title/path chrome can vary; this static approximation does not prove no scrolling or full image coverage.
    #expect(abs(estimatedIconViewportHeight - logicalBackgroundHeight) <= 1)

    guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: backgroundURL)) else {
      Issue.record("AppKit could not decode the checked-in DMG background pixels.")
      return
    }
    var arrowPixelCount = 0
    var stemPixelCount = 0
    var leftWingPixelCount = 0
    var rightWingPixelCount = 0
    var tipPixelCount = 0
    var minX = Int.max
    var maxX = Int.min
    var minY = Int.max
    var maxY = Int.min
    for y in 420..<551 {
      for x in 320..<381 {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        let meanChannel =
          (color.redComponent + color.greenComponent + color.blueComponent) * 255 / 3
        guard meanChannel < 225 else { continue }

        arrowPixelCount += 1
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
        if (347..<354).contains(x) && (450..<505).contains(y) {
          stemPixelCount += 1
        }
        if (335..<349).contains(x) && (500..<528).contains(y) {
          leftWingPixelCount += 1
        }
        if (352..<366).contains(x) && (500..<528).contains(y) {
          rightWingPixelCount += 1
        }
        if (348..<353).contains(x) && (520..<531).contains(y) {
          tipPixelCount += 1
        }
      }
    }
    #expect(arrowPixelCount >= 120 && arrowPixelCount <= 450)
    guard arrowPixelCount > 0 else {
      Issue.record("Could not detect a downward arrow in the checked-in DMG background.")
      return
    }
    #expect(maxX - minX <= 40)
    #expect(minY >= 430 && minY <= 465)
    #expect(maxY >= 515 && maxY <= 535)
    #expect(stemPixelCount >= 20)
    #expect(leftWingPixelCount >= 20)
    #expect(rightWingPixelCount >= 20)
    #expect(tipPixelCount >= 5)

    let scale = 2.0
    let arrowCenterX = Double(minX + maxX) / 2
    let arrowCenterY = Double(minY + maxY) / 2
    let finalIconAxis = 175 * scale
    let iconHalfHeight = 88.0 / 2
    let appLabelClearance = 4.0
    let appLabelLineHeight = 12.0 + 2.0
    let appLabelBottom = 112.0 + iconHalfHeight + appLabelClearance + appLabelLineHeight
    let applicationsIconTop = 346.0 - iconHalfHeight
    let opticalGapMidpoint = (appLabelBottom + applicationsIconTop) / 2
    #expect(abs(arrowCenterX - finalIconAxis) <= 3)
    #expect(abs(arrowCenterY - opticalGapMidpoint * scale) <= 20)
  }

  @Test func actualMakeDMGRecipeBuildsAndSelfVerifiesInTheApprovedOrder() throws {
    let success = try DMGRecipeProbe().run()
    #expect(success.status == 0)
    #expect(
      success.events == [
        "ditto", "hdiutil:create", "hdiutil:attach", "osascript", "sync",
        "hdiutil:detach:1", "hdiutil:convert", "shasum", "release:sign-update-artifact",
        "release:verify-update-artifact:internal",
      ])
    #expect(!success.workdirExists)
  }

  @Test func actualMakeDMGRecipePreservesDirectoryAndDanglingSymlinkCollisions() throws {
    for collision in [DMGRecipeProbe.Collision.directory, .danglingSymlink] {
      let result = try DMGRecipeProbe().run(collision: collision)
      #expect(result.status != 0)
      #expect(!result.events.contains("hdiutil:attach"))
      #expect(result.foreignEntryStillExists)
    }
  }

  @Test func actualMakeDMGRecipeHandlesAttachAndFinderFailures() throws {
    let attachFailure = try DMGRecipeProbe().run(mode: .attachFailure)
    #expect(attachFailure.status != 0)
    #expect(attachFailure.detachCount == 0)
    #expect(!attachFailure.events.contains("hdiutil:convert"))

    let finderFailure = try DMGRecipeProbe().run(mode: .finderFailure)
    #expect(finderFailure.status != 0)
    #expect(finderFailure.detachCount == 1)
    #expect(!finderFailure.mountStillOwned)
    #expect(!finderFailure.workdirExists)
  }

  @Test func actualMakeDMGRecipeRetriesInitialDetachFailureThenStops() throws {
    let detachRetry = try DMGRecipeProbe().run(mode: .firstDetachFailure)
    #expect(detachRetry.status != 0)
    #expect(detachRetry.detachCount == 2)
    #expect(!detachRetry.mountStillOwned)
    #expect(!detachRetry.workdirExists)
    #expect(!detachRetry.events.contains("hdiutil:convert"))
  }

  @Test func actualMakeDMGRecipePreservesRecoveryImageAfterRepeatedDetachFailure() throws {
    let repeatedDetachFailure = try DMGRecipeProbe().run(mode: .detachFailure)
    #expect(repeatedDetachFailure.status != 0)
    #expect(repeatedDetachFailure.detachCount == 2)
    #expect(repeatedDetachFailure.mountStillOwned)
    #expect(repeatedDetachFailure.workdirExists)
    #expect(repeatedDetachFailure.backingImageExists)
    #expect(repeatedDetachFailure.output.contains("recovery"))
    #expect(!repeatedDetachFailure.events.contains("hdiutil:convert"))
  }

  @Test func actualMakeDMGRecipeStopsAfterConvertFailure() throws {
    let convertFailure = try DMGRecipeProbe().run(mode: .convertFailure)
    #expect(convertFailure.status != 0)
    #expect(convertFailure.detachCount == 1)
    #expect(!convertFailure.events.contains(where: { $0.hasPrefix("release:") }))
  }

  @Test func actualMakeDMGRecipeStopsAfterSigningOrProofFailure() throws {
    let signingFailure = try DMGRecipeProbe().run(mode: .signingFailure)
    #expect(signingFailure.status != 0)
    #expect(signingFailure.events.contains("release:sign-update-artifact"))
    #expect(!signingFailure.events.contains("release:verify-update-artifact:internal"))
    #expect(!signingFailure.events.contains("release:verify-update-artifact:external"))

    let proofFailure = try DMGRecipeProbe().run(mode: .proofFailure)
    #expect(proofFailure.status != 0)
    #expect(proofFailure.events.contains("release:sign-update-artifact"))
    #expect(proofFailure.events.contains("release:verify-update-artifact:internal"))
    #expect(!proofFailure.events.contains("release:verify-update-artifact:external"))
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

  @Test func releasePreflightRejectsMissingAndDuplicateCoreRecipeFields() throws {
    let fixture = try ReleasePreflightFixture()
    let revision = "CORE_REVISION := \(String(repeating: "a", count: 40))"
    let invalidLocks = [
      fixture.coreLock.replacingOccurrences(of: revision + "\n", with: ""),
      fixture.coreLock + "\nCORE_VERSION := 1.13.18\n",
    ]
    for lock in invalidLocks {
      let caseFixture = try ReleasePreflightFixture()
      try caseFixture.write(lock, to: "Core.lock")
      let result = try caseFixture.run(tag: "v1.1.11")
      #expect(result.status != 0)
      #expect(result.output.contains("Core.lock"))
    }
  }

  @Test func releasePreflightRejectsMalformedCoreRecipeValues() throws {
    let invalidCases = [
      ("CORE_VERSION := 1.13.18", "CORE_VERSION := 01.13.18", "stable semantic version"),
      (
        "CORE_REVISION := \(String(repeating: "a", count: 40))", "CORE_REVISION := abc",
        "40 lowercase"
      ),
      ("CORE_GO_DIRECTIVE := 1.24.1", "CORE_GO_DIRECTIVE := 1.24", "CORE_GO_DIRECTIVE"),
      ("CORE_GO_VERSION := 1.24.2", "CORE_GO_VERSION := 1.25", "major.minor.patch"),
      ("CORE_BUILD_TAGS := with_quic,with_utls", "CORE_BUILD_TAGS := ", "non-empty"),
      (
        "CORE_BUILD_TAGS := with_quic,with_utls", "CORE_BUILD_TAGS := with_quic,with_quic",
        "unique tags"
      ),
      ("CORE_CGO_ENABLED := 1", "CORE_CGO_ENABLED := 2", "must be 0 or 1"),
      (
        "CORE_LDFLAGS := -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0",
        "CORE_LDFLAGS := ", "must not be empty"
      ),
    ]
    for (valid, invalid, expected) in invalidCases {
      let fixture = try ReleasePreflightFixture()
      let lock = fixture.coreLock.replacingOccurrences(of: valid, with: invalid)
      try fixture.write(lock, to: "Core.lock")
      let result = try fixture.run(tag: "v1.1.11")
      #expect(result.status != 0)
      #expect(result.output.contains(expected))
    }
  }

  @Test func releasePreflightRejectsCoreBuildInfoRecipeMismatchAndBadHashes() throws {
    let cases: [(String, String, String)] = [
      ("revision", String(repeating: "b", count: 40), "CoreBuildInfo revision does not match"),
      ("goVersion", "go1.25.2", "CoreBuildInfo goVersion does not match"),
      ("buildTags", "with_quic", "CoreBuildInfo buildTags does not match"),
      ("cgo", "disabled", "CoreBuildInfo cgo does not match"),
      ("linkerFlags", "-X other=value", "CoreBuildInfo linkerFlags does not match"),
      ("unsignedSHA256", "invalid", "unsignedSHA256 must be a lowercase"),
      ("signedSHA256", "invalid", "signedSHA256 must be a lowercase"),
    ]
    for (field, value, expected) in cases {
      let fixture = try ReleasePreflightFixture()
      try fixture.write(
        fixture.coreBuildInfo(version: "1.13.18", overrides: [field: value]),
        to: "Sources/SBMShared/CoreBuildInfo.swift"
      )
      let result = try fixture.run(tag: "v1.1.11")
      #expect(result.status != 0)
      #expect(result.output.contains(expected))
    }
  }

  @Test func releasePreflightRejectsTrackedCodexFiles() throws {
    let fixture = try ReleasePreflightFixture()
    try fixture.write("role = \"test\"\n", to: ".codex/agent.toml")
    try fixture.git(["add", "--", ".codex/agent.toml"])
    let result = try fixture.run(tag: "v1.1.11")

    #expect(result.status != 0)
    #expect(result.output.contains("tracked .codex files are forbidden"))
  }

  @Test func releasePreflightDrainsCapturedOutputBeforeWaitingForTheChild() throws {
    let fixture = try ReleasePreflightFixture()
    let codexDirectory = fixture.root.appending(path: ".codex")
    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    for index in 0..<3_000 {
      let file = codexDirectory.appending(path: "captured-output-\(index).md")
      try Data().write(to: file)
    }
    try fixture.git(["add", "--", ".codex"])

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
    #expect(
      result.output.contains(
        "Built artifact OK: helper plist does not abandon its process group."))
    #expect(
      result.output.contains(
        "Final DMG presentation OK: SBM.app, Applications link, tracked background"))
    #expect(result.output.contains("preserved checkpointed CoreBuildInfo"))
    #expect(result.output.contains("SBMReleaseManifestTool signed update proof"))
    #expect(result.output.contains("SBMReleaseManifestTool verified update proof"))
  }

  @Test func fullReleasePreflightRejectsFinalDmgBackgroundMismatch() throws {
    let fixture = try ReleasePreflightFixture()
    var environment = try fixture.installFullModeTools()
    environment["PREFLIGHT_DMG_BAD_BACKGROUND"] = "1"
    let result = try fixture.run(tag: "v1.1.11", metadataOnly: false, environment: environment)

    #expect(result.status != 0)
    #expect(result.output.contains("final DMG background digest does not match the tracked asset."))
  }

  @Test func fullReleasePreflightRejectsCoreBuildInfoChangedByBuild() throws {
    let fixture = try ReleasePreflightFixture()
    var environment = try fixture.installFullModeTools()
    environment["PREFLIGHT_CHANGE_CORE_BUILD_INFO"] = "1"
    let result = try fixture.run(tag: "v1.1.11", metadataOnly: false, environment: environment)

    #expect(result.status != 0)
    #expect(result.output.contains("changed checkpointed CoreBuildInfo"))
  }

  @Test func fullReleasePreflightPropagatesCanonicalArm64Rejection() throws {
    let fixture = try ReleasePreflightFixture()
    var environment = try fixture.installFullModeTools()
    environment["PREFLIGHT_LIPO_ARCHS"] = "x86_64"
    let result = try fixture.run(tag: "v1.1.11", metadataOnly: false, environment: environment)

    #expect(result.status != 0)
    #expect(result.output.contains("release verifier requires arm64-only artifacts"))
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

  @Test func fullReleasePreflightRejectsAbandonedHelperProcessGroupInBuiltArtifact() throws {
    let fixture = try ReleasePreflightFixture()
    try fixture.write(
      fixture.helperPlist(abandonProcessGroup: true),
      to: "Resources/com.stillnotfree.sbm.helper.plist")
    let environment = try fixture.installFullModeTools()
    let result = try fixture.run(tag: "v1.1.11", metadataOnly: false, environment: environment)

    #expect(result.status != 0)
    #expect(
      result.output.contains(
        "built helper plist must omit AbandonProcessGroup or set it false."))
  }

  @Test func fullReleasePreflightPropagatesCanonicalSpawnConstraintRejection() throws {
    let fixture = try ReleasePreflightFixture()
    try fixture.write(
      fixture.helperPlist(cdHashByte: 0xdd),
      to: "Resources/com.stillnotfree.sbm.helper.plist"
    )
    var environment = try fixture.installFullModeTools()
    environment["PREFLIGHT_REJECT_SPAWN"] = "1"
    let result = try fixture.run(tag: "v1.1.11", metadataOnly: false, environment: environment)

    #expect(result.status != 0)
    #expect(result.output.contains("SpawnConstraint does not match the current helper signature"))
  }
}

private struct DMGRecipeProbe {
  enum Mode: String {
    case success
    case attachFailure = "attach-failure"
    case finderFailure = "finder-failure"
    case firstDetachFailure = "first-detach-failure"
    case detachFailure = "detach-failure"
    case convertFailure = "convert-failure"
    case signingFailure = "signing-failure"
    case proofFailure = "proof-failure"
  }

  enum Collision {
    case directory
    case danglingSymlink
  }

  struct Result {
    let status: Int32
    let output: String
    let events: [String]
    let detachCount: Int
    let mountStillOwned: Bool
    let workdirExists: Bool
    let backingImageExists: Bool
    let foreignEntryStillExists: Bool
  }

  func run(mode: Mode = .success, collision: Collision? = nil) throws -> Result {
    let files = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("SBM-DMGRecipe-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    let log = root.appendingPathComponent("events.log")
    let mountpoint = root.appendingPathComponent("mountpoint", isDirectory: true)
    let mountFile = root.appendingPathComponent("mountpoint.txt")
    let backingFile = root.appendingPathComponent("backing-image.txt")
    let counterFile = root.appendingPathComponent("detach-count.txt")
    let foreignMarker = mountpoint.appendingPathComponent("foreign-entry")
    try files.createDirectory(at: bin, withIntermediateDirectories: true)
    try files.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }

    if let collision {
      switch collision {
      case .directory:
        try files.createDirectory(at: mountpoint, withIntermediateDirectories: false)
        try Data("foreign".utf8).write(to: foreignMarker)
      case .danglingSymlink:
        try files.createSymbolicLink(
          atPath: mountpoint.path,
          withDestinationPath: root.appendingPathComponent("missing-target").path)
      }
    }

    try writeTool(
      "hdiutil", to: bin,
      contents: """
        #!/bin/sh
        set -eu
        command="$1"
        shift
        if [ "$command" != "detach" ]; then printf 'hdiutil:%s\\n' "$command" >> "$RECIPE_LOG"; fi
        case "$command" in
          create)
            last=""
            for value in "$@"; do last="$value"; done
            printf '%s' "$last" > "$RECIPE_BACKING_PATH"
            mkdir -p "$(dirname "$last")"
            : > "$last"
            ;;
          attach)
            mountpoint=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-mountpoint" ]; then mountpoint="$2"; shift 2; else shift; fi
            done
            if [ "$RECIPE_MODE" = "attach-failure" ]; then exit 41; fi
            mkdir -p "$mountpoint"
            printf 'owned\\n' > "$mountpoint/.operation-owned"
            printf '%s' "$mountpoint" > "$RECIPE_MOUNT_PATH"
            ;;
          detach)
            mountpoint="$1"
            count=0
            if [ -f "$RECIPE_DETACH_COUNT" ]; then count="$(cat "$RECIPE_DETACH_COUNT")"; fi
            count=$((count + 1))
            printf '%s' "$count" > "$RECIPE_DETACH_COUNT"
            printf 'hdiutil:detach:%s\\n' "$count" >> "$RECIPE_LOG"
            if [ "$RECIPE_MODE" = "detach-failure" ] || { [ "$RECIPE_MODE" = "first-detach-failure" ] && [ "$count" -eq 1 ]; }; then
              echo 'synthetic detach failure' >&2
              exit 42
            fi
            rm -f "$mountpoint/.operation-owned"
            rmdir "$mountpoint"
            ;;
          convert)
            if [ "$RECIPE_MODE" = "convert-failure" ]; then exit 43; fi
            output=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi
            done
            mkdir -p "$(dirname "$output")"
            : > "$output"
            ;;
          *) exit 44 ;;
        esac
        """)
    try writeTool(
      "ditto", to: bin,
      contents: """
        #!/bin/sh
        printf 'ditto\\n' >> "$RECIPE_LOG"
        """)
    try writeTool(
      "osascript", to: bin,
      contents: """
        #!/bin/sh
        printf 'osascript\\n' >> "$RECIPE_LOG"
        if [ "$RECIPE_MODE" = "finder-failure" ]; then exit 45; fi
        """)
    try writeTool(
      "sync", to: bin,
      contents: """
        #!/bin/sh
        printf 'sync\\n' >> "$RECIPE_LOG"
        """)
    try writeTool(
      "shasum", to: bin,
      contents: """
        #!/bin/sh
        printf 'shasum\\n' >> "$RECIPE_LOG"
        printf '%s  %s\\n' '0000000000000000' "$3"
        """)
    try writeTool(
      "SBMReleaseManifestTool", to: bin,
      contents: """
        #!/bin/sh
        case "$1" in
          sign-update-artifact)
            printf 'release:sign-update-artifact\\n' >> "$RECIPE_LOG"
            if [ "$RECIPE_MODE" = "signing-failure" ]; then exit 46; fi
            printf 'release:verify-update-artifact:internal\\n' >> "$RECIPE_LOG"
            if [ "$RECIPE_MODE" = "proof-failure" ]; then exit 47; fi
            ;;
          verify-update-artifact)
            printf 'release:verify-update-artifact:external\\n' >> "$RECIPE_LOG"
            ;;
        esac
        """)

    let environmentRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let sourceMakefile = environmentRoot.appendingPathComponent("Makefile")
    var makefile = try String(contentsOf: sourceMakefile, encoding: .utf8)
    let buildDirectoryAssignment =
      "BUILD_DIR := $(shell swift build -c release --arch arm64 --show-bin-path --disable-sandbox 2>/dev/null)"
    guard makefile.components(separatedBy: buildDirectoryAssignment).count == 2 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    makefile = makefile.replacingOccurrences(
      of: buildDirectoryAssignment,
      with: "BUILD_DIR := \(root.appendingPathComponent("build").path)")
    let probeMakefile = root.appendingPathComponent("Makefile")
    try Data(makefile.utf8).write(to: probeMakefile)
    let escapedAppName = "../../private/tmp/\(root.lastPathComponent)/mountpoint"
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = bin.path + ":/usr/bin:/bin"
    environment["RECIPE_LOG"] = log.path
    environment["RECIPE_MODE"] = mode.rawValue
    environment["RECIPE_BACKING_PATH"] = backingFile.path
    environment["RECIPE_MOUNT_PATH"] = mountFile.path
    environment["RECIPE_DETACH_COUNT"] = counterFile.path
    let makeArguments = [
      "--no-print-directory", "-n", "-o", "app", "-f",
      probeMakefile.path, "dmg",
      "BUILD_DIR=\(root.appendingPathComponent("build").path)",
      "APP_NAME=\(escapedAppName)", "APP_VERSION=1.2.0", "BUNDLE_NAME=SBM",
      "DIST_DIR=\(dist.path)", "DMG=\(dist.appendingPathComponent("final.dmg").path)",
      "APP_BUNDLE=\(root.appendingPathComponent("SBM.app").path)",
      "CORE_BUILD_INFO=\(root.appendingPathComponent("CoreBuildInfo.swift").path)",
      "RELEASE_TOOL=\(bin.appendingPathComponent("SBMReleaseManifestTool").path)",
    ]
    let expansion = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/make"),
      arguments: makeArguments,
      currentDirectory: environmentRoot,
      environment: environment
    )
    let result: TestProcessResult
    if expansion.status == 0 {
      result = try runProcess(
        executable: URL(fileURLWithPath: "/bin/zsh"),
        arguments: ["-c", expansion.output],
        currentDirectory: environmentRoot,
        environment: environment
      )
    } else {
      result = expansion
    }
    let events =
      (try? String(contentsOf: log, encoding: .utf8))?
      .split(whereSeparator: \.isNewline).map(String.init) ?? []
    let backingPath = (try? String(contentsOf: backingFile, encoding: .utf8)) ?? ""
    let workdir = URL(fileURLWithPath: backingPath).deletingLastPathComponent()
    let operationMount =
      (try? String(contentsOf: mountFile, encoding: .utf8))
      .map { URL(fileURLWithPath: $0) } ?? mountpoint
    var mountInfo = stat()
    let mountEntryExists = lstat(operationMount.path, &mountInfo) == 0
    let foreignEntryStillExists: Bool
    switch collision {
    case .directory:
      foreignEntryStillExists = files.fileExists(atPath: foreignMarker.path)
    case .danglingSymlink:
      var symlinkInfo = stat()
      foreignEntryStillExists = lstat(mountpoint.path, &symlinkInfo) == 0
    case nil:
      foreignEntryStillExists = !mountEntryExists
    }
    return Result(
      status: result.status,
      output: result.output,
      events: events,
      detachCount: events.filter { $0.hasPrefix("hdiutil:detach:") }.count,
      mountStillOwned: files.fileExists(
        atPath: operationMount.appendingPathComponent(".operation-owned").path),
      workdirExists: !backingPath.isEmpty && files.fileExists(atPath: workdir.path),
      backingImageExists: !backingPath.isEmpty && files.fileExists(atPath: backingPath),
      foreignEntryStillExists: foreignEntryStillExists
    )
  }

  private func writeTool(_ name: String, to bin: URL, contents: String) throws {
    let url = bin.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  private func runProcess(
    executable: URL,
    arguments: [String],
    currentDirectory: URL,
    environment: [String: String]
  ) throws -> TestProcessResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return TestProcessResult(
      status: process.terminationStatus,
      output: String(decoding: data, as: UTF8.self))
  }
}

private final class ReleasePreflightFixture {
  let root: URL
  private let helperPlistContents: String
  let packagingInputs = """
    test "$$source_go" = "$(CORE_GO_DIRECTIVE)"
    GOTOOLCHAIN=go$(CORE_GO_VERSION)
    -mod=readonly
    -trimpath
    -tags "$(CORE_BUILD_TAGS)"
    """

  var coreLock: String {
    """
    CORE_VERSION := 1.13.18
    CORE_REVISION := \(String(repeating: "a", count: 40))
    CORE_GO_DIRECTIVE := 1.24.1
    CORE_GO_VERSION := 1.24.2
    CORE_BUILD_TAGS := with_quic,with_utls
    CORE_CGO_ENABLED := 1
    CORE_LDFLAGS := -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0
    """
  }

  init() throws {
    root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("SBMReleasePreflight-\(UUID().uuidString)", isDirectory: true)
    let helperPlistURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Resources/com.stillnotfree.sbm.helper.plist")
    helperPlistContents = try String(contentsOf: helperPlistURL, encoding: .utf8)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try write("APP_VERSION := 1.1.11\n" + packagingInputs, to: "Makefile")
    try write(coreLock, to: "Core.lock")
    try write(infoPlist(version: "1.1.11"), to: "Resources/Info.plist")
    try write(helperPlist(), to: "Resources/com.stillnotfree.sbm.helper.plist")
    try write(coreBuildInfo(version: "1.13.18"), to: "Sources/SBMShared/CoreBuildInfo.swift")
    let releaseTool = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("scripts/release-manifest.swift")
    try write(
      try String(contentsOf: releaseTool, encoding: .utf8),
      to: "scripts/release-manifest.swift")
    try write("fixture background", to: "Resources/DMG/background.png")
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
    var arguments = [
      FileManager.default.currentDirectoryPath + "/scripts/release-preflight.swift",
      "--root",
      root.path,
      "--tag",
      tag,
    ]
    if metadataOnly {
      arguments.append("--metadata-only")
    }
    let result = try TestProcessSupport.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/swift"),
      arguments: arguments,
      currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      environment: environment
    )
    return (result.status, result.output)
  }

  func write(_ contents: String, to relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
  }

  func helperPlist(abandonProcessGroup: Bool? = nil, cdHashByte: UInt8 = 0xbb) -> String {
    var contents = helperPlistContents
    guard let closingDictionary = contents.range(of: "</dict>", options: .backwards) else {
      return contents
    }
    var generated = ""
    if let abandonProcessGroup {
      generated +=
        "  <key>AbandonProcessGroup</key>\n  <\(abandonProcessGroup ? "true" : "false")/>\n"
    }
    generated += """
          <key>SpawnConstraint</key>
          <dict>
            <key>cdhash</key><data>\(Data(repeating: cdHashByte, count: 20).base64EncodedString())</data>
            <key>signing-identifier</key><string>com.stillnotfree.sbm.helper</string>
          </dict>
      """
    contents.replaceSubrange(
      closingDictionary,
      with: generated + "\n</dict>"
    )
    return contents
  }

  func git(_ arguments: [String]) throws {
    let result = try TestProcessSupport.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["git"] + arguments,
      currentDirectoryURL: root
    )
    guard result.status == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  func installFullModeTools() throws -> [String: String] {
    let tools = root.appendingPathComponent(".preflight-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try writeTool(
      "swift",
      contents: """
        #!/bin/sh
        if [ "$1" = "test" ]; then
          if [ "$#" -ne 3 ] || [ "$2" != "--disable-sandbox" ] || [ "$3" != "--no-parallel" ]; then
            exit 1
          fi
          exit 0
        fi
        if [ "$1" = "build" ]; then
          printf '%s\\n' "$PREFLIGHT_RELEASE_BIN"
        fi
        exit 0
        """
    )
    try writeTool("plutil", contents: "#!/bin/sh\nexit 0\n")
    try writeTool("git", contents: "#!/bin/sh\nexit 0\n")
    try writeTool(
      "SBMReleaseManifestTool",
      contents: """
        #!/bin/sh
        validate_dmg() {
          if [ "${PREFLIGHT_REJECT_SPAWN:-0}" = "1" ]; then
            echo 'SpawnConstraint does not match the current helper signature.' >&2
            exit 1
          fi
          if [ "${PREFLIGHT_LIPO_ARCHS:-arm64}" != "arm64" ]; then
            echo 'release verifier requires arm64-only artifacts.' >&2
            exit 1
          fi
        }
        if [ "$1" = "sign-update-artifact" ]; then
          validate_dmg
          echo 'SBMReleaseManifestTool signed update proof'
          validate_dmg
          echo 'SBMReleaseManifestTool verified update proof'
        elif [ "$1" = "verify-update-artifact" ]; then
          validate_dmg
          echo 'SBMReleaseManifestTool verified update proof'
        fi
        exit 0
        """
    )
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
      "hdiutil",
      contents: """
        #!/bin/sh
        set -e
        if [ "$1" = "attach" ]; then
          shift
          mountpoint=""
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "-mountpoint" ]; then
              mountpoint="$2"
              shift 2
            else
              shift
            fi
          done
          mkdir -p "$mountpoint/SBM.app" "$mountpoint/.background"
          ln -s /Applications "$mountpoint/Applications"
          if [ "$PREFLIGHT_DMG_BAD_BACKGROUND" = "1" ]; then
            printf 'wrong background' > "$mountpoint/.background/background.png"
          else
            cp Resources/DMG/background.png "$mountpoint/.background/background.png"
          fi
          printf 'Finder layout' > "$mountpoint/.DS_Store"
        elif [ "$1" != "detach" ]; then
          exit 2
        fi
        exit 0
        """
    )
    try writeTool(
      "make",
      contents: """
        #!/bin/sh
        set -e
        if [ "${PREFLIGHT_CHANGE_CORE_BUILD_INFO:-0}" = "1" ]; then
          printf '\\n' >> Sources/SBMShared/CoreBuildInfo.swift
        fi
        mkdir -p dist/SBM.app/Contents/MacOS dist/SBM.app/Contents/Resources dist/SBM.app/Contents/Library/LaunchDaemons
        cp Resources/Info.plist dist/SBM.app/Contents/Info.plist
        cp Resources/com.stillnotfree.sbm.helper.plist dist/SBM.app/Contents/Library/LaunchDaemons/
        if [ -n "${PREFLIGHT_BUILT_VERSION:-}" ]; then
          /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PREFLIGHT_BUILT_VERSION" dist/SBM.app/Contents/Info.plist
        fi
        if [ -n "${PREFLIGHT_BUILT_BUILD:-}" ]; then
          /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PREFLIGHT_BUILT_BUILD" dist/SBM.app/Contents/Info.plist
        fi
        : > dist/SBM.app/Contents/MacOS/SBM
        : > dist/SBM.app/Contents/Resources/SBMHelper
        : > dist/SBM.app/Contents/Resources/sing-box
        : > dist/SBM-1.1.11-arm64.dmg
        "$PREFLIGHT_RELEASE_BIN/SBMReleaseManifestTool" sign-update-artifact --dmg dist/SBM-1.1.11-arm64.dmg --core-digest-file Sources/SBMShared/CoreBuildInfo.swift
        """
    )
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = tools.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
    environment["PREFLIGHT_RELEASE_BIN"] = tools.path
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
      <key>CFBundleIdentifier</key><string>com.stillnotfree.sbm</string>
    </dict></plist>
    """
  }

  func coreBuildInfo(version: String, overrides: [String: String] = [:]) -> String {
    let fields = [
      ("version", version),
      ("revision", String(repeating: "a", count: 40)),
      ("goVersion", "go1.24.2"),
      ("buildTags", "with_quic,with_utls"),
      ("cgo", "enabled"),
      ("linkerFlags", "-X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0"),
      ("unsignedSHA256", String(repeating: "0", count: 64)),
      ("signedSHA256", String(repeating: "1", count: 64)),
    ]
    let declarations = fields.map { name, value in
      "  public static let \(name) = \"\(overrides[name] ?? value)\""
    }
    return "public enum CoreBuildInfo {\n\(declarations.joined(separator: "\n"))\n}\n"
  }
}
