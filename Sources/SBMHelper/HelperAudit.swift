import Darwin
import Foundation
import SBMShared

struct HelperCoreAuditState: Equatable, Sendable {
  let coreRunning: Bool
  let desiredRunning: Bool
}

struct HelperPeerIdentity: Equatable, Sendable {
  let pid: pid_t?
  let uid: uid_t
  let executablePath: String?
}

enum HelperPeerIdentityResolver {
  static func processID(for descriptor: Int32) -> pid_t? {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
      pid > 0
    else { return nil }
    return pid
  }

  static func executablePath(for pid: pid_t?) -> String? {
    guard let pid, pid > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: 4096)
    let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard count > 0 else { return nil }
    let bytes = buffer.prefix(Int(count)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let path = String(decoding: bytes, as: UTF8.self)
    return path.isEmpty ? nil : path
  }
}

struct HelperAuditRecord: Equatable, Sendable {
  let action: HelperAction
  let stopReason: HelperStopReason?
  let peer: HelperPeerIdentity
  let before: HelperCoreAuditState
  let after: HelperCoreAuditState
  let result: String
}

enum HelperAuditFormatter {
  static func result(
    action: HelperAction,
    response: HelperResponse,
    before: HelperCoreAuditState,
    after: HelperCoreAuditState
  ) -> String {
    guard response.success else { return "error" }
    if response.runtimeOutcome == .reconnectRequired { return "reconnectRequired" }
    if action == .status, before == after { return "no-op" }
    return "success"
  }

  static func message(_ record: HelperAuditRecord) -> String {
    let pid = record.peer.pid.map(String.init) ?? "unknown"
    let path = record.peer.executablePath ?? "unknown"
    let reason = record.stopReason?.rawValue ?? "none"
    return [
      "action=\(record.action.rawValue)",
      "reason=\(reason)",
      "peer_pid=\(pid)",
      "peer_uid=\(record.peer.uid)",
      "peer_executable=\(path)",
      "core_before=\(record.before.coreRunning)",
      "core_after=\(record.after.coreRunning)",
      "desired_before=\(record.before.desiredRunning)",
      "desired_after=\(record.after.desiredRunning)",
      "result=\(record.result)",
    ].joined(separator: " ")
  }
}
