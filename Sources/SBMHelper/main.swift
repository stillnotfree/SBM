import Darwin
import Foundation
import SBMShared

private final class HelperServer {
  private let socketName = "Listener"
  private let manager = CoreManager()

  func run() throws {
    guard geteuid() == 0 else {
      throw HelperFailure.notRoot
    }

    _ = umask(0o077)
    manager.bootstrap()
    let listener = try activatedListener()
    defer { close(listener) }

    var connection: Int32
    repeat {
      connection = accept(listener, nil, nil)
    } while connection < 0 && errno == EINTR
    guard connection >= 0 else {
      throw HelperFailure.systemCall("accept", errno)
    }
    try configureTimeouts(connection)
    autoreleasepool {
      handle(connection)
    }
    close(connection)
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

  private func handle(_ descriptor: Int32) {
    let response: HelperResponse
    do {
      try authenticatePeer(descriptor)
      let request = try readRequest(from: descriptor)
      guard request.protocolVersion == HelperConstants.protocolVersion else {
        throw HelperFailure.protocolMismatch
      }
      switch request.action {
      case .status:
        let recoveryMessage = try manager.reconcileDesiredRuntime()
        response = manager.status(message: recoveryMessage ?? "Helper connected")
      case .start:
        response = try manager.start(
          profile: request.profile,
          profileID: request.profileID,
          mode: request.mode,
          selectedNode: request.node,
          localSOCKSEnabled: request.localSOCKSEnabled,
          localSOCKSPort: request.localSOCKSPort,
          latencyTestURL: request.latencyTestURL
        )
      case .stop:
        response = try manager.stop()
      case .setMode:
        guard let mode = request.mode else { throw HelperFailure.missingParameter("mode") }
        response = try manager.setMode(mode)
      case .setNode:
        guard let node = request.node else { throw HelperFailure.missingParameter("node") }
        response = try manager.setNode(node)
      case .setLatencyTarget:
        guard let target = request.latencyTestURL else {
          throw HelperFailure.missingParameter("latencyTestURL")
        }
        response = try manager.setLatencyTarget(target)
      case .testLatency:
        response = try manager.testLatency(node: request.node)
      case .validateProfile:
        guard let profile = request.profile else { throw HelperFailure.missingParameter("profile") }
        response = try manager.validate(profile: profile)
      case .matchRuleSets:
        guard let tags = request.ruleSetTags else {
          throw HelperFailure.missingParameter("ruleSetTags")
        }
        guard let destination = request.routingDestination else {
          throw HelperFailure.missingParameter("routingDestination")
        }
        response = try manager.matchRuleSets(tags: tags, destination: destination)
      case .shutdown:
        response = try manager.stop()
      }
    } catch HelperFailure.unauthorizedPeer {
      return
    } catch {
      let current = manager.status()
      response = HelperResponse(
        success: false,
        coreRunning: current.coreRunning,
        coreVersion: current.coreVersion,
        mode: current.mode,
        selectedNode: current.selectedNode,
        activeProfileID: current.activeProfileID,
        nodes: current.nodes,
        runtimeOutcome: current.runtimeOutcome,
        message: error.localizedDescription
      )
    }

    guard var encoded = try? JSONEncoder().encode(response) else { return }
    encoded.append(0x0A)
    guard encoded.count < 256 * 1_024 else { return }
    var offset = 0
    encoded.withUnsafeBytes { bytes in
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        if count <= 0 { break }
        offset += count
      }
    }
  }

  private func authenticatePeer(_ descriptor: Int32) throws {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(descriptor, &uid, &gid) == 0 else {
      throw HelperFailure.systemCall("getpeereid", errno)
    }
    guard uid != 0 else { return }
    guard let account = getpwuid(uid),
      let adminGroup = getgrnam("admin")
    else { throw HelperFailure.unauthorizedPeer }

    var groupCount: Int32 = 16
    var groups = [Int32](repeating: 0, count: Int(groupCount))
    let userName = account.pointee.pw_name
    let primaryGroup = Int32(account.pointee.pw_gid)
    var result = getgrouplist(userName, primaryGroup, &groups, &groupCount)
    if result == -1 {
      groups = [Int32](repeating: 0, count: Int(groupCount))
      result = getgrouplist(userName, primaryGroup, &groups, &groupCount)
    }
    guard result >= 0,
      groups.prefix(Int(groupCount)).contains(Int32(adminGroup.pointee.gr_gid))
    else { throw HelperFailure.unauthorizedPeer }
  }

  private func readRequest(from descriptor: Int32) throws -> HelperRequest {
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let maximumRequestSize = 2 * 1_048_576
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while request.count < maximumRequestSize {
      guard clock.now < deadline else { throw HelperFailure.requestTimedOut }
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
          continue
        }
        throw HelperFailure.systemCall("read", errno)
      }
      if count == 0 { break }
      request.append(contentsOf: buffer.prefix(count))
      if request.last == 0x0A { break }
    }
    guard request.count < maximumRequestSize else { throw HelperFailure.requestTooLarge }
    if request.last == 0x0A { request.removeLast() }
    guard !request.isEmpty else { throw HelperFailure.emptyRequest }
    return try JSONDecoder().decode(HelperRequest.self, from: request)
  }
}

private enum HelperFailure: LocalizedError {
  case notRoot
  case socketActivation(Int32)
  case protocolMismatch
  case emptyRequest
  case requestTooLarge
  case requestTimedOut
  case unauthorizedPeer
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
    case .unauthorizedPeer: "The helper accepts requests only from local administrators."
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
