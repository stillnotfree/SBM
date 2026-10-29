import Darwin
import Foundation
import SBMShared
import Testing

@testable import SBMHelper

private func apiResponse(_ head: String, body: String = "") -> Data {
  Data((head + "\r\n\r\n" + body).utf8)
}

@Test func managedCoreChildSharesTheHelperGroupAndStopsOnlyItsOwnedPID() throws {
  let workingDirectory = FileManager.default.temporaryDirectory
  let child = try ManagedCoreChild.launch(
    executableURL: URL(fileURLWithPath: "/bin/sleep"),
    arguments: ["30"],
    currentDirectoryURL: workingDirectory
  )
  let peer = try ManagedCoreChild.launch(
    executableURL: URL(fileURLWithPath: "/bin/sleep"),
    arguments: ["30"],
    currentDirectoryURL: workingDirectory
  )
  defer {
    _ = child.terminate()
    _ = peer.terminate()
  }

  let childPID = try #require(child.pid)
  let peerPID = try #require(peer.pid)
  #expect(getpgid(childPID) == getpgrp())
  #expect(getpgid(peerPID) == getpgrp())
  #expect(child.terminate())
  #expect(child.pid == nil)
  #expect(peer.isRunning)

  var waitStatus: Int32 = 0
  let waitResult = waitpid(childPID, &waitStatus, WNOHANG)
  let waitError = errno
  #expect(waitResult == -1)
  #expect(waitError == ECHILD)
}

@Test func managedCoreChildReapsAnUnexpectedExitAndClearsItsPID() throws {
  let child = try ManagedCoreChild.launch(
    executableURL: URL(fileURLWithPath: "/bin/sleep"),
    arguments: ["30"],
    currentDirectoryURL: FileManager.default.temporaryDirectory
  )
  defer { _ = child.terminate() }

  let childPID = try #require(child.pid)
  #expect(kill(childPID, SIGKILL) == 0)
  let waitStarted = Date()
  let exitStatus = try #require(child.waitUntilExit(timeout: 5))
  #expect(Date().timeIntervalSince(waitStarted) < 2)
  #expect(exitStatus == 128 + SIGKILL)
  #expect(child.pid == nil)

  var waitStatus: Int32 = 0
  let waitResult = waitpid(childPID, &waitStatus, WNOHANG)
  let waitError = errno
  #expect(waitResult == -1)
  #expect(waitError == ECHILD)
}

@Test func localAPIPortProbeIgnoresTimeWaitButRejectsLiveListener() throws {
  var listener = socket(AF_INET, SOCK_STREAM, 0)
  #expect(listener >= 0)
  defer {
    if listener >= 0 {
      close(listener)
    }
  }
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
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  var boundListener = false
  for candidatePort in UInt16(48_000)...UInt16(49_151) {
    address.sin_port = candidatePort.bigEndian
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if bindResult == 0 {
      boundListener = true
      break
    }
    let bindError = errno
    guard bindError == EADDRINUSE else {
      Issue.record(
        "Failed to bind loopback test listener on port \(candidatePort): errno \(bindError)."
      )
      return
    }
  }
  guard boundListener else {
    Issue.record("Could not bind loopback test listener on any port in 48000...49151.")
    return
  }
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

  var client = socket(AF_INET, SOCK_STREAM, 0)
  #expect(client >= 0)
  defer {
    if client >= 0 {
      close(client)
    }
  }
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
  client = -1
  close(listener)
  listener = -1

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

@Test func runningChangedConfigurationRequiresReconnectBeforeTransition() {
  #expect(
    CoreActivationPolicy.disposition(wasRunning: true, configurationChanged: true)
      == .reconnectRequired
  )
  #expect(
    CoreActivationPolicy.disposition(wasRunning: true, configurationChanged: false)
      == .activate
  )
  #expect(
    CoreActivationPolicy.disposition(wasRunning: false, configurationChanged: true)
      == .activate
  )
}

private enum DeferredMarkerTestError: Error {
  case invalidCandidate
  case persistence
  case coreStillRunning
}

private enum StopTransactionTestError: Error, Equatable {
  case stop
  case persistence
}

private func durableStopTestState() -> PersistentState {
  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "durable-stop-test"),
          displayName: "Durable Stop Test",
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "192.0.2.1",
              port: 443,
              method: "aes-256-gcm",
              password: "test-password"
            )
          )
        )
      ]
    )
  )
  var state = PersistentState()
  state.profile = profile
  state.activeProfileID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
  state.nodes = profile.nodes
  state.desiredRunning = true
  state.deferredRuntimeApplyPending = true
  return state
}

@Test func deferredCandidatePersistsMarkerOnlyAfterValidationAndKeepsActiveState() throws {
  var state = PersistentState()
  let activeProfileID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
  state.activeProfileID = activeProfileID
  state.desiredRunning = true
  let activeProfile = state.activeProfileID
  var validationFinished = false
  var persisted: [PersistentState] = []

  let outcome = try DeferredRuntimeMarkerPolicy.deferValidatedCandidate(
    validate: { validationFinished = true },
    persistMarker: {
      try DeferredRuntimeMarkerPolicy.persist(true, in: &state) { snapshot in
        #expect(validationFinished)
        persisted.append(snapshot)
      }
    }
  )

  #expect(outcome == .reconnectRequired)
  #expect(state.activeProfileID == activeProfile)
  #expect(state.desiredRunning)
  #expect(state.deferredRuntimeApplyPending)
  #expect(persisted.count == 1)
  #expect(persisted.first?.deferredRuntimeApplyPending == true)
  #expect(
    DeferredRuntimeMarkerPolicy.outcome(
      coreRunning: true,
      marker: state.deferredRuntimeApplyPending
    )
      == .reconnectRequired
  )

  let reloaded = try JSONDecoder().decode(
    PersistentState.self,
    from: JSONEncoder().encode(persisted[0])
  )
  #expect(reloaded.deferredRuntimeApplyPending)
  #expect(reloaded.activeProfileID == activeProfile)
}

@Test func invalidDeferredCandidateNeverPersistsMarker() {
  var persistCalls = 0
  var state = PersistentState()

  #expect(throws: DeferredMarkerTestError.self) {
    try DeferredRuntimeMarkerPolicy.deferValidatedCandidate(
      validate: { throw DeferredMarkerTestError.invalidCandidate },
      persistMarker: {
        persistCalls += 1
        try DeferredRuntimeMarkerPolicy.persist(true, in: &state) { _ in }
      }
    )
  }

  #expect(persistCalls == 0)
  #expect(!state.deferredRuntimeApplyPending)
}

@Test func deferredMarkerPersistenceFailureDoesNotClaimReconnectRequired() {
  var state = PersistentState()
  var saveCalls = 0

  #expect(throws: DeferredMarkerTestError.self) {
    try DeferredRuntimeMarkerPolicy.persist(true, in: &state) { _ in
      saveCalls += 1
      throw DeferredMarkerTestError.persistence
    }
  }

  #expect(saveCalls == 1)
  #expect(!state.deferredRuntimeApplyPending)
}

@Test func revertingOrSuccessfullyReconnectingClearsDeferredMarker() throws {
  var state = PersistentState()
  state.deferredRuntimeApplyPending = true
  var persisted: [PersistentState] = []

  try DeferredRuntimeMarkerPolicy.persist(false, in: &state) { persisted.append($0) }
  #expect(!state.deferredRuntimeApplyPending)
  #expect(persisted.last?.deferredRuntimeApplyPending == false)
  #expect(
    DeferredRuntimeMarkerPolicy.outcome(
      coreRunning: true,
      marker: state.deferredRuntimeApplyPending
    )
      == .applied
  )

  state.deferredRuntimeApplyPending = true
  var coreRunning = true
  #expect(throws: DeferredMarkerTestError.self) {
    guard !coreRunning else { throw DeferredMarkerTestError.coreStillRunning }
    try DeferredRuntimeMarkerPolicy.persist(false, in: &state) { persisted.append($0) }
  }
  #expect(state.deferredRuntimeApplyPending)

  // An explicit stop is proven before metadata is cleared.
  coreRunning = false
  try DeferredRuntimeMarkerPolicy.persist(false, in: &state) { persisted.append($0) }
  #expect(!coreRunning)
  #expect(!state.deferredRuntimeApplyPending)
  #expect(
    DeferredRuntimeMarkerPolicy.outcome(
      coreRunning: true,
      marker: state.deferredRuntimeApplyPending
    )
      == .applied
  )
}

@Test func failedCoreStopDoesNotPersistDesiredStateChange() {
  var state = PersistentState()
  state.desiredRunning = true
  state.automaticRecoveryAttempted = true
  state.deferredRuntimeApplyPending = true
  var saves = 0

  #expect(throws: StopTransactionTestError.stop) {
    try CoreStopTransaction.run(
      state: &state,
      stopKnownGood: { throw StopTransactionTestError.stop },
      save: { _ in saves += 1 }
    )
  }

  #expect(state.desiredRunning)
  #expect(state.automaticRecoveryAttempted)
  #expect(state.deferredRuntimeApplyPending)
  #expect(saves == 0)
}

@Test func successfulCoreStopPersistsOnlyAfterStopProof() throws {
  var state = PersistentState()
  state.desiredRunning = true
  state.automaticRecoveryAttempted = true
  state.deferredRuntimeApplyPending = true
  var stopProven = false
  var persisted: PersistentState?

  try CoreStopTransaction.run(
    state: &state,
    stopKnownGood: { stopProven = true },
    save: { snapshot in
      #expect(stopProven)
      persisted = snapshot
    }
  )

  #expect(!state.desiredRunning)
  #expect(!state.automaticRecoveryAttempted)
  #expect(!state.deferredRuntimeApplyPending)
  let saved = try #require(persisted)
  #expect(saved.desiredRunning == state.desiredRunning)
  #expect(saved.automaticRecoveryAttempted == state.automaticRecoveryAttempted)
  #expect(saved.deferredRuntimeApplyPending == state.deferredRuntimeApplyPending)
}

@Test func persistenceFailureAfterProvenCoreStopKeepsLiveStateOff() {
  var state = PersistentState()
  state.desiredRunning = true
  state.automaticRecoveryAttempted = true
  state.deferredRuntimeApplyPending = true

  #expect(throws: StopTransactionTestError.persistence) {
    try CoreStopTransaction.run(
      state: &state,
      stopKnownGood: {},
      save: { _ in throw StopTransactionTestError.persistence }
    )
  }

  #expect(!state.desiredRunning)
  #expect(!state.automaticRecoveryAttempted)
  #expect(!state.deferredRuntimeApplyPending)
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      recoveryAuthorized: true,
      desiredRunning: state.desiredRunning,
      coreRunning: false,
      profileAvailable: true,
      configurationAvailable: true,
      recoveryAlreadyAttempted: state.automaticRecoveryAttempted
    ) == .stop
  )
}

@Test func unauthorizedDesiredRuntimeRecoveryIsNoActionForEveryState() {
  for desiredRunning in [false, true] {
    for coreRunning in [false, true] {
      for profileAvailable in [false, true] {
        for configurationAvailable in [false, true] {
          for recoveryAlreadyAttempted in [false, true] {
            #expect(
              DesiredRuntimeRecoveryPolicy.decision(
                recoveryAuthorized: false,
                desiredRunning: desiredRunning,
                coreRunning: coreRunning,
                profileAvailable: profileAvailable,
                configurationAvailable: configurationAvailable,
                recoveryAlreadyAttempted: recoveryAlreadyAttempted
              ) == .noAction
            )
          }
        }
      }
    }
  }
}

@Test func stopSaveFailureBeforeReplacementIsRetriedInNextHelperLifetime() throws {
  var durableBytes = try JSONEncoder().encode(durableStopTestState())
  let firstLifetimeState = try JSONDecoder().decode(PersistentState.self, from: durableBytes)
  #expect(firstLifetimeState.desiredRunning)
  #expect(firstLifetimeState.profile != nil)
  #expect(firstLifetimeState.activeProfileID != nil)

  var firstLifetime = firstLifetimeState
  var physicalCoreRunning = true
  #expect(throws: StopTransactionTestError.persistence) {
    try CoreStopTransaction.run(
      state: &firstLifetime,
      stopKnownGood: { physicalCoreRunning = false },
      save: { _ in throw StopTransactionTestError.persistence }
    )
  }
  #expect(!physicalCoreRunning)
  #expect(!firstLifetime.desiredRunning)
  #expect(firstLifetime.profile != nil)

  let secondLifetime = try JSONDecoder().decode(PersistentState.self, from: durableBytes)
  #expect(secondLifetime.desiredRunning)
  #expect(secondLifetime.profile != nil)
  #expect(secondLifetime.activeProfileID == firstLifetimeState.activeProfileID)

  var retryState = secondLifetime
  try CoreStopTransaction.run(
    state: &retryState,
    stopKnownGood: { #expect(!physicalCoreRunning) },
    save: { durableBytes = try JSONEncoder().encode($0) }
  )
  let finalDurableState = try JSONDecoder().decode(PersistentState.self, from: durableBytes)
  #expect(!retryState.desiredRunning)
  #expect(!retryState.deferredRuntimeApplyPending)
  #expect(!finalDurableState.desiredRunning)
  #expect(!finalDurableState.deferredRuntimeApplyPending)
}

@Test func stopSaveFailureAfterReplacementIsSafelyRetriedInNextHelperLifetime() throws {
  var durableBytes = try JSONEncoder().encode(durableStopTestState())
  var firstLifetime = try JSONDecoder().decode(PersistentState.self, from: durableBytes)
  var physicalCoreRunning = true

  #expect(throws: StopTransactionTestError.persistence) {
    try CoreStopTransaction.run(
      state: &firstLifetime,
      stopKnownGood: { physicalCoreRunning = false },
      save: { snapshot in
        durableBytes = try JSONEncoder().encode(snapshot)
        // Model a failure after replacement, during the existing sync boundary.
        throw StopTransactionTestError.persistence
      }
    )
  }
  #expect(!physicalCoreRunning)
  #expect(!firstLifetime.desiredRunning)

  var secondLifetime = try JSONDecoder().decode(PersistentState.self, from: durableBytes)
  #expect(!secondLifetime.desiredRunning)
  #expect(secondLifetime.profile != nil)
  var retryStopCount = 0
  try CoreStopTransaction.run(
    state: &secondLifetime,
    stopKnownGood: {
      retryStopCount += 1
      physicalCoreRunning = false
    },
    save: { durableBytes = try JSONEncoder().encode($0) }
  )
  let finalDurableState = try JSONDecoder().decode(PersistentState.self, from: durableBytes)
  #expect(retryStopCount == 1)
  #expect(!physicalCoreRunning)
  #expect(!secondLifetime.desiredRunning)
  #expect(!finalDurableState.desiredRunning)
  #expect(!finalDurableState.deferredRuntimeApplyPending)
}

@Test func clashAPIResponseRequiresCompleteContentLengthAndHTTPStatus() throws {
  let complete = try CoreManager.parseAPIResponse(
    apiResponse("HTTP/1.1 200 OK\r\ncOnTeNt-LeNgTh: 5", body: "hello")
  )
  #expect(String(data: complete, encoding: .utf8) == "hello")

  #expect(throws: CoreFailure.self) {
    try CoreManager.parseAPIResponse(
      apiResponse("HTTP/1.1 200 OK\r\nContent-Length: 5", body: "he")
    )
  }
  #expect(throws: CoreFailure.self) {
    try CoreManager.parseAPIResponse(
      apiResponse("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3", body: "hey")
    )
  }
  #expect(throws: CoreFailure.self) {
    try CoreManager.parseAPIResponse(apiResponse("HTTP/1.1 503 Unavailable"))
  }
  #expect(throws: CoreFailure.self) {
    try CoreManager.parseAPIResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 0".utf8))
  }
}

@Test func clashAPIResponseSupportsStrictChunkedAndConnectionCloseBodies() throws {
  let chunked = try CoreManager.parseAPIResponse(
    apiResponse(
      "HTTP/1.1 200 OK\r\ntRaNsFeR-EnCoDiNg: Chunked",
      body: "5\r\nhello\r\n0\r\n\r\n"
    )
  )
  #expect(String(data: chunked, encoding: .utf8) == "hello")

  let closeDelimited = try CoreManager.parseAPIResponse(
    apiResponse("HTTP/1.1 200 OK\r\nContent-Type: application/json", body: "{}")
  )
  #expect(String(data: closeDelimited, encoding: .utf8) == "{}")

  for malformedChunked in [
    "z\r\nhello\r\n0\r\n\r\n",
    "5\r\nhello\r\n",
    "5\r\nhelloXX0\r\n\r\n",
  ] {
    #expect(throws: CoreFailure.self) {
      try CoreManager.parseAPIResponse(
        apiResponse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked", body: malformedChunked)
      )
    }
  }
  #expect(throws: CoreFailure.self) {
    try CoreManager.parseAPIResponse(
      apiResponse(
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked",
        body: "0\r\n\r\n"
      )
    )
  }
}

@Test func clashAPIResponseAcceptsExactRawCapAndRejectsCapPlusOne() throws {
  let maximum = 1_048_576
  let prefix = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Pad: "
  let separator = "\r\n\r\n"
  let paddingCount = maximum - prefix.utf8.count - separator.utf8.count
  let exact = Data((prefix + String(repeating: "a", count: paddingCount) + separator).utf8)
  #expect(exact.count == maximum)
  #expect(try CoreManager.parseAPIResponse(exact).isEmpty)

  let overLimit = Data(repeating: 0x78, count: maximum + 1)
  #expect(throws: CoreFailure.self) {
    try CoreManager.parseAPIResponse(overLimit)
  }
}
