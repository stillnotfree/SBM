import CryptoKit
import Darwin
import Foundation

private enum ReleaseToolFailure: LocalizedError {
  case check(String)
  case command(String, Int32, String)

  var errorDescription: String? {
    switch self {
    case .check(let detail): return "release trust: \(detail)"
    case .command(let name, let status, let output):
      let failure = "release trust: \(name) failed with status \(status)"
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      let diagnostic = String(decoding: trimmed.utf8.prefix(4_096), as: UTF8.self)
      return diagnostic.isEmpty ? failure : "\(failure): \(diagnostic)"
    }
  }
}

private struct CodeIdentity {
  let identifier: String
  let cdHash: String
  let adHoc: Bool
  let hardenedRuntime: Bool
}

@main
private enum ReleaseManifestTool {
  static func main() {
    do {
      try run(arguments: Array(CommandLine.arguments.dropFirst()))
    } catch {
      FileHandle.standardError.write(
        Data("\(error.localizedDescription)\n".utf8)
      )
      exit(EXIT_FAILURE)
    }
  }

  private static func run(arguments: [String]) throws {
    guard let command = arguments.first else {
      throw ReleaseToolFailure.check("a command is required.")
    }
    let values = try options(Array(arguments.dropFirst()))
    switch command {
    case "helper-plist":
      try generateHelperPlist(
        helper: required("helper", values),
        template: required("template", values),
        output: required("output", values)
      )
    case "verify-helper-plist":
      let plistURL = URL(fileURLWithPath: try required("plist", values))
      let plist = try propertyList(plistURL)
      let identity = try codeIdentity(at: URL(fileURLWithPath: required("helper", values)))
      try verifySpawnConstraint(in: plist, helper: identity)
      try verifyHelperServicePlist(
        plist,
        expectedLabel: expectedHelperServiceLabel(for: plistURL.lastPathComponent)
      )
    case "sign-attach-verify":
      guard values["--helper"] == nil, values["--core"] == nil else {
        throw ReleaseToolFailure.check(
          "pass one --app package root; helper and core paths are derived.")
      }
      let app = URL(fileURLWithPath: try required("app", values), isDirectory: true)
      let helper = app.appendingPathComponent("Contents/Resources/SBMHelper")
      let core = app.appendingPathComponent("Contents/Resources/sing-box")
      let digestFile = URL(fileURLWithPath: try required("core-digest-file", values))
      let privateKey = try loadProjectPrivateKey()
      try signAndAttach(
        app: app,
        helper: helper,
        core: core,
        coreDigestFile: digestFile,
        privateKey: privateKey
      )
      _ = try verifyBundle(app: app, helper: helper, core: core, coreDigestFile: digestFile)
    case "verify-bundle":
      guard values["--helper"] == nil, values["--core"] == nil else {
        throw ReleaseToolFailure.check(
          "pass one --app package root; helper and core paths are derived.")
      }
      let app = URL(fileURLWithPath: try required("app", values), isDirectory: true)
      _ = try verifyBundle(
        app: app,
        helper: app.appendingPathComponent("Contents/Resources/SBMHelper"),
        core: app.appendingPathComponent("Contents/Resources/sing-box"),
        coreDigestFile: URL(fileURLWithPath: required("core-digest-file", values))
      )
    case "verify-dmg":
      _ = try verifyDMG(
        dmg: URL(fileURLWithPath: required("dmg", values)),
        coreDigestFile: URL(fileURLWithPath: required("core-digest-file", values))
      )
    case "sign-update-artifact":
      guard Set(values.keys) == Set(["--dmg", "--core-digest-file"]) else {
        throw ReleaseToolFailure.check("update artifact facts are derived from the verified DMG.")
      }
      let dmg = URL(fileURLWithPath: try required("dmg", values))
      let coreDigestFile = URL(fileURLWithPath: try required("core-digest-file", values))
      let manifest = try verifyDMG(dmg: dmg, coreDigestFile: coreDigestFile)
      let facts = try updateArtifactFacts(for: dmg, appVersion: manifest.appVersion)
      let privateKey = try loadProjectPrivateKey()
      guard privateKey.publicKey.rawRepresentation == CurrentReleaseManifest.projectPublicKey else {
        throw ReleaseToolFailure.check(
          "the external release key does not match the current project key.")
      }
      let payload = UpdateArtifactProofPayload(
        keyID: CurrentReleaseManifest.projectKeyID,
        appVersion: manifest.appVersion,
        assetName: facts.name,
        assetSize: facts.size,
        assetSHA256: facts.sha256
      )
      let proof = try UpdateArtifactProof.sign(payload, with: privateKey)
      try proof.write(
        to: updateProofURL(for: dmg, appVersion: manifest.appVersion), options: .atomic)
      try verifyUpdateArtifact(dmg: dmg, coreDigestFile: coreDigestFile)
      print("Generated and verified the detached update-artifact proof.")
    case "verify-update-artifact":
      guard Set(values.keys) == Set(["--dmg", "--core-digest-file"]) else {
        throw ReleaseToolFailure.check("update artifact facts are derived from the verified DMG.")
      }
      try verifyUpdateArtifact(
        dmg: URL(fileURLWithPath: try required("dmg", values)),
        coreDigestFile: URL(fileURLWithPath: try required("core-digest-file", values))
      )
    default:
      throw ReleaseToolFailure.check("unknown command \(command).")
    }
  }

  private static func options(_ arguments: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let name = arguments[index]
      guard name.hasPrefix("--"), index + 1 < arguments.count,
        result[name] == nil
      else { throw ReleaseToolFailure.check("command options are malformed.") }
      result[name] = arguments[index + 1]
      index += 2
    }
    return result
  }

  private static func required(_ name: String, _ values: [String: String]) throws -> String {
    guard let value = values["--\(name)"], !value.isEmpty else {
      throw ReleaseToolFailure.check("--\(name) is required.")
    }
    return value
  }

  private static func generateHelperPlist(helper: String, template: String, output: String)
    throws
  {
    let identity = try codeIdentity(at: URL(fileURLWithPath: helper))
    guard identity.identifier == "com.stillnotfree.sbm.helper",
      identity.adHoc,
      identity.hardenedRuntime
    else {
      throw ReleaseToolFailure.check("the helper must be ad-hoc signed with Hardened Runtime.")
    }

    let templateURL = URL(fileURLWithPath: template)
    let outputURL = URL(fileURLWithPath: output)
    let expectedLabel = try expectedHelperServiceLabel(for: outputURL.lastPathComponent)
    guard
      let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: templateURL),
        format: nil
      ) as? [String: Any]
    else { throw ReleaseToolFailure.check("the helper launchd template is invalid.") }
    try verifyHelperServicePlist(plist, expectedLabel: expectedLabel)

    var generated = plist
    generated["SpawnConstraint"] = [
      "cdhash": try data(hex: identity.cdHash),
      "signing-identifier": identity.identifier,
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: generated,
      format: .xml,
      options: 0
    )
    try data.write(to: outputURL, options: .atomic)
    try verifySpawnConstraint(in: generated, helper: identity)
    try verifyHelperServicePlist(generated, expectedLabel: expectedLabel)
    print("Generated SpawnConstraint for helper \(identity.cdHash).")
  }

  private static func signAndAttach(
    app: URL,
    helper: URL,
    core: URL,
    coreDigestFile: URL,
    privateKey: Curve25519.Signing.PrivateKey
  ) throws {
    let appInfo = try appInformation(app)
    let appIdentity = try codeIdentity(at: app.appendingPathComponent("Contents/MacOS/SBM"))
    let helperIdentity = try codeIdentity(at: helper)
    let coreDigest = try verifyCoreDigest(core, digestFile: coreDigestFile)
    guard appInfo.bundleIdentifier == "com.stillnotfree.sbm",
      appIdentity.identifier == appInfo.bundleIdentifier,
      appIdentity.adHoc,
      appIdentity.hardenedRuntime,
      helperIdentity.identifier == "com.stillnotfree.sbm.helper",
      helperIdentity.adHoc,
      helperIdentity.hardenedRuntime,
      privateKey.publicKey.rawRepresentation == CurrentReleaseManifest.projectPublicKey
    else {
      throw ReleaseToolFailure.check("signed identities or project key do not match this release.")
    }

    let payload = CurrentReleaseManifestPayload(
      keyID: CurrentReleaseManifest.projectKeyID,
      appVersion: appInfo.version,
      appBuild: appInfo.build,
      appBundleIdentifier: appInfo.bundleIdentifier,
      appCDHash: appIdentity.cdHash,
      helperSigningIdentifier: helperIdentity.identifier,
      helperCDHash: helperIdentity.cdHash,
      helperRevision: HelperConstants.helperRevision,
      ipcProtocolVersion: HelperConstants.protocolVersion,
      coreSHA256: coreDigest
    )
    let signed = try CurrentReleaseManifest.sign(payload, with: privateKey)
    try CurrentReleaseManifest.attach(signed, to: app)
    print("Signed and attached the current-release manifest.")
  }

  private static func verifyBundle(
    app: URL,
    helper: URL,
    core: URL,
    coreDigestFile: URL
  ) throws -> CurrentReleaseManifestPayload {
    let appExecutable = app.appendingPathComponent("Contents/MacOS/SBM")
    let appInfo = try appInformation(app)
    let appIdentity = try codeIdentity(at: appExecutable)
    let helperIdentity = try codeIdentity(at: helper)
    let expectedCoreDigest = try verifyCoreDigest(core, digestFile: coreDigestFile)
    let manifestData = try CurrentReleaseManifest.read(from: app)
    let manifest = try CurrentReleaseManifest.verify(
      manifestData,
      publicKey: CurrentReleaseManifest.projectPublicKey,
      expectedKeyID: CurrentReleaseManifest.projectKeyID
    )

    guard appInfo.bundleIdentifier == manifest.appBundleIdentifier,
      appInfo.version == manifest.appVersion,
      appInfo.build == manifest.appBuild,
      appIdentity.identifier == manifest.appBundleIdentifier,
      appIdentity.cdHash == manifest.appCDHash,
      appIdentity.adHoc,
      appIdentity.hardenedRuntime,
      helperIdentity.identifier == manifest.helperSigningIdentifier,
      helperIdentity.cdHash == manifest.helperCDHash,
      helperIdentity.adHoc,
      helperIdentity.hardenedRuntime,
      manifest.helperRevision == HelperConstants.helperRevision,
      manifest.ipcProtocolVersion == HelperConstants.protocolVersion,
      manifest.coreSHA256 == expectedCoreDigest
    else {
      throw ReleaseToolFailure.check("app/helper/core identity does not match the signed manifest.")
    }

    for plistName in [
      "com.stillnotfree.sbm.helper.plist",
      "com.stillnotfree.sbm.helper.v12.plist",
    ] {
      let helperPlistURL = app.appendingPathComponent(
        "Contents/Library/LaunchDaemons/\(plistName)"
      )
      let helperPlist = try propertyList(helperPlistURL)
      try verifySpawnConstraint(in: helperPlist, helper: helperIdentity)
      try verifyHelperServicePlist(
        helperPlist,
        expectedLabel: try expectedHelperServiceLabel(for: plistName)
      )
    }
    _ = try output("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", app.path])
    _ = try output("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", helper.path])
    _ = try output("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", core.path])
    try verifyArm64(appExecutable)
    try verifyArm64(helper)
    try verifyArm64(core)
    print(
      "Release bundle verified: app/helper CDHashes, manifest, core digest, both exact launchd plists, signatures, and arm64."
    )
    return manifest
  }

  private static func verifyDMG(
    dmg: URL,
    coreDigestFile: URL
  ) throws -> CurrentReleaseManifestPayload {
    let mountURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("SBM-R3-DMG-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: false)

    do {
      _ = try output(
        "/usr/bin/hdiutil",
        ["attach", "-readonly", "-nobrowse", "-mountpoint", mountURL.path, dmg.path]
      )
    } catch let attachFailure {
      let contents = try? FileManager.default.contentsOfDirectory(atPath: mountURL.path)
      if contents?.isEmpty == true {
        do {
          try FileManager.default.removeItem(at: mountURL)
        } catch {
          throw ReleaseToolFailure.check(
            "DMG attach failed: \(attachFailure.localizedDescription); private mount cleanup failed: \(error.localizedDescription); path retained at \(mountURL.path)."
          )
        }
      } else {
        throw ReleaseToolFailure.check(
          "DMG attach failed: \(attachFailure.localizedDescription); unconfirmed mount path retained at \(mountURL.path)."
        )
      }
      throw attachFailure
    }

    let app = mountURL.appendingPathComponent("SBM.app", isDirectory: true)
    let manifest: CurrentReleaseManifestPayload
    do {
      manifest = try verifyBundle(
        app: app,
        helper: app.appendingPathComponent("Contents/Resources/SBMHelper"),
        core: app.appendingPathComponent("Contents/Resources/sing-box"),
        coreDigestFile: coreDigestFile
      )
    } catch let verificationFailure {
      do {
        _ = try output("/usr/bin/hdiutil", ["detach", "-quiet", mountURL.path])
      } catch {
        throw ReleaseToolFailure.check(
          "DMG verification failed: \(verificationFailure.localizedDescription); owned-mount detach cleanup failed: \(error.localizedDescription); mount retained at \(mountURL.path)."
        )
      }
      do {
        try FileManager.default.removeItem(at: mountURL)
      } catch {
        throw ReleaseToolFailure.check(
          "DMG verification failed: \(verificationFailure.localizedDescription); detached mount directory cleanup failed: \(error.localizedDescription)."
        )
      }
      throw verificationFailure
    }

    do {
      _ = try output("/usr/bin/hdiutil", ["detach", "-quiet", mountURL.path])
    } catch {
      throw ReleaseToolFailure.check(
        "DMG verification passed but owned-mount detach failed: \(error.localizedDescription); mount retained at \(mountURL.path)."
      )
    }
    do {
      try FileManager.default.removeItem(at: mountURL)
    } catch {
      throw ReleaseToolFailure.check(
        "DMG verification and detach succeeded, but private mount directory cleanup failed: \(error.localizedDescription)."
      )
    }
    print("DMG preserves the bounded signed manifest xattr.")
    return manifest
  }

  private static func updateArtifactFacts(
    for dmg: URL,
    appVersion: String
  ) throws -> (name: String, size: Int64, sha256: String) {
    let expectedName = "SBM-\(appVersion)-arm64.dmg"
    var metadata = stat()
    guard dmg.lastPathComponent == expectedName,
      lstat(dmg.path, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_size > 0,
      metadata.st_size <= UpdateArtifactProof.maximumAssetBytes
    else { throw ReleaseToolFailure.check("the final DMG name or size is invalid.") }
    return (expectedName, metadata.st_size, try sha256(of: dmg))
  }

  private static func updateProofURL(for dmg: URL, appVersion: String) -> URL {
    URL(fileURLWithPath: "dist", isDirectory: true)
      .appendingPathComponent("SBM-\(appVersion)-arm64.update.json")
  }

  private static func verifyUpdateArtifact(dmg: URL, coreDigestFile: URL) throws {
    let manifest = try verifyDMG(dmg: dmg, coreDigestFile: coreDigestFile)
    let facts = try updateArtifactFacts(for: dmg, appVersion: manifest.appVersion)
    let proofURL = updateProofURL(for: dmg, appVersion: manifest.appVersion)
    var metadata = stat()
    guard lstat(proofURL.path, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_size > 0,
      metadata.st_size <= Int64(UpdateArtifactProof.maximumEnvelopeBytes)
    else {
      throw ReleaseToolFailure.check("the detached update-artifact proof is missing or oversized.")
    }
    let data = try Data(contentsOf: proofURL, options: [.mappedIfSafe])
    guard Int64(data.count) == metadata.st_size else {
      throw ReleaseToolFailure.check("the detached update-artifact proof changed while reading.")
    }
    let payload = try UpdateArtifactProof.verify(
      data,
      publicKey: CurrentReleaseManifest.projectPublicKey,
      expectedKeyID: CurrentReleaseManifest.projectKeyID
    )
    guard
      UpdateArtifactProof.matches(
        payload,
        appVersion: manifest.appVersion,
        assetName: facts.name,
        assetSize: facts.size,
        assetSHA256: facts.sha256
      )
    else {
      throw ReleaseToolFailure.check("the update-artifact proof does not match this final DMG.")
    }
    print("Detached update-artifact proof matches the verified final DMG.")
  }

  private static func appInformation(_ app: URL) throws -> (
    bundleIdentifier: String, version: String, build: String
  ) {
    let info = try propertyList(app.appendingPathComponent("Contents/Info.plist"))
    guard let identifier = info["CFBundleIdentifier"] as? String,
      let version = info["CFBundleShortVersionString"] as? String,
      let build = info["CFBundleVersion"] as? String
    else { throw ReleaseToolFailure.check("app Info.plist is missing current release fields.") }
    return (identifier, version, build)
  }

  private static func propertyList(_ url: URL) throws -> [String: Any] {
    guard
      let value = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url),
        format: nil
      ) as? [String: Any]
    else { throw ReleaseToolFailure.check("a release property list is invalid.") }
    return value
  }

  private static func verifySpawnConstraint(in plist: [String: Any], helper: CodeIdentity) throws {
    guard let constraint = plist["SpawnConstraint"] as? [String: Any],
      Set(constraint.keys) == Set(["cdhash", "signing-identifier"]),
      let cdHash = constraint["cdhash"] as? Data,
      cdHash == (try data(hex: helper.cdHash)),
      constraint["signing-identifier"] as? String == helper.identifier,
      helper.identifier == "com.stillnotfree.sbm.helper",
      helper.adHoc,
      helper.hardenedRuntime
    else {
      throw ReleaseToolFailure.check("SpawnConstraint does not match the current helper signature.")
    }
  }

  private static func expectedHelperServiceLabel(for plistName: String) throws -> String {
    return switch plistName {
    case HelperConstants.legacyDaemonPlistName:
      HelperConstants.legacyServiceLabel
    case HelperConstants.daemonPlistName:
      HelperConstants.currentServiceLabel
    default:
      throw ReleaseToolFailure.check("unknown helper service plist filename \(plistName).")
    }
  }

  private static func verifyHelperServicePlist(
    _ plist: [String: Any],
    expectedLabel: String
  ) throws {
    guard plist["BundleProgram"] as? String == "Contents/Resources/SBMHelper",
      let label = plist["Label"] as? String,
      label == expectedLabel,
      let environment = plist["EnvironmentVariables"] as? [String: String],
      environment[HelperConstants.serviceLabelEnvironmentKey] == label
    else {
      throw ReleaseToolFailure.check("helper service label and execution marker are invalid.")
    }

    if label == HelperConstants.legacyServiceLabel {
      guard plist["Sockets"] == nil else {
        throw ReleaseToolFailure.check(
          "the legacy helper plist must be unregister-only and have no sockets.")
      }
      return
    }

    guard label == HelperConstants.currentServiceLabel,
      let sockets = plist["Sockets"] as? [String: Any],
      Set(sockets.keys) == Set(["Listener"]),
      let listener = sockets["Listener"] as? [String: Any],
      listener["SockPathName"] as? String == HelperConstants.socketPath,
      (listener["SockPathOwner"] as? NSNumber)?.intValue == 0,
      (listener["SockPathGroup"] as? NSNumber)?.intValue == 80,
      (listener["SockPathMode"] as? NSNumber)?.intValue == 0o660
    else {
      throw ReleaseToolFailure.check("the current v12 helper plist has an invalid socket or label.")
    }
  }

  private static func codeIdentity(at url: URL) throws -> CodeIdentity {
    let output = try output(
      "/usr/bin/codesign",
      ["--display", "--verbose=4", url.path]
    )
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    guard
      let identifier = lines.first(where: { $0.hasPrefix("Identifier=") })
        .map({ String($0.dropFirst("Identifier=".count)) }),
      let cdHash = lines.first(where: { $0.hasPrefix("CDHash=") })
        .map({ String($0.dropFirst("CDHash=".count)).lowercased() }),
      cdHash.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression) != nil
    else {
      throw ReleaseToolFailure.check("codesign did not report an exact identifier and CDHash.")
    }
    let adHoc = lines.contains(where: { $0.lowercased().contains("signature=adhoc") })
    let hardenedRuntime = lines.contains {
      $0.lowercased().contains("flags=") && $0.lowercased().contains("runtime")
    }
    return CodeIdentity(
      identifier: identifier,
      cdHash: cdHash,
      adHoc: adHoc,
      hardenedRuntime: hardenedRuntime
    )
  }

  private static func verifyCoreDigest(_ core: URL, digestFile: URL) throws -> String {
    let source = try String(contentsOf: digestFile, encoding: .utf8)
    let pattern = #"(?m)^[ \t]*public static let signedSHA256\s*=\s*"([a-f0-9]{64})""#
    guard let range = source.range(of: pattern, options: .regularExpression) else {
      throw ReleaseToolFailure.check("CoreBuildInfo does not contain one pinned SHA-256 digest.")
    }
    let match = String(source[range])
    guard let digestRange = match.range(of: #"[a-f0-9]{64}"#, options: .regularExpression) else {
      throw ReleaseToolFailure.check("CoreBuildInfo digest is malformed.")
    }
    let expected = String(match[digestRange])
    let actual = try sha256(of: core)
    guard actual == expected else {
      throw ReleaseToolFailure.check("the packaged core digest is not the pinned digest.")
    }
    return actual
  }

  private static func sha256(of url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hasher = SHA256()
    while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func verifyArm64(_ executable: URL) throws {
    let architectures = try output("/usr/bin/lipo", ["-archs", executable.path])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard architectures == "arm64" else {
      throw ReleaseToolFailure.check("a release executable is not arm64-only.")
    }
  }

  private static func loadProjectPrivateKey() throws -> Curve25519.Signing.PrivateKey {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/sbm", isDirectory: true)
    let keyURL = directory.appendingPathComponent("release-ed25519-private.raw")
    var directoryStat = stat()
    var keyStat = stat()
    guard lstat(directory.path, &directoryStat) == 0,
      (directoryStat.st_mode & S_IFMT) == S_IFDIR,
      directoryStat.st_uid == getuid(),
      (directoryStat.st_mode & 0o777) == 0o700,
      lstat(keyURL.path, &keyStat) == 0,
      (keyStat.st_mode & S_IFMT) == S_IFREG,
      keyStat.st_uid == getuid(),
      (keyStat.st_mode & 0o777) == 0o600,
      keyStat.st_size == 32
    else {
      throw ReleaseToolFailure.check("the external release key is missing or has unsafe metadata.")
    }
    do {
      return try Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(contentsOf: keyURL)
      )
    } catch {
      throw ReleaseToolFailure.check("the external release key is malformed.")
    }
  }

  private static func data(hex: String) throws -> Data {
    guard hex.count.isMultiple(of: 2) else {
      throw ReleaseToolFailure.check("a CDHash is malformed.")
    }
    var result = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else {
        throw ReleaseToolFailure.check("a CDHash is malformed.")
      }
      result.append(byte)
      index = next
    }
    return result
  }

  private static func output(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      throw ReleaseToolFailure.check("a required release command is unavailable.")
    }
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let error = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let captured = String(decoding: output + error, as: UTF8.self)
    guard process.terminationStatus == 0 else {
      throw ReleaseToolFailure.command(
        URL(fileURLWithPath: executable).lastPathComponent, process.terminationStatus, captured)
    }
    return captured
  }

}
