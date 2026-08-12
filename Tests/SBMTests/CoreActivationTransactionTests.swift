import Darwin
import Foundation
import Testing

@testable import SBMHelper

@Test func localAPIPortProbeIgnoresTimeWaitButRejectsLiveListener() throws {
  let listener = socket(AF_INET, SOCK_STREAM, 0)
  #expect(listener >= 0)
  defer { close(listener) }
  var reuseAddress: Int32 = 1
  #expect(
    setsockopt(
      listener, SOL_SOCKET, SO_REUSEADDR, &reuseAddress,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0
  )
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = 0
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  #expect(
    withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    } == 0
  )
  #expect(listen(listener, 1) == 0)
  var boundAddress = sockaddr_in()
  var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
  #expect(
    withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(listener, $0, &boundLength)
      }
    } == 0
  )
  let port = UInt16(bigEndian: boundAddress.sin_port)
  #expect(!LocalTCPPortProbe.isAvailable(port))

  let client = socket(AF_INET, SOCK_STREAM, 0)
  #expect(client >= 0)
  defer { close(client) }
  #expect(
    withUnsafePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(client, $0, boundLength)
      }
    } == 0
  )
  let accepted = accept(listener, nil, nil)
  #expect(accepted >= 0)
  close(accepted)
  close(client)
  close(listener)

  #expect(LocalTCPPortProbe.isAvailable(port))
}

enum InjectedActivationFailure: Error {
  case composition
  case validation
  case stop
  case commit
  case start
}

private final class ActivationHarness {
  var activeConfiguration: String? = "A"
  var events: [String] = []
  var failure: InjectedActivationFailure?

  func transaction() -> CoreActivationTransaction<String> {
    CoreActivationTransaction(
      prepare: { [self] in
        events.append("compose-B")
        if failure == .composition { throw InjectedActivationFailure.composition }
        events.append("validate-B")
        if failure == .validation { throw InjectedActivationFailure.validation }
        events.append("backup-A")
        return "B"
      },
      stopKnownGood: { [self] in
        events.append("stop-A")
        if failure == .stop { throw InjectedActivationFailure.stop }
        activeConfiguration = nil
      },
      commit: { [self] candidate in
        events.append("commit-\(candidate)")
        if failure == .commit { throw InjectedActivationFailure.commit }
      },
      startCandidate: { [self] in
        events.append("start-B")
        activeConfiguration = "B"
        if failure == .start { throw InjectedActivationFailure.start }
      },
      restoreKnownGood: { [self] in
        events.append("restore-A")
        activeConfiguration = "A"
      },
      restoreDisconnected: { [self] _ in
        events.append("restore-disconnected")
        activeConfiguration = "A"
      }
    )
  }
}

@Test func validCandidateActivationConvergesFromAToB() throws {
  let harness = ActivationHarness()

  try harness.transaction().run(wasRunning: true)

  #expect(harness.activeConfiguration == "B")
  #expect(
    harness.events == [
      "compose-B", "validate-B", "backup-A", "stop-A", "commit-B", "start-B",
    ])
}

@Test(arguments: [InjectedActivationFailure.composition, .validation])
func candidatePreparationFailureNeverStopsKnownGood(
  failure: InjectedActivationFailure
) {
  let harness = ActivationHarness()
  harness.failure = failure

  #expect(throws: InjectedActivationFailure.self) {
    try harness.transaction().run(wasRunning: true)
  }
  #expect(harness.activeConfiguration == "A")
  #expect(!harness.events.contains("stop-A"))
  #expect(!harness.events.contains("restore-A"))
}

@Test(arguments: [InjectedActivationFailure.stop, .commit, .start])
func transitionFailureRestoresKnownGoodConfiguration(
  failure: InjectedActivationFailure
) {
  let harness = ActivationHarness()
  harness.failure = failure

  #expect(throws: CoreActivationTransactionFailure.self) {
    try harness.transaction().run(wasRunning: true)
  }
  #expect(harness.activeConfiguration == "A")
  #expect(harness.events.last == "restore-A")
}

enum DisconnectedActivationFailure: Error, CaseIterable {
  case commit
  case waitForAPI
  case applyMode
  case applyNode
  case saveState
}

enum DisconnectedCleanupFailure: Error {
  case termination
}

private final class DisconnectedActivationHarness {
  var activeConfiguration: String? = "A"
  var persistedState = "disconnected"
  var candidateRunning = false
  var events: [String] = []
  let failure: DisconnectedActivationFailure
  let cleanupFails: Bool

  init(failure: DisconnectedActivationFailure, cleanupFails: Bool = false) {
    self.failure = failure
    self.cleanupFails = cleanupFails
  }

  func transaction() -> CoreActivationTransaction<String> {
    CoreActivationTransaction(
      prepare: { [self] in
        events.append("prepare-B")
        return "B"
      },
      stopKnownGood: { [self] in
        events.append("unexpected-stop")
      },
      commit: { [self] candidate in
        events.append("commit-\(candidate)")
        activeConfiguration = candidate
        if failure == .commit { throw failure }
      },
      startCandidate: { [self] in
        events.append("launch-B")
        candidateRunning = true
        events.append("wait-for-api")
        if failure == .waitForAPI { throw failure }
        events.append("apply-mode")
        if failure == .applyMode { throw failure }
        events.append("apply-node")
        if failure == .applyNode { throw failure }
        events.append("save-state")
        if failure == .saveState { throw failure }
        persistedState = "connected"
      },
      restoreKnownGood: { [self] in
        events.append("unexpected-known-good-restore")
      },
      restoreDisconnected: { [self] candidateLaunchAttempted in
        events.append("restore-disconnected")
        if candidateLaunchAttempted {
          events.append("terminate-B")
          if cleanupFails { throw DisconnectedCleanupFailure.termination }
          candidateRunning = false
        }
        activeConfiguration = "A"
        persistedState = "disconnected"
      }
    )
  }
}

@Test(
  arguments: [
    DisconnectedActivationFailure.waitForAPI,
    .applyMode,
    .applyNode,
    .saveState,
  ])
func disconnectedPostLaunchFailureCleansCandidateAndRestoresSnapshot(
  failure: DisconnectedActivationFailure
) {
  let harness = DisconnectedActivationHarness(failure: failure)

  do {
    try harness.transaction().run(wasRunning: false)
    Issue.record("Expected disconnected activation to fail")
  } catch let transactionFailure as CoreActivationTransactionFailure {
    #expect(
      transactionFailure.activationError as? DisconnectedActivationFailure == failure
    )
    #expect(transactionFailure.recoveryError == nil)
  } catch {
    Issue.record("Unexpected error: \(error)")
  }

  #expect(harness.events.contains("launch-B"))
  #expect(harness.events.contains("terminate-B"))
  #expect(harness.candidateRunning == false)
  #expect(harness.activeConfiguration == "A")
  #expect(harness.persistedState == "disconnected")
  #expect(!harness.events.contains("unexpected-known-good-restore"))
}

@Test func disconnectedPreLaunchFailureRestoresSnapshotWithoutTerminate() {
  let harness = DisconnectedActivationHarness(failure: .commit)

  #expect(throws: CoreActivationTransactionFailure.self) {
    try harness.transaction().run(wasRunning: false)
  }

  #expect(!harness.events.contains("launch-B"))
  #expect(!harness.events.contains("terminate-B"))
  #expect(harness.candidateRunning == false)
  #expect(harness.activeConfiguration == "A")
  #expect(harness.persistedState == "disconnected")
}

@Test func disconnectedCleanupFailurePreservesActivationAndRecoveryErrors() {
  let harness = DisconnectedActivationHarness(failure: .waitForAPI, cleanupFails: true)

  do {
    try harness.transaction().run(wasRunning: false)
    Issue.record("Expected disconnected activation to fail")
  } catch let transactionFailure as CoreActivationTransactionFailure {
    #expect(
      transactionFailure.activationError as? DisconnectedActivationFailure == .waitForAPI
    )
    #expect(transactionFailure.recoveryError is DisconnectedCleanupFailure)
  } catch {
    Issue.record("Unexpected error: \(error)")
  }

  #expect(harness.events.filter { $0 == "terminate-B" }.count == 1)
  #expect(harness.candidateRunning)
  #expect(harness.activeConfiguration == "B")
}
