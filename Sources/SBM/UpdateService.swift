import CryptoKit
import Foundation

struct AppUpdate: Sendable {
  let version: String
  let assetURL: URL
  let expectedDigest: String
  let expectedSize: Int64
  let releaseURL: URL
}

enum UpdateService {
  private static let repository = "stillnotfree/SBM"
  private static let maximumAssetSize: Int64 = 200 * 1_024 * 1_024
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(
      configuration: configuration,
      delegate: UpdateHTTPSOnlySessionDelegate(),
      delegateQueue: nil
    )
  }()

  static func latest(currentVersion: String) async throws -> AppUpdate? {
    let endpoint = URL(
      string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 15
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("SBM/\(currentVersion)", forHTTPHeaderField: "User-Agent")

    let (temporaryURL, response) = try await session.download(for: request)
    guard let http = response as? HTTPURLResponse,
      http.statusCode == 200,
      http.url?.scheme?.lowercased() == "https"
    else {
      throw UpdateFailure.releaseUnavailable
    }
    let data = try Data(contentsOf: temporaryURL, options: [.mappedIfSafe])
    guard data.count <= 1_048_576 else { throw UpdateFailure.invalidResponse }
    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    guard let version = normalizedVersion(release.tagName) else {
      throw UpdateFailure.invalidResponse
    }
    guard isNewer(version, than: currentVersion) else { return nil }

    let expectedName = "SBM-\(version)-arm64.dmg"
    guard let asset = release.assets.first(where: { $0.name == expectedName }),
      asset.size > 0,
      asset.size <= maximumAssetSize,
      let digest = asset.digest?.lowercased(),
      digest.hasPrefix("sha256:"),
      digest.dropFirst(7).count == 64,
      asset.browserDownloadURL.scheme?.lowercased() == "https",
      release.htmlURL.scheme?.lowercased() == "https"
    else {
      throw UpdateFailure.verifiedAssetMissing
    }
    return AppUpdate(
      version: version,
      assetURL: asset.browserDownloadURL,
      expectedDigest: String(digest.dropFirst(7)),
      expectedSize: asset.size,
      releaseURL: release.htmlURL
    )
  }

  static func download(_ update: AppUpdate) async throws -> URL {
    var request = URLRequest(url: update.assetURL)
    request.timeoutInterval = 120
    request.setValue("SBM updater", forHTTPHeaderField: "User-Agent")
    let (temporaryURL, response) = try await session.download(for: request)
    guard let http = response as? HTTPURLResponse,
      http.statusCode == 200,
      http.url?.scheme?.lowercased() == "https"
    else {
      throw UpdateFailure.downloadFailed
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
    guard let size = attributes[.size] as? NSNumber,
      size.int64Value == update.expectedSize,
      size.int64Value <= maximumAssetSize
    else {
      throw UpdateFailure.assetSizeMismatch
    }
    guard try sha256(of: temporaryURL) == update.expectedDigest else {
      throw UpdateFailure.assetDigestMismatch
    }

    let directory = try FileManager.default.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("SBM/Updates", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableDirectory = directory
    try mutableDirectory.setResourceValues(values)

    let destination = directory.appendingPathComponent(
      "SBM-\(update.version)-arm64.dmg"
    )
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
    return destination
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

  static func normalizedVersion(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      components.allSatisfy({
        !$0.isEmpty
          && $0.allSatisfy(\.isNumber)
          && ($0 == "0" || !$0.hasPrefix("0"))
          && Int($0) != nil
      })
    else { return nil }
    return normalized
  }

  static func isNewer(_ candidate: String, than current: String) -> Bool {
    guard let normalizedCandidate = normalizedVersion(candidate),
      let normalizedCurrent = normalizedVersion(current)
    else { return false }
    let lhs = normalizedCandidate.split(separator: ".").compactMap { Int(String($0)) }
    let rhs = normalizedCurrent.split(separator: ".").compactMap { Int(String($0)) }
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      if left != right { return left > right }
    }
    return false
  }
}

private final class UpdateHTTPSOnlySessionDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
  }
}

private struct GitHubRelease: Decodable {
  let tagName: String
  let htmlURL: URL
  let assets: [GitHubAsset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
    case assets
  }
}

private struct GitHubAsset: Decodable {
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

enum UpdateFailure: LocalizedError {
  case releaseUnavailable
  case invalidResponse
  case verifiedAssetMissing
  case downloadFailed
  case assetSizeMismatch
  case assetDigestMismatch

  var errorDescription: String? {
    switch self {
    case .releaseUnavailable: "GitHub Releases is unavailable."
    case .invalidResponse: "GitHub returned an invalid update response."
    case .verifiedAssetMissing: "The release has no SHA-256 verified Apple Silicon DMG."
    case .downloadFailed: "The update download failed."
    case .assetSizeMismatch: "The downloaded update size does not match GitHub."
    case .assetDigestMismatch: "The downloaded update failed SHA-256 verification."
    }
  }
}
