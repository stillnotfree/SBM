import CryptoKit
import Foundation
import SBMShared
import Testing

private func releaseManifestPayload(keyID: String) -> CurrentReleaseManifestPayload {
  CurrentReleaseManifestPayload(
    keyID: keyID,
    appVersion: "1.2.0",
    appBuild: "57",
    appBundleIdentifier: "com.stillnotfree.sbm",
    appCDHash: String(repeating: "a", count: 40),
    helperSigningIdentifier: "com.stillnotfree.sbm.helper",
    helperCDHash: String(repeating: "b", count: 40),
    helperRevision: HelperConstants.helperRevision,
    ipcProtocolVersion: HelperConstants.protocolVersion,
    coreSHA256: String(repeating: "c", count: 64)
  )
}

private func signedReleaseManifest(
  payload: CurrentReleaseManifestPayload,
  key: Curve25519.Signing.PrivateKey
) throws -> Data {
  try CurrentReleaseManifest.sign(payload, with: key)
}

@Test func currentReleaseManifestAcceptsOneValidEd25519Signature() throws {
  let privateKey = Curve25519.Signing.PrivateKey()
  let publicKey = privateKey.publicKey.rawRepresentation
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: publicKey)
  let payload = releaseManifestPayload(keyID: keyID)
  let data = try signedReleaseManifest(payload: payload, key: privateKey)

  #expect(data.count <= CurrentReleaseManifest.maximumEnvelopeBytes)
  #expect(
    try CurrentReleaseManifest.verify(data, publicKey: publicKey, expectedKeyID: keyID) == payload
  )
}

@Test func currentReleaseManifestRejectsWrongKeyAndSignature() throws {
  let signingKey = Curve25519.Signing.PrivateKey()
  let otherKey = Curve25519.Signing.PrivateKey()
  let trustedPublicKey = otherKey.publicKey.rawRepresentation
  let trustedKeyID = CurrentReleaseManifest.signingKeyID(publicKey: trustedPublicKey)
  let data = try signedReleaseManifest(
    payload: releaseManifestPayload(keyID: trustedKeyID),
    key: signingKey
  )

  try expectManifestFailure(
    data,
    publicKey: trustedPublicKey,
    expectedKeyID: trustedKeyID,
    expected: .invalidSignature
  )
}

@Test func currentReleaseManifestRejectsUnknownAndDuplicateKeys() throws {
  let key = Curve25519.Signing.PrivateKey()
  let publicKey = key.publicKey.rawRepresentation
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: publicKey)
  let payload = releaseManifestPayload(keyID: keyID)
  let valid = try signedReleaseManifest(payload: payload, key: key)
  let root = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])

  var unknownRoot = root
  unknownRoot["releaseSequence"] = 1
  let unknownRootBytes = try JSONSerialization.data(
    withJSONObject: unknownRoot, options: [.sortedKeys])

  var unknownPayload = root
  var payloadObject = try #require(unknownPayload["payload"] as? [String: Any])
  payloadObject["releaseSequence"] = 1
  unknownPayload["payload"] = payloadObject
  let unknownPayloadBytes = try JSONSerialization.data(
    withJSONObject: unknownPayload,
    options: [.sortedKeys]
  )

  let canonical = try #require(String(data: valid, encoding: .utf8))
  let duplicateRoot = try duplicateJSONMember("signature", in: canonical)
  let duplicatePayload = try duplicateJSONMember("appBuild", in: canonical)
  let escapedRootDuplicate = try duplicateJSONMember(
    "signature",
    escapedKey: #"\u0073ignature"#,
    in: canonical
  )
  let escapedPayloadDuplicate = try duplicateJSONMember(
    "appBuild",
    escapedKey: #"app\u0042uild"#,
    in: canonical
  )

  for malformed in [
    unknownRootBytes,
    unknownPayloadBytes,
    duplicateRoot,
    duplicatePayload,
    escapedRootDuplicate,
    escapedPayloadDuplicate,
  ] {
    try expectManifestFailure(
      malformed,
      publicKey: publicKey,
      expectedKeyID: keyID,
      expected: .malformed
    )
  }
}

@Test func currentReleaseManifestRequiresEveryPayloadFieldAndItsExactType() throws {
  let key = Curve25519.Signing.PrivateKey()
  let publicKey = key.publicKey.rawRepresentation
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: publicKey)
  let valid = try signedReleaseManifest(payload: releaseManifestPayload(keyID: keyID), key: key)
  let fields = [
    "formatVersion", "keyID", "appVersion", "appBuild", "appBundleIdentifier", "appCDHash",
    "helperSigningIdentifier", "helperCDHash", "helperRevision", "ipcProtocolVersion",
    "coreSHA256",
  ]
  let malformedValues: [String: Any] = [
    "formatVersion": "1",
    "keyID": 4,
    "appVersion": 4,
    "appBuild": NSNull(),
    "appBundleIdentifier": true,
    "appCDHash": ["a"],
    "helperSigningIdentifier": ["value": "helper"],
    "helperCDHash": NSNull(),
    "helperRevision": String(HelperConstants.helperRevision),
    "ipcProtocolVersion": false,
    "coreSHA256": 64,
  ]

  for field in fields {
    let missing = try changingPayload(valid, field: field, remove: true)
    try expectManifestFailure(
      missing,
      publicKey: publicKey,
      expectedKeyID: keyID,
      expected: .malformed
    )

    let wrongType = try changingPayload(valid, field: field, value: malformedValues[field]!)
    try expectManifestFailure(
      wrongType,
      publicKey: publicKey,
      expectedKeyID: keyID,
      expected: .malformed
    )
  }
}

@Test func currentReleaseManifestRequiresCanonicalBytesAndBoundedEnvelope() throws {
  let key = Curve25519.Signing.PrivateKey()
  let publicKey = key.publicKey.rawRepresentation
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: publicKey)
  let valid = try signedReleaseManifest(payload: releaseManifestPayload(keyID: keyID), key: key)
  let canonical = try #require(String(data: valid, encoding: .utf8))
  let root = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])

  var malformedBase64Root = root
  malformedBase64Root["signature"] = "not base64!"
  let malformedBase64 = try JSONSerialization.data(
    withJSONObject: malformedBase64Root,
    options: [.sortedKeys]
  )
  let malformedNumber = Data(
    canonical.replacingOccurrences(of: #""formatVersion":1"#, with: #""formatVersion":1.0"#)
      .utf8
  )
  let escapedValue = Data(
    canonical.replacingOccurrences(of: "com.stillnotfree.sbm", with: #"com\u002estillnotfree.sbm"#)
      .utf8
  )

  for malformed in [
    Data("not-json".utf8),
    valid + Data([0x20]),
    malformedNumber,
    escapedValue,
    malformedBase64,
    Data(repeating: 0x20, count: CurrentReleaseManifest.maximumEnvelopeBytes + 1),
  ] {
    try expectManifestFailure(
      malformed,
      publicKey: publicKey,
      expectedKeyID: keyID,
      expected: .malformed
    )
  }
}

@Test func currentReleaseManifestRejectsCanonicalPayloadTamperingAndWrongKeyBinding() throws {
  let key = Curve25519.Signing.PrivateKey()
  let publicKey = key.publicKey.rawRepresentation
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: publicKey)
  let valid = try signedReleaseManifest(payload: releaseManifestPayload(keyID: keyID), key: key)
  let canonical = try #require(String(data: valid, encoding: .utf8))

  let tamperedPayload = Data(
    canonical.replacingOccurrences(of: #""appBuild":"57""#, with: #""appBuild":"58""#)
      .utf8
  )
  #expect(tamperedPayload != valid)
  let root = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
  let signature = try #require(root["signature"] as? String)
  let signatureBytes = try #require(Data(base64Encoded: signature))
  var changedSignatureBytes = signatureBytes
  changedSignatureBytes[0] ^= 1
  let invalidSignature = Data(
    canonical.replacingOccurrences(
      of: #""signature":"\#(signature)""#,
      with: #""signature":"\#(changedSignatureBytes.base64EncodedString())""#
    ).utf8
  )

  try expectManifestFailure(
    tamperedPayload,
    publicKey: publicKey,
    expectedKeyID: keyID,
    expected: .invalidSignature
  )
  try expectManifestFailure(
    invalidSignature,
    publicKey: publicKey,
    expectedKeyID: keyID,
    expected: .invalidSignature
  )
  try expectManifestFailure(
    valid,
    publicKey: publicKey,
    expectedKeyID: "wrong-key-id",
    expected: .invalidField
  )

  let otherPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
  try expectManifestFailure(
    valid,
    publicKey: otherPublicKey,
    expectedKeyID: keyID,
    expected: .invalidField
  )
}

@Test func currentReleaseManifestBindsExactAppHelperAndCoreFields() throws {
  let key = Curve25519.Signing.PrivateKey()
  let publicKey = key.publicKey.rawRepresentation
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: publicKey)
  let current = releaseManifestPayload(keyID: keyID)
  let data = try signedReleaseManifest(payload: current, key: key)
  let decoded = try CurrentReleaseManifest.verify(data, publicKey: publicKey, expectedKeyID: keyID)

  #expect(decoded.appCDHash == current.appCDHash)
  #expect(decoded.helperCDHash == current.helperCDHash)
  #expect(decoded.helperRevision == HelperConstants.helperRevision)
  #expect(decoded.ipcProtocolVersion == HelperConstants.protocolVersion)
  #expect(decoded.coreSHA256 == current.coreSHA256)
  #expect(throws: CurrentReleaseManifestFailure.self) {
    try CurrentReleaseManifest.canonicalPayload(
      CurrentReleaseManifestPayload(
        keyID: keyID,
        appVersion: current.appVersion,
        appBuild: current.appBuild,
        appBundleIdentifier: current.appBundleIdentifier,
        appCDHash: "not-a-cdhash",
        helperSigningIdentifier: current.helperSigningIdentifier,
        helperCDHash: current.helperCDHash,
        helperRevision: current.helperRevision,
        ipcProtocolVersion: current.ipcProtocolVersion,
        coreSHA256: current.coreSHA256
      )
    )
  }
}

@Test func updateArtifactProofAcceptsCanonicalPayloadWithEphemeralKey() throws {
  let key = Curve25519.Signing.PrivateKey()
  let publicKey = key.publicKey.rawRepresentation
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: publicKey)
  let payload = updateArtifactPayload(keyID: keyID)
  let data = try UpdateArtifactProof.sign(payload, with: key)
  let decoded = try UpdateArtifactProof.verify(
    data,
    publicKey: publicKey,
    expectedKeyID: keyID
  )
  let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let signedPayload = try #require(envelope["payload"] as? [String: Any])

  #expect(decoded == payload)
  #expect(
    Set(signedPayload.keys)
      == Set([
        "formatVersion", "keyID", "appVersion", "assetName", "assetSize", "assetSHA256",
      ]))
}

@Test func updateArtifactProofRejectsUnknownDuplicateNonCanonicalAndOversizedData() throws {
  let key = Curve25519.Signing.PrivateKey()
  let publicKey = key.publicKey.rawRepresentation
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: publicKey)
  let signed = try UpdateArtifactProof.sign(updateArtifactPayload(keyID: keyID), with: key)
  let canonical = try #require(String(data: signed, encoding: .utf8))
  let unknownField = try changingUpdatePayload(signed, field: "futureField", value: "x")
  let duplicateField = try duplicateJSONMember("appVersion", in: canonical)
  let malformed = [
    Data((" " + canonical).utf8),
    unknownField,
    duplicateField,
    Data(repeating: 0x20, count: UpdateArtifactProof.maximumEnvelopeBytes + 1),
  ]

  for data in malformed {
    #expect(throws: UpdateArtifactProofFailure.self) {
      try UpdateArtifactProof.verify(data, publicKey: publicKey, expectedKeyID: keyID)
    }
  }
}

@Test func updateArtifactProofRejectsPayloadTamperingAndWrongKeyBinding() throws {
  let key = Curve25519.Signing.PrivateKey()
  let publicKey = key.publicKey.rawRepresentation
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: publicKey)
  let signed = try UpdateArtifactProof.sign(updateArtifactPayload(keyID: keyID), with: key)
  let canonical = try #require(String(data: signed, encoding: .utf8))
  let payload = try UpdateArtifactProof.verify(
    signed,
    publicKey: publicKey,
    expectedKeyID: keyID
  )
  #expect(
    UpdateArtifactProof.matches(
      payload,
      appVersion: "2.0.0",
      assetName: "SBM-2.0.0-arm64.dmg",
      assetSize: 128,
      assetSHA256: String(repeating: "a", count: 64)
    ))
  #expect(
    !UpdateArtifactProof.matches(
      payload,
      appVersion: "2.0.0",
      assetName: "SBM-2.0.0-arm64.dmg",
      assetSize: 128,
      assetSHA256: String(repeating: "b", count: 64)
    ))
  let changedDigest = Data(
    canonical.replacingOccurrences(
      of: String(repeating: "a", count: 64),
      with: String(repeating: "b", count: 64)
    ).utf8
  )

  #expect(throws: UpdateArtifactProofFailure.self) {
    try UpdateArtifactProof.verify(changedDigest, publicKey: publicKey, expectedKeyID: keyID)
  }
  #expect(throws: UpdateArtifactProofFailure.self) {
    try UpdateArtifactProof.verify(
      signed,
      publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
      expectedKeyID: keyID
    )
  }
  #expect(throws: UpdateArtifactProofFailure.self) {
    try UpdateArtifactProof.verify(signed, publicKey: publicKey, expectedKeyID: "wrong-key-id")
  }
}

@Test func updateArtifactProofRejectsInvalidVersionNameSizeAndDigest() throws {
  let key = Curve25519.Signing.PrivateKey()
  let keyID = CurrentReleaseManifest.signingKeyID(publicKey: key.publicKey.rawRepresentation)
  let valid = updateArtifactPayload(keyID: keyID)
  let invalid = [
    UpdateArtifactProofPayload(
      keyID: keyID, appVersion: "02.0.0", assetName: "SBM-02.0.0-arm64.dmg",
      assetSize: valid.assetSize, assetSHA256: valid.assetSHA256),
    UpdateArtifactProofPayload(
      keyID: keyID, appVersion: valid.appVersion, assetName: "SBM-2.0.0-x86_64.dmg",
      assetSize: valid.assetSize, assetSHA256: valid.assetSHA256),
    UpdateArtifactProofPayload(
      keyID: keyID, appVersion: valid.appVersion, assetName: valid.assetName,
      assetSize: 0, assetSHA256: valid.assetSHA256),
    UpdateArtifactProofPayload(
      keyID: keyID, appVersion: valid.appVersion, assetName: valid.assetName,
      assetSize: UpdateArtifactProof.maximumAssetBytes + 1, assetSHA256: valid.assetSHA256),
    UpdateArtifactProofPayload(
      keyID: keyID, appVersion: valid.appVersion, assetName: valid.assetName,
      assetSize: valid.assetSize, assetSHA256: String(repeating: "A", count: 64)),
  ]
  for payload in invalid {
    #expect(throws: UpdateArtifactProofFailure.self) {
      try UpdateArtifactProof.sign(payload, with: key)
    }
  }
}

private func updateArtifactPayload(keyID: String) -> UpdateArtifactProofPayload {
  UpdateArtifactProofPayload(
    keyID: keyID,
    appVersion: "2.0.0",
    assetName: "SBM-2.0.0-arm64.dmg",
    assetSize: 128,
    assetSHA256: String(repeating: "a", count: 64)
  )
}

private func changingUpdatePayload(_ data: Data, field: String, value: Any) throws -> Data {
  var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var payload = try #require(root["payload"] as? [String: Any])
  payload[field] = value
  root["payload"] = payload
  return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private func changingPayload(
  _ data: Data,
  field: String,
  remove: Bool = false,
  value: Any = NSNull()
) throws -> Data {
  var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var payload = try #require(root["payload"] as? [String: Any])
  if remove {
    payload.removeValue(forKey: field)
  } else {
    payload[field] = value
  }
  root["payload"] = payload
  return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private func duplicateJSONMember(
  _ key: String,
  escapedKey: String? = nil,
  in canonical: String
) throws -> Data {
  let marker = "\"\(key)\":"
  let location = try #require(canonical.range(of: marker))
  let duplicate = "\"" + (escapedKey ?? key) + "\":\"\","
  var changed = canonical
  changed.insert(contentsOf: duplicate, at: location.lowerBound)
  return Data(changed.utf8)
}

private func expectManifestFailure(
  _ data: Data,
  publicKey: Data,
  expectedKeyID: String,
  expected: CurrentReleaseManifestFailure
) throws {
  do {
    _ = try CurrentReleaseManifest.verify(
      data,
      publicKey: publicKey,
      expectedKeyID: expectedKeyID
    )
    Issue.record("Expected current-release manifest verification to fail.")
  } catch {
    let matches: Bool
    switch (expected, error) {
    case (.malformed, CurrentReleaseManifestFailure.malformed),
      (.invalidSignature, CurrentReleaseManifestFailure.invalidSignature),
      (.invalidField, CurrentReleaseManifestFailure.invalidField),
      (.unavailableAttribute, CurrentReleaseManifestFailure.unavailableAttribute):
      matches = true
    default:
      matches = false
    }
    #expect(matches)
  }
}
