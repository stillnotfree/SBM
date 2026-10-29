import CryptoKit
import Darwin
import Foundation

public struct CurrentReleaseManifestPayload: Codable, Equatable, Sendable {
  public let formatVersion: Int
  public let keyID: String
  public let appVersion: String
  public let appBuild: String
  public let appBundleIdentifier: String
  public let appCDHash: String
  public let helperSigningIdentifier: String
  public let helperCDHash: String
  public let helperRevision: Int
  public let ipcProtocolVersion: Int
  public let coreSHA256: String

  public init(
    formatVersion: Int = 1,
    keyID: String,
    appVersion: String,
    appBuild: String,
    appBundleIdentifier: String,
    appCDHash: String,
    helperSigningIdentifier: String,
    helperCDHash: String,
    helperRevision: Int,
    ipcProtocolVersion: Int,
    coreSHA256: String
  ) {
    self.formatVersion = formatVersion
    self.keyID = keyID
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.appBundleIdentifier = appBundleIdentifier
    self.appCDHash = appCDHash
    self.helperSigningIdentifier = helperSigningIdentifier
    self.helperCDHash = helperCDHash
    self.helperRevision = helperRevision
    self.ipcProtocolVersion = ipcProtocolVersion
    self.coreSHA256 = coreSHA256
  }

}

public enum CurrentReleaseManifestFailure: Error {
  case malformed
  case invalidSignature
  case invalidField
  case unavailableAttribute
}

public struct UpdateArtifactProofPayload: Codable, Equatable, Sendable {
  public let formatVersion: Int
  public let keyID: String
  public let appVersion: String
  public let assetName: String
  public let assetSize: Int64
  public let assetSHA256: String

  public init(
    formatVersion: Int = 1,
    keyID: String,
    appVersion: String,
    assetName: String,
    assetSize: Int64,
    assetSHA256: String
  ) {
    self.formatVersion = formatVersion
    self.keyID = keyID
    self.appVersion = appVersion
    self.assetName = assetName
    self.assetSize = assetSize
    self.assetSHA256 = assetSHA256
  }
}

public enum UpdateArtifactProofFailure: Error {
  case malformed
  case invalidSignature
  case invalidField
}

public enum UpdateArtifactProof {
  public static let maximumEnvelopeBytes = 4 * 1_024
  public static let maximumAssetBytes: Int64 = 200 * 1_024 * 1_024

  private struct Envelope: Codable, Equatable {
    let payload: UpdateArtifactProofPayload
    let signature: Data
  }

  private static func canonicalPayload(_ payload: UpdateArtifactProofPayload) throws -> Data {
    try validate(payload)
    return try encoder().encode(payload)
  }

  public static func sign(
    _ payload: UpdateArtifactProofPayload,
    with privateKey: Curve25519.Signing.PrivateKey
  ) throws -> Data {
    let bytes = try canonicalPayload(payload)
    let envelope = Envelope(payload: payload, signature: try privateKey.signature(for: bytes))
    let encoded = try encoder().encode(envelope)
    guard encoded.count <= maximumEnvelopeBytes else {
      throw UpdateArtifactProofFailure.malformed
    }
    return encoded
  }

  public static func verify(
    _ data: Data,
    publicKey: Data,
    expectedKeyID: String
  ) throws -> UpdateArtifactProofPayload {
    guard !data.isEmpty, data.count <= maximumEnvelopeBytes else {
      throw UpdateArtifactProofFailure.malformed
    }
    let envelope: Envelope
    do {
      envelope = try JSONDecoder().decode(Envelope.self, from: data)
    } catch {
      throw UpdateArtifactProofFailure.malformed
    }
    guard try encoder().encode(envelope) == data else {
      throw UpdateArtifactProofFailure.malformed
    }
    try validate(envelope.payload)
    guard envelope.payload.keyID == expectedKeyID,
      CurrentReleaseManifest.signingKeyID(publicKey: publicKey) == expectedKeyID
    else { throw UpdateArtifactProofFailure.invalidField }

    let key: Curve25519.Signing.PublicKey
    do {
      key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    } catch {
      throw UpdateArtifactProofFailure.invalidField
    }
    let payloadBytes = try canonicalPayload(envelope.payload)
    guard key.isValidSignature(envelope.signature, for: payloadBytes) else {
      throw UpdateArtifactProofFailure.invalidSignature
    }
    return envelope.payload
  }

  public static func matches(
    _ payload: UpdateArtifactProofPayload,
    appVersion: String,
    assetName: String,
    assetSize: Int64,
    assetSHA256: String
  ) -> Bool {
    payload.appVersion == appVersion
      && payload.assetName == assetName
      && payload.assetSize == assetSize
      && payload.assetSHA256 == assetSHA256
  }

  private static func validate(_ payload: UpdateArtifactProofPayload) throws {
    let versionParts = payload.appVersion.split(separator: ".", omittingEmptySubsequences: false)
    guard payload.formatVersion == 1,
      !payload.keyID.isEmpty, payload.keyID.utf8.count <= 64,
      versionParts.count == 3,
      versionParts.allSatisfy({
        !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
          && ($0 == "0" || !$0.hasPrefix("0")) && Int($0) != nil
      }),
      payload.assetName == "SBM-\(payload.appVersion)-arm64.dmg",
      payload.assetSize > 0, payload.assetSize <= maximumAssetBytes,
      payload.assetSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    else { throw UpdateArtifactProofFailure.invalidField }
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

public enum CurrentReleaseManifest {
  public static let xattrName = "com.stillnotfree.sbm.release-manifest"
  public static let maximumEnvelopeBytes = 16 * 1024
  public static let projectPublicKey = Data([
    0x79, 0x6d, 0x87, 0x94, 0xda, 0xfe, 0x45, 0x6a,
    0x58, 0xc4, 0xfa, 0x6e, 0x9f, 0xfa, 0x5c, 0x49,
    0xa2, 0x5f, 0x3f, 0x8c, 0xa8, 0x8f, 0x68, 0x6b,
    0xcd, 0x6d, 0x54, 0x96, 0xae, 0x09, 0xcf, 0xe7,
  ])
  public static let projectKeyID = "sbm-ed25519-04fb27e677881126"

  private struct Envelope: Codable, Equatable {
    let payload: CurrentReleaseManifestPayload
    let signature: Data
  }

  public static func signingKeyID(publicKey: Data) -> String {
    let digest = SHA256.hash(data: publicKey)
      .map { String(format: "%02x", $0) }
      .joined()
    return "sbm-ed25519-" + String(digest.prefix(16))
  }

  public static func canonicalPayload(_ payload: CurrentReleaseManifestPayload) throws -> Data {
    try validate(payload)
    return try encoder().encode(payload)
  }

  public static func sign(
    _ payload: CurrentReleaseManifestPayload,
    with privateKey: Curve25519.Signing.PrivateKey
  ) throws -> Data {
    let bytes = try canonicalPayload(payload)
    let envelope = Envelope(payload: payload, signature: try privateKey.signature(for: bytes))
    let encoded = try encoder().encode(envelope)
    guard encoded.count <= maximumEnvelopeBytes else {
      throw CurrentReleaseManifestFailure.malformed
    }
    return encoded
  }

  public static func verify(
    _ data: Data,
    publicKey: Data,
    expectedKeyID: String
  ) throws -> CurrentReleaseManifestPayload {
    guard !data.isEmpty, data.count <= maximumEnvelopeBytes else {
      throw CurrentReleaseManifestFailure.malformed
    }
    let envelope: Envelope
    do {
      envelope = try JSONDecoder().decode(Envelope.self, from: data)
    } catch {
      throw CurrentReleaseManifestFailure.malformed
    }
    guard try encoder().encode(envelope) == data else {
      throw CurrentReleaseManifestFailure.malformed
    }
    try validate(envelope.payload)
    guard envelope.payload.keyID == expectedKeyID,
      signingKeyID(publicKey: publicKey) == expectedKeyID
    else { throw CurrentReleaseManifestFailure.invalidField }

    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    let payloadBytes = try canonicalPayload(envelope.payload)
    guard key.isValidSignature(envelope.signature, for: payloadBytes) else {
      throw CurrentReleaseManifestFailure.invalidSignature
    }
    return envelope.payload
  }

  public static func read(from bundleURL: URL) throws -> Data {
    let size = getxattr(
      bundleURL.path,
      xattrName,
      nil,
      0,
      0,
      XATTR_NOFOLLOW
    )
    guard size > 0, size <= maximumEnvelopeBytes else {
      throw CurrentReleaseManifestFailure.unavailableAttribute
    }
    var data = Data(count: size)
    let readSize = data.withUnsafeMutableBytes { buffer in
      getxattr(
        bundleURL.path,
        xattrName,
        buffer.baseAddress,
        buffer.count,
        0,
        XATTR_NOFOLLOW
      )
    }
    guard readSize == size else {
      throw CurrentReleaseManifestFailure.unavailableAttribute
    }
    data.count = readSize
    return data
  }

  public static func attach(_ data: Data, to bundleURL: URL) throws {
    guard !data.isEmpty, data.count <= maximumEnvelopeBytes else {
      throw CurrentReleaseManifestFailure.malformed
    }
    let result = data.withUnsafeBytes { buffer in
      setxattr(
        bundleURL.path,
        xattrName,
        buffer.baseAddress,
        buffer.count,
        0,
        XATTR_NOFOLLOW
      )
    }
    guard result == 0 else { throw CurrentReleaseManifestFailure.unavailableAttribute }
  }

  private static func validate(_ payload: CurrentReleaseManifestPayload) throws {
    guard payload.formatVersion == 1,
      payload.keyID.count <= 64,
      !payload.appVersion.isEmpty, payload.appVersion.utf8.count <= 64,
      !payload.appBuild.isEmpty, payload.appBuild.utf8.count <= 32,
      !payload.appBundleIdentifier.isEmpty, payload.appBundleIdentifier.utf8.count <= 255,
      payload.appCDHash.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression) != nil,
      !payload.helperSigningIdentifier.isEmpty,
      payload.helperSigningIdentifier.utf8.count <= 255,
      payload.helperCDHash.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression) != nil,
      payload.helperRevision > 0,
      payload.ipcProtocolVersion > 0,
      payload.coreSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    else { throw CurrentReleaseManifestFailure.invalidField }
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

}
