import CryptoKit
import Darwin
import Foundation
import SBMShared
import Testing

@testable import SBMHelper

private func currentTestManifest() -> CurrentReleaseManifestPayload {
  CurrentReleaseManifestPayload(
    keyID: "sbm-ed25519-test-key",
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

private func currentAppIdentity(
  manifest: CurrentReleaseManifestPayload,
  cdHash: String? = nil,
  signingIdentifier: String = "com.stillnotfree.sbm",
  bundleIdentifier: String? = "com.stillnotfree.sbm",
  executablePath: String = "/Applications/SBM.app/Contents/MacOS/SBM"
) -> HelperDynamicCodeIdentity {
  HelperDynamicCodeIdentity(
    signingIdentifier: signingIdentifier,
    bundleIdentifier: bundleIdentifier,
    cdHash: cdHash ?? manifest.appCDHash,
    executablePath: executablePath
  )
}

@Test func socketAuditTokenMustAgreeWithKernelPeerCredentials() throws {
  var descriptors = [Int32](repeating: -1, count: 2)
  let result = descriptors.withUnsafeMutableBufferPointer { buffer in
    socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
  }
  #expect(result == 0)
  guard result == 0 else { throw HelperFailure.unauthorizedPeer }
  defer {
    close(descriptors[0])
    close(descriptors[1])
  }

  let credentials = try HelperPeerIdentityResolver.peerCredentials(from: descriptors[0])
  #expect(credentials.pid == getpid())
  #expect(credentials.uid == geteuid())
  #expect(HelperPeerIdentityResolver.credentialsAreConsistent(credentials))

  let wrongPID = HelperPeerCredentials(
    pid: credentials.pid + 1,
    uid: credentials.uid,
    processVersion: credentials.processVersion,
    auditToken: credentials.auditToken
  )
  let wrongUID = HelperPeerCredentials(
    pid: credentials.pid,
    uid: credentials.uid + 1,
    processVersion: credentials.processVersion,
    auditToken: credentials.auditToken
  )
  let wrongVersion = HelperPeerCredentials(
    pid: credentials.pid,
    uid: credentials.uid,
    processVersion: credentials.processVersion + 1,
    auditToken: credentials.auditToken
  )
  #expect(!HelperPeerIdentityResolver.credentialsAreConsistent(wrongPID))
  #expect(!HelperPeerIdentityResolver.credentialsAreConsistent(wrongUID))
  #expect(!HelperPeerIdentityResolver.credentialsAreConsistent(wrongVersion))
}

@Test func sameAdminUIDWithDifferentDynamicCDHashIsRejected() {
  let manifest = currentTestManifest()
  let unrelatedCode = currentAppIdentity(
    manifest: manifest,
    cdHash: String(repeating: "d", count: 40)
  )
  #expect(!HelperPeerIdentityResolver.appCodeIdentityMatches(unrelatedCode, manifest: manifest))
}

@Test func successfulPeerAuthorizationIsCachedByExactCredentials() throws {
  var descriptors = [Int32](repeating: -1, count: 2)
  let result = descriptors.withUnsafeMutableBufferPointer { buffer in
    socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
  }
  #expect(result == 0)
  guard result == 0 else { throw HelperFailure.unauthorizedPeer }
  defer {
    close(descriptors[0])
    close(descriptors[1])
  }

  let credentials = try HelperPeerIdentityResolver.peerCredentials(from: descriptors[0])
  let manifest = currentTestManifest()
  let acceptedIdentity = HelperPeerIdentity(
    pid: credentials.pid,
    uid: credentials.uid,
    executablePath: HelperPeerIdentityResolver.appExecutablePath,
    processVersion: credentials.processVersion,
    signingIdentifier: manifest.appBundleIdentifier,
    cdHash: manifest.appCDHash
  )
  var cache: HelperPeerIdentity? = acceptedIdentity
  let cached = try HelperPeerIdentityResolver.authorize(
    credentials, manifest: manifest, cache: &cache)

  #expect(cached == acceptedIdentity)
  #expect(cache == acceptedIdentity)
}

@Test func peerAuthorizationDoesNotReuseACacheWithChangedPIDVersionOrUID() throws {
  var descriptors = [Int32](repeating: -1, count: 2)
  let result = descriptors.withUnsafeMutableBufferPointer { buffer in
    socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
  }
  #expect(result == 0)
  guard result == 0 else { throw HelperFailure.unauthorizedPeer }
  defer {
    close(descriptors[0])
    close(descriptors[1])
  }

  let credentials = try HelperPeerIdentityResolver.peerCredentials(from: descriptors[0])
  let manifest = currentTestManifest()
  let current = HelperPeerIdentity(
    pid: credentials.pid,
    uid: credentials.uid,
    executablePath: HelperPeerIdentityResolver.appExecutablePath,
    processVersion: credentials.processVersion,
    signingIdentifier: manifest.appBundleIdentifier,
    cdHash: manifest.appCDHash
  )
  let staleIdentities = [
    HelperPeerIdentity(
      pid: credentials.pid + 1,
      uid: credentials.uid,
      executablePath: current.executablePath,
      processVersion: credentials.processVersion,
      signingIdentifier: current.signingIdentifier,
      cdHash: current.cdHash
    ),
    HelperPeerIdentity(
      pid: credentials.pid,
      uid: credentials.uid,
      executablePath: current.executablePath,
      processVersion: credentials.processVersion + 1,
      signingIdentifier: current.signingIdentifier,
      cdHash: current.cdHash
    ),
    HelperPeerIdentity(
      pid: credentials.pid,
      uid: credentials.uid + 1,
      executablePath: current.executablePath,
      processVersion: credentials.processVersion,
      signingIdentifier: current.signingIdentifier,
      cdHash: current.cdHash
    ),
  ]

  for stale in staleIdentities {
    var cache: HelperPeerIdentity? = stale
    var rejected = false
    do {
      _ = try HelperPeerIdentityResolver.authorize(
        credentials,
        manifest: manifest,
        cache: &cache
      )
    } catch HelperFailure.unauthorizedPeer {
      rejected = true
    } catch {
    }
    #expect(rejected)
    #expect(cache == stale)
  }
}

@Test func appIdentityRequiresSigningIdentifierBundlePathAndCDHash() {
  let manifest = currentTestManifest()
  #expect(
    HelperPeerIdentityResolver.appCodeIdentityMatches(
      currentAppIdentity(manifest: manifest),
      manifest: manifest
    )
  )
  #expect(
    !HelperPeerIdentityResolver.appCodeIdentityMatches(
      currentAppIdentity(
        manifest: manifest,
        signingIdentifier: "com.other.admin"
      ),
      manifest: manifest
    )
  )
  #expect(
    !HelperPeerIdentityResolver.appCodeIdentityMatches(
      currentAppIdentity(manifest: manifest, bundleIdentifier: nil),
      manifest: manifest
    )
  )
  #expect(
    !HelperPeerIdentityResolver.appCodeIdentityMatches(
      currentAppIdentity(
        manifest: manifest,
        executablePath: "/tmp/SBM"
      ),
      manifest: manifest
    )
  )
  #expect(
    !HelperPeerIdentityResolver.appCodeIdentityMatches(
      currentAppIdentity(manifest: manifest, cdHash: String(repeating: "d", count: 40)),
      manifest: manifest
    )
  )
}

@Test func helperIdentityAndCurrentReleaseFieldsMustMatch() {
  let manifest = currentTestManifest()
  let helper = HelperDynamicCodeIdentity(
    signingIdentifier: manifest.helperSigningIdentifier,
    bundleIdentifier: nil,
    cdHash: manifest.helperCDHash,
    executablePath: "/Applications/SBM.app/Contents/Resources/SBMHelper"
  )
  #expect(HelperPeerIdentityResolver.helperCodeIdentityMatches(helper, manifest: manifest))
  #expect(
    !HelperPeerIdentityResolver.helperCodeIdentityMatches(
      HelperDynamicCodeIdentity(
        signingIdentifier: manifest.helperSigningIdentifier,
        bundleIdentifier: nil,
        cdHash: String(repeating: "d", count: 40),
        executablePath: helper.executablePath
      ),
      manifest: manifest
    )
  )

  #expect(
    HelperPeerIdentityResolver.currentReleaseFieldsMatch(
      manifest,
      appBundleIdentifier: manifest.appBundleIdentifier,
      appVersion: manifest.appVersion,
      appBuild: manifest.appBuild,
      helperRevision: HelperConstants.helperRevision,
      ipcProtocolVersion: HelperConstants.protocolVersion,
      coreSHA256: manifest.coreSHA256
    )
  )
  #expect(
    !HelperPeerIdentityResolver.currentReleaseFieldsMatch(
      manifest,
      appBundleIdentifier: manifest.appBundleIdentifier,
      appVersion: manifest.appVersion,
      appBuild: manifest.appBuild,
      helperRevision: HelperConstants.helperRevision - 1,
      ipcProtocolVersion: HelperConstants.protocolVersion,
      coreSHA256: manifest.coreSHA256
    )
  )
  #expect(
    !HelperPeerIdentityResolver.currentReleaseFieldsMatch(
      manifest,
      appBundleIdentifier: manifest.appBundleIdentifier,
      appVersion: manifest.appVersion,
      appBuild: manifest.appBuild,
      helperRevision: HelperConstants.helperRevision - 1,
      ipcProtocolVersion: HelperConstants.protocolVersion,
      coreSHA256: manifest.coreSHA256
    )
  )
  #expect(
    !HelperPeerIdentityResolver.currentReleaseFieldsMatch(
      manifest,
      appBundleIdentifier: manifest.appBundleIdentifier,
      appVersion: manifest.appVersion,
      appBuild: manifest.appBuild,
      helperRevision: HelperConstants.helperRevision,
      ipcProtocolVersion: HelperConstants.protocolVersion - 1,
      coreSHA256: manifest.coreSHA256
    )
  )
  #expect(
    !HelperPeerIdentityResolver.currentReleaseFieldsMatch(
      manifest,
      appBundleIdentifier: manifest.appBundleIdentifier,
      appVersion: manifest.appVersion,
      appBuild: manifest.appBuild,
      helperRevision: HelperConstants.helperRevision,
      ipcProtocolVersion: HelperConstants.protocolVersion,
      coreSHA256: String(repeating: "d", count: 64)
    )
  )
}
