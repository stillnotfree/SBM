import Darwin
import Foundation
import OSLog
import SBMShared

private final class HelperServer {
  private enum TerminalDisposition {
    case normal
    case exiting
  }

  private let socketName = "Listener"
  private let manager = CoreManager()
  private var authorizedPeer: HelperPeerIdentity?
  private var terminalDisposition = TerminalDisposition.normal
  private var coldOffProof: ColdOffProof?
  private let auditLogger = Logger(
    subsystem: "com.stillnotfree.sbm.helper",
    category: "ipc-audit"
  )

  func run() throws {
    guard geteuid() == 0 else {
      throw HelperFailure.notRoot
    }

    let manifest = try HelperPeerIdentityResolver.verifiedCurrentRelease()
    guard
      ProcessInfo.processInfo.environment[HelperConstants.serviceLabelEnvironmentKey]
        == HelperConstants.currentServiceLabel
    else { return }
    _ = umask(0o077)
    _ = prepareColdOffLifetime()
    let listener = try activatedListener()
    defer { close(listener) }

    while true {
      var connection: Int32
      repeat {
        connection = accept(listener, nil, nil)
      } while connection < 0 && errno == EINTR
      guard connection >= 0 else {
        throw HelperFailure.systemCall("accept", errno)
      }
      var shouldExit = false
      do {
        try configureTimeouts(connection)
        shouldExit = autoreleasepool {
          handle(connection, manifest: manifest)
        }
      } catch {
        FileHandle.standardError.write(
          Data(
            "Unable to configure helper request connection: \(error.localizedDescription)\n".utf8
          )
        )
      }
      close(connection)
      if shouldExit { break }
    }
  }

  private func activatedListener() throws -> Int32 {
    let placeholder = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    var descriptors = placeholder
    var count = 0
    let result = socketName.withCString {
      launch_activate_socket($0, &descriptors, &count)
    }
    placeholder.deallocate()
    guard result == 0, descriptors != placeholder, count == 1 else {
      if descriptors != placeholder { free(descriptors) }
      throw HelperFailure.socketActivation(result == 0 ? EINVAL : result)
    }
    let listener = descriptors[0]
    free(descriptors)
    return listener
  }

  private func configureTimeouts(_ descriptor: Int32) throws {
    var noSigPipe: Int32 = 1
    guard
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else {
      throw HelperFailure.systemCall("setsockopt(SO_NOSIGPIPE)", errno)
    }
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    let receiveResult = withUnsafePointer(to: &timeout) { pointer in
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        pointer,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }
    guard receiveResult == 0 else {
      throw HelperFailure.systemCall("setsockopt(SO_RCVTIMEO)", errno)
    }
    let sendResult = withUnsafePointer(to: &timeout) { pointer in
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_SNDTIMEO,
        pointer,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }
    guard sendResult == 0 else {
      throw HelperFailure.systemCall("setsockopt(SO_SNDTIMEO)", errno)
    }
  }

  private func handle(
    _ descriptor: Int32,
    manifest: CurrentReleaseManifestPayload
  ) -> Bool {
    guard terminalDisposition != .exiting else { return true }
    var peer: HelperPeerIdentity?
    var request: HelperRequest?
    var before: HelperCoreAuditState?
    let response: HelperResponse
    do {
      let credentials = try HelperPeerIdentityResolver.peerCredentials(from: descriptor)
      peer = try authenticatePeer(credentials, manifest: manifest)
      let frame = try readRequestFrame(from: descriptor)
      request = try decodeRequest(frame)
      guard let request else { throw HelperFailure.emptyRequest }
      guard request.protocolVersion == HelperConstants.protocolVersion else {
        throw HelperFailure.protocolMismatch
      }
      guard prepareColdOffLifetime() else {
        try writeResponse(
          HelperResponse(
            success: false,
            coreRunning: false,
            legacy1115Retired: nil,
            message: "Cold OFF helper authority is unavailable."
          ),
          to: descriptor
        )
        return false
      }
      if manager.legacy1115Retired { before = manager.auditSnapshot() }
      switch request.action {
      case .status:
        if !manager.legacy1115Retired {
          response = manager.inertLegacyUpgradeResponse()
          break
        }
        let recoveryMessage = try manager.reconcileDesiredRuntime(
          recoveryAuthorized: request.recoverDesiredRuntime ?? false
        )
        response = manager.status(
          message: recoveryMessage ?? "Helper connected",
          observeAutoNode: request.observeAutoNode ?? false
        )
      case .start:
        guard manager.legacy1115Retired else {
          response = manager.inertLegacyUpgradeResponse(
            success: false,
            message: "Connect is unavailable until legacy helper retirement is proven."
          )
          break
        }
        response = try manager.start(
          profile: request.profile,
          profileID: request.profileID,
          mode: request.mode,
          selectedNode: request.node,
          localSOCKSEnabled: request.localSOCKSEnabled,
          localSOCKSPort: request.localSOCKSPort,
          latencyTestURL: request.latencyTestURL,
          ipv6Enabled: request.ipv6Enabled,
          dnsSettings: request.dnsSettings ?? .defaults
        )
      case .stop:
        response =
          manager.legacy1115Retired
          ? try manager.stop()
          : manager.inertLegacyUpgradeResponse(
            success: false,
            message: "Stop cannot report OFF before legacy helper retirement is proven."
          )
      case .setMode:
        guard manager.legacy1115Retired else {
          response = manager.inertLegacyUpgradeResponse(success: false)
          break
        }
        guard let mode = request.mode else { throw HelperFailure.missingParameter("mode") }
        response = try manager.setMode(mode)
      case .setNode:
        guard manager.legacy1115Retired else {
          response = manager.inertLegacyUpgradeResponse(success: false)
          break
        }
        guard let node = request.node else { throw HelperFailure.missingParameter("node") }
        response = try manager.setNode(node)
      case .setLatencyTarget:
        guard manager.legacy1115Retired else {
          response = manager.inertLegacyUpgradeResponse(success: false)
          break
        }
        guard let target = request.latencyTestURL else {
          throw HelperFailure.missingParameter("latencyTestURL")
        }
        response = try manager.setLatencyTarget(target)
      case .testLatency:
        guard manager.legacy1115Retired else {
          response = manager.inertLegacyUpgradeResponse(success: false)
          break
        }
        response = try manager.testLatency(node: request.node)
      case .validateProfile:
        guard manager.legacy1115Retired else {
          response = manager.inertLegacyUpgradeResponse(success: false)
          break
        }
        guard let profile = request.profile else { throw HelperFailure.missingParameter("profile") }
        response = try manager.validate(profile: profile)
      case .shutdown:
        terminalDisposition = .exiting
        response =
          manager.legacy1115Retired
          ? try manager.stop()
          : manager.inertLegacyUpgradeResponse(
            success: false,
            message: "Legacy helper retirement is unresolved; shutdown cannot report OFF."
          )
        if response.success && !response.coreRunning {
          do {
            try coldOffProof?.publishOFFAndSync()
            auditLogger.notice(
              "Published terminal Cold OFF marker at \(ColdOffProof.path, privacy: .public)"
            )
          } catch {
            auditLogger.error(
              "Terminal Stop succeeded but Cold OFF marker publication failed at \(ColdOffProof.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
      case .finishLegacy1115Upgrade:
        guard request.profile == nil, request.profileID == nil, request.mode == nil,
          request.node == nil, request.localSOCKSEnabled == nil,
          request.localSOCKSPort == nil, request.latencyTestURL == nil,
          request.ipv6Enabled == nil, request.stopReason == nil,
          request.observeAutoNode == nil, request.recoverDesiredRuntime == nil,
          request.dnsSettings == nil
        else { throw HelperFailure.protocolMismatch }
        response = try manager.finishLegacy1115Upgrade()
      }
    } catch HelperFailure.unauthorizedPeer {
      return terminalDisposition == .exiting
    } catch {
      if manager.legacy1115Retired {
        let current = manager.status()
        response = HelperResponse(
          success: false,
          coreRunning: current.coreRunning,
          coreVersion: current.coreVersion,
          mode: current.mode,
          selectedNode: current.selectedNode,
          activeProfileID: current.activeProfileID,
          activeIPv6Enabled: current.activeIPv6Enabled,
          nodes: current.nodes,
          runtimeOutcome: current.runtimeOutcome,
          legacy1115Retired: true,
          message: error.localizedDescription
        )
      } else {
        response = manager.inertLegacyUpgradeResponse(
          success: false,
          message: error.localizedDescription
        )
      }
    }

    if let peer, let request, let before,
      !(request.action == .status && response.success)
    {
      let after = manager.auditSnapshot()
      let record = HelperAuditRecord(
        action: request.action,
        stopReason: request.stopReason
          ?? (request.action == .shutdown ? .appTermination : nil),
        peer: peer,
        before: before,
        after: after,
        result: HelperAuditFormatter.result(
          action: request.action,
          response: response,
          before: before,
          after: after
        )
      )
      auditLogger.notice("\(HelperAuditFormatter.message(record), privacy: .public)")
    }

    guard var encoded = try? JSONEncoder().encode(response) else {
      return terminalDisposition == .exiting
    }
    encoded.append(0x0A)
    guard encoded.count < 256 * 1_024 else { return terminalDisposition == .exiting }
    try? writeFrame(encoded, to: descriptor)
    return terminalDisposition == .exiting
  }

  private func authenticatePeer(
    _ credentials: HelperPeerCredentials,
    manifest: CurrentReleaseManifestPayload
  ) throws -> HelperPeerIdentity {
    try HelperPeerIdentityResolver.authorize(
      credentials,
      manifest: manifest,
      cache: &authorizedPeer
    )
  }

  private func readRequestFrame(
    from descriptor: Int32,
    maximumBytes: Int = 2 * 1_048_576 - 1
  ) throws -> Data {
    var frame = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while true {
      guard clock.now < deadline else { throw HelperFailure.requestTimedOut }
      let count = Darwin.read(
        descriptor,
        &buffer,
        min(buffer.count, maximumBytes + 1 - frame.count)
      )
      if count < 0 {
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
          continue
        }
        throw HelperFailure.systemCall("read", errno)
      }
      if count == 0 { break }
      frame.append(contentsOf: buffer.prefix(count))
      guard frame.count <= maximumBytes else { throw HelperFailure.requestTooLarge }
      if frame.last == 0x0A { break }
    }
    guard !frame.isEmpty else { throw HelperFailure.emptyRequest }
    return frame
  }

  private func decodeRequest(_ frame: Data) throws -> HelperRequest {
    var request = frame
    if request.last == 0x0A { request.removeLast() }
    let maximumRequestSize = 2 * 1_048_576 - 1
    do {
      try StrictJSONDuplicateValidator.validate(
        request,
        maximumBytes: maximumRequestSize,
        maximumDepth: 32,
        maximumStringBytes: maximumRequestSize
      )
    } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "The helper request JSON is invalid.")
      )
    }
    return try JSONDecoder().decode(HelperRequest.self, from: request)
  }

  private func prepareColdOffLifetime() -> Bool {
    if coldOffProof != nil { return true }
    let proof: ColdOffProof
    do {
      proof = try ColdOffProof.acquireLifetime()
    } catch {
      auditLogger.error(
        "Cold OFF lifetime lock unavailable at \(ColdOffProof.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return false
    }
    do {
      try proof.clearAndSync()
      manager.bootstrap()
      coldOffProof = proof
      auditLogger.notice(
        "Acquired Cold OFF lifetime lock at \(ColdOffProof.path, privacy: .public)"
      )
      return true
    } catch {
      auditLogger.error(
        "Cold OFF marker invalidation failed at \(ColdOffProof.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      proof.release()
      return false
    }
  }

  private func writeResponse(_ response: HelperResponse, to descriptor: Int32) throws {
    var encoded = try JSONEncoder().encode(response)
    encoded.append(0x0A)
    guard encoded.count < 256 * 1_024 else { throw HelperFailure.requestTooLarge }
    try writeFrame(encoded, to: descriptor)
  }

  private func writeFrame(_ frame: Data, to descriptor: Int32) throws {
    try frame.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw HelperFailure.systemCall("write", errno) }
        offset += count
      }
    }
  }
}

enum HelperFailure: LocalizedError {
  case notRoot
  case socketActivation(Int32)
  case protocolMismatch
  case emptyRequest
  case requestTooLarge
  case requestTimedOut
  case unauthorizedPeer
  case invalidReleaseProof
  case missingParameter(String)
  case systemCall(String, Int32)

  var errorDescription: String? {
    switch self {
    case .notRoot: "The helper must run as root."
    case .socketActivation(let code): "launchd socket activation failed with errno \(code)."
    case .protocolMismatch: "Unsupported helper protocol version."
    case .emptyRequest: "The helper received an empty request."
    case .requestTooLarge: "The helper request is too large."
    case .requestTimedOut: "The helper request did not complete within five seconds."
    case .unauthorizedPeer: "The helper accepts requests only from the current SBM app."
    case .invalidReleaseProof: "The helper could not verify the current SBM release."
    case .missingParameter(let name): "The helper request is missing \(name)."
    case .systemCall(let name, let code): "\(name) failed with errno \(code)."
    }
  }
}

do {
  try HelperServer().run()
} catch {
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  exit(EXIT_FAILURE)
}
