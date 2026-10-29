#!/usr/bin/env swift
import Foundation

private struct Release: Decodable {
  let tagName: String
  let draft: Bool
  let prerelease: Bool

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case draft
    case prerelease
  }
}

private struct GitReference: Decodable {
  let object: GitObject
}

private struct GitObject: Decodable {
  let type: String
  let sha: String
}

private enum UpdateCoreFailure: LocalizedError {
  case usage
  case wrongDirectory
  case invalidRelease
  case invalidTagReference(String)
  case invalidSourceMetadata(String)
  case invalidPinnedRecipe(String)
  case invalidPinnedVersion
  case downgradeRefused(pinned: String, fetched: String)
  case requestFailed(String)

  var errorDescription: String? {
    switch self {
    case .usage: "Usage: swift scripts/update-core.swift stable"
    case .wrongDirectory: "Run this script from the SBM repository root."
    case .invalidRelease: "GitHub did not return a stable semantic sing-box release."
    case .invalidTagReference(let type):
      "The stable release tag resolved to unsupported Git object type \(type); expected a direct commit."
    case .invalidSourceMetadata(let path):
      "The exact upstream revision has invalid or missing \(path) metadata."
    case .invalidPinnedRecipe(let name):
      "Core.lock must define \(name) exactly once with a supported value."
    case .invalidPinnedVersion:
      "Core.lock does not contain a valid stable CORE_VERSION."
    case .downgradeRefused(let pinned, let fetched):
      "Refusing to downgrade the pinned sing-box core from \(pinned) to \(fetched)."
    case .requestFailed(let endpoint):
      "Could not read bounded HTTPS metadata from \(endpoint)."
    }
  }
}

private enum UpdateCore {
  private static let repository = "https://api.github.com/repos/SagerNet/sing-box"
  private static let userAgent = "SBM core updater"

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
    let lockURL = root.appendingPathComponent("Core.lock")
    let lock = try String(contentsOf: lockURL, encoding: .utf8)
    let pinnedVersion = try oneAssignment(named: "CORE_VERSION", in: lock)
    guard isStableVersion(pinnedVersion) else { throw UpdateCoreFailure.invalidPinnedVersion }

    let releaseData = try await getData(
      at: URL(string: "\(repository)/releases/latest")!, maximumBytes: 4 * 1_024 * 1_024,
      githubAPI: true
    )
    let release = try JSONDecoder().decode(Release.self, from: releaseData)
    let version =
      release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
    guard !release.draft, !release.prerelease, isStableVersion(version) else {
      throw UpdateCoreFailure.invalidRelease
    }
    guard let comparison = compareStableVersions(version, pinnedVersion) else {
      throw UpdateCoreFailure.invalidPinnedVersion
    }
    switch comparison {
    case 0:
      print("Pinned sing-box \(pinnedVersion) is already current.")
      return
    case let order where order < 0:
      throw UpdateCoreFailure.downgradeRefused(pinned: pinnedVersion, fetched: version)
    default:
      break
    }

    let reference = try await resolveReleaseTag(version)
    guard reference.object.type == "commit",
      matches(reference.object.sha, pattern: #"^[a-f0-9]{40}$"#)
    else {
      throw UpdateCoreFailure.invalidTagReference(reference.object.type)
    }
    let revision = reference.object.sha
    let rawRoot = "https://raw.githubusercontent.com/SagerNet/sing-box/\(revision)"
    let goMod = try await getText(at: URL(string: "\(rawRoot)/go.mod")!, maximumBytes: 1_048_576)
    let linkerFile = try await getText(
      at: URL(string: "\(rawRoot)/release/LDFLAGS")!, maximumBytes: 64 * 1_024)
    let workflow = try await getText(
      at: URL(string: "\(rawRoot)/.github/workflows/build.yml")!, maximumBytes: 1_048_576)
    let goDirective = try parseGoVersion(goMod)
    let goVersion = try parseWorkflowGoVersion(workflow)
    let linkerFlags = try parseLinkerFlags(linkerFile)
    let buildTags = try oneAssignment(named: "CORE_BUILD_TAGS", in: lock)
    let cgoEnabled = try oneAssignment(named: "CORE_CGO_ENABLED", in: lock)
    guard validBuildTags(buildTags), cgoEnabled == "0" || cgoEnabled == "1" else {
      throw UpdateCoreFailure.invalidPinnedRecipe("CORE_BUILD_TAGS or CORE_CGO_ENABLED")
    }

    let newLock = """
      CORE_VERSION := \(version)
      CORE_REVISION := \(revision)
      CORE_GO_DIRECTIVE := \(goDirective)
      CORE_GO_VERSION := \(goVersion)
      CORE_BUILD_TAGS := \(buildTags)
      CORE_CGO_ENABLED := \(cgoEnabled)
      CORE_LDFLAGS := \(linkerFlags)

      """
    try Data(newLock.utf8).write(to: lockURL, options: .atomic)
    print("Pinned sing-box \(version) source recipe")
    print("Revision: \(revision)")
    print("Source Go directive: \(goDirective)")
    print("Compiler toolchain: \(goVersion)")
    print("Build tags: \(buildTags)")
    print("CGO: \(cgoEnabled)")
    print("Linker flags: \(linkerFlags)")
    print("Run make core to build and review the new artifact.")
  }

  private static func resolveReleaseTag(_ version: String) async throws -> GitReference {
    let endpoint = "\(repository)/git/ref/tags/v\(version)"
    let data = try await getData(
      at: URL(string: endpoint)!, maximumBytes: 64 * 1_024, githubAPI: true)
    do {
      return try JSONDecoder().decode(GitReference.self, from: data)
    } catch {
      throw UpdateCoreFailure.requestFailed(endpoint)
    }
  }

  private static func getText(at url: URL, maximumBytes: Int) async throws -> String {
    let data = try await getData(at: url, maximumBytes: maximumBytes)
    guard let text = String(data: data, encoding: .utf8) else {
      throw UpdateCoreFailure.requestFailed(url.absoluteString)
    }
    return text
  }

  private static func getData(
    at url: URL,
    maximumBytes: Int,
    githubAPI: Bool = false
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if githubAPI {
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse,
      http.statusCode == 200,
      http.url?.scheme?.lowercased() == "https"
    else {
      bytes.task.cancel()
      throw UpdateCoreFailure.requestFailed(url.absoluteString)
    }
    var data = Data()
    data.reserveCapacity(min(maximumBytes, 64 * 1_024))
    for try await byte in bytes {
      guard data.count < maximumBytes else {
        bytes.task.cancel()
        throw UpdateCoreFailure.requestFailed(url.absoluteString)
      }
      data.append(byte)
    }
    return data
  }

  private static func parseGoVersion(_ goMod: String) throws -> String {
    let values = goMod.split(whereSeparator: \.isNewline).compactMap { line -> String? in
      let fields = line.split(whereSeparator: \.isWhitespace)
      return fields.first == "go" && fields.count >= 2 ? String(fields[1]) : nil
    }
    guard values.count == 1, let version = values.first, isStableVersion(version) else {
      throw UpdateCoreFailure.invalidSourceMetadata("go.mod Go directive")
    }
    return version
  }

  private static func parseLinkerFlags(_ source: String) throws -> String {
    let lines = source.split(whereSeparator: \.isNewline)
    guard lines.count == 1 else {
      throw UpdateCoreFailure.invalidSourceMetadata("release/LDFLAGS")
    }
    let value = lines[0].trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { throw UpdateCoreFailure.invalidSourceMetadata("release/LDFLAGS") }
    return value
  }

  private static func parseWorkflowGoVersion(_ workflow: String) throws -> String {
    let values = captures(
      #"(?m)^[ \t]*go-version[ \t]*:[ \t]*(.*?)[ \t]*$"#,
      in: workflow
    )
    guard !values.isEmpty else {
      throw UpdateCoreFailure.invalidSourceMetadata("release workflow Go version")
    }

    var versions = Set<String>()
    for match in values {
      guard var value = match.first?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
        throw UpdateCoreFailure.invalidSourceMetadata("release workflow Go version")
      }
      if let quote = value.first, quote == "'" || quote == "\"" {
        guard value.last == quote, value.count >= 2 else {
          throw UpdateCoreFailure.invalidSourceMetadata("release workflow Go version")
        }
        value.removeFirst()
        value.removeLast()
      }
      guard isStableVersion(value) else {
        throw UpdateCoreFailure.invalidSourceMetadata("release workflow Go version")
      }
      versions.insert(value)
    }
    guard versions.count == 1, let version = versions.first else {
      throw UpdateCoreFailure.invalidSourceMetadata("release workflow Go version")
    }
    return version
  }

  private static func validBuildTags(_ value: String) -> Bool {
    let tags = value.split(separator: ",", omittingEmptySubsequences: false)
    return !tags.isEmpty
      && tags.allSatisfy {
        !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
      } && Set(tags).count == tags.count
  }

  private static func isStableVersion(_ value: String) -> Bool {
    stableComponents(value) != nil
  }

  private static func stableComponents(_ value: String) -> [Int]? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    let values = parts.compactMap { part -> Int? in
      guard !part.isEmpty,
        part.allSatisfy({ $0.isASCII && $0.isNumber }),
        part == "0" || part.first != "0"
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

  private static func oneAssignment(named name: String, in text: String) throws -> String {
    let pattern =
      #"(?m)^[ \t]*"# + NSRegularExpression.escapedPattern(for: name)
      + #"[ \t]*:=[ \t]*(.*?)[ \t]*$"#
    let values = captures(pattern, in: text)
    guard values.count == 1, let value = values.first?.first else {
      throw UpdateCoreFailure.invalidPinnedRecipe(name)
    }
    return value
  }

  private static func captures(_ pattern: String, in text: String) -> [[String]] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
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
  try await UpdateCore.runUpdate()
} catch {
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  exit(EXIT_FAILURE)
}
