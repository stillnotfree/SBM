import CryptoKit
import Foundation
import SBMShared
import Synchronization
import Testing

@testable import SBM

private struct UpdaterHTTPFixture: Sendable {
  var statusCode = 200
  var body = Data()
  var finalURL: URL?
  var redirectURL: URL?
  var useURLSessionRedirectCallback = false
  var finishRedirectAsResponse = false
  var omitContentLength = false
  var firstChunkSize: Int?
  var streamInChunks = false
  var holdAfterFirstChunk = false
}

private struct UpdaterProtocolState: Sendable {
  var fixtures: [String: [String: UpdaterHTTPFixture]] = [:]
  var stoppedKeys: Set<String> = []
  var firstChunkKeys: Set<String> = []
  var firstChunkURLs: [String: Set<String>] = [:]
  var releasedKeys: Set<String> = []
  var stoppedURLs: Set<String> = []
  var releasedURLs: Set<String> = []
  var requestedSchemes: [String: Set<String>] = [:]
  var requestedURLs: [String: Set<String>] = [:]
}

private enum UpdaterProtocolRegistry {
  private static let state = Mutex(UpdaterProtocolState())

  static func install(_ fixture: UpdaterHTTPFixture, for key: String, path: String? = nil) {
    state.withLock {
      if path == nil || $0.fixtures[key] == nil {
        $0.fixtures[key] = [:]
        $0.stoppedKeys.remove(key)
        $0.stoppedURLs = $0.stoppedURLs.subtracting(
          $0.requestedURLs[key] ?? []
        )
        $0.releasedURLs = $0.releasedURLs.subtracting(
          $0.requestedURLs[key] ?? []
        )
        $0.firstChunkKeys.remove(key)
        $0.firstChunkURLs[key] = []
        $0.releasedKeys.remove(key)
        $0.requestedSchemes[key] = []
        $0.requestedURLs[key] = []
      }
      $0.fixtures[key, default: [:]][path ?? "*"] = fixture
    }
  }

  static func fixture(for key: String, url: URL?) -> UpdaterHTTPFixture? {
    state.withLock {
      guard let fixtures = $0.fixtures[key] else { return nil }
      return fixtures[url?.absoluteString ?? ""]
        ?? fixtures[url?.path ?? ""]
        ?? fixtures["*"]
    }
  }

  static func markStopped(_ key: String, url: URL?) {
    state.withLock {
      $0.stoppedKeys.insert(key)
      if let absoluteString = url?.absoluteString {
        $0.stoppedURLs.insert(absoluteString)
      }
    }
  }

  static func wasStopped(_ key: String) -> Bool {
    state.withLock { $0.stoppedKeys.contains(key) }
  }

  static func markFirstChunk(_ key: String, url: URL?) {
    state.withLock {
      $0.firstChunkKeys.insert(key)
      if let absoluteString = url?.absoluteString {
        $0.firstChunkURLs[key, default: []].insert(absoluteString)
      }
    }
  }

  static func receivedFirstChunk(_ key: String) -> Bool {
    state.withLock { $0.firstChunkKeys.contains(key) }
  }

  static func receivedFirstChunk(for url: URL, key: String) -> Bool {
    state.withLock { $0.firstChunkURLs[key, default: []].contains(url.absoluteString) }
  }

  static func release(_ key: String) {
    _ = state.withLock { $0.releasedKeys.insert(key) }
  }

  static func release(_ key: String, url: URL) {
    _ = state.withLock { $0.releasedURLs.insert(url.absoluteString) }
  }

  static func waitUntilReleasedOrStopped(_ key: String, url: URL?) {
    while !state.withLock({ state in
      if let absoluteString = url?.absoluteString {
        return state.releasedURLs.contains(absoluteString)
          || state.stoppedURLs.contains(absoluteString)
      }
      return state.releasedKeys.contains(key) || state.stoppedKeys.contains(key)
    }) {
      Thread.sleep(forTimeInterval: 0.001)
    }
  }

  static func wasStopped(_ key: String, url: URL?) -> Bool {
    state.withLock { state in
      guard let absoluteString = url?.absoluteString else {
        return state.stoppedKeys.contains(key)
      }
      return state.stoppedURLs.contains(absoluteString)
    }
  }

  static func recordRequest(_ url: URL?, for key: String) {
    guard let scheme = url?.scheme?.lowercased() else { return }
    state.withLock {
      $0.requestedSchemes[key, default: []].insert(scheme)
      if let absoluteString = url?.absoluteString {
        $0.requestedURLs[key, default: []].insert(absoluteString)
      }
    }
  }

  static func requestedScheme(_ scheme: String, for key: String) -> Bool {
    state.withLock { $0.requestedSchemes[key, default: []].contains(scheme) }
  }

  static func requestedURL(_ url: URL, for key: String) -> Bool {
    state.withLock { $0.requestedURLs[key, default: []].contains(url.absoluteString) }
  }

  static func remove(_ key: String) {
    state.withLock {
      $0.fixtures[key] = nil
      $0.stoppedKeys.remove(key)
      $0.stoppedURLs = $0.stoppedURLs.subtracting($0.requestedURLs[key] ?? [])
      $0.releasedURLs = $0.releasedURLs.subtracting($0.requestedURLs[key] ?? [])
      $0.firstChunkKeys.remove(key)
      $0.firstChunkURLs[key] = nil
      $0.releasedKeys.remove(key)
      $0.requestedSchemes[key] = nil
      $0.requestedURLs[key] = nil
    }
  }

  static func remove(_ key: String, path: String) {
    state.withLock {
      $0.fixtures[key]?[path] = nil
      $0.requestedURLs[key]?.remove(path)
      $0.firstChunkURLs[key]?.remove(path)
      $0.stoppedURLs.remove(path)
      $0.releasedURLs.remove(path)
      if $0.fixtures[key]?.isEmpty == true { $0.fixtures[key] = nil }
    }
  }
}

private actor TransferStartGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    opened = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

private final class UpdaterURLProtocol: URLProtocol, @unchecked Sendable {
  private let loadingQueue = DispatchQueue(label: "SBMTests.UpdaterURLProtocol")

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "api.github.com" || request.url?.host?.hasSuffix(".test") == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let key = request.value(forHTTPHeaderField: "User-Agent") ?? ""
    UpdaterProtocolRegistry.recordRequest(request.url, for: key)
    guard let fixture = UpdaterProtocolRegistry.fixture(for: key, url: request.url) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    if fixture.streamInChunks {
      DispatchQueue.global(qos: .utility).async { [self] in
        send(fixture, key: key)
      }
    } else {
      send(fixture, key: key)
    }
  }

  override func stopLoading() {
    let key = request.value(forHTTPHeaderField: "User-Agent") ?? ""
    UpdaterProtocolRegistry.markStopped(key, url: request.url)
  }

  private func send(_ fixture: UpdaterHTTPFixture, key: String) {
    guard let requestURL = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    if let redirectURL = fixture.redirectURL {
      guard
        let redirectResponse = HTTPURLResponse(
          url: requestURL,
          statusCode: 302,
          httpVersion: "HTTP/1.1",
          headerFields: ["Location": redirectURL.absoluteString, "Content-Length": "0"]
        )
      else { return }
      if fixture.useURLSessionRedirectCallback {
        var redirectedRequest = request
        redirectedRequest.url = redirectURL
        client?.urlProtocol(
          self,
          wasRedirectedTo: redirectedRequest,
          redirectResponse: redirectResponse
        )
        if fixture.finishRedirectAsResponse {
          client?.urlProtocol(self, didReceive: redirectResponse, cacheStoragePolicy: .notAllowed)
          client?.urlProtocolDidFinishLoading(self)
        }
      } else {
        client?.urlProtocol(self, didReceive: redirectResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
      }
      return
    }
    let headers = fixture.omitContentLength ? [:] : ["Content-Length": String(fixture.body.count)]
    guard
      let response = HTTPURLResponse(
        url: fixture.finalURL ?? requestURL,
        statusCode: fixture.statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

    let firstChunkSize = min(fixture.firstChunkSize ?? fixture.body.count, fixture.body.count)
    if firstChunkSize > 0 {
      let firstChunk = fixture.body.prefix(firstChunkSize)
      client?.urlProtocol(self, didLoad: Data(firstChunk))
      UpdaterProtocolRegistry.markFirstChunk(key, url: requestURL)
    }
    if fixture.streamInChunks {
      sendRemaining(fixture, key: key, offset: firstChunkSize)
      return
    }
    if firstChunkSize < fixture.body.count {
      let remaining = fixture.body.dropFirst(firstChunkSize)
      client?.urlProtocol(self, didLoad: Data(remaining))
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  private func sendRemaining(_ fixture: UpdaterHTTPFixture, key: String, offset: Int) {
    loadingQueue.async { [self] in
      if fixture.holdAfterFirstChunk {
        UpdaterProtocolRegistry.waitUntilReleasedOrStopped(key, url: request.url)
      }
      guard !UpdaterProtocolRegistry.wasStopped(key, url: request.url) else { return }
      guard offset < fixture.body.count else {
        client?.urlProtocolDidFinishLoading(self)
        return
      }
      let nextOffset = min(offset + 64 * 1_024, fixture.body.count)
      let chunk = Data(fixture.body.dropFirst(offset).prefix(nextOffset - offset))
      client?.urlProtocol(self, didLoad: chunk)
      sendRemaining(fixture, key: key, offset: nextOffset)
    }
  }
}

private enum ExpectedUpdateFailure: Equatable {
  case releaseUnavailable
  case invalidResponse
  case verifiedAssetMissing
  case publisherProofInvalid
  case downloadFailed
  case assetSizeMismatch
  case assetDigestMismatch
}

private func updateFailureKind(_ error: Error) -> ExpectedUpdateFailure? {
  guard let failure = error as? UpdateFailure else { return nil }
  switch failure {
  case .releaseUnavailable: return .releaseUnavailable
  case .invalidResponse: return .invalidResponse
  case .verifiedAssetMissing: return .verifiedAssetMissing
  case .publisherProofInvalid: return .publisherProofInvalid
  case .downloadFailed: return .downloadFailed
  case .assetSizeMismatch: return .assetSizeMismatch
  case .assetDigestMismatch: return .assetDigestMismatch
  }
}

private func stubbedConfiguration() -> URLSessionConfiguration {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [UpdaterURLProtocol.self]
  return configuration
}

private func releaseResponse(
  tagName: String = "v2.0.0",
  releaseURL: String = "https://github.com/stillnotfree/SBM/releases/tag/v2.0.0",
  assetName: String = "SBM-2.0.0-arm64.dmg",
  assetURL: String =
    "https://github.com/stillnotfree/SBM/releases/download/v2.0.0/SBM-2.0.0-arm64.dmg",
  size: Int64 = 128,
  digest: String? = "sha256:" + String(repeating: "a", count: 64),
  additionalAssets: [[String: Any]] = [],
  padding: Int = 0
) throws -> Data {
  var asset: [String: Any] = [
    "name": assetName,
    "size": size,
    "browser_download_url": assetURL,
  ]
  if let digest { asset["digest"] = digest }
  var release: [String: Any] = [
    "tag_name": tagName,
    "html_url": releaseURL,
    "assets": additionalAssets + [asset],
  ]
  if padding > 0 { release["body"] = String(repeating: "x", count: padding) }
  return try JSONSerialization.data(withJSONObject: release, options: [.sortedKeys])
}

private func updateProofAsset(
  name: String = "SBM-2.0.0-arm64.update.json",
  size: Int64 = 1,
  url: String = "https://downloads.example.test/SBM-2.0.0-arm64.update.json"
) -> [String: Any] {
  ["name": name, "size": size, "browser_download_url": url]
}

private func metadataStagingFiles(in directory: URL) throws -> Set<String> {
  return Set(
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0.hasPrefix("SBM-release-metadata-")
    }
  )
}

private func proofStagingFiles(in directory: URL) throws -> Set<String> {
  Set(
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0.hasPrefix("SBM-update-proof-")
    }
  )
}

private func waitForUpdaterRequest(_ key: String) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !UpdaterProtocolRegistry.requestedScheme("https", for: key),
    ContinuousClock.now < deadline
  {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return UpdaterProtocolRegistry.requestedScheme("https", for: key)
}

private func waitForUpdaterURL(_ url: URL, key: String) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !UpdaterProtocolRegistry.requestedURL(url, for: key),
    ContinuousClock.now < deadline
  {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return UpdaterProtocolRegistry.requestedURL(url, for: key)
}

private func waitForUpdaterFirstChunk(_ key: String) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !UpdaterProtocolRegistry.receivedFirstChunk(key),
    ContinuousClock.now < deadline
  {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return UpdaterProtocolRegistry.receivedFirstChunk(key)
}

private func waitForUpdaterFirstChunk(for url: URL, key: String) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !UpdaterProtocolRegistry.receivedFirstChunk(for: url, key: key),
    ContinuousClock.now < deadline
  {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return UpdaterProtocolRegistry.receivedFirstChunk(for: url, key: key)
}

private func sha256Hex(_ data: Data) -> String {
  Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
}

private func downloadUpdate(
  version: String,
  url: URL,
  expectedSize: Int64,
  expectedDigest: String
) -> AppUpdate {
  AppUpdate(
    version: version,
    assetURL: url,
    expectedDigest: expectedDigest,
    expectedSize: expectedSize
  )
}

private func downloadStagingFiles(in directory: URL) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { $0.hasPrefix(".download-") && $0.hasSuffix(".tmp") }
}

private func downloadedFileMode(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func uniqueDownloadDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "sbm-f06-download-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: false
  )
  return directory
}

private func expectLatestFailure(
  _ expected: ExpectedUpdateFailure,
  currentVersion: String = "1.0.0",
  body: Data,
  finalURL: URL? = nil
) async throws {
  let key = "SBM/\(currentVersion)"
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: body, finalURL: finalURL),
    for: key
  )
  defer { UpdaterProtocolRegistry.remove(key) }
  do {
    _ = try await UpdateService.latest(
      currentVersion: currentVersion,
      sessionConfiguration: stubbedConfiguration()
    )
    Issue.record("Expected UpdateFailure.\(expected)")
  } catch {
    #expect(updateFailureKind(error) == expected)
  }
}

@Test func updateVersionNormalization() {
  #expect(UpdateService.normalizedVersion("v1.0.0") == "1.0.0")
  #expect(UpdateService.normalizedVersion(" 1.0.0\n") == "1.0.0")
  #expect(UpdateService.normalizedVersion("../1.0.0") == nil)
  #expect(UpdateService.normalizedVersion("1.0") == nil)
  #expect(UpdateService.normalizedVersion("1.0.0-beta") == nil)
  #expect(UpdateService.normalizedVersion("01.0.0") == nil)
}

@Test func updateVersionComparison() {
  #expect(UpdateService.isNewer("0.5.0", than: "0.4.9"))
  #expect(UpdateService.isNewer("0.5.1", than: "0.5.0"))
  #expect(UpdateService.isNewer("1.0.0", than: "0.99.99"))
  #expect(!UpdateService.isNewer("1.0", than: "0.99.99"))
  #expect(!UpdateService.isNewer("0.5.0", than: "0.5.0"))
  #expect(!UpdateService.isNewer("0.4.9", than: "0.5.0"))
}

@Test func updaterLocalizationUsesPublisherAuthenticationLanguageInAllLocales() throws {
  let keys = [
    "SBM could not authenticate this update from its publisher.",
    "DMG authenticated by the SBM project publisher and opened",
    "The downloaded update does not match the signed publisher proof.",
  ]
  for language in ["en", "ru", "zh-Hans"] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/SBM/Resources/\(language).lproj/Localizable.strings")
    let contents = try String(contentsOf: url, encoding: .utf8)
    for key in keys {
      #expect(contents.components(separatedBy: "\"\(key)\" = ").count - 1 == 1)
    }
    #expect(!contents.contains("DMG SHA-256 verified and opened"))
    #expect(!contents.contains("The release has no SHA-256 verified Apple Silicon DMG."))
  }
}

@Test func updateCompositionUsesSignedFactsAndRejectsGitHubReplacementFacts() throws {
  let key = Curve25519.Signing.PrivateKey()
  let publicKey = key.publicKey.rawRepresentation
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: publicKey)
  let payload = UpdateArtifactProofPayload(
    keyID: keyID,
    appVersion: "2.0.0",
    assetName: "SBM-2.0.0-arm64.dmg",
    assetSize: 128,
    assetSHA256: String(repeating: "a", count: 64)
  )
  let proof = try UpdateArtifactProof.sign(payload, with: key)
  let verified = try UpdateArtifactProof.verify(
    proof,
    publicKey: publicKey,
    expectedKeyID: keyID
  )
  let assetURL = URL(string: "https://downloads.example.test/SBM-2.0.0-arm64.dmg")!
  let update = try UpdateService.composeUpdate(
    tagVersion: "2.0.0",
    assetURL: assetURL,
    githubSize: 128,
    githubDigest: String(repeating: "a", count: 64),
    proof: verified
  )
  #expect(update.version == "2.0.0")
  #expect(update.expectedSize == 128)
  #expect(update.expectedDigest == String(repeating: "a", count: 64))

  for (tagVersion, size, digest) in [
    ("2.0.1", Int64(128), String(repeating: "a", count: 64)),
    ("2.0.0", Int64(129), String(repeating: "a", count: 64)),
    ("2.0.0", Int64(128), String(repeating: "b", count: 64)),
  ] {
    do {
      _ = try UpdateService.composeUpdate(
        tagVersion: tagVersion,
        assetURL: assetURL,
        githubSize: size,
        githubDigest: digest,
        proof: verified
      )
      Issue.record("Expected GitHub metadata to disagree with the signed proof")
    } catch {
      #expect(updateFailureKind(error) == .publisherProofInvalid)
    }
  }
}

@Test func latestRequiresOneExpectedDmgAndPublisherProof() async throws {
  let duplicateDMG: [String: Any] = [
    "name": "SBM-2.0.0-arm64.dmg",
    "size": 128,
    "digest": "sha256:" + String(repeating: "a", count: 64),
    "browser_download_url": "https://downloads.example.test/duplicate.dmg",
  ]
  try await expectLatestFailure(
    .verifiedAssetMissing,
    body: try releaseResponse(additionalAssets: [duplicateDMG])
  )
  try await expectLatestFailure(
    .publisherProofInvalid,
    body: try releaseResponse()
  )
  try await expectLatestFailure(
    .publisherProofInvalid,
    body: try releaseResponse(additionalAssets: [
      updateProofAsset(), updateProofAsset(),
    ])
  )
  try await expectLatestFailure(
    .publisherProofInvalid,
    body: try releaseResponse(additionalAssets: [
      updateProofAsset(url: "http://downloads.example.test/proof.json")
    ])
  )
  try await expectLatestFailure(
    .publisherProofInvalid,
    body: try releaseResponse(additionalAssets: [
      updateProofAsset(size: Int64(UpdateArtifactProof.maximumEnvelopeBytes + 1))
    ])
  )

  let metadataKey = "SBM/1.0.79"
  let proofKey = "SBM updater proof"
  let ephemeralKey = Curve25519.Signing.PrivateKey()
  let invalidSignatureProof = try UpdateArtifactProof.sign(
    UpdateArtifactProofPayload(
      keyID: CurrentReleaseManifest.projectKeyID,
      appVersion: "2.0.0",
      assetName: "SBM-2.0.0-arm64.dmg",
      assetSize: 128,
      assetSHA256: String(repeating: "a", count: 64)
    ),
    with: ephemeralKey
  )
  let metadata = try releaseResponse(
    additionalAssets: [updateProofAsset(size: Int64(invalidSignatureProof.count))]
  )
  UpdaterProtocolRegistry.install(UpdaterHTTPFixture(body: metadata), for: metadataKey)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: invalidSignatureProof),
    for: proofKey,
    path: "/SBM-2.0.0-arm64.update.json"
  )
  defer {
    UpdaterProtocolRegistry.remove(metadataKey)
    UpdaterProtocolRegistry.remove(proofKey)
  }
  do {
    _ = try await UpdateService.latest(
      currentVersion: "1.0.79",
      sessionConfiguration: stubbedConfiguration()
    )
    Issue.record("Expected the non-project proof signature to fail")
  } catch {
    #expect(updateFailureKind(error) == .publisherProofInvalid)
  }
  #expect(UpdaterProtocolRegistry.requestedScheme("https", for: proofKey))
}

@Test func updateMetadataTransferIsBoundedValidatedAndCleaned() async throws {
  let key = "SBM/1.0.0"
  let isolatedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "SBM-UpdateServiceTests-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: isolatedDirectory,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700]
  )
  defer { try? FileManager.default.removeItem(at: isolatedDirectory) }
  let siblingURL = isolatedDirectory.appendingPathComponent(
    "SBM-release-metadata-unrelated.tmp"
  )
  let siblingContents = Data("unrelated sibling bytes owned by this test".utf8)
  try siblingContents.write(to: siblingURL)
  defer { UpdaterProtocolRegistry.remove(key) }
  let wrongAsset: [String: Any] = [
    "name": "SBM-2.0.0-x86_64.dmg",
    "size": 128,
    "digest": "sha256:" + String(repeating: "b", count: 64),
    "browser_download_url": "https://example.test/wrong.dmg",
  ]
  let boundedBody = try releaseResponse(
    additionalAssets: [wrongAsset, updateProofAsset(size: 1)],
    padding: 1_047_000
  )
  #expect(boundedBody.count <= 1_048_576)
  let malformedProof = Data("x".utf8)
  UpdaterProtocolRegistry.install(UpdaterHTTPFixture(body: boundedBody), for: key)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: malformedProof),
    for: "SBM updater proof",
    path: "/SBM-2.0.0-arm64.update.json"
  )
  do {
    _ = try await UpdateService.latest(
      currentVersion: "1.0.0",
      sessionConfiguration: stubbedConfiguration(),
      stagingDirectory: isolatedDirectory
    )
    Issue.record("Expected malformed publisher proof to fail closed")
  } catch {
    #expect(updateFailureKind(error) == .publisherProofInvalid)
  }
  #expect(
    try metadataStagingFiles(in: isolatedDirectory)
      == Set([siblingURL.lastPathComponent]))
  #expect(try proofStagingFiles(in: isolatedDirectory).isEmpty)
  #expect(try Data(contentsOf: siblingURL) == siblingContents)
  UpdaterProtocolRegistry.remove(key)
  UpdaterProtocolRegistry.remove("SBM updater proof")

  let oversizedBody = try releaseResponse(padding: 4 * 1_024 * 1_024)
  #expect(oversizedBody.count > 1_048_576)
  let oversizedFixture = UpdaterHTTPFixture(
    body: oversizedBody,
    firstChunkSize: 1_048_577,
    streamInChunks: true
  )
  UpdaterProtocolRegistry.install(oversizedFixture, for: key)
  do {
    _ = try await UpdateService.latest(
      currentVersion: "1.0.0",
      sessionConfiguration: stubbedConfiguration(),
      stagingDirectory: isolatedDirectory
    )
    Issue.record("Expected oversized release metadata to fail during transfer")
  } catch {
    #expect(updateFailureKind(error) == .invalidResponse)
  }
  #expect(UpdaterProtocolRegistry.wasStopped(key))
  #expect(
    try metadataStagingFiles(in: isolatedDirectory)
      == Set([siblingURL.lastPathComponent]))
  #expect(try Data(contentsOf: siblingURL) == siblingContents)
  UpdaterProtocolRegistry.remove(key)

  let heldBody = try releaseResponse(padding: 2_048)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(
      body: heldBody,
      firstChunkSize: 128,
      streamInChunks: true,
      holdAfterFirstChunk: true
    ),
    for: key
  )
  let cancelledCheck = Task {
    try await UpdateService.latest(
      currentVersion: "1.0.0",
      sessionConfiguration: stubbedConfiguration(),
      stagingDirectory: isolatedDirectory
    )
  }
  #expect(await waitForUpdaterRequest(key))
  #expect(await waitForUpdaterFirstChunk(key))
  cancelledCheck.cancel()
  await #expect(throws: CancellationError.self) { _ = try await cancelledCheck.value }
  #expect(UpdaterProtocolRegistry.wasStopped(key))
  #expect(
    try metadataStagingFiles(in: isolatedDirectory)
      == Set([siblingURL.lastPathComponent]))
  #expect(try Data(contentsOf: siblingURL) == siblingContents)
  UpdaterProtocolRegistry.remove(key)

  let zeroSize = try releaseResponse(size: 0)
  try await expectLatestFailure(.verifiedAssetMissing, body: zeroSize)
  let oversizedAsset = try releaseResponse(size: 200 * 1_024 * 1_024 + 1)
  try await expectLatestFailure(.verifiedAssetMissing, body: oversizedAsset)
  let missingDigest = try releaseResponse(digest: nil)
  try await expectLatestFailure(.verifiedAssetMissing, body: missingDigest)
  let invalidDigest = try releaseResponse(digest: "sha256:abc")
  try await expectLatestFailure(.verifiedAssetMissing, body: invalidDigest)
  let insecureAsset = try releaseResponse(assetURL: "http://example.test/release.dmg")
  try await expectLatestFailure(.verifiedAssetMissing, body: insecureAsset)
  let insecureRelease = try releaseResponse(releaseURL: "http://github.com/release")
  try await expectLatestFailure(.verifiedAssetMissing, body: insecureRelease)

  let oldRelease = try releaseResponse(tagName: "v1.0.0")
  let oldKey = "SBM/1.0.0"
  UpdaterProtocolRegistry.install(UpdaterHTTPFixture(body: oldRelease), for: oldKey)
  let noUpdate = try await UpdateService.latest(
    currentVersion: "1.0.0",
    sessionConfiguration: stubbedConfiguration()
  )
  #expect(noUpdate == nil)
  UpdaterProtocolRegistry.remove(oldKey)

  let finalHTTPURL = URL(string: "http://api.github.com/releases/latest")!
  try await expectLatestFailure(
    .releaseUnavailable,
    body: try releaseResponse(),
    finalURL: finalHTTPURL
  )
}

@Test func publisherProofTransferCancellationCleansItsStagingFile() async throws {
  let metadataKey = "SBM/1.0.37"
  let proofKey = "SBM updater proof"
  let isolatedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "SBM-UpdateProofCancellation-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: isolatedDirectory,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700]
  )
  defer {
    try? FileManager.default.removeItem(at: isolatedDirectory)
    UpdaterProtocolRegistry.remove(metadataKey)
    UpdaterProtocolRegistry.remove(proofKey)
  }
  let proofBody = Data(repeating: 0x5a, count: 4_096)
  let metadata = try releaseResponse(
    additionalAssets: [updateProofAsset(size: Int64(proofBody.count))]
  )
  UpdaterProtocolRegistry.install(UpdaterHTTPFixture(body: metadata), for: metadataKey)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(
      body: proofBody,
      firstChunkSize: 128,
      streamInChunks: true,
      holdAfterFirstChunk: true
    ),
    for: proofKey,
    path: "/SBM-2.0.0-arm64.update.json"
  )
  let check = Task {
    try await UpdateService.latest(
      currentVersion: "1.0.37",
      sessionConfiguration: stubbedConfiguration(),
      stagingDirectory: isolatedDirectory
    )
  }
  #expect(await waitForUpdaterRequest(metadataKey))
  #expect(await waitForUpdaterRequest(proofKey))
  #expect(await waitForUpdaterFirstChunk(proofKey))
  check.cancel()
  await #expect(throws: CancellationError.self) { _ = try await check.value }
  #expect(UpdaterProtocolRegistry.wasStopped(proofKey))
  #expect(try proofStagingFiles(in: isolatedDirectory).isEmpty)
  #expect(try metadataStagingFiles(in: isolatedDirectory).isEmpty)
}

@Test func oversizedPublisherProofTransferFailsWithBoundedPublisherError() async throws {
  let metadataKey = "SBM/1.0.83"
  let proofKey = "SBM updater proof"
  let isolatedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "SBM-OversizedUpdateProof-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: isolatedDirectory,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700]
  )
  defer {
    try? FileManager.default.removeItem(at: isolatedDirectory)
    UpdaterProtocolRegistry.remove(metadataKey)
    UpdaterProtocolRegistry.remove(proofKey)
  }
  let body = Data(repeating: 0x4b, count: UpdateArtifactProof.maximumEnvelopeBytes + 1)
  let metadata = try releaseResponse(additionalAssets: [updateProofAsset(size: 1)])
  UpdaterProtocolRegistry.install(UpdaterHTTPFixture(body: metadata), for: metadataKey)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: body),
    for: proofKey,
    path: "/SBM-2.0.0-arm64.update.json"
  )

  do {
    _ = try await UpdateService.latest(
      currentVersion: "1.0.83",
      sessionConfiguration: stubbedConfiguration(),
      stagingDirectory: isolatedDirectory
    )
    Issue.record("Expected an oversized publisher proof to fail")
  } catch {
    #expect(updateFailureKind(error) == .publisherProofInvalid)
  }
  #expect(UpdaterProtocolRegistry.wasStopped(proofKey))
  #expect(try proofStagingFiles(in: isolatedDirectory).isEmpty)
}

@Test func updateDownloadTransferBoundsAssets() async throws {
  let requestURL = URL(string: "https://downloads.example.test/update.dmg")!
  let requestKey = "s4-update-normal"
  let body = Data(repeating: 0x5a, count: 64 * 1_024)
  UpdaterProtocolRegistry.install(UpdaterHTTPFixture(body: body), for: requestKey)
  var request = URLRequest(url: requestURL)
  request.setValue(requestKey, forHTTPHeaderField: "User-Agent")
  let normalStagingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "sbm-s4-normal-\(UUID().uuidString).tmp"
  )
  defer { try? FileManager.default.removeItem(at: normalStagingURL) }
  let normalTransfer = UpdateDownloadTransfer(
    stagingURL: normalStagingURL,
    maximumBytes: Int64(body.count),
    sessionConfiguration: stubbedConfiguration(),
    progress: { _ in }
  )
  let normalTask = Task { try await normalTransfer.start(request) }
  let response = try await normalTask.value
  normalTask.cancel()
  #expect((response as? HTTPURLResponse)?.statusCode == 200)
  #expect(try Data(contentsOf: normalStagingURL) == body)
  UpdaterProtocolRegistry.remove(requestKey)

  let oversizedKey = "s4-update-oversized"
  let oversizedBody = Data(repeating: 0x7b, count: 3 * 1_024 * 1_024)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(
      body: oversizedBody,
      firstChunkSize: 1_025,
      streamInChunks: true
    ),
    for: oversizedKey
  )
  var oversizedRequest = URLRequest(url: requestURL)
  oversizedRequest.setValue(oversizedKey, forHTTPHeaderField: "User-Agent")
  let oversizedStagingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "sbm-s4-oversized-\(UUID().uuidString).tmp"
  )
  defer { try? FileManager.default.removeItem(at: oversizedStagingURL) }
  let oversizedTransfer = UpdateDownloadTransfer(
    stagingURL: oversizedStagingURL,
    maximumBytes: 1_024,
    sessionConfiguration: stubbedConfiguration(),
    progress: { _ in }
  )
  do {
    _ = try await oversizedTransfer.start(oversizedRequest)
    Issue.record("Expected oversized asset to fail")
  } catch {
    #expect(updateFailureKind(error) == .assetSizeMismatch)
  }
  #expect(UpdaterProtocolRegistry.wasStopped(oversizedKey))
  #expect(!FileManager.default.fileExists(atPath: oversizedStagingURL.path))
  UpdaterProtocolRegistry.remove(oversizedKey)

}

@Test func updateDownloadTransferFollowsHTTPSRedirectThroughURLSessionDelegate() async throws {
  let key = "s4-update-https-redirect-\(UUID().uuidString)"
  let initialURL = URL(string: "https://redirect-chain.example.test/initial")!
  let targetURL = URL(string: "https://redirect-chain.example.test/final")!
  let body = Data("redirected final DMG bytes".utf8)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: body),
    for: key,
    path: targetURL.absoluteString
  )
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(
      redirectURL: targetURL,
      useURLSessionRedirectCallback: true
    ),
    for: key,
    path: initialURL.absoluteString
  )
  defer { UpdaterProtocolRegistry.remove(key) }

  var request = URLRequest(url: initialURL)
  request.setValue(key, forHTTPHeaderField: "User-Agent")
  request.timeoutInterval = 3
  let directory = try uniqueDownloadDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let stagingURL = directory.appendingPathComponent("redirect-stage.tmp")
  let transfer = UpdateDownloadTransfer(
    stagingURL: stagingURL,
    maximumBytes: Int64(body.count),
    sessionConfiguration: stubbedConfiguration(),
    progress: { _ in }
  )

  let response = try await transfer.start(request)
  #expect((response as? HTTPURLResponse)?.statusCode == 200)
  #expect(await waitForUpdaterURL(initialURL, key: key))
  #expect(await waitForUpdaterURL(targetURL, key: key))
  #expect(UpdaterProtocolRegistry.requestedScheme("https", for: key))
  #expect(try Data(contentsOf: stagingURL) == body)
}

@Test func updateDownloadRejectsURLSessionHTTPSDowngradeBeforePublication() async throws {
  let key = "SBM updater"
  let initialURL = URL(string: "https://downgrade.example.test/initial-\(UUID().uuidString)")!
  let targetURL = URL(string: "http://downgrade.example.test/insecure.dmg")!
  let body = Data("signed artifact bytes".utf8)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(
      redirectURL: targetURL,
      useURLSessionRedirectCallback: true,
      finishRedirectAsResponse: true
    ),
    for: key,
    path: initialURL.absoluteString
  )
  defer { UpdaterProtocolRegistry.remove(key, path: initialURL.absoluteString) }

  let directory = try uniqueDownloadDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let update = downloadUpdate(
    version: "2.0.0-\(UUID().uuidString)",
    url: initialURL,
    expectedSize: Int64(body.count),
    expectedDigest: sha256Hex(body)
  )
  do {
    _ = try await UpdateService.download(
      update,
      sessionConfiguration: stubbedConfiguration(),
      destinationDirectory: directory
    )
    Issue.record("Expected the public download owner to reject the HTTPS downgrade")
  } catch {
    #expect(updateFailureKind(error) == .downloadFailed)
  }
  #expect(await waitForUpdaterURL(initialURL, key: key))
  #expect(!UpdaterProtocolRegistry.requestedURL(targetURL, for: key))
  #expect(!UpdaterProtocolRegistry.requestedScheme("http", for: key))
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("SBM-\(update.version)-arm64.dmg").path
    ))
  #expect(try downloadStagingFiles(in: directory).isEmpty)
}

@Test func updateServiceDownloadPublishesExactContentLengthArtifact() async throws {
  let key = "SBM updater"
  let assetURL = URL(string: "https://public-download.example.test/exact-\(UUID().uuidString).dmg")!
  let body = Data("signed bytes with a known response length".utf8)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: body),
    for: key,
    path: assetURL.absoluteString
  )
  defer { UpdaterProtocolRegistry.remove(key, path: assetURL.absoluteString) }
  let directory = try uniqueDownloadDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let version = "2.0.0-\(UUID().uuidString)"
  let update = downloadUpdate(
    version: version,
    url: assetURL,
    expectedSize: Int64(body.count),
    expectedDigest: sha256Hex(body)
  )
  let observedProgress = Mutex<[Double]>([])

  let destination = try await UpdateService.download(
    update,
    sessionConfiguration: stubbedConfiguration(),
    destinationDirectory: directory,
    progress: { fraction in observedProgress.withLock { $0.append(fraction) } }
  )

  #expect(destination == directory.appendingPathComponent("SBM-\(version)-arm64.dmg"))
  #expect(try Data(contentsOf: destination) == body)
  #expect(try downloadedFileMode(destination) == 0o600)
  let progress = observedProgress.withLock { $0 }
  #expect(progress.first == 0)
  #expect(progress.allSatisfy { 0...1 ~= $0 })
  #expect(progress.last == 1)
  #expect(try downloadStagingFiles(in: directory).isEmpty)
}

@Test func updateServiceDownloadAcceptsUnknownLengthWhenFinalBytesMatch() async throws {
  let key = "SBM updater"
  let assetURL = URL(
    string: "https://public-download.example.test/unknown-\(UUID().uuidString).dmg")!
  let body = Data("exact bytes without positive Content-Length".utf8)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: body, omitContentLength: true),
    for: key,
    path: assetURL.absoluteString
  )
  defer { UpdaterProtocolRegistry.remove(key, path: assetURL.absoluteString) }
  let directory = try uniqueDownloadDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let version = "2.0.0-\(UUID().uuidString)"
  let update = downloadUpdate(
    version: version,
    url: assetURL,
    expectedSize: Int64(body.count),
    expectedDigest: sha256Hex(body)
  )

  let destination = try await UpdateService.download(
    update,
    sessionConfiguration: stubbedConfiguration(),
    destinationDirectory: directory
  )
  #expect(try Data(contentsOf: destination) == body)
  #expect(try downloadedFileMode(destination) == 0o600)
  #expect(try downloadStagingFiles(in: directory).isEmpty)
}

@Test func updateServiceDownloadPreservesOldFileOnDigestMismatch() async throws {
  let key = "SBM updater"
  let assetURL = URL(
    string: "https://public-download.example.test/digest-\(UUID().uuidString).dmg")!
  let body = Data("wrong but correctly sized artifact".utf8)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: body),
    for: key,
    path: assetURL.absoluteString
  )
  defer { UpdaterProtocolRegistry.remove(key, path: assetURL.absoluteString) }
  let directory = try uniqueDownloadDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let version = "2.0.0-\(UUID().uuidString)"
  let destination = directory.appendingPathComponent("SBM-\(version)-arm64.dmg")
  let oldBytes = Data("pre-existing destination".utf8)
  try oldBytes.write(to: destination)
  let update = downloadUpdate(
    version: version,
    url: assetURL,
    expectedSize: Int64(body.count),
    expectedDigest: sha256Hex(Data("different signed bytes".utf8))
  )

  do {
    _ = try await UpdateService.download(
      update,
      sessionConfiguration: stubbedConfiguration(),
      destinationDirectory: directory
    )
    Issue.record("Expected a signed digest mismatch")
  } catch {
    #expect(updateFailureKind(error) == .assetDigestMismatch)
  }
  #expect(try Data(contentsOf: destination) == oldBytes)
  #expect(try downloadStagingFiles(in: directory).isEmpty)
}

@Test func updateServiceDownloadPreservesOldFileOnShortBody() async throws {
  let key = "SBM updater"
  let assetURL = URL(string: "https://public-download.example.test/short-\(UUID().uuidString).dmg")!
  let body = Data("short body".utf8)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: body),
    for: key,
    path: assetURL.absoluteString
  )
  defer { UpdaterProtocolRegistry.remove(key, path: assetURL.absoluteString) }
  let directory = try uniqueDownloadDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let version = "2.0.0-\(UUID().uuidString)"
  let destination = directory.appendingPathComponent("SBM-\(version)-arm64.dmg")
  let oldBytes = Data("old signed destination".utf8)
  try oldBytes.write(to: destination)
  let update = downloadUpdate(
    version: version,
    url: assetURL,
    expectedSize: Int64(body.count + 5),
    expectedDigest: sha256Hex(body)
  )

  do {
    _ = try await UpdateService.download(
      update,
      sessionConfiguration: stubbedConfiguration(),
      destinationDirectory: directory
    )
    Issue.record("Expected an asset size mismatch")
  } catch {
    #expect(updateFailureKind(error) == .assetSizeMismatch)
  }
  #expect(try Data(contentsOf: destination) == oldBytes)
  #expect(try downloadStagingFiles(in: directory).isEmpty)
}

@Test func updateServiceDownloadPreservesOldFileOnOversizedBody() async throws {
  let key = "SBM updater"
  let assetURL = URL(
    string: "https://public-download.example.test/oversized-\(UUID().uuidString).dmg")!
  let body = Data(repeating: 0x6a, count: 4_096)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: body, streamInChunks: true),
    for: key,
    path: assetURL.absoluteString
  )
  defer { UpdaterProtocolRegistry.remove(key, path: assetURL.absoluteString) }
  let directory = try uniqueDownloadDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let version = "2.0.0-\(UUID().uuidString)"
  let destination = directory.appendingPathComponent("SBM-\(version)-arm64.dmg")
  let oldBytes = Data("old signed destination".utf8)
  try oldBytes.write(to: destination)
  let update = downloadUpdate(
    version: version,
    url: assetURL,
    expectedSize: 32,
    expectedDigest: sha256Hex(body)
  )

  do {
    _ = try await UpdateService.download(
      update,
      sessionConfiguration: stubbedConfiguration(),
      destinationDirectory: directory
    )
    Issue.record("Expected an oversized asset to fail closed")
  } catch {
    #expect(updateFailureKind(error) == .assetSizeMismatch)
  }
  #expect(try Data(contentsOf: destination) == oldBytes)
  #expect(try downloadStagingFiles(in: directory).isEmpty)
}

@Test func updateServiceDownloadReplacesOldFileWithSecureArtifact() async throws {
  let key = "SBM updater"
  let assetURL = URL(
    string: "https://public-download.example.test/replace-\(UUID().uuidString).dmg")!
  let body = Data("new exact signed artifact".utf8)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: body),
    for: key,
    path: assetURL.absoluteString
  )
  defer { UpdaterProtocolRegistry.remove(key, path: assetURL.absoluteString) }
  let directory = try uniqueDownloadDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let version = "2.0.0-\(UUID().uuidString)"
  let destination = directory.appendingPathComponent("SBM-\(version)-arm64.dmg")
  try Data("old artifact".utf8).write(to: destination)
  let update = downloadUpdate(
    version: version,
    url: assetURL,
    expectedSize: Int64(body.count),
    expectedDigest: sha256Hex(body)
  )

  let published = try await UpdateService.download(
    update,
    sessionConfiguration: stubbedConfiguration(),
    destinationDirectory: directory
  )
  #expect(published == destination)
  #expect(try Data(contentsOf: published) == body)
  #expect(try downloadedFileMode(published) == 0o600)
  #expect(try downloadStagingFiles(in: directory).isEmpty)
}

@Test func updateServiceDownloadCancellationPreservesOldFileAndCleansStaging() async throws {
  let key = "SBM updater"
  let assetURL = URL(
    string: "https://public-download.example.test/cancel-\(UUID().uuidString).dmg")!
  let body = Data(repeating: 0x7d, count: 64 * 1_024)
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(
      body: body,
      firstChunkSize: 512,
      streamInChunks: true,
      holdAfterFirstChunk: true
    ),
    for: key,
    path: assetURL.absoluteString
  )
  defer { UpdaterProtocolRegistry.remove(key, path: assetURL.absoluteString) }
  let directory = try uniqueDownloadDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let version = "2.0.0-\(UUID().uuidString)"
  let destination = directory.appendingPathComponent("SBM-\(version)-arm64.dmg")
  let oldBytes = Data("old artifact survives cancellation".utf8)
  try oldBytes.write(to: destination)
  let update = downloadUpdate(
    version: version,
    url: assetURL,
    expectedSize: Int64(body.count),
    expectedDigest: sha256Hex(body)
  )
  let task = Task {
    try await UpdateService.download(
      update,
      sessionConfiguration: stubbedConfiguration(),
      destinationDirectory: directory
    )
  }
  #expect(await waitForUpdaterURL(assetURL, key: key))
  #expect(await waitForUpdaterFirstChunk(for: assetURL, key: key))
  task.cancel()
  UpdaterProtocolRegistry.release(key, url: assetURL)
  do {
    _ = try await task.value
    Issue.record("Expected the cancelled public download to fail")
  } catch {
    #expect(error is CancellationError || updateFailureKind(error) != nil)
  }
  #expect(try Data(contentsOf: destination) == oldBytes)
  #expect(try downloadStagingFiles(in: directory).isEmpty)
}

@Test func updateDownloadTransferCancellationBeforeAndAfterTaskInstallIsExactlyOnce() async throws {
  let requestURL = URL(string: "https://downloads.example.test/update.dmg")!
  let preStartKey = "s4-update-cancel-before-start"
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(body: Data(repeating: 0x41, count: 1_024)),
    for: preStartKey
  )
  var preStartRequest = URLRequest(url: requestURL)
  preStartRequest.setValue(preStartKey, forHTTPHeaderField: "User-Agent")
  let preStartURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "sbm-cancel-before-\(UUID().uuidString).tmp"
  )
  let preStartTransfer = UpdateDownloadTransfer(
    stagingURL: preStartURL,
    maximumBytes: 1_024,
    sessionConfiguration: stubbedConfiguration(),
    progress: { _ in }
  )
  let gate = TransferStartGate()
  let preStartTask = Task {
    await gate.wait()
    return try await preStartTransfer.start(preStartRequest)
  }
  preStartTask.cancel()
  await gate.release()
  await #expect(throws: CancellationError.self) { _ = try await preStartTask.value }
  #expect(!UpdaterProtocolRegistry.requestedScheme("https", for: preStartKey))
  #expect(!FileManager.default.fileExists(atPath: preStartURL.path))
  UpdaterProtocolRegistry.remove(preStartKey)

  let activeKey = "s4-update-cancel-active"
  UpdaterProtocolRegistry.install(
    UpdaterHTTPFixture(
      body: Data(repeating: 0x72, count: 64 * 1_024),
      firstChunkSize: 512,
      streamInChunks: true,
      holdAfterFirstChunk: true
    ),
    for: activeKey
  )
  var activeRequest = URLRequest(url: requestURL)
  activeRequest.setValue(activeKey, forHTTPHeaderField: "User-Agent")
  let activeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "sbm-cancel-active-\(UUID().uuidString).tmp"
  )
  let activeTransfer = UpdateDownloadTransfer(
    stagingURL: activeURL,
    maximumBytes: 64 * 1_024,
    sessionConfiguration: stubbedConfiguration(),
    progress: { _ in }
  )
  let activeTask = Task { try await activeTransfer.start(activeRequest) }
  #expect(await waitForUpdaterRequest(activeKey))
  activeTask.cancel()
  await #expect(throws: CancellationError.self) { _ = try await activeTask.value }
  #expect(UpdaterProtocolRegistry.wasStopped(activeKey))
  #expect(!FileManager.default.fileExists(atPath: activeURL.path))
  UpdaterProtocolRegistry.release(activeKey)
  UpdaterProtocolRegistry.remove(activeKey)
}
