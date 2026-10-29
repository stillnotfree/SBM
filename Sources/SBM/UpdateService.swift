import CryptoKit
import Foundation
import SBMShared

struct AppUpdate: Sendable {
  let version: String
  let assetURL: URL
  let expectedDigest: String
  let expectedSize: Int64
}

enum UpdateService {
  private static let repository = "stillnotfree/SBM"
  private static let maximumReleaseResponseSize: Int64 = 1_048_576
  private static let maximumAssetSize = UpdateArtifactProof.maximumAssetBytes

  static func latest(
    currentVersion: String,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    stagingDirectory: URL = FileManager.default.temporaryDirectory
  ) async throws -> AppUpdate? {
    let endpoint = URL(
      string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 15
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("SBM/\(currentVersion)", forHTTPHeaderField: "User-Agent")

    let stagingURL = stagingDirectory.appendingPathComponent(
      "SBM-release-metadata-\(UUID().uuidString).tmp"
    )
    defer { try? FileManager.default.removeItem(at: stagingURL) }
    let transfer = UpdateDownloadTransfer(
      stagingURL: stagingURL,
      maximumBytes: maximumReleaseResponseSize,
      oversizeFailure: .invalidResponse,
      sessionConfiguration: sessionConfiguration,
      progress: { _ in }
    )
    let response = try await transfer.start(request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse,
      http.statusCode == 200,
      http.url?.scheme?.lowercased() == "https"
    else {
      throw UpdateFailure.releaseUnavailable
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
    guard let size = attributes[.size] as? NSNumber,
      size.int64Value <= maximumReleaseResponseSize
    else {
      throw UpdateFailure.invalidResponse
    }
    let data = try Data(contentsOf: stagingURL, options: [.mappedIfSafe])
    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    guard let version = normalizedVersion(release.tagName) else {
      throw UpdateFailure.invalidResponse
    }
    guard isNewer(version, than: currentVersion) else { return nil }

    let expectedName = "SBM-\(version)-arm64.dmg"
    let matchingAssets = release.assets.filter { $0.name == expectedName }
    guard matchingAssets.count == 1,
      let asset = matchingAssets.first,
      asset.size > 0,
      asset.size <= maximumAssetSize,
      let digest = asset.digest?.lowercased(),
      digest.hasPrefix("sha256:"),
      digest.dropFirst(7).range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
      asset.browserDownloadURL.scheme?.lowercased() == "https",
      release.htmlURL.scheme?.lowercased() == "https"
    else {
      throw UpdateFailure.verifiedAssetMissing
    }
    let expectedProofName = "SBM-\(version)-arm64.update.json"
    let matchingProofs = release.assets.filter { $0.name == expectedProofName }
    guard matchingProofs.count == 1,
      let proofAsset = matchingProofs.first,
      proofAsset.size > 0,
      proofAsset.size <= Int64(UpdateArtifactProof.maximumEnvelopeBytes),
      proofAsset.browserDownloadURL.scheme?.lowercased() == "https"
    else {
      throw UpdateFailure.publisherProofInvalid
    }

    let proofData = try await fetchProof(
      from: proofAsset.browserDownloadURL,
      sessionConfiguration: sessionConfiguration,
      stagingDirectory: stagingDirectory
    )
    try Task.checkCancellation()
    let payload: UpdateArtifactProofPayload
    do {
      payload = try UpdateArtifactProof.verify(
        proofData,
        publicKey: CurrentReleaseManifest.projectPublicKey,
        expectedKeyID: CurrentReleaseManifest.projectKeyID
      )
    } catch {
      throw UpdateFailure.publisherProofInvalid
    }
    return try composeUpdate(
      tagVersion: version,
      assetURL: asset.browserDownloadURL,
      githubSize: asset.size,
      githubDigest: String(digest.dropFirst(7)),
      proof: payload
    )
  }

  static func composeUpdate(
    tagVersion: String,
    assetURL: URL,
    githubSize: Int64,
    githubDigest: String,
    proof: UpdateArtifactProofPayload
  ) throws -> AppUpdate {
    guard normalizedVersion(tagVersion) == tagVersion,
      assetURL.scheme?.lowercased() == "https",
      proof.assetSize > 0, proof.assetSize <= maximumAssetSize,
      UpdateArtifactProof.matches(
        proof,
        appVersion: tagVersion,
        assetName: "SBM-\(tagVersion)-arm64.dmg",
        assetSize: githubSize,
        assetSHA256: githubDigest
      )
    else { throw UpdateFailure.publisherProofInvalid }
    return AppUpdate(
      version: proof.appVersion,
      assetURL: assetURL,
      expectedDigest: proof.assetSHA256,
      expectedSize: proof.assetSize
    )
  }

  private static func fetchProof(
    from url: URL,
    sessionConfiguration: URLSessionConfiguration,
    stagingDirectory: URL
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("SBM updater proof", forHTTPHeaderField: "User-Agent")
    let stagingURL = stagingDirectory.appendingPathComponent(
      "SBM-update-proof-\(UUID().uuidString).tmp"
    )
    defer { try? FileManager.default.removeItem(at: stagingURL) }
    let transfer = UpdateDownloadTransfer(
      stagingURL: stagingURL,
      maximumBytes: Int64(UpdateArtifactProof.maximumEnvelopeBytes),
      oversizeFailure: .publisherProofInvalid,
      sessionConfiguration: sessionConfiguration,
      progress: { _ in }
    )
    let response = try await transfer.start(request)
    guard let http = response as? HTTPURLResponse,
      http.statusCode == 200,
      http.url?.scheme?.lowercased() == "https"
    else { throw UpdateFailure.publisherProofInvalid }
    let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
    guard let size = attributes[.size] as? NSNumber,
      size.int64Value > 0,
      size.int64Value <= Int64(UpdateArtifactProof.maximumEnvelopeBytes)
    else { throw UpdateFailure.publisherProofInvalid }
    let data = try Data(contentsOf: stagingURL, options: [.mappedIfSafe])
    guard Int64(data.count) == size.int64Value else {
      throw UpdateFailure.publisherProofInvalid
    }
    return data
  }

  static func download(
    _ update: AppUpdate,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    destinationDirectory: URL? = nil,
    progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> URL {
    var request = URLRequest(url: update.assetURL)
    request.timeoutInterval = 120
    request.setValue("SBM updater", forHTTPHeaderField: "User-Agent")

    let directory = try destinationDirectory ?? updateDirectory()
    let stagingURL = directory.appendingPathComponent(
      ".download-\(UUID().uuidString).tmp"
    )
    let transfer = UpdateDownloadTransfer(
      stagingURL: stagingURL,
      maximumBytes: min(update.expectedSize, maximumAssetSize),
      sessionConfiguration: sessionConfiguration,
      progress: progress
    )
    defer { try? FileManager.default.removeItem(at: stagingURL) }
    progress(0)
    let response = try await transfer.start(request)
    try Task.checkCancellation()

    guard let http = response as? HTTPURLResponse,
      http.statusCode == 200,
      http.url?.scheme?.lowercased() == "https"
    else {
      throw UpdateFailure.downloadFailed
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
    guard let size = attributes[.size] as? NSNumber,
      size.int64Value == update.expectedSize,
      size.int64Value <= maximumAssetSize
    else {
      throw UpdateFailure.assetSizeMismatch
    }
    try Task.checkCancellation()
    progress(1)
    guard try sha256(of: stagingURL) == update.expectedDigest else {
      throw UpdateFailure.assetDigestMismatch
    }
    try Task.checkCancellation()

    let destination = directory.appendingPathComponent(
      "SBM-\(update.version)-arm64.dmg"
    )
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: stagingURL, to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
    return destination
  }

  private static func updateDirectory() throws -> URL {
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
    return directory
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
    let lhs = normalizedCandidate.split(separator: ".").map { Int($0)! }
    let rhs = normalizedCurrent.split(separator: ".").map { Int($0)! }
    for index in 0..<3 {
      if lhs[index] != rhs[index] { return lhs[index] > rhs[index] }
    }
    return false
  }
}

final class UpdateDownloadTransfer: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let stagingURL: URL
  private let maximumBytes: Int64
  private let oversizeFailure: UpdateFailure
  private let sessionConfiguration: URLSessionConfiguration
  private let progressHandler: @Sendable (Double) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URLResponse, any Error>?
  private var session: URLSession?
  private var downloadTask: URLSessionDownloadTask?
  private var cancelled = false
  private var downloadResponse: URLResponse?
  private var transferError: (any Error)?

  init(
    stagingURL: URL,
    maximumBytes: Int64,
    oversizeFailure: UpdateFailure = .assetSizeMismatch,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    progress: @escaping @Sendable (Double) -> Void
  ) {
    self.stagingURL = stagingURL
    self.maximumBytes = maximumBytes
    self.oversizeFailure = oversizeFailure
    self.sessionConfiguration = sessionConfiguration
    progressHandler = progress
  }

  func start(_ request: URLRequest) async throws -> URLResponse {
    let response = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<URLResponse, any Error>) in
        lock.lock()
        guard !cancelled else {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        lock.unlock()

        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(
          configuration: configuration,
          delegate: self,
          delegateQueue: queue
        )
        let downloadTask = session.downloadTask(with: request)

        lock.lock()
        guard !cancelled, self.continuation != nil else {
          lock.unlock()
          downloadTask.cancel()
          session.invalidateAndCancel()
          return
        }
        self.session = session
        self.downloadTask = downloadTask
        lock.unlock()
        downloadTask.resume()
      }
    } onCancel: {
      self.cancel()
    }
    try Task.checkCancellation()
    return response
  }

  private func cancel() {
    lock.lock()
    cancelled = true
    let downloadTask = self.downloadTask
    let session = self.session
    let continuation: CheckedContinuation<URLResponse, any Error>?
    if downloadTask == nil {
      continuation = self.continuation
      self.continuation = nil
    } else {
      continuation = nil
    }
    let transferError = self.transferError
    lock.unlock()

    downloadTask?.cancel()
    session?.invalidateAndCancel()
    continuation?.resume(throwing: transferError ?? CancellationError())
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesWritten > maximumBytes
      || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > maximumBytes)
    {
      lock.lock()
      if transferError == nil {
        transferError = oversizeFailure
      }
      let shouldCancel = !cancelled
      lock.unlock()
      if shouldCancel { downloadTask.cancel() }
      return
    }
    guard totalBytesExpectedToWrite > 0 else { return }
    let fraction = min(
      1,
      max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    )
    progressHandler(fraction)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      if FileManager.default.fileExists(atPath: stagingURL.path) {
        try FileManager.default.removeItem(at: stagingURL)
      }
      try FileManager.default.moveItem(at: location, to: stagingURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: stagingURL.path
      )
      lock.lock()
      downloadResponse = downloadTask.response
      lock.unlock()
    } catch {
      lock.lock()
      transferError = error
      lock.unlock()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    let response = downloadResponse
    let finalError = transferError ?? (cancelled ? CancellationError() : error)
    self.session = nil
    self.downloadTask = nil
    lock.unlock()

    session.finishTasksAndInvalidate()
    if let finalError {
      continuation?.resume(throwing: finalError)
    } else if let response {
      continuation?.resume(returning: response)
    } else {
      continuation?.resume(throwing: UpdateFailure.downloadFailed)
    }
  }

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
  case publisherProofInvalid
  case downloadFailed
  case assetSizeMismatch
  case assetDigestMismatch

  var errorDescription: String? {
    switch self {
    case .releaseUnavailable: SBMText.localized("GitHub Releases is unavailable.")
    case .invalidResponse: SBMText.localized("GitHub returned an invalid update response.")
    case .verifiedAssetMissing:
      SBMText.localized("The release has no valid Apple Silicon DMG asset metadata.")
    case .publisherProofInvalid:
      SBMText.localized("SBM could not authenticate this update from its publisher.")
    case .downloadFailed: SBMText.localized("The update download failed.")
    case .assetSizeMismatch:
      SBMText.localized("The downloaded update size does not match the signed publisher proof.")
    case .assetDigestMismatch:
      SBMText.localized("The downloaded update does not match the signed publisher proof.")
    }
  }
}
