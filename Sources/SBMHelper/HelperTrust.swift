import Darwin
import Foundation
import SBMShared
import Security

struct HelperPeerCredentials {
  let pid: pid_t
  let uid: uid_t
  let processVersion: Int32
  let auditToken: audit_token_t
}

struct HelperDynamicCodeIdentity: Equatable, Sendable {
  let signingIdentifier: String
  let bundleIdentifier: String?
  let cdHash: String
  let executablePath: String
}

extension HelperPeerIdentityResolver {
  static let installedAppURL = URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true)
  static let helperSigningIdentifier = "com.stillnotfree.sbm.helper"
  static let appExecutablePath = "/Applications/SBM.app/Contents/MacOS/SBM"
  static let helperExecutablePath = "/Applications/SBM.app/Contents/Resources/SBMHelper"

  static func peerCredentials(from descriptor: Int32) throws -> HelperPeerCredentials {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(descriptor, &uid, &gid) == 0 else {
      throw HelperFailure.systemCall("getpeereid", errno)
    }

    var pid: pid_t = 0
    var pidLength = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0,
      pidLength == MemoryLayout<pid_t>.size,
      pid > 0
    else { throw HelperFailure.unauthorizedPeer }

    var auditToken = audit_token_t()
    var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
    guard
      getsockopt(
        descriptor,
        SOL_LOCAL,
        LOCAL_PEERTOKEN,
        &auditToken,
        &tokenLength
      ) == 0,
      tokenLength == MemoryLayout<audit_token_t>.size
    else { throw HelperFailure.unauthorizedPeer }

    let credentials = HelperPeerCredentials(
      pid: pid,
      uid: uid,
      processVersion: audit_token_to_pidversion(auditToken),
      auditToken: auditToken
    )
    guard credentialsAreConsistent(credentials) else {
      throw HelperFailure.unauthorizedPeer
    }
    return credentials
  }

  static func credentialsAreConsistent(_ credentials: HelperPeerCredentials) -> Bool {
    credentials.pid > 0
      && credentials.processVersion >= 0
      && credentials.pid == audit_token_to_pid(credentials.auditToken)
      && credentials.uid == audit_token_to_euid(credentials.auditToken)
      && credentials.processVersion == audit_token_to_pidversion(credentials.auditToken)
  }

  static func authorize(
    _ credentials: HelperPeerCredentials,
    manifest: CurrentReleaseManifestPayload,
    cache: inout HelperPeerIdentity?
  ) throws -> HelperPeerIdentity {
    guard credentialsAreConsistent(credentials) else {
      throw HelperFailure.unauthorizedPeer
    }
    if let cached = cache,
      cached.pid == credentials.pid,
      cached.processVersion == credentials.processVersion,
      cached.uid == credentials.uid
    {
      return cached
    }

    let codeIdentity = try dynamicCodeIdentity(for: credentials.auditToken)
    guard appCodeIdentityMatches(codeIdentity, manifest: manifest) else {
      throw HelperFailure.unauthorizedPeer
    }

    let identity = HelperPeerIdentity(
      pid: credentials.pid,
      uid: credentials.uid,
      executablePath: codeIdentity.executablePath,
      processVersion: credentials.processVersion,
      signingIdentifier: codeIdentity.signingIdentifier,
      cdHash: codeIdentity.cdHash
    )
    cache = identity
    return identity
  }

  private static func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
      && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid
      && lhs.st_gid == rhs.st_gid && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  static func verifiedCurrentRelease() throws -> CurrentReleaseManifestPayload {
    let manifestData = try CurrentReleaseManifest.read(from: installedAppURL)
    let manifest = try CurrentReleaseManifest.verify(
      manifestData,
      publicKey: CurrentReleaseManifest.projectPublicKey,
      expectedKeyID: CurrentReleaseManifest.projectKeyID
    )
    let appInfoURL = installedAppURL.appendingPathComponent("Contents/Info.plist")
    let appInfoData = try boundedInfoPlistData(at: appInfoURL.path)
    guard
      let appInfo = try PropertyListSerialization.propertyList(
        from: appInfoData,
        format: nil
      ) as? [String: Any],
      currentReleaseFieldsMatch(
        manifest,
        appBundleIdentifier: appInfo["CFBundleIdentifier"] as? String,
        appVersion: appInfo["CFBundleShortVersionString"] as? String,
        appBuild: appInfo["CFBundleVersion"] as? String,
        helperRevision: HelperConstants.helperRevision,
        ipcProtocolVersion: HelperConstants.protocolVersion,
        coreSHA256: CoreBuildInfo.signedSHA256
      )
    else { throw HelperFailure.invalidReleaseProof }

    let helper = try selfCodeIdentity()
    guard helperCodeIdentityMatches(helper, manifest: manifest)
    else { throw HelperFailure.invalidReleaseProof }
    return manifest
  }

  private static func boundedInfoPlistData(at path: String) throws -> Data {
    let maximumBytes = 256 * 1_024
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw HelperFailure.invalidReleaseProof }
    defer { _ = close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_nlink == 1,
      info.st_size >= 0,
      info.st_size <= maximumBytes
    else { throw HelperFailure.invalidReleaseProof }

    let expectedSize = Int(info.st_size)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while data.count <= maximumBytes {
      let remaining = maximumBytes + 1 - data.count
      let count = Darwin.read(descriptor, &buffer, min(buffer.count, remaining))
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw HelperFailure.invalidReleaseProof }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= maximumBytes else { throw HelperFailure.invalidReleaseProof }
    }
    var after = stat()
    var pathInfo = stat()
    guard data.count == expectedSize, fstat(descriptor, &after) == 0,
      lstat(path, &pathInfo) == 0,
      sameFileIdentity(info, after), sameFileIdentity(after, pathInfo)
    else { throw HelperFailure.invalidReleaseProof }
    return data
  }

  static func currentReleaseFieldsMatch(
    _ manifest: CurrentReleaseManifestPayload,
    appBundleIdentifier: String?,
    appVersion: String?,
    appBuild: String?,
    helperRevision: Int,
    ipcProtocolVersion: Int,
    coreSHA256: String
  ) -> Bool {
    appBundleIdentifier == manifest.appBundleIdentifier
      && appVersion == manifest.appVersion
      && appBuild == manifest.appBuild
      && manifest.appBundleIdentifier == "com.stillnotfree.sbm"
      && manifest.helperSigningIdentifier == helperSigningIdentifier
      && manifest.helperRevision == helperRevision
      && manifest.ipcProtocolVersion == ipcProtocolVersion
      && manifest.coreSHA256 == coreSHA256
  }

  static func appCodeIdentityMatches(
    _ codeIdentity: HelperDynamicCodeIdentity,
    manifest: CurrentReleaseManifestPayload
  ) -> Bool {
    codeIdentity.signingIdentifier == manifest.appBundleIdentifier
      && codeIdentity.bundleIdentifier == manifest.appBundleIdentifier
      && codeIdentity.cdHash == manifest.appCDHash
      && canonical(codeIdentity.executablePath) == canonical(appExecutablePath)
  }

  static func helperCodeIdentityMatches(
    _ codeIdentity: HelperDynamicCodeIdentity,
    manifest: CurrentReleaseManifestPayload
  ) -> Bool {
    codeIdentity.signingIdentifier == manifest.helperSigningIdentifier
      && codeIdentity.cdHash == manifest.helperCDHash
      && canonical(codeIdentity.executablePath) == canonical(helperExecutablePath)
  }

  static func dynamicCodeIdentity(for auditToken: audit_token_t) throws
    -> HelperDynamicCodeIdentity
  {
    var guest: SecCode?
    let tokenData = withUnsafeBytes(of: auditToken) { Data($0) }
    let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
    guard
      SecCodeCopyGuestWithAttributes(
        nil,
        attributes,
        SecCSFlags(),
        &guest
      ) == errSecSuccess,
      let guest,
      SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    else { throw HelperFailure.unauthorizedPeer }
    return try signingIdentity(for: guest)
  }

  private static func selfCodeIdentity() throws -> HelperDynamicCodeIdentity {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
      let code,
      SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    else { throw HelperFailure.invalidReleaseProof }
    return try signingIdentity(for: code)
  }

  private static func signingIdentity(for code: SecCode) throws -> HelperDynamicCodeIdentity {
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
      let staticCode
    else { throw HelperFailure.invalidReleaseProof }
    return try signingIdentity(for: staticCode)
  }

  private static func signingIdentity(for staticCode: SecStaticCode) throws
    -> HelperDynamicCodeIdentity
  {
    var rawInformation: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &rawInformation
      ) == errSecSuccess, let rawInformation
    else { throw HelperFailure.invalidReleaseProof }
    let information = rawInformation as NSDictionary
    guard let signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String,
      let hash = information[kSecCodeInfoUnique as String] as? Data,
      hash.count == 20,
      let executableURL = information[kSecCodeInfoMainExecutable as String] as? URL
    else { throw HelperFailure.invalidReleaseProof }
    let propertyList = information[kSecCodeInfoPList as String] as? [String: Any]
    let bundleIdentifier = propertyList?["CFBundleIdentifier"] as? String
    return HelperDynamicCodeIdentity(
      signingIdentifier: signingIdentifier,
      bundleIdentifier: bundleIdentifier,
      cdHash: hash.map { String(format: "%02x", $0) }.joined(),
      executablePath: executableURL.path
    )
  }

  private static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }
}
