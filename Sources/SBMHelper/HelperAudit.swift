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
  let processVersion: Int32?
  let signingIdentifier: String?
  let cdHash: String?

  init(
    pid: pid_t?,
    uid: uid_t,
    executablePath: String?,
    processVersion: Int32? = nil,
    signingIdentifier: String? = nil,
    cdHash: String? = nil
  ) {
    self.pid = pid
    self.uid = uid
    self.executablePath = executablePath
    self.processVersion = processVersion
    self.signingIdentifier = signingIdentifier
    self.cdHash = cdHash
  }
}

enum HelperPeerIdentityResolver {}

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
