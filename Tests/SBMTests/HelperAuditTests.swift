import Foundation
import SBMShared
import Testing

@testable import SBMHelper

@Test func helperAuditMessageContainsPeerAndStateButNoResponseSecrets() {
  let response = HelperResponse(
    success: true,
    coreRunning: false,
    runtimeOutcome: .applied,
    message: "subscription=https://secret.example/uuid password=not-for-logs"
  )
  let record = HelperAuditRecord(
    action: .stop,
    stopReason: .userDisconnect,
    peer: HelperPeerIdentity(
      pid: 123,
      uid: 501,
      executablePath: "/Applications/SBM.app/Contents/MacOS/SBM"
    ),
    before: HelperCoreAuditState(coreRunning: true, desiredRunning: true),
    after: HelperCoreAuditState(coreRunning: false, desiredRunning: false),
    result: HelperAuditFormatter.result(
      action: .stop,
      response: response,
      before: HelperCoreAuditState(coreRunning: true, desiredRunning: true),
      after: HelperCoreAuditState(coreRunning: false, desiredRunning: false)
    )
  )

  let message = HelperAuditFormatter.message(record)
  #expect(message.contains("action=stop"))
  #expect(message.contains("reason=userDisconnect"))
  #expect(message.contains("peer_pid=123"))
  #expect(message.contains("peer_uid=501"))
  #expect(message.contains("peer_executable=/Applications/SBM.app/Contents/MacOS/SBM"))
  #expect(message.contains("core_before=true"))
  #expect(message.contains("core_after=false"))
  #expect(message.contains("desired_before=true"))
  #expect(message.contains("desired_after=false"))
  #expect(message.contains("result=success"))
  #expect(!message.contains("secret.example"))
  #expect(!message.contains("not-for-logs"))
}

@Test func helperAuditResultClassifiesErrorReconnectAndNoOp() {
  let state = HelperCoreAuditState(coreRunning: false, desiredRunning: false)
  let error = HelperResponse(success: false, coreRunning: false, message: "internal detail")
  let reconnect = HelperResponse(
    success: true,
    coreRunning: true,
    runtimeOutcome: .reconnectRequired,
    message: "Changes ready to apply"
  )
  let status = HelperResponse(success: true, coreRunning: false, message: "Helper connected")

  #expect(
    HelperAuditFormatter.result(
      action: .start,
      response: error,
      before: state,
      after: state
    ) == "error"
  )
  #expect(
    HelperAuditFormatter.result(
      action: .start,
      response: reconnect,
      before: state,
      after: HelperCoreAuditState(coreRunning: true, desiredRunning: true)
    ) == "reconnectRequired"
  )
  #expect(
    HelperAuditFormatter.result(
      action: .status,
      response: status,
      before: state,
      after: state
    ) == "no-op"
  )
}

@Test func helperStopReasonRoundTripsThroughTheIPCRequest() throws {
  let request = HelperRequest(action: .shutdown, stopReason: .appTermination)
  let decoded = try JSONDecoder().decode(
    HelperRequest.self,
    from: JSONEncoder().encode(request)
  )

  #expect(decoded.stopReason == .appTermination)
}
