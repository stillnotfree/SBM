#!/usr/bin/env swift
import CryptoKit
import Darwin
import Foundation

private struct Release: Decodable {
  let tagName: String
  let draft: Bool
  let prerelease: Bool
  let assets: [Asset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case draft
    case prerelease
    case assets
  }
}

private struct Asset: Decodable {
  let name: String
  let size: Int64
  let digest: String?
  let browserDownloadURL: URL

  enum CodingKeys: String, CodingKey {
    case name
    case size
    case digest
    case browserDownloadURL = "browser_download_url"
  }
}

private enum UpdateCoreFailure: LocalizedError {
  case usage
  case wrongDirectory
  case invalidRelease
  case missingAsset(String)
  case downloadFailed
  case digestMismatch
  case extractionFailed
  case architectureMismatch(String)
  case versionMismatch(String)
  case invalidPinnedVersion
  case downgradeRefused(pinned: String, fetched: String)

  var errorDescription: String? {
    switch self {
    case .usage: "Usage: scripts/update-core.swift stable"
    case .wrongDirectory: "Run this script from the SBM repository root."
    case .invalidRelease: "GitHub did not return a stable semantic sing-box release."
    case .missingAsset(let name):
      "The stable release does not contain \(name) with a SHA-256 digest."
    case .downloadFailed: "The official sing-box archive download failed."
    case .digestMismatch: "The official sing-box archive failed SHA-256 verification."
    case .extractionFailed: "The sing-box archive could not be extracted."
    case .architectureMismatch(let output):
      "The extracted sing-box binary is not arm64: \(output)"
    case .versionMismatch(let output):
      "The extracted core reported an unexpected version: \(output)"
    case .invalidPinnedVersion:
      "Core.lock does not contain a valid stable CORE_VERSION."
    case .downgradeRefused(let pinned, let fetched):
      "Refusing to downgrade the pinned sing-box core from \(pinned) to \(fetched)."
    }
  }
}

private enum UpdateCore {
  static func runUpdate() async throws {
    guard CommandLine.arguments == [CommandLine.arguments[0], "stable"] else {
      throw UpdateCoreFailure.usage
    }

    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    guard fileManager.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
      fileManager.fileExists(atPath: root.appendingPathComponent("Makefile").path)
    else {
      throw UpdateCoreFailure.wrongDirectory
    }
    let pinnedVersion = try readPinnedVersion(from: root.appendingPathComponent("Core.lock"))

    var releaseRequest = URLRequest(
      url: URL(string: "https://api.github.com/repos/SagerNet/sing-box/releases/latest")!)
    releaseRequest.timeoutInterval = 30
    releaseRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    releaseRequest.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    releaseRequest.setValue("SBM core updater", forHTTPHeaderField: "User-Agent")
    let (releaseData, releaseResponse) = try await URLSession.shared.data(for: releaseRequest)
    guard let releaseHTTP = releaseResponse as? HTTPURLResponse,
      releaseHTTP.statusCode == 200,
      releaseData.count <= 4 * 1_024 * 1_024
    else {
      throw UpdateCoreFailure.invalidRelease
    }
    let release = try JSONDecoder().decode(Release.self, from: releaseData)
    let version =
      release.tagName.hasPrefix("v")
      ? String(release.tagName.dropFirst()) : release.tagName
    guard !release.draft, !release.prerelease, isStableVersion(version) else {
      throw UpdateCoreFailure.invalidRelease
    }
    guard let versionComparison = compareStableVersions(version, pinnedVersion) else {
      throw UpdateCoreFailure.invalidPinnedVersion
    }
    switch versionComparison {
    case 0:
      print("Pinned sing-box \(pinnedVersion) is already current.")
      return
    case let order where order < 0:
      throw UpdateCoreFailure.downgradeRefused(pinned: pinnedVersion, fetched: version)
    default:
      break
    }

    let assetName = "sing-box-\(version)-darwin-arm64.tar.gz"
    guard let asset = release.assets.first(where: { $0.name == assetName }),
      asset.size > 0,
      asset.size <= 128 * 1_024 * 1_024,
      asset.browserDownloadURL.scheme?.lowercased() == "https",
      let digest = asset.digest?.lowercased(),
      digest.hasPrefix("sha256:"),
      digest.dropFirst(7).count == 64
    else {
      throw UpdateCoreFailure.missingAsset(assetName)
    }
    let expectedArchiveDigest = String(digest.dropFirst(7))

    let vendor = root.appendingPathComponent(".vendor", isDirectory: true)
    try fileManager.createDirectory(at: vendor, withIntermediateDirectories: true)
    let temporaryDirectory = vendor.appendingPathComponent(
      ".core-update-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    var assetRequest = URLRequest(url: asset.browserDownloadURL)
    assetRequest.timeoutInterval = 180
    assetRequest.setValue("SBM core updater", forHTTPHeaderField: "User-Agent")
    let (downloadedURL, assetResponse) = try await URLSession.shared.download(for: assetRequest)
    guard let assetHTTP = assetResponse as? HTTPURLResponse,
      assetHTTP.statusCode == 200,
      assetHTTP.url?.scheme?.lowercased() == "https"
    else {
      throw UpdateCoreFailure.downloadFailed
    }
    let archive = temporaryDirectory.appendingPathComponent(assetName)
    try fileManager.moveItem(at: downloadedURL, to: archive)
    let archiveSize = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
    guard Int64(archiveSize) == asset.size,
      try sha256(of: archive) == expectedArchiveDigest
    else {
      throw UpdateCoreFailure.digestMismatch
    }

    let extractDirectory = temporaryDirectory.appendingPathComponent("extract", isDirectory: true)
    try fileManager.createDirectory(at: extractDirectory, withIntermediateDirectories: false)
    let archiveMember = "sing-box-\(version)-darwin-arm64/sing-box"
    guard
      try run(
        URL(fileURLWithPath: "/usr/bin/tar"),
        [
          "-xzf", archive.path, "--strip-components", "1", "-C", extractDirectory.path,
          archiveMember,
        ]
      ).status == 0
    else {
      throw UpdateCoreFailure.extractionFailed
    }
    let extractedCore = extractDirectory.appendingPathComponent("sing-box")
    let binaryDigest = try sha256(of: extractedCore)
    let architectureResult = try run(
      URL(fileURLWithPath: "/usr/bin/xcrun"),
      ["lipo", "-archs", extractedCore.path]
    )
    let architectures = architectureResult.output
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard architectureResult.status == 0, architectures == "arm64" else {
      throw UpdateCoreFailure.architectureMismatch(architectures)
    }
    let versionResult = try run(extractedCore, ["version"])
    let firstLine = versionResult.output.split(separator: "\n").first.map(String.init) ?? ""
    guard versionResult.status == 0, firstLine == "sing-box version \(version)" else {
      throw UpdateCoreFailure.versionMismatch(firstLine)
    }

    let archiveDestination = vendor.appendingPathComponent(assetName)
    let binaryDestination = vendor.appendingPathComponent("sing-box-upstream")
    try replace(archive, at: archiveDestination)
    try replace(extractedCore, at: binaryDestination)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryDestination.path)

    let lock = """
      CORE_VERSION := \(version)
      CORE_ARCHIVE_SHA256 := \(expectedArchiveDigest)
      CORE_BINARY_SHA256 := \(binaryDigest)

      """
    try Data(lock.utf8).write(to: root.appendingPathComponent("Core.lock"), options: .atomic)
    print("Pinned sing-box \(version)")
    print("Archive SHA-256: \(expectedArchiveDigest)")
    print("Binary SHA-256:  \(binaryDigest)")
    print("Run make core to sign the pinned core and regenerate CoreBuildInfo.swift.")
  }

  private static func isStableVersion(_ value: String) -> Bool {
    stableComponents(value) != nil
  }

  private static func stableComponents(_ value: String) -> [Int]? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    let values = parts.compactMap { part -> Int? in
      guard !part.isEmpty,
        part.unicodeScalars.allSatisfy({ (48...57).contains($0.value) })
      else { return nil }
      return Int(part)
    }
    return values.count == 3 ? values : nil
  }

  private static func compareStableVersions(_ lhs: String, _ rhs: String) -> Int? {
    guard let left = stableComponents(lhs), let right = stableComponents(rhs) else { return nil }
    for index in 0..<3 where left[index] != right[index] {
      return left[index] < right[index] ? -1 : 1
    }
    return 0
  }

  private static func readPinnedVersion(from url: URL) throws -> String {
    guard let contents = try? String(contentsOf: url, encoding: .utf8),
      let line = contents.split(whereSeparator: \.isNewline).first(where: {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("CORE_VERSION :=")
      })
    else {
      throw UpdateCoreFailure.invalidPinnedVersion
    }
    let value = line
      .replacingOccurrences(of: "CORE_VERSION :=", with: "")
      .trimmingCharacters(in: .whitespaces)
    guard isStableVersion(value) else { throw UpdateCoreFailure.invalidPinnedVersion }
    return value
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func run(_ executable: URL, _ arguments: [String]) throws -> (
    status: Int32, output: String
  ) {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private static func replace(_ source: URL, at destination: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: source)
    } else {
      try fileManager.moveItem(at: source, to: destination)
    }
  }
}

do {
  try await UpdateCore.runUpdate()
} catch {
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  exit(EXIT_FAILURE)
}
