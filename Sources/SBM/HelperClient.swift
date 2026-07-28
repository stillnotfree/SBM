import Darwin
import Foundation
import SBMShared

enum HelperClientError: LocalizedError {
  case socketCreation(Int32)
  case socketOption(Int32)
  case socketPathTooLong
  case connection(Int32)
  case write(Int32)
  case emptyResponse
  case invalidResponse
  case timeout

  var errorDescription: String? {
    switch self {
    case .socketCreation(let code): "Unable to create helper socket (errno \(code))."
    case .socketOption(let code): "Unable to secure helper socket timeouts (errno \(code))."
    case .socketPathTooLong: "Helper socket path is too long."
    case .connection(let code): "Unable to reach helper (errno \(code))."
    case .write(let code): "Unable to send helper request (errno \(code))."
    case .emptyResponse: "Helper returned an empty response."
    case .invalidResponse: "Helper returned an invalid response."
    case .timeout: "The background helper did not respond in time."
    }
  }
}

enum HelperClient {
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
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw HelperClientError.socketCreation(errno)
    }
    defer { close(descriptor) }
    try configureTimeouts(
      descriptor,
      receiveTimeoutSeconds: receiveTimeoutSeconds
    )

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(HelperConstants.socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw HelperClientError.socketPathTooLong
    }

    withUnsafeMutablePointer(to: &address.sun_path) { destination in
      pathBytes.withUnsafeBytes { source in
        _ = memcpy(
          UnsafeMutableRawPointer(destination),
          source.baseAddress,
          pathBytes.count
        )
      }
    }

    let addressLength = socklen_t(
      MemoryLayout<sa_family_t>.size + pathBytes.count
    )
    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, addressLength)
      }
    }
    guard connectResult == 0 else {
      throw HelperClientError.connection(errno)
    }

    var payload = try JSONEncoder().encode(request)
    payload.append(0x0A)
    var offset = 0
    try payload.withUnsafeBytes { bytes in
      while offset < bytes.count {
        let written = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        guard written > 0 else { throw HelperClientError.write(errno) }
        offset += written
      }
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let maximumResponseSize = 256 * 1_024
    while response.count < maximumResponseSize {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 {
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
    guard let decoded = try? JSONDecoder().decode(HelperResponse.self, from: response) else {
      throw HelperClientError.invalidResponse
    }
    return decoded
  }

  private static func configureTimeouts(
    _ descriptor: Int32,
    receiveTimeoutSeconds: Int
  ) throws {
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
