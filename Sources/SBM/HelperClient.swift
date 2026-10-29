import Darwin
import Foundation
import OSLog
import SBMShared
import Security

enum HelperClientError: LocalizedError {
  case socketCreation(Int32)
  case socketOption(Int32)
  case socketPathTooLong
  case connection(Int32)
  case write(Int32)
  case requestTooLarge
  case emptyResponse
  case invalidResponse
  case timeout

  var errorDescription: String? {
    switch self {
    case .socketCreation(let code):
      SBMText.format("Unable to create helper socket (errno %lld).", code)
    case .socketOption(let code):
      SBMText.format("Unable to secure helper socket timeouts (errno %lld).", code)
    case .socketPathTooLong: SBMText.localized("Helper socket path is too long.")
    case .connection(let code): SBMText.format("Unable to reach helper (errno %lld).", code)
    case .write(let code): SBMText.format("Unable to send helper request (errno %lld).", code)
    case .requestTooLarge: SBMText.localized("The helper request is too large.")
    case .emptyResponse: SBMText.localized("Helper returned an empty response.")
    case .invalidResponse: SBMText.localized("Helper returned an invalid response.")
    case .timeout: SBMText.localized("The background helper did not respond in time.")
    }
  }
}

enum HelperClient {
  private static let requestLock = NSLock()
  private static let lifecycleLogger = Logger(
    subsystem: "com.stillnotfree.sbm",
    category: "helper-lifecycle"
  )
  // A start may include one bounded core check plus a failed transition and rollback.
  static let runtimeMutationReceiveTimeoutSeconds = 60

  static func send(_ action: HelperAction) throws -> HelperResponse {
    try send(HelperRequest(action: action))
  }

  static func send(
    _ action: HelperAction,
    receiveTimeoutSeconds: Int
  ) throws -> HelperResponse {
    try send(
      HelperRequest(action: action),
      receiveTimeoutSeconds: receiveTimeoutSeconds
    )
  }

  static func send(
    _ request: HelperRequest,
    receiveTimeoutSeconds: Int = 30
  ) throws -> HelperResponse {
    requestLock.lock()
    defer { requestLock.unlock() }

    let descriptor = try connectToHelper(
      receiveTimeoutSeconds: receiveTimeoutSeconds
    )
    defer { close(descriptor) }

    var payload = try JSONEncoder().encode(request)
    payload.append(0x0A)
    guard payload.count < 2 * 1_048_576 else {
      throw HelperClientError.requestTooLarge
    }
    try write(payload, to: descriptor)

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let maximumResponseSize = 256 * 1_024
    while response.count < maximumResponseSize {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          throw HelperClientError.timeout
        }
        throw HelperClientError.invalidResponse
      }
      if count == 0 { break }
      response.append(contentsOf: buffer.prefix(count))
      if response.last == 0x0A { break }
    }

    guard !response.isEmpty else { throw HelperClientError.emptyResponse }
    guard response.count < maximumResponseSize else { throw HelperClientError.invalidResponse }
    if response.last == 0x0A { response.removeLast() }
    do {
      try StrictJSONDuplicateValidator.validate(
        response,
        maximumBytes: maximumResponseSize,
        maximumDepth: 32,
        maximumStringBytes: 2 * 1_048_576
      )
    } catch {
      throw HelperClientError.invalidResponse
    }
    guard let decoded = try? JSONDecoder().decode(HelperResponse.self, from: response) else {
      throw HelperClientError.invalidResponse
    }
    return decoded
  }

  static func acquireColdOffClaim(bundleURL: URL) throws -> ColdOffProof {
    do {
      let before = try currentCandidateSnapshot(bundleURL: bundleURL)
      let claim = try ColdOffProof.acquireClaim()
      do {
        let after = try currentCandidateSnapshot(bundleURL: bundleURL)
        guard before.manifest == after.manifest, before.objects.count == after.objects.count,
          zip(before.objects, after.objects).allSatisfy({ sameFileIdentity($0.0, $0.1) })
        else { throw HelperClientError.invalidResponse }
        lifecycleLogger.notice(
          "Validated held Cold OFF claim at \(ColdOffProof.path, privacy: .public)"
        )
        return claim
      } catch {
        claim.release()
        throw error
      }
    } catch {
      lifecycleLogger.error(
        "Cold OFF claim or installed candidate validation failed at \(ColdOffProof.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }

  static func validateHeldColdOffClaim(bundleURL: URL, claim: ColdOffProof) throws {
    do {
      let before = try currentCandidateSnapshot(bundleURL: bundleURL)
      try claim.requireOFFMarker()
      let after = try currentCandidateSnapshot(bundleURL: bundleURL)
      guard before.manifest == after.manifest, before.objects.count == after.objects.count,
        zip(before.objects, after.objects).allSatisfy({ sameFileIdentity($0.0, $0.1) })
      else { throw HelperClientError.invalidResponse }
    } catch {
      lifecycleLogger.error(
        "Held Cold OFF claim revalidation failed at \(ColdOffProof.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }

  private static func connectToHelper(
    receiveTimeoutSeconds: Int
  ) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw HelperClientError.socketCreation(errno) }
    do {
      try configureTimeouts(descriptor, receiveTimeoutSeconds: receiveTimeoutSeconds)
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let pathBytes = Array(HelperConstants.socketPath.utf8CString)
      guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw HelperClientError.socketPathTooLong
      }
      withUnsafeMutablePointer(to: &address.sun_path) { destination in
        pathBytes.withUnsafeBytes { source in
          _ = memcpy(UnsafeMutableRawPointer(destination), source.baseAddress, pathBytes.count)
        }
      }
      let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
      guard length <= UInt8.max else { throw HelperClientError.socketPathTooLong }
      address.sun_len = UInt8(length)
      var result: Int32
      repeat {
        result = withUnsafePointer(to: &address) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, length)
          }
        }
      } while result != 0 && errno == EINTR
      guard result == 0 else { throw HelperClientError.connection(errno) }
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  private static func write(_ frame: Data, to descriptor: Int32) throws {
    var offset = 0
    try frame.withUnsafeBytes { bytes in
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { throw HelperClientError.timeout }
        guard count > 0 else { throw HelperClientError.write(errno) }
        offset += count
      }
    }
  }

  static func currentCandidateSnapshot(
    bundleURL: URL
  ) throws -> (manifest: Data, objects: [stat]) {
    let bundlePath = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
    guard bundlePath == "/Applications/SBM.app" else { throw HelperClientError.invalidResponse }
    let paths = [
      bundleURL.path,
      bundleURL.appendingPathComponent("Contents/Info.plist").path,
      bundleURL.appendingPathComponent("Contents/MacOS/SBM").path,
      bundleURL.appendingPathComponent("Contents/Resources/SBMHelper").path,
    ]
    let before = try candidateFileIdentities(paths)
    let manifest = try CurrentReleaseManifest.read(from: bundleURL)
    let payload = try CurrentReleaseManifest.verify(
      manifest,
      publicKey: CurrentReleaseManifest.projectPublicKey,
      expectedKeyID: CurrentReleaseManifest.projectKeyID
    )
    guard
      payload.appBundleIdentifier == "com.stillnotfree.sbm",
      payload.helperSigningIdentifier == "com.stillnotfree.sbm.helper",
      payload.helperRevision == HelperConstants.helperRevision,
      payload.ipcProtocolVersion == HelperConstants.protocolVersion,
      payload.coreSHA256 == CoreBuildInfo.signedSHA256
    else { throw HelperClientError.invalidResponse }

    guard
      let info = try PropertyListSerialization.propertyList(
        from: boundedInfoPlistData(at: paths[1]),
        format: nil
      ) as? [String: Any],
      info["CFBundleIdentifier"] as? String == payload.appBundleIdentifier,
      info["CFBundleShortVersionString"] as? String == payload.appVersion,
      info["CFBundleVersion"] as? String == payload.appBuild
    else { throw HelperClientError.invalidResponse }

    let appIdentity = try staticCodeIdentity(at: paths[0], isBundle: true)
    let helperIdentity = try staticCodeIdentity(at: paths[3])
    let runningAppIdentity = try runningCodeIdentity()
    guard
      codeIdentityMatches(
        appIdentity,
        identifier: payload.appBundleIdentifier,
        bundleIdentifier: payload.appBundleIdentifier,
        cdHash: payload.appCDHash,
        executablePath: paths[2]
      ),
      codeIdentityMatches(
        helperIdentity,
        identifier: payload.helperSigningIdentifier,
        bundleIdentifier: nil,
        cdHash: payload.helperCDHash,
        executablePath: paths[3]
      ),
      codeIdentityMatches(
        runningAppIdentity,
        identifier: payload.appBundleIdentifier,
        bundleIdentifier: payload.appBundleIdentifier,
        cdHash: payload.appCDHash,
        executablePath: paths[2]
      )
    else { throw HelperClientError.invalidResponse }

    let after = try candidateFileIdentities(paths)
    guard before.count == after.count,
      zip(before, after).allSatisfy({ sameFileIdentity($0.0, $0.1) })
    else { throw HelperClientError.invalidResponse }
    return (manifest, after)
  }

  private static func candidateFileIdentities(_ paths: [String]) throws -> [stat] {
    try paths.enumerated().map { index, path -> stat in
      var info = stat()
      guard lstat(path, &info) == 0,
        (info.st_mode & S_IFMT) == (index == 0 ? S_IFDIR : S_IFREG),
        index == 0 || info.st_nlink == 1
      else { throw HelperClientError.invalidResponse }
      return info
    }
  }

  private static func boundedInfoPlistData(at path: String) throws -> Data {
    let maximumBytes = 256 * 1_024
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw HelperClientError.invalidResponse }
    defer { _ = close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_nlink == 1,
      before.st_size >= 0,
      before.st_size <= maximumBytes
    else { throw HelperClientError.invalidResponse }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while data.count <= maximumBytes {
      let count = Darwin.read(
        descriptor,
        &buffer,
        min(buffer.count, maximumBytes + 1 - data.count)
      )
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw HelperClientError.invalidResponse }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= maximumBytes else { throw HelperClientError.invalidResponse }
    }

    var after = stat()
    var pathInfo = stat()
    guard data.count == before.st_size,
      fstat(descriptor, &after) == 0,
      lstat(path, &pathInfo) == 0,
      sameFileIdentity(before, after),
      sameFileIdentity(after, pathInfo)
    else { throw HelperClientError.invalidResponse }
    return data
  }

  private static func staticCodeIdentity(at path: String, isBundle: Bool = false) throws -> (
    identifier: String, bundleIdentifier: String?, cdHash: String, executablePath: String
  ) {
    let descriptor = open(
      path,
      O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (isBundle ? O_DIRECTORY : 0)
    )
    guard descriptor >= 0 else { throw HelperClientError.invalidResponse }
    defer { _ = close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == (isBundle ? S_IFDIR : S_IFREG),
      isBundle || before.st_nlink == 1
    else { throw HelperClientError.invalidResponse }

    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code)
        == errSecSuccess,
      let code,
      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        == errSecSuccess
    else { throw HelperClientError.invalidResponse }
    let identity = try signingIdentity(for: code)

    var after = stat()
    var pathInfo = stat()
    guard fstat(descriptor, &after) == 0,
      lstat(path, &pathInfo) == 0,
      sameFileIdentity(before, after),
      sameFileIdentity(after, pathInfo)
    else { throw HelperClientError.invalidResponse }
    return identity
  }

  private static func runningCodeIdentity() throws -> (
    identifier: String, bundleIdentifier: String?, cdHash: String, executablePath: String
  ) {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
      let code,
      SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    else { throw HelperClientError.invalidResponse }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
      let staticCode
    else { throw HelperClientError.invalidResponse }
    return try signingIdentity(for: staticCode)
  }

  private static func signingIdentity(for staticCode: SecStaticCode) throws -> (
    identifier: String, bundleIdentifier: String?, cdHash: String, executablePath: String
  ) {
    var rawInformation: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &rawInformation
      ) == errSecSuccess, let rawInformation
    else {
      throw HelperClientError.invalidResponse
    }
    let information = rawInformation as NSDictionary
    guard let identifier = information[kSecCodeInfoIdentifier as String] as? String,
      let hash = information[kSecCodeInfoUnique as String] as? Data,
      hash.count == 20,
      let executableURL = information[kSecCodeInfoMainExecutable as String] as? URL
    else { throw HelperClientError.invalidResponse }
    let propertyList = information[kSecCodeInfoPList as String] as? [String: Any]
    return (
      identifier,
      propertyList?["CFBundleIdentifier"] as? String,
      hash.map { String(format: "%02x", $0) }.joined(),
      executableURL.path
    )
  }

  private static func codeIdentityMatches(
    _ identity: (
      identifier: String, bundleIdentifier: String?, cdHash: String, executablePath: String
    ),
    identifier: String,
    bundleIdentifier: String?,
    cdHash: String,
    executablePath: String
  ) -> Bool {
    identity.identifier == identifier
      && (bundleIdentifier == nil || identity.bundleIdentifier == bundleIdentifier)
      && identity.cdHash == cdHash
      && canonical(identity.executablePath) == canonical(executablePath)
  }

  private static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
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

  private static func configureTimeouts(
    _ descriptor: Int32,
    receiveTimeoutSeconds: Int
  ) throws {
    var noSigPipe: Int32 = 1
    let noSigPipeResult = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSigPipe,
      socklen_t(MemoryLayout<Int32>.size)
    )
    guard noSigPipeResult == 0 else {
      throw HelperClientError.socketOption(errno)
    }
    var receiveTimeout = timeval(
      tv_sec: max(1, receiveTimeoutSeconds),
      tv_usec: 0
    )
    var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
    let receiveResult = withUnsafePointer(to: &receiveTimeout) { pointer in
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        pointer,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }
    guard receiveResult == 0 else {
      throw HelperClientError.socketOption(errno)
    }
    let sendResult = withUnsafePointer(to: &sendTimeout) { pointer in
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_SNDTIMEO,
        pointer,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }
    guard sendResult == 0 else {
      throw HelperClientError.socketOption(errno)
    }
  }
}
