import Foundation
import Observation
import SBMShared
import Testing

@testable import SBM

private let canonicalLegacyUpgradeBundleURL = URL(
  fileURLWithPath: "/Applications/SBM.app", isDirectory: true
)

@MainActor
private func canonicalInstalledBundleHasLegacyTombstone() -> Bool {
  guard
    canonicalLegacyUpgradeBundleURL.standardizedFileURL.resolvingSymlinksInPath()
      .standardizedFileURL.path == "/Applications/SBM.app",
    Bundle(url: canonicalLegacyUpgradeBundleURL)?.bundleIdentifier == "com.stillnotfree.sbm",
    HelperLifecycle.legacyTombstoneIsValid(bundleURL: canonicalLegacyUpgradeBundleURL)
  else { return false }
  return true
}

private let installedLegacyBundleSkipReason =
  Comment(
    rawValue:
      "Requires canonical /Applications/SBM.app with a valid legacy tombstone; service and IPC boundaries are test doubles."
  )

@MainActor
private final class ReadyHelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState
  var legacyRegistrationState: HelperRegistrationState = .notRegistered
  private(set) var registrationCount = 0
  private(set) var unregistrationCount = 0

  init(registrationState: HelperRegistrationState = .enabled) {
    self.registrationState = registrationState
  }

  func register() throws { registrationCount += 1 }
  func unregister() async throws { unregistrationCount += 1 }
  func unregisterLegacy() async throws { legacyRegistrationState = .notRegistered }
  func openSystemSettings() {}
}

private actor CancellationNotice {
  private var cancelled = false

  func record() { cancelled = true }

  func wait(timeout: Duration = .seconds(1)) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !cancelled, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    defer { cancelled = false }
    return cancelled
  }
}

private enum AnnouncementWaitFailure: Error {
  case timedOut
}

private func waitForAnnouncementWait(
  timeout: Duration = .seconds(1),
  _ isWaiting: @Sendable () async -> Bool
) async throws -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    try Task.checkCancellation()
    if await isWaiting() { return true }
    try await Task.sleep(for: .milliseconds(1))
  }
  return await isWaiting()
}

private actor RuntimeActionRecorder {
  private var actions: [HelperAction] = []
  private let shutdownResponse: HelperResponse

  init(
    shutdownResponse: HelperResponse = HelperResponse(
      success: true,
      coreRunning: false,
      message: "stopped"
    )
  ) {
    self.shutdownResponse = shutdownResponse
  }

  func send(_ request: HelperRequest) -> HelperResponse {
    actions.append(request.action)
    if request.action == .shutdown { return shutdownResponse }
    return HelperResponse(
      success: true,
      coreRunning: request.action == .start,
      activeProfileID: request.profileID,
      message: "runtime"
    )
  }

  func recordedActions() -> [HelperAction] { actions }
}

private actor ControlledSubscriptionFetcher {
  private struct Pending {
    let value: String
    let continuation: CheckedContinuation<SubscriptionFetchResult, any Error>
  }
  private var pending: [Pending] = []
  private var announced: [String] = []
  private var activeRequestWaits = 0
  private var closedAfterTestFailure = false
  private let cancellationNotice = CancellationNotice()

  func fetch(_ value: String, _ headers: SubscriptionHeaders) async throws
    -> SubscriptionFetchResult
  {
    guard !closedAfterTestFailure else { throw CancellationError() }
    announced.append(value)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending.append(Pending(value: value, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancellationNotice.record() }
    }
  }

  func nextRequest(timeout: Duration = .seconds(2)) async throws -> String {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    try Task.checkCancellation()
    guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
    if !announced.isEmpty { return announced.removeFirst() }

    activeRequestWaits += 1
    defer { activeRequestWaits -= 1 }
    while true {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
      if !announced.isEmpty {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
        return announced.removeFirst()
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func complete(_ value: String, with result: SubscriptionFetchResult) {
    let index = pending.firstIndex(where: { $0.value == value })!
    pending.remove(at: index).continuation.resume(returning: result)
  }

  func fail(_ value: String) {
    let index = pending.firstIndex(where: { $0.value == value })!
    pending.remove(at: index).continuation.resume(throwing: URLError(.cannotConnectToHost))
  }

  func requestCount() -> Int { pending.count + announced.count }
  func announcedCount() -> Int { announced.count }
  func hasActiveRequestWait() -> Bool { activeRequestWaits > 0 }

  func closeAfterTestFailure() {
    guard !closedAfterTestFailure else { return }
    closedAfterTestFailure = true
    let outstanding = pending
    pending.removeAll()
    announced.removeAll()
    for operation in outstanding {
      operation.continuation.resume(throwing: CancellationError())
    }
  }

  func waitForCancellation() async -> Bool { await cancellationNotice.wait() }
}

private actor ControlledHelperResponses {
  private struct Pending {
    let request: HelperRequest
    let continuation: CheckedContinuation<HelperResponse, any Error>
  }
  private var pending: [Pending] = []
  private var announced: [HelperRequest] = []
  private var activeRequestWaits = 0
  private var closedAfterTestFailure = false
  private let cancellationNotice = CancellationNotice()

  func send(_ request: HelperRequest) async throws -> HelperResponse {
    guard !closedAfterTestFailure else { throw CancellationError() }
    announced.append(request)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending.append(Pending(request: request, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancellationNotice.record() }
    }
  }

  func nextRequest(timeout: Duration = .seconds(2)) async throws -> HelperRequest {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    try Task.checkCancellation()
    guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
    if !announced.isEmpty { return announced.removeFirst() }

    activeRequestWaits += 1
    defer { activeRequestWaits -= 1 }
    while true {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
      if !announced.isEmpty {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
        return announced.removeFirst()
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func completeNext(_ response: HelperResponse) {
    pending.removeFirst().continuation.resume(returning: response)
  }

  func failNext(_ error: any Error = URLError(.timedOut)) {
    pending.removeFirst().continuation.resume(throwing: error)
  }

  func pendingCount() -> Int { pending.count + announced.count }
  func announcedCount() -> Int { announced.count }
  func hasActiveRequestWait() -> Bool { activeRequestWaits > 0 }

  func closeAfterTestFailure() {
    guard !closedAfterTestFailure else { return }
    closedAfterTestFailure = true
    let outstanding = pending
    pending.removeAll()
    announced.removeAll()
    for operation in outstanding {
      operation.continuation.resume(throwing: CancellationError())
    }
  }

  func waitForCancellation() async -> Bool { await cancellationNotice.wait() }
}

private actor UpdateCallGate<Value: Sendable> {
  private var nextID = 0
  private var started: [Int] = []
  private var activeStartedWaits = 0
  private var pending: [Int: CheckedContinuation<Value, any Error>] = [:]
  private var results: [Int: Result<Value, any Error>] = [:]
  private var resolved: Set<Int> = []
  private var cancelled: Set<Int> = []

  func begin() -> Int {
    let id = nextID
    nextID += 1
    started.append(id)
    return id
  }

  func wait(_ id: Int) async throws -> Value {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if let result = results.removeValue(forKey: id) {
          resolved.insert(id)
          continuation.resume(with: result)
        } else {
          pending[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func nextStarted(timeout: Duration = .seconds(2)) async throws -> Int {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    try Task.checkCancellation()
    guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
    if !started.isEmpty { return started.removeFirst() }

    activeStartedWaits += 1
    defer { activeStartedWaits -= 1 }
    while true {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
      if !started.isEmpty {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
        return started.removeFirst()
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func startedCount() -> Int { nextID }
  func hasActiveStartedWait() -> Bool { activeStartedWaits > 0 }
  func hasPendingWait(_ id: Int) -> Bool { pending[id] != nil }

  func succeed(_ id: Int, with value: Value) {
    finish(id, with: .success(value))
  }

  func fail(_ id: Int, with error: any Error) {
    finish(id, with: .failure(error))
  }

  func wasCancelled(_ id: Int) -> Bool { cancelled.contains(id) }

  private func finish(_ id: Int, with result: Result<Value, any Error>) {
    if let continuation = pending.removeValue(forKey: id) {
      resolved.insert(id)
      continuation.resume(with: result)
    } else if !resolved.contains(id) {
      results[id] = result
    }
  }

  private func cancel(_ id: Int) {
    cancelled.insert(id)
    if let continuation = pending.removeValue(forKey: id) {
      resolved.insert(id)
      continuation.resume(throwing: CancellationError())
    } else if !resolved.contains(id), results[id] == nil {
      results[id] = .failure(CancellationError())
    }
  }
}

private actor ControlledUpdater {
  private let checkGate = UpdateCallGate<AppUpdate?>()
  private let downloadGate = UpdateCallGate<URL>()
  private var currentVersions: [String] = []
  private var progressHandlers: [Int: @Sendable (Double) -> Void] = [:]

  func check(currentVersion: String) async throws -> AppUpdate? {
    currentVersions.append(currentVersion)
    let id = await checkGate.begin()
    return try await checkGate.wait(id)
  }

  func download(
    _ update: AppUpdate,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL {
    let id = await downloadGate.begin()
    progressHandlers[id] = progress
    return try await downloadGate.wait(id)
  }

  func nextCheck(timeout: Duration = .seconds(2)) async throws -> Int {
    try await checkGate.nextStarted(timeout: timeout)
  }
  func nextDownload(timeout: Duration = .seconds(2)) async throws -> Int {
    try await downloadGate.nextStarted(timeout: timeout)
  }
  func hasActiveCheckWait() async -> Bool { await checkGate.hasActiveStartedWait() }
  func hasActiveDownloadWait() async -> Bool { await downloadGate.hasActiveStartedWait() }
  func checkCount() async -> Int { await checkGate.startedCount() }
  func downloadCount() async -> Int { await downloadGate.startedCount() }
  func wasCheckCancelled(_ id: Int) async -> Bool { await checkGate.wasCancelled(id) }
  func wasDownloadCancelled(_ id: Int) async -> Bool { await downloadGate.wasCancelled(id) }
  func completeCheck(_ id: Int, with update: AppUpdate?) async {
    await checkGate.succeed(id, with: update)
  }
  func failCheck(_ id: Int, with error: any Error) async {
    await checkGate.fail(id, with: error)
  }
  func completeDownload(_ id: Int, with url: URL) async {
    await downloadGate.succeed(id, with: url)
  }
  func failDownload(_ id: Int, with error: any Error) async {
    await downloadGate.fail(id, with: error)
  }
  func progressHandler(_ id: Int) -> (@Sendable (Double) -> Void)? {
    progressHandlers[id]
  }
}

private struct ControlledUpdateFailure: Error, Sendable {}

private final class UpdaterStateContinuation: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var signalled = false

  func install(_ continuation: CheckedContinuation<Void, Never>) {
    lock.lock()
    if signalled {
      lock.unlock()
      continuation.resume()
    } else {
      self.continuation = continuation
      lock.unlock()
    }
  }

  func signal() {
    lock.lock()
    guard !signalled else {
      lock.unlock()
      return
    }
    signalled = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume()
  }
}

@MainActor
private func awaitUpdaterState(
  timeout: Duration = .seconds(2),
  _ condition: @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !condition() {
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else { return false }
    let signal = UpdaterStateContinuation()
    await withCheckedContinuation { continuation in
      signal.install(continuation)
      let timeoutTask = Task {
        try? await Task.sleep(for: remaining)
        signal.signal()
      }
      withObservationTracking {
        _ = condition()
      } onChange: {
        timeoutTask.cancel()
        signal.signal()
      }
    }
  }
  return true
}

@MainActor
private func invokeProgressAndDrain(
  _ callback: @escaping @Sendable (Double) -> Void,
  fraction: Double
) async {
  await withCheckedContinuation { continuation in
    Task { @MainActor in
      callback(fraction)
      Task { @MainActor in continuation.resume() }
    }
  }
}

private func updaterTestDefaults() -> (UserDefaults, String) {
  let name = "SBMTests.Updater.\(UUID().uuidString)"
  return (UserDefaults(suiteName: name)!, name)
}

private func updaterFixture() -> AppUpdate {
  AppUpdate(
    version: "2.0.0",
    assetURL: URL(string: "https://downloads.example.test/SBM-2.0.0-arm64.dmg")!,
    expectedDigest: String(repeating: "a", count: 64),
    expectedSize: 128
  )
}

@MainActor
private func controlledUpdaterModel(
  _ updater: ControlledUpdater,
  userDefaults: UserDefaults,
  updateOpener: ((URL) -> Bool)? = nil
) -> AppModel {
  hardeningModel(
    library: .empty,
    userDefaults: userDefaults,
    updateChecker: { currentVersion in
      try await updater.check(currentVersion: currentVersion)
    },
    updateDownloader: { update, progress in
      try await updater.download(update, progress: progress)
    },
    updateOpener: updateOpener
  )
}

@MainActor
private func publishUpdaterFixture(
  _ update: AppUpdate,
  model: AppModel,
  updater: ControlledUpdater
) async throws -> Bool {
  model.checkForUpdates()
  let id = try await updater.nextCheck()
  await updater.completeCheck(id, with: update)
  return await awaitUpdaterState {
    !model.isCheckingForUpdates && model.availableUpdateVersion == update.version
  }
}

private final class AutoSelectionMutationEventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []

  func append(_ event: String) {
    lock.lock()
    defer { lock.unlock() }
    events.append(event)
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}

private final class UpdateOpenerRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private let result: Bool
  private var openedURLs: [URL] = []

  init(result: Bool) {
    self.result = result
  }

  func open(_ url: URL) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    openedURLs.append(url)
    return result
  }

  func snapshot() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return openedURLs
  }
}

private actor HelperStatusSequence {
  private var responses: [HelperResponse]

  init(_ responses: [HelperResponse]) {
    self.responses = responses
  }

  func next() -> HelperResponse {
    responses.removeFirst()
  }
}

@MainActor
private func waitForRuntimeRequest(
  _ runtime: ControlledHelperResponses,
  count: Int = 1,
  timeout: Duration = .seconds(2)
) async throws -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    try Task.checkCancellation()
    if await runtime.announcedCount() >= count { return true }
    try await Task.sleep(for: .milliseconds(1))
  }
  try Task.checkCancellation()
  return await runtime.announcedCount() >= count
}

@MainActor
private func waitForSubmittedRuntimeRequest(
  _ runtime: ControlledHelperResponses,
  timeout: Duration = .seconds(2)
) async throws -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    try Task.checkCancellation()
    if await runtime.announcedCount() > 0 { return true }
    try await Task.sleep(for: .milliseconds(1))
  }
  try Task.checkCancellation()
  return await runtime.announcedCount() > 0
}

@MainActor
private func waitForRuntimeApplyStatus(
  _ model: AppModel,
  _ status: RuntimeApplyStatus
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while model.runtimeApplyStatus != status, ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return model.runtimeApplyStatus == status
}

@MainActor
private func waitForHardeningCondition(
  timeout: Duration = .seconds(2),
  _ condition: @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !condition(), ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return condition()
}

private func makeIsolatedHardeningDefaults() -> (suite: String, defaults: UserDefaults) {
  let suite = "SBMTests.DurableStopProof.\(UUID().uuidString)"
  return (suite, UserDefaults(suiteName: suite)!)
}

private actor FailingThenStoppedStatus {
  private var attempt = 0

  func send(_: HelperRequest, _: Int) throws -> HelperResponse {
    attempt += 1
    if attempt == 1 { throw URLError(.timedOut) }
    return HelperResponse(success: true, coreRunning: false, message: "observed stopped")
  }
}

private final class SaveFailureController {
  var attempts = 0
  var failOnAttempts: Set<Int>

  init(failOnAttempts: Set<Int>) {
    self.failOnAttempts = failOnAttempts
  }

  func save(_: ProfileLibrary) throws {
    attempts += 1
    if failOnAttempts.contains(attempts) {
      throw CocoaError(.fileWriteNoPermission)
    }
  }
}

private actor ControlledValidator {
  private var continuation: CheckedContinuation<HelperResponse, any Error>?
  private var announced: [CoreProfile] = []
  private var activeProfileWaits = 0
  private var closedAfterTestFailure = false
  private let cancellationNotice = CancellationNotice()

  func validate(_ profile: CoreProfile) async throws -> HelperResponse {
    guard !closedAfterTestFailure else { throw CancellationError() }
    announced.append(profile)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation = $0 }
    } onCancel: {
      Task { await self.cancellationNotice.record() }
    }
  }

  func nextProfile(timeout: Duration = .seconds(2)) async throws -> CoreProfile {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    try Task.checkCancellation()
    guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
    if !announced.isEmpty { return announced.removeFirst() }

    activeProfileWaits += 1
    defer { activeProfileWaits -= 1 }
    while true {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
      if !announced.isEmpty {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
        return announced.removeFirst()
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func complete() {
    continuation?.resume(
      returning: HelperResponse(success: true, coreRunning: false, message: "valid")
    )
    continuation = nil
  }

  func waitForCancellation() async -> Bool { await cancellationNotice.wait() }

  func requestWasMade() -> Bool { !announced.isEmpty || continuation != nil }
  func hasActiveProfileWait() -> Bool { activeProfileWaits > 0 }

  func closeAfterTestFailure() {
    guard !closedAfterTestFailure else { return }
    closedAfterTestFailure = true
    announced.removeAll()
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(throwing: CancellationError())
  }
}

private actor QueuedValidator {
  private struct Pending {
    let profile: CoreProfile
    let continuation: CheckedContinuation<HelperResponse, any Error>
  }

  private var announced: [CoreProfile] = []
  private var activeProfileWaits = 0
  private var pending: [Pending] = []
  private var closedAfterTestFailure = false

  func validate(_ profile: CoreProfile) async throws -> HelperResponse {
    guard !closedAfterTestFailure else { throw CancellationError() }
    announced.append(profile)
    return try await withCheckedThrowingContinuation { continuation in
      pending.append(Pending(profile: profile, continuation: continuation))
    }
  }

  func nextProfile(timeout: Duration = .seconds(2)) async throws -> CoreProfile {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    try Task.checkCancellation()
    guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
    if !announced.isEmpty { return announced.removeFirst() }

    activeProfileWaits += 1
    defer { activeProfileWaits -= 1 }
    while true {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
      if !announced.isEmpty {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw AnnouncementWaitFailure.timedOut }
        return announced.removeFirst()
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func hasActiveProfileWait() -> Bool { activeProfileWaits > 0 }
  func announcedCount() -> Int { announced.count }

  func closeAfterTestFailure() {
    guard !closedAfterTestFailure else { return }
    closedAfterTestFailure = true
    announced.removeAll()
    let outstanding = pending
    pending.removeAll()
    for operation in outstanding {
      operation.continuation.resume(throwing: CancellationError())
    }
  }

  func complete(_ profile: CoreProfile) {
    guard let index = pending.firstIndex(where: { $0.profile == profile }) else {
      preconditionFailure("No pending validation for the requested profile")
    }
    pending.remove(at: index).continuation.resume(
      returning: HelperResponse(success: true, coreRunning: false, message: "valid")
    )
  }

  func completeNext() {
    pending.removeFirst().continuation.resume(
      returning: HelperResponse(success: true, coreRunning: false, message: "valid")
    )
  }
}

private func hardeningConnection(_ host: String) -> ManagedConnection {
  ManagedConnection(
    outbound: .shadowsocks(
      ShadowsocksProfile(
        server: host,
        port: 443,
        method: "aes-256-gcm",
        password: "test-password",
        displayName: host
      )
    )
  )
}

private func hardeningPayload(_ host: String) -> CoreProfile {
  .compatibility(VPNProfile(connections: [hardeningConnection(host)]))
}

private func hardeningProfileStoreDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "SBM-SelectedProfile-\(UUID().uuidString)", isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
  )
  return directory
}

private func hardeningServer(_ payload: CoreProfile?) -> String? {
  guard case .compatibility(let profile)? = payload,
    case .shadowsocks(let connection)? = profile.connections.first?.outbound
  else { return nil }
  return connection.server
}

private func hardeningApplicationBundle(_ name: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-" + name + "-" + UUID().uuidString, isDirectory: true)
  let bundle = root.appendingPathComponent(name + ".app", isDirectory: true)
  let executable = bundle.appendingPathComponent("Contents/MacOS/" + name)
  try FileManager.default.createDirectory(
    at: executable.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("#!/bin/sh\n".utf8).write(to: executable)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: executable.path
  )
  let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>\(name)</string>
      <key>CFBundleIdentifier</key><string>test.sbm.\(name.lowercased())</string>
      <key>CFBundleDisplayName</key><string>\(name)</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
    """
  try Data(plist.utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
  return bundle
}

private func hardeningResponse(
  coreRunning: Bool,
  revision: Int,
  protocolVersion: Int = HelperConstants.protocolVersion,
  activeProfileID: UUID? = nil,
  message: String = "status"
) throws -> HelperResponse {
  let response = HelperResponse(
    success: true,
    coreRunning: coreRunning,
    activeProfileID: activeProfileID,
    message: message
  )
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
  )
  object["protocolVersion"] = protocolVersion
  object["helperRevision"] = revision
  return try JSONDecoder().decode(
    HelperResponse.self,
    from: JSONSerialization.data(withJSONObject: object)
  )
}

@MainActor
private func hardeningModel(
  library: ProfileLibrary,
  userDefaults: UserDefaults = IsolatedTestUserDefaults(),
  performStartup: Bool = false,
  helperService: ReadyHelperService? = nil,
  helperApprovalPollDuration: Duration? = nil,
  helperApprovalPollInterval: Duration? = nil,
  applicationBundleURL: URL? = nil,
  manager: SubscriptionManager = SubscriptionManager { _, _ in
    SubscriptionFetchResult(profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  },
  lifecycleSender: @escaping @Sendable (HelperRequest, Int) async throws -> HelperResponse = {
    _, _ in
    HelperResponse(success: true, coreRunning: false, message: "status")
  },
  helperRequestSender: (@Sendable (HelperRequest) async throws -> HelperResponse)? = nil,
  runtimeSender: @escaping @Sendable (HelperRequest) async throws -> HelperResponse = { request in
    HelperResponse(
      success: true,
      coreRunning: request.action == .start,
      mode: request.mode ?? .rule,
      selectedNode: request.node ?? .auto,
      activeProfileID: request.profileID,
      activeIPv6Enabled: request.action == .start ? (request.ipv6Enabled ?? false) : nil,
      message: "runtime"
    )
  },
  validator: @escaping @Sendable (CoreProfile) async throws -> HelperResponse = { _ in
    HelperResponse(success: true, coreRunning: false, message: "valid")
  },
  saver: @escaping (ProfileLibrary) throws -> Void = { _ in },
  helperRegistrationState: HelperRegistrationState = .enabled,
  runtimeStateReader: @escaping @Sendable () async throws -> HelperResponse = {
    HelperResponse(success: true, coreRunning: false, message: "observed")
  },
  latencySettleDelay: Duration? = nil,
  latencySender: @escaping @Sendable (ProxyNodeID?) async throws -> HelperResponse = { node in
    HelperResponse(
      success: true,
      coreRunning: true,
      activeIPv6Enabled: true,
      delays: node.map { [NodeDelay(node: $0, milliseconds: 20)] } ?? [],
      message: "latency"
    )
  },
  updateChecker: (@Sendable (String) async throws -> AppUpdate?)? = nil,
  updateDownloader: (
    @Sendable (
      AppUpdate, @escaping @Sendable (Double) -> Void
    ) async throws -> URL
  )? = nil,
  updateOpener: ((URL) -> Bool)? = nil
) -> AppModel {
  let model = AppModel(
    helperService: helperService ?? ReadyHelperService(registrationState: helperRegistrationState),
    subscriptionManager: manager,
    helperLifecycleSender: lifecycleSender,
    helperApprovalPollDuration: helperApprovalPollDuration,
    helperApprovalPollInterval: helperApprovalPollInterval,
    applicationBundleURL: applicationBundleURL,
    runtimeSender: runtimeSender,
    helperRequestSender: helperRequestSender,
    profileValidator: validator,
    profileLibraryLoader: { library },
    profileLibrarySaver: saver,
    userDefaults: userDefaults,
    runtimeStateReader: runtimeStateReader,
    latencySender: latencySender,
    latencySettleDelay: latencySettleDelay,
    updateChecker: updateChecker,
    updateDownloader: updateDownloader,
    updateOpener: updateOpener,
    performStartup: performStartup
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  return model
}

private func autoObservationResponse(
  for profile: ManagedProfile,
  effectiveNode: ProxyNodeID?,
  message: String = "observed"
) -> HelperResponse {
  let nodes = (profile.payload?.nodes ?? []).map { node in
    ProxyNodeDescriptor(
      id: node.id,
      name: node.id == effectiveNode ? "Observed child" : node.name,
      kind: node.kind
    )
  }
  return HelperResponse(
    success: true,
    coreRunning: true,
    coreVersion: message,
    selectedNode: .auto,
    effectiveAutoNode: effectiveNode,
    activeProfileID: profile.id,
    activeIPv6Enabled: false,
    nodes: nodes,
    message: message
  )
}

@MainActor
private func nextHelperRequest(_ responses: ControlledHelperResponses) async throws
  -> HelperRequest?
{
  guard try await waitForRuntimeRequest(responses) else { return nil }
  return try await responses.nextRequest()
}

@MainActor
private func nextRefreshStatusRequest(
  _ model: AppModel,
  _ responses: ControlledHelperResponses,
  timeout: Duration = .seconds(2)
) async throws -> HelperRequest {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    try Task.checkCancellation()
    model.refresh()
    if await responses.announcedCount() > 0 {
      return try await responses.nextRequest(timeout: .milliseconds(100))
    }
    try await Task.sleep(for: .milliseconds(1))
  }
  throw AnnouncementWaitFailure.timedOut
}

private func nextSubscriptionRequest(
  _ fetcher: ControlledSubscriptionFetcher,
  timeout: Duration = .seconds(2)
) async throws -> String? {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    try Task.checkCancellation()
    if await fetcher.announcedCount() > 0 { return try await fetcher.nextRequest() }
    try await Task.sleep(for: .milliseconds(1))
  }
  try Task.checkCancellation()
  guard await fetcher.announcedCount() > 0 else { return nil }
  return try await fetcher.nextRequest()
}

private func expectAnnouncementTimeout(
  _ operation: @Sendable () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected the announcement wait to time out.")
  } catch is AnnouncementWaitFailure {
  } catch {
    Issue.record("Expected announcement timeout, received \(error).")
  }
}

private func expectCancellation<T: Sendable>(_ task: Task<T, any Error>) async {
  do {
    _ = try await task.value
    Issue.record("Expected the announcement wait to be cancelled.")
  } catch is CancellationError {
  } catch {
    Issue.record("Expected cancellation, received \(error).")
  }
}

private func cancelAndJoin<T: Sendable>(_ tasks: [Task<T, any Error>]) async {
  for task in tasks {
    task.cancel()
    _ = try? await task.value
  }
}

@Test @MainActor
func helperAnnouncementWaitsAreBoundedCancelableFIFOAndDoNotTrustPendingCounts() async throws {
  let responses = ControlledHelperResponses()
  var announcementWaiters: [Task<HelperRequest, any Error>] = []
  var operations: [Task<HelperResponse, any Error>] = []
  do {
    await expectAnnouncementTimeout {
      _ = try await responses.nextRequest(timeout: .milliseconds(10))
    }

    let firstRequest = HelperRequest(action: .status)
    let firstSend = Task { try await responses.send(firstRequest) }
    operations.append(firstSend)
    guard try await waitForRuntimeRequest(responses, timeout: .seconds(1)) else {
      throw AnnouncementWaitFailure.timedOut
    }
    let secondRequest = HelperRequest(action: .start)
    let secondSend = Task { try await responses.send(secondRequest) }
    operations.append(secondSend)
    guard try await waitForRuntimeRequest(responses, count: 2, timeout: .seconds(1)) else {
      throw AnnouncementWaitFailure.timedOut
    }

    let cancelledBeforeDequeue = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await responses.nextRequest()
    }
    announcementWaiters.append(cancelledBeforeDequeue)
    await expectCancellation(cancelledBeforeDequeue)

    let dequeuedFirst = try await responses.nextRequest()
    let dequeuedSecond = try await responses.nextRequest()
    #expect(dequeuedFirst.action == .status)
    #expect(dequeuedSecond.action == .start)
    #expect(await responses.pendingCount() == 2)
    #expect(await responses.announcedCount() == 0)
    #expect(try await waitForRuntimeRequest(responses, timeout: .milliseconds(10)) == false)
    #expect(
      try await waitForSubmittedRuntimeRequest(responses, timeout: .milliseconds(10)) == false)

    let cancelledDuringWait = Task { try await responses.nextRequest(timeout: .seconds(2)) }
    announcementWaiters.append(cancelledDuringWait)
    #expect(try await waitForAnnouncementWait { await responses.hasActiveRequestWait() })
    cancelledDuringWait.cancel()
    await expectCancellation(cancelledDuringWait)

    let thirdRequest = HelperRequest(action: .stop)
    let thirdSend = Task { try await responses.send(thirdRequest) }
    operations.append(thirdSend)
    guard try await waitForRuntimeRequest(responses, timeout: .seconds(1)) else {
      throw AnnouncementWaitFailure.timedOut
    }
    let dequeuedThird = try await responses.nextRequest()
    #expect(dequeuedThird.action == .stop)

    let firstResponse = HelperResponse(success: true, coreRunning: false, message: "first")
    let secondResponse = HelperResponse(success: true, coreRunning: true, message: "second")
    let thirdResponse = HelperResponse(success: true, coreRunning: false, message: "third")
    await responses.completeNext(firstResponse)
    await responses.completeNext(secondResponse)
    await responses.completeNext(thirdResponse)
    #expect(try await firstSend.value.message == "first")
    #expect(try await secondSend.value.message == "second")
    #expect(try await thirdSend.value.message == "third")
    #expect(await responses.pendingCount() == 0)
  } catch {
    Issue.record("Helper announcement regression exited early: \(error).")
    await responses.closeAfterTestFailure()
    await cancelAndJoin(announcementWaiters)
    await cancelAndJoin(operations)
  }
}

@Test
func subscriptionAnnouncementWaitsPropagateCancellationAndKeepFIFO() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  var announcementWaiters: [Task<String, any Error>] = []
  var operations: [Task<SubscriptionFetchResult, any Error>] = []
  do {
    await expectAnnouncementTimeout {
      _ = try await fetcher.nextRequest(timeout: .milliseconds(10))
    }

    let cancelledDuringWait = Task { try await fetcher.nextRequest(timeout: .seconds(2)) }
    announcementWaiters.append(cancelledDuringWait)
    #expect(try await waitForAnnouncementWait { await fetcher.hasActiveRequestWait() })
    cancelledDuringWait.cancel()
    await expectCancellation(cancelledDuringWait)

    let firstURL = "https://one.example.test"
    let secondURL = "https://two.example.test"
    let firstFetch = Task { try await fetcher.fetch(firstURL, SubscriptionHeaders()) }
    operations.append(firstFetch)
    guard try await waitForAnnouncementWait({ await fetcher.announcedCount() == 1 }) else {
      throw AnnouncementWaitFailure.timedOut
    }
    let secondFetch = Task { try await fetcher.fetch(secondURL, SubscriptionHeaders()) }
    operations.append(secondFetch)
    guard try await waitForAnnouncementWait({ await fetcher.announcedCount() == 2 }) else {
      throw AnnouncementWaitFailure.timedOut
    }

    let cancelledBeforeDequeue = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await fetcher.nextRequest()
    }
    announcementWaiters.append(cancelledBeforeDequeue)
    await expectCancellation(cancelledBeforeDequeue)

    let dequeuedFirst = try #require(try await nextSubscriptionRequest(fetcher))
    let dequeuedSecond = try #require(try await nextSubscriptionRequest(fetcher))
    #expect(dequeuedFirst == firstURL)
    #expect(dequeuedSecond == secondURL)
    #expect(await fetcher.requestCount() == 2)
    #expect(await fetcher.announcedCount() == 0)
    #expect(try await nextSubscriptionRequest(fetcher, timeout: .milliseconds(10)) == nil)

    let firstResult = SubscriptionFetchResult(
      profile: hardeningPayload("one.example.test"), skippedTransports: [:]
    )
    let secondResult = SubscriptionFetchResult(
      profile: hardeningPayload("two.example.test"), skippedTransports: [:]
    )
    await fetcher.complete("https://one.example.test", with: firstResult)
    await fetcher.complete("https://two.example.test", with: secondResult)
    #expect(try await firstFetch.value.profile == firstResult.profile)
    #expect(try await secondFetch.value.profile == secondResult.profile)
    #expect(await fetcher.requestCount() == 0)
  } catch {
    Issue.record("Subscription announcement regression exited early: \(error).")
    await fetcher.closeAfterTestFailure()
    await cancelAndJoin(announcementWaiters)
    await cancelAndJoin(operations)
  }
}

@Test
func controlledValidatorAnnouncementsTimeOutCancelAndArriveAfterPriorWait() async throws {
  let validator = ControlledValidator()
  var announcementWaiters: [Task<CoreProfile, any Error>] = []
  var operations: [Task<HelperResponse, any Error>] = []
  do {
    await expectAnnouncementTimeout {
      _ = try await validator.nextProfile(timeout: .milliseconds(10))
    }

    let cancelledDuringWait = Task { try await validator.nextProfile(timeout: .seconds(2)) }
    announcementWaiters.append(cancelledDuringWait)
    #expect(try await waitForAnnouncementWait { await validator.hasActiveProfileWait() })
    cancelledDuringWait.cancel()
    await expectCancellation(cancelledDuringWait)

    let firstProfile = hardeningPayload("controlled-first.example.test")
    let firstValidation = Task { try await validator.validate(firstProfile) }
    operations.append(firstValidation)
    guard try await waitForAnnouncementWait({ await validator.requestWasMade() }) else {
      throw AnnouncementWaitFailure.timedOut
    }
    let cancelledBeforeDequeue = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await validator.nextProfile()
    }
    announcementWaiters.append(cancelledBeforeDequeue)
    await expectCancellation(cancelledBeforeDequeue)
    let dequeuedFirst = try await validator.nextProfile()
    #expect(dequeuedFirst == firstProfile)
    await validator.complete()
    #expect(try await firstValidation.value.message == "valid")

    let secondProfile = hardeningPayload("controlled-second.example.test")
    let waitingForSecond = Task { try await validator.nextProfile(timeout: .seconds(2)) }
    announcementWaiters.append(waitingForSecond)
    guard try await waitForAnnouncementWait({ await validator.hasActiveProfileWait() }) else {
      throw AnnouncementWaitFailure.timedOut
    }
    let secondValidation = Task { try await validator.validate(secondProfile) }
    operations.append(secondValidation)
    guard try await waitForAnnouncementWait({ await validator.requestWasMade() }) else {
      throw AnnouncementWaitFailure.timedOut
    }
    let dequeuedSecond = try await waitingForSecond.value
    #expect(dequeuedSecond == secondProfile)
    await validator.complete()
    #expect(try await secondValidation.value.message == "valid")
  } catch {
    Issue.record("Controlled validator regression exited early: \(error).")
    await validator.closeAfterTestFailure()
    await cancelAndJoin(announcementWaiters)
    await cancelAndJoin(operations)
  }
}

@Test
func queuedValidatorAnnouncementsAreBoundedCancelableAndFIFO() async throws {
  let validator = QueuedValidator()
  var announcementWaiters: [Task<CoreProfile, any Error>] = []
  var operations: [Task<HelperResponse, any Error>] = []
  do {
    await expectAnnouncementTimeout {
      _ = try await validator.nextProfile(timeout: .milliseconds(10))
    }

    let cancelledDuringWait = Task { try await validator.nextProfile(timeout: .seconds(2)) }
    announcementWaiters.append(cancelledDuringWait)
    #expect(try await waitForAnnouncementWait { await validator.hasActiveProfileWait() })
    cancelledDuringWait.cancel()
    await expectCancellation(cancelledDuringWait)

    let firstProfile = hardeningPayload("queued-first.example.test")
    let secondProfile = hardeningPayload("queued-second.example.test")
    let firstValidation = Task { try await validator.validate(firstProfile) }
    operations.append(firstValidation)
    guard try await waitForAnnouncementWait({ await validator.announcedCount() == 1 }) else {
      throw AnnouncementWaitFailure.timedOut
    }
    let secondValidation = Task { try await validator.validate(secondProfile) }
    operations.append(secondValidation)
    guard try await waitForAnnouncementWait({ await validator.announcedCount() == 2 }) else {
      throw AnnouncementWaitFailure.timedOut
    }

    let cancelledBeforeDequeue = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await validator.nextProfile()
    }
    announcementWaiters.append(cancelledBeforeDequeue)
    await expectCancellation(cancelledBeforeDequeue)
    let dequeuedFirst = try await validator.nextProfile()
    let dequeuedSecond = try await validator.nextProfile()
    #expect(dequeuedFirst == firstProfile)
    #expect(dequeuedSecond == secondProfile)

    await validator.complete(firstProfile)
    await validator.complete(secondProfile)
    #expect(try await firstValidation.value.message == "valid")
    #expect(try await secondValidation.value.message == "valid")
  } catch {
    Issue.record("Queued validator regression exited early: \(error).")
    await validator.closeAfterTestFailure()
    await cancelAndJoin(announcementWaiters)
    await cancelAndJoin(operations)
  }
}

@Test
func updateAnnouncementGateAndUpdaterForwardingPropagateWaitCancellation() async throws {
  let gate = UpdateCallGate<String>()
  let updater = ControlledUpdater()
  var announcementWaiters: [Task<Int, any Error>] = []
  var gateOperations: [Task<String, any Error>] = []
  var checkOperations: [Task<AppUpdate?, any Error>] = []
  var downloadOperations: [Task<URL, any Error>] = []
  do {
    await expectAnnouncementTimeout {
      _ = try await gate.nextStarted(timeout: .milliseconds(10))
    }

    let cancelledDuringWait = Task { try await gate.nextStarted(timeout: .seconds(2)) }
    announcementWaiters.append(cancelledDuringWait)
    #expect(try await waitForAnnouncementWait { await gate.hasActiveStartedWait() })
    cancelledDuringWait.cancel()
    await expectCancellation(cancelledDuringWait)

    let firstID = await gate.begin()
    let secondID = await gate.begin()
    let cancelledBeforeDequeue = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await gate.nextStarted()
    }
    announcementWaiters.append(cancelledBeforeDequeue)
    await expectCancellation(cancelledBeforeDequeue)
    let dequeuedFirst = try await gate.nextStarted()
    let dequeuedSecond = try await gate.nextStarted()
    #expect(dequeuedFirst == firstID)
    #expect(dequeuedSecond == secondID)

    let firstOperation = Task { try await gate.wait(firstID) }
    gateOperations.append(firstOperation)
    let secondOperation = Task { try await gate.wait(secondID) }
    gateOperations.append(secondOperation)
    #expect(
      try await waitForAnnouncementWait {
        let firstPending = await gate.hasPendingWait(firstID)
        let secondPending = await gate.hasPendingWait(secondID)
        return firstPending && secondPending
      })
    await gate.succeed(firstID, with: "first result")
    await gate.succeed(secondID, with: "second result")
    #expect(try await firstOperation.value == "first result")
    #expect(try await secondOperation.value == "second result")

    let cancelledForwardedCheckWait = Task {
      try await updater.nextCheck(timeout: .seconds(2))
    }
    announcementWaiters.append(cancelledForwardedCheckWait)
    #expect(try await waitForAnnouncementWait { await updater.hasActiveCheckWait() })
    cancelledForwardedCheckWait.cancel()
    await expectCancellation(cancelledForwardedCheckWait)

    let checkOperation = Task { try await updater.check(currentVersion: "1.2.0") }
    checkOperations.append(checkOperation)
    do {
      let checkID = try await updater.nextCheck()
      await updater.completeCheck(checkID, with: nil)
      #expect(try await checkOperation.value == nil)
    } catch {
      Issue.record("Expected updater check announcement, received \(error).")
      checkOperation.cancel()
      await expectCancellation(checkOperation)
    }

    let cancelledForwardedDownloadWait = Task {
      try await updater.nextDownload(timeout: .seconds(2))
    }
    announcementWaiters.append(cancelledForwardedDownloadWait)
    #expect(try await waitForAnnouncementWait { await updater.hasActiveDownloadWait() })
    cancelledForwardedDownloadWait.cancel()
    await expectCancellation(cancelledForwardedDownloadWait)

    let update = AppUpdate(
      version: "1.3.0",
      assetURL: URL(string: "https://example.test/update.dmg")!,
      expectedDigest: String(repeating: "a", count: 64),
      expectedSize: 1
    )
    let downloadURL = URL(fileURLWithPath: "/tmp/announcement-update.dmg")
    let downloadOperation = Task { try await updater.download(update, progress: { _ in }) }
    downloadOperations.append(downloadOperation)
    do {
      let downloadID = try await updater.nextDownload()
      await updater.completeDownload(downloadID, with: downloadURL)
      #expect(try await downloadOperation.value == downloadURL)
    } catch {
      Issue.record("Expected updater download announcement, received \(error).")
      downloadOperation.cancel()
      await expectCancellation(downloadOperation)
    }
  } catch {
    Issue.record("Updater announcement regression exited early: \(error).")
    await cancelAndJoin(announcementWaiters)
    await cancelAndJoin(gateOperations)
    await cancelAndJoin(checkOperations)
    await cancelAndJoin(downloadOperations)
  }
}

@Test @MainActor
func explicitAutoObservationPublishesMappedChildAndManualSelectionClearsIt() async throws {
  let payload = hardeningPayload("auto-child.example.test")
  let childID = try #require(payload.nodes.first(where: { $0.id != .auto })?.id)
  let profile = ManagedProfile(name: "Auto", payload: payload)
  let childName = try #require(profile.payload?.nodes.first(where: { $0.id == childID })?.name)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh(observeAutoNode: true)
  #expect(model.effectiveAutoNodeID == nil)
  let request = try await nextHelperRequest(status)
  #expect(request?.observeAutoNode == true)
  let response = autoObservationResponse(
    for: profile, effectiveNode: childID, message: "auto-child-observation"
  )
  await status.completeNext(response)
  #expect(await waitForHardeningCondition { model.coreVersion == response.coreVersion })

  #expect(model.effectiveAutoNodeID == childID)
  #expect(model.effectiveAutoNodeName == childName)

  model.setSelectedNode(childID)
  #expect(model.effectiveAutoNodeID == nil)
  #expect(model.effectiveAutoNodeName == nil)
  let mutation = try await nextHelperRequest(runtime)
  #expect(mutation?.action == .setNode)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      selectedNode: childID,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      nodes: profile.payload?.nodes ?? [],
      message: "manual"
    )
  )
}

@Test @MainActor
func explicitObservationClearsBeforeRefreshInProgressReturnsWithoutSecondRequest() async throws {
  let payload = hardeningPayload("refresh-child.example.test")
  let childID = try #require(payload.nodes.first(where: { $0.id != .auto })?.id)
  let profile = ManagedProfile(name: "A", payload: payload)
  let status = ControlledHelperResponses()
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) }
  )

  model.refresh(observeAutoNode: true)
  #expect((try await nextHelperRequest(status))?.observeAutoNode == true)
  let firstResponse = autoObservationResponse(
    for: profile, effectiveNode: childID, message: "initial-auto-observation"
  )
  await status.completeNext(firstResponse)
  #expect(await waitForHardeningCondition { model.coreVersion == firstResponse.coreVersion })
  #expect(model.effectiveAutoNodeID == childID)

  model.refresh()
  #expect((try await nextHelperRequest(status))?.observeAutoNode == nil)
  model.refresh(observeAutoNode: true)
  #expect(model.effectiveAutoNodeID == nil)
  #expect(await status.pendingCount() == 1)

  let coalescedResponse = autoObservationResponse(
    for: profile, effectiveNode: childID, message: "coalesced-auto-observation"
  )
  await status.completeNext(coalescedResponse)
  #expect(await waitForHardeningCondition { model.coreVersion == coalescedResponse.coreVersion })
  #expect(model.effectiveAutoNodeID == nil)
}

@Test @MainActor
func helperApprovalRefreshCannotBypassRuntimeMutationStatusAdmission() async throws {
  let service = ReadyHelperService(registrationState: .enabled)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperService: service,
    helperApprovalPollDuration: .seconds(120),
    helperApprovalPollInterval: .seconds(30),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  let start = try #require(try await nextHelperRequest(runtime))
  #expect(start.action == .start)

  service.registrationState = .requiresApproval
  model.enableHelper()
  #expect(await waitForHardeningCondition { model.helperApprovalPending })
  #expect(model.helperApprovalPending)
  #expect(await waitForHardeningCondition { !(model.helperSetupInProgress) })
  #expect(!model.helperSetupInProgress)

  service.registrationState = .enabled
  model.refresh()
  #expect(model.helperApprovalPending)
  #expect(!model.helperSetupInProgress)
  #expect(await status.pendingCount() == 0)
  #expect(await runtime.pendingCount() == 1)

  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "started"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.runtimeApplyStatus != .applying)

  model.refresh()
  #expect(model.helperSetupInProgress)
  let statusRequest = try #require(try await nextHelperRequest(status))
  #expect(statusRequest.action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "helper enabled"
    )
  )
  #expect(
    await waitForHardeningCondition {
      !model.helperApprovalPending && model.helperReachable && !model.helperSetupInProgress
    }
  )

  #expect(!model.helperApprovalPending)
  #expect(model.helperReachable)
  #expect(!model.helperSetupInProgress)
  #expect(await status.pendingCount() == 0)
}

@Test @MainActor
func staleAutoObservationDoesNotPublishAcrossProfileOrRuntimeGenerationChanges() async throws {
  let payloadA = hardeningPayload("profile-a.example.test")
  let payloadB = hardeningPayload("profile-b.example.test")
  let childA = try #require(payloadA.nodes.first(where: { $0.id != .auto })?.id)
  let profileA = ManagedProfile(name: "A", payload: payloadA)
  let profileB = ManagedProfile(name: "B", payload: payloadB)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh(observeAutoNode: true)
  #expect(try await nextHelperRequest(status)?.observeAutoNode == true)
  model.selectedProfileID = profileB.id
  let oldProfileResponse = autoObservationResponse(
    for: profileA, effectiveNode: childA, message: "old-profile-observation"
  )
  await status.completeNext(oldProfileResponse)
  #expect(await waitForHardeningCondition { model.coreVersion == oldProfileResponse.coreVersion })
  #expect(model.coreRunning)
  #expect(model.selectedProfileID == profileB.id)
  #expect(model.effectiveAutoNodeID == nil)

  model.selectedProfileID = profileA.id
  model.refresh(observeAutoNode: true)
  #expect(try await nextHelperRequest(status)?.observeAutoNode == true)
  let currentProfileResponse = autoObservationResponse(
    for: profileA, effectiveNode: childA, message: "current-profile-observation"
  )
  await status.completeNext(currentProfileResponse)
  #expect(
    await waitForHardeningCondition {
      model.coreVersion == currentProfileResponse.coreVersion
    }
  )
  #expect(model.effectiveAutoNodeID == childA)

  model.refresh(observeAutoNode: true)
  #expect(try await nextHelperRequest(status)?.observeAutoNode == true)
  model.setCoreEnabled(true)
  #expect(model.effectiveAutoNodeID == nil)
  #expect(try await nextHelperRequest(runtime)?.action == .start)
  model.refresh(observeAutoNode: true)
  #expect(model.effectiveAutoNodeID == nil)
  #expect(await status.pendingCount() == 1)

  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "stale-runtime-observation",
      selectedNode: .auto,
      effectiveAutoNode: childA,
      activeProfileID: profileA.id,
      message: "stale status"
    )
  )
  #expect(model.effectiveAutoNodeID == nil)
  #expect(model.coreRunning)

  let runtimeResponse = HelperResponse(
    success: true,
    coreRunning: true,
    coreVersion: "runtime-after-stale-observation",
    activeProfileID: profileA.id,
    activeIPv6Enabled: false,
    nodes: profileA.payload?.nodes ?? [],
    message: "started"
  )
  await runtime.completeNext(runtimeResponse)
  #expect(await waitForHardeningCondition { model.coreVersion == runtimeResponse.coreVersion })
  #expect(await waitForHardeningCondition { model.coreRunning })
  #expect(model.coreRunning)
}

@Test @MainActor
func nilUnmappedStoppedAndUnavailableObservationsStayPlainAuto() async throws {
  let payload = hardeningPayload("failure-child.example.test")
  let childID = try #require(payload.nodes.first(where: { $0.id != .auto })?.id)
  let profile = ManagedProfile(name: "A", payload: payload)
  let status = ControlledHelperResponses()
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) }
  )

  model.refresh(observeAutoNode: true)
  #expect(try await nextHelperRequest(status)?.observeAutoNode == true)
  let nilObservation = autoObservationResponse(
    for: profile, effectiveNode: nil, message: "nil-auto-observation"
  )
  await status.completeNext(nilObservation)
  #expect(await waitForHardeningCondition { model.coreVersion == nilObservation.coreVersion })
  #expect(model.effectiveAutoNodeID == nil)
  #expect(model.effectiveAutoNodeName == nil)

  let unknownID = ProxyNodeID(rawValue: "not-a-current-runtime-node")
  model.refresh(observeAutoNode: true)
  #expect(try await nextHelperRequest(status)?.observeAutoNode == true)
  let unknownObservation = autoObservationResponse(
    for: profile, effectiveNode: unknownID, message: "unknown-auto-observation"
  )
  await status.completeNext(unknownObservation)
  #expect(await waitForHardeningCondition { model.coreVersion == unknownObservation.coreVersion })
  #expect(model.effectiveAutoNodeID == nil)
  #expect(model.effectiveAutoNodeName == nil)

  model.refresh(observeAutoNode: true)
  #expect(try await nextHelperRequest(status)?.observeAutoNode == true)
  let childObservation = autoObservationResponse(
    for: profile, effectiveNode: childID, message: "child-auto-observation"
  )
  await status.completeNext(childObservation)
  #expect(await waitForHardeningCondition { model.coreVersion == childObservation.coreVersion })
  #expect(model.effectiveAutoNodeID == childID)

  model.refresh()
  #expect((try await nextHelperRequest(status))?.observeAutoNode == nil)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "stopped-clear-auto",
      message: "stopped"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "stopped-clear-auto" })
  #expect(model.effectiveAutoNodeID == nil)

  model.refresh(observeAutoNode: true)
  #expect(try await nextHelperRequest(status)?.observeAutoNode == true)
  let recoveredObservation = autoObservationResponse(
    for: profile, effectiveNode: childID, message: "recovered-auto-observation"
  )
  await status.completeNext(recoveredObservation)
  #expect(await waitForHardeningCondition { model.coreVersion == recoveredObservation.coreVersion })
  #expect(model.effectiveAutoNodeID == childID)

  model.refresh()
  #expect((try await nextHelperRequest(status))?.observeAutoNode == nil)
  await status.failNext()
  #expect(await waitForHardeningCondition { !model.helperReachable })
  #expect(!model.helperReachable)
  #expect(model.effectiveAutoNodeID == nil)

  model.refresh(observeAutoNode: true)
  #expect(try await nextHelperRequest(status)?.observeAutoNode == true)
  let finalObservation = autoObservationResponse(
    for: profile, effectiveNode: childID, message: "final-auto-observation"
  )
  await status.completeNext(finalObservation)
  #expect(await waitForHardeningCondition { model.coreVersion == finalObservation.coreVersion })
  #expect(model.effectiveAutoNodeID == childID)

  model.refresh()
  #expect((try await nextHelperRequest(status))?.observeAutoNode == nil)
  await status.completeNext(
    try hardeningResponse(
      coreRunning: true,
      revision: 61,
      activeProfileID: profile.id,
      message: "outdated helper"
    )
  )
  #expect(await waitForHardeningCondition { model.helperUpdateRequired })
  #expect(model.helperUpdateRequired)
  #expect(model.effectiveAutoNodeID == nil)
  #expect(!model.coreRunning)
}

@Test @MainActor func manualRefreshAttemptsEveryRemoteSourceExactlyOnce() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let urls = (1...3).map { "https://source\($0).example.test/list" }
  let profiles = [
    ManagedProfile(
      name: "A",
      sources: urls.prefix(2).map {
        ManagedSource(name: $0, value: $0, payload: hardeningPayload("old.example.test"))
      },
      payload: hardeningPayload("old.example.test")
    ),
    ManagedProfile(
      name: "B",
      sources: [
        ManagedSource(name: "B", value: urls[2], payload: hardeningPayload("old.example.test"))
      ],
      payload: hardeningPayload("old.example.test")
    ),
  ]
  let model = hardeningModel(
    library: ProfileLibrary(profiles: profiles, selectedProfileID: profiles[0].id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refreshExternalState()
  #expect((try await status.nextRequest()).action == .status)
  var attempted: [String] = []
  for _ in urls {
    let requested = try await fetcher.nextRequest()
    attempted.append(requested)
    await fetcher.complete(
      requested,
      with: SubscriptionFetchResult(
        profile: hardeningPayload("fresh.example.test"), skippedTransports: [:]
      )
    )
    #expect(urls.contains(requested))
  }
  #expect(await waitForHardeningCondition { !(model.isRefreshing) })
  #expect(Set(attempted) == Set(urls))
  #expect(attempted.count == urls.count)
  #expect(model.subscriptionStatus.contains("3 updated"))
  #expect(await runtime.pendingCount() == 0)

  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "manual-refresh-stopped",
      message: "still stopped"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "manual-refresh-stopped" })
  #expect(model.coreIsKnownStopped)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func refreshSurfacesPartialParserWarningsAfterSavingValidNodes() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let url = "https://source.example.test/list"
  let source = ManagedSource(
    name: "Remote",
    value: url,
    payload: hardeningPayload("old.example.test")
  )
  let profile = ManagedProfile(
    name: "A",
    sources: [source],
    payload: hardeningPayload("old.example.test")
  )
  let parsed = try SubscriptionClient.parsePayloadResult(
    [
      "ss://aes-128-gcm:secret@fresh.example.test:443/#Fetched",
      "hysteria2://bad@hy.example.test:443/?obfs=unsupported#Skipped",
    ].joined(separator: "\n")
  )
  let warning = try #require(parsed.warningDescription)
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  #expect(try await fetcher.nextRequest() == url)
  await fetcher.complete(url, with: parsed)
  #expect(await waitForHardeningCondition { !(model.isRefreshing) })

  #expect(hardeningServer(model.profiles[0].sources[0].payload) == "fresh.example.test")
  #expect(model.subscriptionStatus.contains("1 updated"))
  #expect(model.subscriptionStatus.contains(warning))
  #expect(model.subscriptionStatusLevel == .warning)
  #expect(!model.subscriptionStatus.contains(url))
}

@Test @MainActor func refreshBoundsDetailedParserWarningsAndLocalizesOverflow() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let urls = (0..<5).map { "https://source-\($0).example.test/list?token=source-secret-\($0)" }
  let sources = urls.enumerated().map { index, url in
    ManagedSource(
      name: "Remote \(index + 1)",
      value: url,
      payload: hardeningPayload("old-\(index).example.test")
    )
  }
  let profile = ManagedProfile(
    name: "A",
    sources: sources,
    payload: hardeningPayload("old-profile.example.test")
  )
  var parsedResults: [SubscriptionFetchResult] = []
  var warnings: [String] = []
  for index in urls.indices {
    let valid = "ss://aes-128-gcm:node-secret-\(index)@fresh-\(index).example.test:443/#Fetched"
    let malformed = (0...index).map { _ in
      "hysteria2://bad@hy.example.test:443/?obfs=unsupported#Skipped"
    }
    let result = try SubscriptionClient.parsePayloadResult(
      ([valid] + malformed).joined(separator: "\n")
    )
    parsedResults.append(result)
    warnings.append(try #require(result.warningDescription))
  }
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  for (index, url) in urls.enumerated() {
    let requested = try await fetcher.nextRequest()
    #expect(requested == url)
    await fetcher.complete(requested, with: parsedResults[index])
  }
  #expect(await waitForHardeningCondition { !(model.isRefreshing) })

  for warning in warnings.prefix(4) {
    #expect(model.subscriptionStatus.contains(warning))
  }
  #expect(!model.subscriptionStatus.contains(warnings[4]))
  #expect(
    model.subscriptionStatus.contains(SBMText.format("Additional source warnings: %@", "1"))
  )
  #expect(model.subscriptionStatusLevel == .warning)
  #expect(!urls.contains(where: model.subscriptionStatus.contains))
  #expect(!model.subscriptionStatus.contains("source-secret"))
  #expect(!model.subscriptionStatus.contains("node-secret"))
}

@Test @MainActor func refreshCompletionCannotRecreateDeletedSourceOrProfile() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let profileID = UUID()
  let sourceID = UUID()
  let url = "https://source.example.test/list"
  let source = ManagedSource(
    id: sourceID,
    name: "Remote",
    value: url,
    payload: hardeningPayload("old.example.test")
  )
  let profile = ManagedProfile(
    id: profileID,
    name: "A",
    sources: [source],
    payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  #expect(try await fetcher.nextRequest() == url)
  model.deleteSelectedSource(profileID: profileID, sourceID: sourceID)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  #expect(await waitForHardeningCondition { !(model.isRefreshing) })
  #expect(model.profiles.first?.sources.isEmpty == true)

  let model2 = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )
  model2.refreshExternalState()
  #expect(try await fetcher.nextRequest() == url)
  model2.deleteSelectedProfile(profileID: profileID)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  #expect(await waitForHardeningCondition { !(model2.isRefreshing) })
  #expect(model2.profiles.isEmpty)
}

@Test @MainActor func repeatedManualRefreshCoalescesToOneSweep() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let url = "https://source.example.test/list"
  let profile = ManagedProfile(
    name: "A",
    sources: [
      ManagedSource(name: "Remote", value: url, payload: hardeningPayload("old.example.test"))
    ],
    payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: true
    ),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  model.refreshExternalState()
  #expect(try await fetcher.nextRequest() == url)
  #expect(await fetcher.requestCount() == 1)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  #expect(await waitForHardeningCondition { !(model.isRefreshing) })
  #expect(await fetcher.requestCount() == 0)
}

@Test @MainActor func failedRefreshCannotEraseNewerUnrelatedProfileEdit() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let url = "https://source.example.test/list"
  let profileA = ManagedProfile(
    name: "A",
    sources: [
      ManagedSource(name: "Remote", value: url, payload: hardeningPayload("old.example.test"))
    ],
    payload: hardeningPayload("old.example.test")
  )
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileA.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  #expect(try await fetcher.nextRequest() == url)
  model.profiles[1].name = "B edited while A refreshed"
  await fetcher.fail(url)
  #expect(await waitForHardeningCondition { !(model.isRefreshing) })
  #expect(model.profiles[1].name == "B edited while A refreshed")
}

@Test @MainActor func newerRuntimeChoiceSupersedesRefreshApplyWithoutHanging() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let runtime = ControlledHelperResponses()
  let url = "https://source.example.test/list"
  let source = ManagedSource(
    name: "Remote", value: url, payload: hardeningPayload("old.example.test")
  )
  let profile = ManagedProfile(
    name: "A", sources: [source], payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: true
    ),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    lifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        coreVersion: "routing-refresh-complete",
        activeProfileID: profile.id,
        activeIPv6Enabled: true,
        message: "status")
    },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.refreshExternalState()
  #expect(try await fetcher.nextRequest() == url)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  #expect(try await runtime.nextRequest().action == .start)
  model.setRoutingMode(.global)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: true, activeProfileID: profile.id, message: "old")
  )
  let current = try await runtime.nextRequest()
  #expect(current.action == .start)
  #expect(current.mode == .global)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      mode: .global,
      activeProfileID: profile.id,
      message: "current"
    )
  )
  #expect(
    await waitForHardeningCondition {
      !(model.isRefreshing || model.runtimeApplyStatus == .applying)
    })
  #expect(model.routingMode == .global)
  guard case .compatibility(let refreshed)? = model.profiles[0].payload else {
    Issue.record("Expected a refreshed compatibility profile")
    return
  }
  guard case .shadowsocks(let outbound)? = refreshed.connections.first?.outbound else {
    Issue.record("Expected the refreshed Shadowsocks connection")
    return
  }
  #expect(outbound.server == "fresh.example.test")
}

@Test @MainActor func routingValidationCannotOverwriteNewerPayload() async throws {
  let validator = ControlledValidator()
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "A",
    payload: hardeningPayload("a.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    validator: { profile in try await validator.validate(profile) }
  )
  let policyURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-policy-\(UUID().uuidString).json")
  try Data(#"{"route":{"rules":[{"domain":["example.com"],"outbound":"direct"}]}}"#.utf8)
    .write(to: policyURL)
  defer { try? FileManager.default.removeItem(at: policyURL) }

  model.importRoutingPolicy(from: policyURL)
  _ = try await validator.nextProfile()
  model.profiles[0].payload = hardeningPayload("b.example.test")
  await validator.complete()
  #expect(await waitForHardeningCondition { !(model.isSyncing) })
  #expect(model.profiles[0].payload == hardeningPayload("b.example.test"))
  #expect(model.lastError?.contains("changed while") == true)
}

@Test @MainActor func websiteMutationStaysBoundToSourceProfileAfterSelectionChange() async throws {
  let validator = QueuedValidator()
  let connectionA = hardeningConnection("a.example.test")
  let profileA = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [connectionA], autoExcludedNodeIDs: [connectionA.id])
    )
  )
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id),
    validator: { profile in try await validator.validate(profile) }
  )

  model.websiteRoutingInput = "a.example"
  model.addWebsiteRoutingRule()
  let validatedA = try await validator.nextProfile()
  model.selectProfile(profileB.id)
  model.websiteRoutingInput = "b.example"
  model.addWebsiteRoutingRule()
  let validatedB = try await validator.nextProfile()

  await validator.complete(validatedA)
  await validator.complete(validatedB)
  #expect(
    await waitForHardeningCondition { !(model.profiles[1].payload?.websiteRoutingRules.count != 1) }
  )

  #expect(model.profiles[0].payload?.websiteRoutingRules.map(\.domain) == ["a.example"])
  #expect(model.profiles[1].payload?.websiteRoutingRules.map(\.domain) == ["b.example"])
  if case .compatibility(let updatedA)? = model.profiles[0].payload {
    #expect(updatedA.autoExcludedNodeIDs == [connectionA.id])
  } else {
    Issue.record("Expected the source profile to remain compatible.")
  }
  #expect(model.selectedProfileID == profileB.id)
}

@Test @MainActor func applicationMutationStaysBoundToSourceProfileAfterSelectionChange()
  async throws
{
  let validator = QueuedValidator()
  let rule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let connectionA = hardeningConnection("a.example.test")
  let payloadA = CoreProfile.compatibility(
    VPNProfile(
      connections: [connectionA],
      applicationRoutingRules: [rule],
      autoExcludedNodeIDs: [connectionA.id]
    )
  )
  let payloadB = CoreProfile.compatibility(
    VPNProfile(
      connections: [hardeningConnection("b.example.test")],
      applicationRoutingRules: [rule]
    )
  )
  let profileA = ManagedProfile(name: "A", payload: payloadA)
  let profileB = ManagedProfile(name: "B", payload: payloadB)
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id),
    validator: { profile in try await validator.validate(profile) }
  )

  model.setApplicationRoutingTarget(rule.id, target: .direct)
  let validatedA = try await validator.nextProfile()
  model.selectProfile(profileB.id)
  model.setApplicationRoutingTarget(rule.id, target: .direct)
  let validatedB = try await validator.nextProfile()

  await validator.complete(validatedA)
  await validator.complete(validatedB)
  #expect(
    await waitForHardeningCondition {
      !(model.profiles[1].payload?.applicationRoutingRules.first?.target != .direct)
    })

  #expect(model.profiles[0].payload?.applicationRoutingRules.first?.target == .direct)
  #expect(model.profiles[1].payload?.applicationRoutingRules.first?.target == .direct)
  if case .compatibility(let updatedA)? = model.profiles[0].payload {
    #expect(updatedA.autoExcludedNodeIDs == [connectionA.id])
  } else {
    Issue.record("Expected the source profile to remain compatible.")
  }
  #expect(model.selectedProfileID == profileB.id)
}

@Test @MainActor func sameProfileWebsiteActionsAreQueuedAndBothPersist() async throws {
  let validator = QueuedValidator()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    validator: { profile in try await validator.validate(profile) }
  )

  model.websiteRoutingInput = "first.example"
  model.addWebsiteRoutingRule()
  let first = try await validator.nextProfile()
  model.websiteRoutingInput = "second.example"
  model.addWebsiteRoutingRule()

  await validator.complete(first)
  let second = try await validator.nextProfile()
  await validator.complete(second)
  #expect(await waitForHardeningCondition { !(model.websiteRoutingRules.count != 2) })

  #expect(model.websiteRoutingRules.map(\.domain) == ["first.example", "second.example"])
  #expect(model.websiteRoutingStatus.state == .saved)
  #expect(model.websiteRoutingInput.isEmpty)
}

@Test @MainActor func websiteAddClearsDraftWhenNewerWebsiteMutationSupersedesItsStatus()
  async throws
{
  let validator = QueuedValidator()
  let existingRule = WebsiteRoutingRule(domain: "existing.example", target: .selectedProxy)
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("a.example.test")],
        websiteRoutingRules: [existingRule]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    validator: { profile in try await validator.validate(profile) }
  )

  model.websiteRoutingInput = "new.example"
  model.addWebsiteRoutingRule()
  let addCandidate = try await validator.nextProfile()

  model.setWebsiteRoutingTarget(existingRule.id, target: .direct)
  await validator.complete(addCandidate)

  let targetCandidate = try await validator.nextProfile()
  await validator.complete(targetCandidate)
  #expect(
    await waitForHardeningCondition {
      model.websiteRoutingRules.count == 2
        && model.websiteRoutingRules.first(where: { $0.id == existingRule.id })?.target == .direct
    }
  )

  #expect(model.websiteRoutingInput.isEmpty)
  #expect(model.websiteRoutingRules.map(\.domain) == ["existing.example", "new.example"])
}

@Test @MainActor func sameProfileWebsiteAndApplicationActionsAreQueued() async throws {
  let validator = QueuedValidator()
  let application = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("a.example.test")],
        applicationRoutingRules: [application]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    validator: { profile in try await validator.validate(profile) }
  )

  model.websiteRoutingInput = "site.example"
  model.addWebsiteRoutingRule()
  let website = try await validator.nextProfile()
  model.setApplicationRoutingTarget(application.id, target: .direct)

  await validator.complete(website)
  let app = try await validator.nextProfile()
  await validator.complete(app)
  #expect(
    await waitForHardeningCondition { !(model.applicationRoutingRules.first?.target != .direct) })

  #expect(model.websiteRoutingRules.map(\.domain) == ["site.example"])
  #expect(model.applicationRoutingRules.first?.target == .direct)
}

@Test @MainActor func newerSameProfileRoutingStatePreventsOlderRuntimeRollback() async throws {
  let validator = QueuedValidator()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    validator: { profile in try await validator.validate(profile) }
  )
  model.coreRunning = true

  model.websiteRoutingInput = "first.example"
  model.addWebsiteRoutingRule()
  let first = try await validator.nextProfile()
  await validator.complete(first)
  #expect(try await runtime.nextRequest().action == .start)

  model.websiteRoutingInput = "second.example"
  model.addWebsiteRoutingRule()
  let second = try await validator.nextProfile()
  await validator.complete(second)

  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "old candidate failed"
    )
  )
  #expect(try await runtime.nextRequest().action == .start)
  #expect(model.websiteRoutingRules.map(\.domain) == ["first.example", "second.example"])
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: true, activeProfileID: profile.id, message: "latest")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.websiteRoutingRules.count == 2)
}

@Test @MainActor func routingImportRemainsBoundToSourceProfileAfterSelectionChange() async throws {
  let validator = QueuedValidator()
  let connectionA = hardeningConnection("a.example.test")
  let profileA = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [connectionA], autoExcludedNodeIDs: [connectionA.id])
    )
  )
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id),
    validator: { profile in try await validator.validate(profile) }
  )
  let policyURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-routing-bound-" + UUID().uuidString + ".json")
  try Data(
    #"{"route":{"rules":[{"domain_suffix":[".example"],"action":"route","outbound":"direct"}]}}"#
      .utf8
  ).write(to: policyURL)
  defer { try? FileManager.default.removeItem(at: policyURL) }

  model.importRoutingPolicy(from: policyURL)
  let validatedA = try await validator.nextProfile()
  model.selectProfile(profileB.id)
  await validator.complete(validatedA)
  #expect(await waitForHardeningCondition { !(model.isSyncing) })

  let importedPolicy: RoutingPolicy?
  let untouchedPolicy: RoutingPolicy?
  let importedExclusions: [ProxyNodeID]?
  if case .compatibility(let profile)? = model.profiles[0].payload {
    importedPolicy = profile.routingPolicy
    importedExclusions = profile.autoExcludedNodeIDs
  } else {
    importedPolicy = nil
    importedExclusions = nil
  }
  if case .compatibility(let profile)? = model.profiles[1].payload {
    untouchedPolicy = profile.routingPolicy
  } else {
    untouchedPolicy = nil
  }
  #expect(importedPolicy != nil)
  #expect(importedExclusions == [connectionA.id])
  #expect(untouchedPolicy == nil)
  #expect(model.selectedProfileID == profileB.id)
}

@Test @MainActor func routingImportDoesNotLeakSyncStateIfSourceProfileDisappearsBeforeQueueing()
  async throws
{
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  )
  let policyURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-routing-deleted-" + UUID().uuidString + ".json")
  try Data(
    #"{"route":{"rules":[{"domain_suffix":[".example"],"action":"route","outbound":"direct"}]}}"#
      .utf8
  ).write(to: policyURL)
  defer { try? FileManager.default.removeItem(at: policyURL) }

  model.importRoutingPolicy(from: policyURL)
  #expect(model.isSyncing)
  model.deleteSelectedProfile(profileID: profile.id)

  #expect(await waitForHardeningCondition { !(model.isSyncing) })

  #expect(model.profiles.isEmpty)
  #expect(!model.isSyncing)
}

@Test @MainActor func deletingProfileCancelsPendingRoutingMutationAcrossRuntimeRollback()
  async throws
{
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let validator = QueuedValidator()
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        coreVersion: "routing-refresh-complete",
        activeProfileID: profile.id,
        activeIPv6Enabled: false,
        nodes: profile.payload?.nodes ?? [],
        message: "running"
      )
    },
    runtimeSender: { request in try await runtime.send(request) },
    validator: { candidate in try await validator.validate(candidate) }
  )

  model.refresh()
  #expect(await waitForHardeningCondition { model.coreVersion == "routing-refresh-complete" })
  model.websiteRoutingInput = "new.example.test"
  model.addWebsiteRoutingRule()
  let candidate = try await validator.nextProfile()
  #expect(candidate.websiteRoutingRules.count == 1)
  #expect(model.websiteRoutingStatus.state == .applying)

  model.deleteSelectedProfile(profileID: profile.id)
  #expect(model.profiles.isEmpty)
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "stop failed"
    )
  )
  #expect(await waitForHardeningCondition { !model.profiles.isEmpty })
  #expect(model.profiles.first?.id == profile.id)
  #expect(model.websiteRoutingStatus.state == .saved)

  await validator.complete(candidate)
  #expect(await waitForHardeningCondition { !(model.isSyncing) })
  #expect(model.profiles.first?.payload?.websiteRoutingRules.isEmpty == true)
  #expect(model.websiteRoutingStatus.state == .saved)
}

@Test @MainActor func refreshUsesOnlyCurrentProfilesOwnBeforeAfterSnapshots() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let validator = QueuedValidator()
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let urlA = "https://refresh-a.example.test/list"
  let urlB = "https://refresh-b.example.test/list"
  let oldA = hardeningPayload("old-source-a.example.test")
  let oldB = hardeningPayload("old-source-b.example.test")
  let profileA = ManagedProfile(
    name: "A",
    sources: [ManagedSource(name: "A", value: urlA, payload: oldA)],
    payload: hardeningPayload("old-a.example.test")
  )
  let profileB = ManagedProfile(
    name: "B",
    sources: [ManagedSource(name: "B", value: urlB, payload: oldB)],
    payload: hardeningPayload("old-b.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) },
    validator: { profile in try await validator.validate(profile) }
  )

  model.refreshExternalState()
  #expect((try await status.nextRequest()).action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "profile-refresh-status",
      message: "stopped"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "profile-refresh-status" })

  #expect(try await fetcher.nextRequest() == urlA)
  await fetcher.complete(
    urlA,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:]
    )
  )
  let validatedA = try await validator.nextProfile()
  await validator.complete(validatedA)

  #expect(try await fetcher.nextRequest() == urlB)
  model.selectProfile(profileB.id)
  model.coreRunning = true
  await fetcher.complete(
    urlB,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-b.example.test"), skippedTransports: [:]
    )
  )
  let validatedB = try await validator.nextProfile()
  await validator.complete(validatedB)

  let request = try await runtime.nextRequest()
  #expect(request.action == .start)
  #expect(request.profileID == profileB.id)
  guard case .compatibility = request.profile else {
    Issue.record("Expected a compatibility profile in the refresh activation")
    return
  }
  #expect(hardeningServer(request.profile) == "fresh-b.example.test")
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileB.id, message: "active")
  )
  #expect(
    await waitForHardeningCondition {
      !(model.isRefreshing || model.runtimeApplyStatus == .applying)
    })
  #expect(hardeningServer(model.profiles[0].payload) == "fresh-a.example.test")
  #expect(hardeningServer(model.profiles[1].payload) == "fresh-b.example.test")
}

@Test @MainActor func websiteAddPreservesInvalidDraftAndClearsAfterSuccess() async {
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  )

  model.websiteRoutingInput = "bad..example"
  model.addWebsiteRoutingRule()
  #expect(model.websiteRoutingInput == "bad..example")
  #expect(model.websiteRoutingStatus.state == .failed)
  #expect(model.websiteRoutingStatus.message?.contains("valid hostname") == true)

  model.websiteRoutingInput = "valid.example"
  model.addWebsiteRoutingRule()
  #expect(await waitForHardeningCondition { !(model.websiteRoutingRules.isEmpty) })
  #expect(model.websiteRoutingInput.isEmpty)
  #expect(model.websiteRoutingStatus.state == .saved)
}

@Test @MainActor func applicationChangePreservesRuleIdentityAndRejectsExactDuplicate() async throws
{
  let firstBundle = try hardeningApplicationBundle("First")
  let replacementBundle = try hardeningApplicationBundle("Replacement")
  let duplicateBundle = try hardeningApplicationBundle("Duplicate")
  defer {
    try? FileManager.default.removeItem(at: firstBundle.deletingLastPathComponent())
    try? FileManager.default.removeItem(at: replacementBundle.deletingLastPathComponent())
    try? FileManager.default.removeItem(at: duplicateBundle.deletingLastPathComponent())
  }
  let rule = ApplicationRoutingRule(
    displayName: "First",
    bundlePath: firstBundle.path,
    executablePath: firstBundle.appendingPathComponent("Contents/MacOS/First").path,
    target: .reject
  )
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("a.example.test")],
        applicationRoutingRules: [rule]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  )

  let replacementExecutable =
    replacementBundle
    .appendingPathComponent("Contents/MacOS/Replacement")
  #expect(
    try ApplicationBundleResolver.resolve(replacementBundle).executableURL == replacementExecutable
  )
  model.replaceApplicationRoutingRule(rule.id, from: replacementBundle, profileID: profile.id)
  #expect(
    await waitForHardeningCondition {
      model.applicationRoutingRules.first?.executablePath == replacementExecutable.path
    }
  )
  #expect(model.applicationRoutingRules.first?.executablePath == replacementExecutable.path)
  #expect(model.applicationRoutingRules.first?.id == rule.id)
  #expect(model.applicationRoutingRules.first?.target == .reject)

  let duplicateRule = ApplicationRoutingRule(
    displayName: "Duplicate",
    bundlePath: duplicateBundle.path,
    executablePath: duplicateBundle.appendingPathComponent("Contents/MacOS/Duplicate").path,
    target: .direct
  )
  guard case .compatibility(let current)? = model.profiles.first?.payload else {
    Issue.record("Expected a compatibility profile")
    return
  }
  model.profiles[0].payload = .compatibility(
    VPNProfile(
      connections: current.connections,
      applicationRoutingRules: [
        model.applicationRoutingRules[0], duplicateRule,
      ]
    )
  )
  model.replaceApplicationRoutingRule(rule.id, from: duplicateBundle, profileID: profile.id)
  #expect(await waitForHardeningCondition { model.applicationRoutingStatus.state != .applying })
  #expect(model.applicationRoutingStatus.state == .failed)
  #expect(model.lastError?.contains("already has a routing rule") == true)
  #expect(model.applicationRoutingRules.first?.id == rule.id)
  #expect(model.applicationRoutingRules.first?.target == .reject)
}

@Test @MainActor func failedDeleteDoesNotRestoreOverNewerWebsiteMutation() async throws {
  let runtime = ControlledHelperResponses()
  let oldRule = WebsiteRoutingRule(domain: "old.example", target: .selectedProxy)
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("a.example.test")],
        websiteRoutingRules: [oldRule]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.removeWebsiteRoutingRule(oldRule.id)
  #expect(try await runtime.nextRequest().action == .start)
  model.websiteRoutingInput = "new.example"
  model.addWebsiteRoutingRule()

  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "delete candidate failed"
    )
  )
  #expect(try await runtime.nextRequest().action == .start)
  #expect(model.websiteRoutingRules.map(\.domain) == ["new.example"])
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "new active"
    )
  )
}

@Test @MainActor func initialStatusKeepsDesiredRoutingAndStartUsesIt() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let persistedNode = ProxyNodeID(rawValue: "node-persisted")
  let observedNode = ProxyNodeID(rawValue: "node-observed")
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(
          id: persistedNode,
          outbound: hardeningConnection("persisted.example.test").outbound
        ),
        ManagedConnection(
          id: observedNode,
          outbound: hardeningConnection("observed.example.test").outbound
        ),
      ])
    )
  )
  var savedLibraries: [ProfileLibrary] = []
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile],
      selectedProfileID: profile.id,
      routingMode: .global,
      selectedNodeID: persistedNode
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) },
    saver: { savedLibraries.append($0) }
  )

  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "stale-desired-routing-observation",
      mode: .rule,
      selectedNode: observedNode,
      activeProfileID: profile.id,
      message: "stopped with stale desired routing"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.coreVersion == "stale-desired-routing-observation"
    }
  )
  #expect(model.routingMode == .global)
  #expect(model.selectedNodeID == persistedNode)
  #expect(savedLibraries.isEmpty)

  model.setCoreEnabled(true)
  let request = try await runtime.nextRequest()
  #expect(request.action == .start)
  #expect(request.mode == .global)
  #expect(request.node == persistedNode)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      mode: .global,
      selectedNode: persistedNode,
      activeProfileID: profile.id,
      message: "started with persisted desired routing"
    )
  )
  #expect(await waitForHardeningCondition { model.coreRunning })
}

@Test @MainActor func helperUnknownNodeDoesNotReplaceDesiredNode() async throws {
  let status = ControlledHelperResponses()
  let currentNode = ProxyNodeID(rawValue: "node-current")
  let staleNode = ProxyNodeID(rawValue: "node-removed")
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(
          id: currentNode,
          outbound: hardeningConnection("current.example.test").outbound
        )
      ])
    )
  )
  var savedLibraries: [ProfileLibrary] = []
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile],
      selectedProfileID: profile.id,
      routingMode: .global,
      selectedNodeID: currentNode
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    saver: { savedLibraries.append($0) }
  )

  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "stale-node-observation",
      mode: .rule,
      selectedNode: staleNode,
      activeProfileID: profile.id,
      message: "stopped with stale node"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "stale-node-observation" })

  #expect(model.routingMode == .global)
  #expect(model.selectedNodeID == currentNode)
  #expect(savedLibraries.isEmpty)
}

@Test @MainActor func disconnectBeforeQuitRequiresProvenStoppedCoreAndCanRetry() async throws {
  let responses = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await responses.send(request) }
  )
  model.coreRunning = true

  let first = Task { await model.disconnectBeforeQuit() }
  #expect(try await responses.nextRequest().action == .shutdown)
  await responses.completeNext(
    HelperResponse(success: false, coreRunning: true, message: "stop failed")
  )
  #expect(await first.value == false)
  #expect(model.connectionPresentation == .failed(previousRuntimePreserved: true))

  let retry = Task { await model.disconnectBeforeQuit() }
  #expect(try await responses.nextRequest().action == .shutdown)
  await responses.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await retry.value)
}

@Test @MainActor func disconnectBeforeQuitRejectsRunningCoreAndIPCFailure() async throws {
  let responses = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await responses.send(request) }
  )
  model.coreRunning = true

  let stillRunning = Task { await model.disconnectBeforeQuit() }
  #expect(try await responses.nextRequest().action == .shutdown)
  await responses.completeNext(
    HelperResponse(success: true, coreRunning: true, message: "still running")
  )
  #expect(await stillRunning.value == false)

  let timeout = Task { await model.disconnectBeforeQuit() }
  #expect(try await responses.nextRequest().action == .shutdown)
  await responses.failNext()
  #expect(await timeout.value == false)
}

@Test @MainActor
func unavailableHelperQuitKeepsUnknownStateWhenShutdownCannotBeProven() async throws {
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: .empty,
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.helperEnabled = true
  model.helperReachable = false
  model.observedCoreState = .unknown

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(try await runtime.nextRequest().action == .shutdown)
  await runtime.failNext(URLError(.cannotConnectToHost))

  #expect(!(await quit.value))
  #expect(model.observedCoreState == .unknown)
  #expect(!model.helperReachable)
  #expect(model.safeCurrentError != nil)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func statusAuthorizationDrainsAcrossDisconnectAndQuit() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(false, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  let initialStatus = try await status.nextRequest()
  #expect(initialStatus.recoverDesiredRuntime != true)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "active-status-before-disconnect",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "active"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.helperReachable && model.coreRunning
        && model.coreVersion == "active-status-before-disconnect"
    }
  )
  let authorizedStatus = try await nextRefreshStatusRequest(model, status)
  #expect(authorizedStatus.recoverDesiredRuntime == true)

  model.setCoreEnabled(false)
  let stop = try await runtime.nextRequest()
  #expect(stop.action == .stop)
  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await status.waitForCancellation())
  model.refresh()
  #expect(await status.pendingCount() == 1)

  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "disconnect proved stopped")
  )
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      message: "accepted status drained after stop proof"
    )
  )
  let shutdown = try await runtime.nextRequest()
  #expect(shutdown.action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "terminal durable OFF")
  )
  #expect(await quit.value)
  #expect(await status.pendingCount() == 0)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func queuedRefreshRechecksDesiredStateAfterDisconnect() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(false, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  let initialStatus = try await status.nextRequest()
  #expect(initialStatus.recoverDesiredRuntime != true)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "running-before-queued-disconnect",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.observedCoreState == .running
        && model.coreVersion == "running-before-queued-disconnect"
    }
  )

  model.refresh()
  model.setCoreEnabled(false)
  let queuedStatus = try await status.nextRequest()
  #expect(queuedStatus.recoverDesiredRuntime != true)
  #expect(try await runtime.nextRequest().action == .stop)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "stale-status-after-disconnect",
      activeProfileID: profile.id,
      message: "stale running observation"
    )
  )
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "disconnect stopped")
  )
  #expect(await waitForHardeningCondition { model.observedCoreState == .stopped })
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func queuedRefreshRechecksTerminalAdmissionBeforeQuitDispatch() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(false, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  let initialStatus = try await status.nextRequest()
  #expect(initialStatus.recoverDesiredRuntime != true)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "running-before-queued-quit",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.observedCoreState == .running
        && model.coreVersion == "running-before-queued-quit"
    }
  )

  model.refresh()
  let statusResponder = Task {
    let request = try await status.nextRequest()
    await status.completeNext(
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        message: "accepted status drained by Quit"
      )
    )
    return request
  }
  let shutdownResponder = Task {
    let request = try await runtime.nextRequest()
    await runtime.completeNext(
      HelperResponse(success: true, coreRunning: false, message: "terminal OFF")
    )
    return request
  }

  let quitSucceeded = await model.disconnectBeforeQuit()
  let queuedStatus = try await statusResponder.value
  let shutdown = try await shutdownResponder.value
  #expect(queuedStatus.recoverDesiredRuntime != true)
  #expect(shutdown.action == .shutdown)
  #expect(quitSucceeded)
  #expect(await status.pendingCount() == 0)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func stoppedOrUnknownObservationCannotAuthorizeSessionRecovery() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(false, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) }
  )

  model.refresh()
  let initialStatus = try await status.nextRequest()
  #expect(initialStatus.recoverDesiredRuntime != true)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "confirmed-active-session",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.observedCoreState == .running
        && model.coreVersion == "confirmed-active-session"
    }
  )

  let activeStatus = try await nextRefreshStatusRequest(model, status)
  #expect(activeStatus.recoverDesiredRuntime == true)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "confirmed-stopped-session",
      message: "stopped"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.observedCoreState == .stopped
        && model.coreVersion == "confirmed-stopped-session"
    }
  )

  let stoppedStatus = try await nextRefreshStatusRequest(model, status)
  #expect(stoppedStatus.recoverDesiredRuntime != true)
  await status.failNext()
  #expect(
    await waitForHardeningCondition {
      model.observedCoreState == .unknown && !model.helperReachable
    }
  )

  let unknownStatus = try await nextRefreshStatusRequest(model, status)
  #expect(unknownStatus.recoverDesiredRuntime != true)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "stopped-after-unknown-session",
      message: "stopped"
    )
  )
}

@Test @MainActor func unresolvedShutdownProofSuppressesStatusRecoveryAuthorization() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(false, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  let initialStatus = try await status.nextRequest()
  #expect(initialStatus.recoverDesiredRuntime != true)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "running-before-failed-shutdown",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.observedCoreState == .running
        && model.coreVersion == "running-before-failed-shutdown"
    }
  )

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(try await runtime.nextRequest().action == .shutdown)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "durable OFF proof failed"
    )
  )
  #expect(!(await quit.value))
  #expect(model.observedCoreState == .running)

  model.refresh()
  let retryStatus = try await status.nextRequest()
  #expect(retryStatus.recoverDesiredRuntime != true)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "running-with-unresolved-shutdown-proof",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.observedCoreState == .running
        && model.coreVersion == "running-with-unresolved-shutdown-proof"
    }
  )
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func incompatibleShutdownResponseRejectsQuitAndInvalidatesRunningObservation() async throws {
  let responses = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await responses.send(request) }
  )
  model.coreRunning = true

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(try await responses.nextRequest().action == .shutdown)
  await responses.completeNext(
    try hardeningResponse(
      coreRunning: true,
      revision: HelperConstants.helperRevision - 1,
      activeProfileID: profile.id,
      message: "incompatible shutdown"
    )
  )

  #expect(await quit.value == false)
  #expect(!model.helperReachable)
  #expect(model.helperUpdateRequired)
  #expect(model.observedCoreState == .unknown)
  #expect(model.activeIPv6Enabled == nil)
  #expect(model.connectionPresentation == .unknown)
}

@Test @MainActor
func incompatibleFailureReadbackNeverMarksHelperReachable() async throws {
  let runtime = ControlledHelperResponses()
  let readback = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: { try await readback.send(HelperRequest(action: .status)) }
  )
  model.coreRunning = true

  model.setCoreEnabled(false)
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.failNext()
  #expect(try await readback.nextRequest().action == .status)
  await readback.completeNext(
    try hardeningResponse(
      coreRunning: true,
      revision: HelperConstants.helperRevision - 1,
      activeProfileID: profile.id,
      message: "incompatible read-back"
    )
  )
  #expect(await waitForHardeningCondition { model.helperUpdateRequired })

  #expect(model.helperUpdateRequired)
  #expect(!model.helperReachable)
  #expect(model.observedCoreState == .unknown)
  #expect(model.activeIPv6Enabled == nil)
  #expect(model.runtimeApplyStatus == .failed)
}

@Test @MainActor func disconnectBeforeQuitSucceedsWhenHelperIsNotRegistered() async {
  for registrationState in [HelperRegistrationState.notRegistered, .notFound] {
    let model = hardeningModel(
      library: .empty,
      runtimeSender: { _ in
        Issue.record("Quit without a registered helper sent a runtime request.")
        return HelperResponse(success: true, coreRunning: false, message: "unexpected")
      },
      helperRegistrationState: registrationState
    )
    #expect(model.helperEnabled)
    model.observedCoreState = .unknown

    #expect(await model.disconnectBeforeQuit())
  }
}

@Test @MainActor
func quitDoesNotTreatMissingCurrentServiceAsProofWhileLegacyServiceRemains() async {
  let service = ReadyHelperService(registrationState: .notFound)
  service.legacyRegistrationState = .enabled
  let runtime = RuntimeActionRecorder(
    shutdownResponse: HelperResponse(
      success: false,
      coreRunning: false,
      legacy1115Retired: false,
      message: "inert helper cannot prove legacy OFF"
    )
  )
  let model = hardeningModel(
    library: .empty,
    helperService: service,
    runtimeSender: { request in await runtime.send(request) }
  )
  model.observedCoreState = .stopped

  #expect(!(await model.disconnectBeforeQuit()))
  #expect(await runtime.recordedActions() == [.shutdown])
}

@Test @MainActor func quitCancelsAcceptedHelperEnableAndClosesHelperAdmission() async {
  let service = ReadyHelperService(registrationState: .notRegistered)
  let model = hardeningModel(
    library: .empty,
    helperService: service,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app")
  )

  model.enableHelper()
  #expect(model.helperSetupInProgress)
  #expect(await model.disconnectBeforeQuit())
  #expect(service.registrationCount == 0)

  model.enableHelper()
  #expect(!model.helperSetupInProgress)
  #expect(service.registrationCount == 0)
}

@Test @MainActor func quitDrainsHelperRepairStatusBeforeShutdown() async throws {
  let status = ControlledHelperResponses()
  let runtime = RuntimeActionRecorder()
  let service = ReadyHelperService(registrationState: .enabled)
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperService: service,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in await runtime.send(request) }
  )
  model.observedCoreState = .stopped

  model.repairHelper()
  #expect(try await status.nextRequest().action == .status)
  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await status.waitForCancellation())
  #expect(await runtime.recordedActions().isEmpty)

  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "running during repair"
    )
  )
  #expect(await quit.value)
  #expect(await runtime.recordedActions() == [.shutdown])
  #expect(!model.coreRunning)
}

@Test @MainActor func quitDrainsRefreshAndRejectsStaleStoppedShortcut() async throws {
  let status = ControlledHelperResponses()
  let runtime = RuntimeActionRecorder()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in await runtime.send(request) }
  )
  model.observedCoreState = .stopped
  model.refresh()
  #expect(try await status.nextRequest().action == .status)

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await status.waitForCancellation())
  #expect(await runtime.recordedActions().isEmpty)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "recovered core"
    )
  )

  #expect(await quit.value)
  #expect(await runtime.recordedActions() == [.shutdown])
  #expect(!model.coreRunning)
}

@Test @MainActor func quitConsumesPendingStartupRestoreBeforeAcceptedStatusReturns() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: "RestoreLastVPNStateEnabled")
  defaults.set(true, forKey: "LastExplicitVPNIntentConnected")
  let status = ControlledHelperResponses()
  let runtime = RuntimeActionRecorder()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    performStartup: true,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in await runtime.send(request) }
  )
  #expect(model.restoreLastVPNStateEnabled)
  #expect(try await status.nextRequest().action == .status)

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await status.waitForCancellation())
  #expect(await runtime.recordedActions().isEmpty)
  await status.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )

  #expect(await quit.value)
  #expect(await runtime.recordedActions() == [.shutdown])
}

@Test @MainActor func helperAbsentShortcutUsesRegistrationAfterAcceptedSetupDrains() async throws {
  let status = ControlledHelperResponses()
  let runtime = RuntimeActionRecorder()
  let service = ReadyHelperService(registrationState: .enabled)
  let model = hardeningModel(
    library: .empty,
    helperService: service,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in await runtime.send(request) }
  )

  model.repairHelper()
  #expect(try await status.nextRequest().action == .status)
  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await status.waitForCancellation())
  service.registrationState = .notRegistered
  await status.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )

  #expect(await quit.value)
  #expect(await runtime.recordedActions().isEmpty)
  #expect(service.registrationCount == 0)
}

@Test @MainActor func connectWithoutSelectedPayloadDoesNotPersistOrSubmitStop() async {
  let runtime = ControlledHelperResponses()
  let suite = "SBMTests.ConnectWithoutPayload.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.set(false, forKey: "LastExplicitVPNIntentConnected")
  let model = hardeningModel(
    library: .empty,
    userDefaults: defaults,
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)

  #expect(await runtime.pendingCount() == 0)
  #expect(!defaults.bool(forKey: "LastExplicitVPNIntentConnected"))
  #expect(
    model.lastError
      == "Connect could not start because the selected profile is unavailable."
  )
  defaults.removePersistentDomain(forName: suite)
}

@Test @MainActor func quitShutdownBypassesOrdinaryHelperReadiness() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.helperReachable = false
  model.observedCoreState = .unknown

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(try await runtime.nextRequest().action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )

  #expect(await quit.value)
}

@Test @MainActor func deniedQuitReopensAdmissionAndTerminalQuitRejectsNewConnect() async throws {
  let runtime = ControlledHelperResponses()
  let status = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let suite = "SBMTests.QuitIntent.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: true, activeProfileID: profile.id, message: "on")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  let deniedQuit = Task { await model.disconnectBeforeQuit() }
  #expect(try await runtime.nextRequest().action == .shutdown)
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profile.id, message: "still on")
  )
  #expect(await deniedQuit.value == false)
  #expect(defaults.bool(forKey: "LastExplicitVPNIntentConnected"))

  model.refresh()
  #expect(try await status.nextRequest().action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "refreshed-status",
      activeProfileID: profile.id,
      activeIPv6Enabled: model.ipv6Enabled,
      message: "refreshed"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "refreshed-status" })

  model.setRoutingMode(.global)
  #expect(try await runtime.nextRequest().action == .setMode)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: true, activeProfileID: profile.id, message: "mode")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  let supersededQuit = Task { await model.disconnectBeforeQuit() }
  #expect(try await runtime.nextRequest().action == .shutdown)
  model.setCoreEnabled(true)
  #expect(await runtime.pendingCount() == 1)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await supersededQuit.value)
  #expect(await runtime.pendingCount() == 0)
  #expect(defaults.bool(forKey: "LastExplicitVPNIntentConnected"))
  defaults.removePersistentDomain(forName: suite)
}

@Test @MainActor func failedShutdownDoesNotStartPostTerminalReadbackAndRetryReopens() async throws {
  let runtime = ControlledHelperResponses()
  let readback = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: { try await readback.send(HelperRequest(action: .status)) }
  )
  model.coreRunning = true

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(try await runtime.nextRequest().action == .shutdown)
  await runtime.failNext()
  #expect(!(await quit.value))
  #expect(await readback.pendingCount() == 0)
  #expect(model.coreRunning)

  model.setCoreEnabled(true)
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: true, activeProfileID: profile.id, message: "retry")
  )
  #expect(model.coreRunning)
  #expect(model.helperReachable)
}

@Test @MainActor func registrationRevocationInvalidatesAnInFlightStatusResponse() async throws {
  let status = ControlledHelperResponses()
  let service = ReadyHelperService(registrationState: .enabled)
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperService: service,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) }
  )

  model.refresh()
  #expect(try await status.nextRequest().action == .status)
  service.registrationState = .requiresApproval
  model.refresh()
  await status.completeNext(
    HelperResponse(success: true, coreRunning: true, activeProfileID: profile.id, message: "stale")
  )

  #expect(model.helperRequiresApproval)
  #expect(!model.helperReachable)
  #expect(model.observedCoreState == .unknown)
}

@Test @MainActor func statusFailureAfterNewerRuntimeMutationDoesNotOverwriteIt() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  #expect(try await status.nextRequest().action == .status)
  model.setCoreEnabled(true)
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profile.id, message: "started")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  model.lastError = "current runtime error"
  await status.failNext()

  #expect(model.coreRunning)
  #expect(model.helperReachable)
  #expect(model.lastError == "current runtime error")
}

@Test @MainActor func helperSetupStatusDoesNotOverwriteANewerRuntimeGeneration() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.enableHelper()
  #expect(try await status.nextRequest().action == .status)
  model.setCoreEnabled(false)
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  await status.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profile.id, message: "old setup")
  )
  #expect(await waitForHardeningCondition { !(model.helperSetupInProgress) })

  #expect(!model.coreRunning)
  #expect(model.observedCoreState == .stopped)
  #expect(model.helperReachable)
}

@Test @MainActor func currentIncompatibleMutationInvalidatesObservedRunningTruth() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true
  model.setCoreEnabled(false)
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.completeNext(
    try hardeningResponse(
      coreRunning: true,
      revision: HelperConstants.helperRevision - 1,
      activeProfileID: profile.id,
      message: "incompatible"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  #expect(!model.helperReachable)
  #expect(model.observedCoreState == .unknown)
  #expect(model.activeIPv6Enabled == nil)
  #expect(model.connectionPresentation == .unknown)
}

@Test @MainActor func staleIncompatibleMutationPublishesNoHelperMetadata() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  #expect(try await runtime.nextRequest().action == .start)
  model.setCoreEnabled(false)
  await runtime.completeNext(
    try hardeningResponse(
      coreRunning: true,
      revision: HelperConstants.helperRevision - 1,
      activeProfileID: profile.id,
      message: "stale incompatible"
    )
  )
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  #expect(model.helperReachable)
  #expect(model.helperRevision == HelperConstants.helperRevision)
  #expect(model.observedCoreState == .stopped)
  #expect(model.lastError == nil)
}

@Test @MainActor func recentErrorsAreBoundedDeduplicatedClearableAndRedacted() {
  let sensitiveURL = "https://private.example.test/subscription/secret"
  let source = ManagedSource(name: "Remote", value: sensitiveURL)
  let profile = ManagedProfile(
    name: "A", sources: [source], payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  )

  model.lastError = "Failed to fetch \(sensitiveURL)"
  model.lastError = "Failed to fetch \(sensitiveURL)"
  #expect(model.recentErrors.count == 1)
  #expect(model.recentErrors[0].repeatCount == 2)
  #expect(!model.recentErrors[0].message.contains(sensitiveURL))

  for index in 0..<55 { model.lastError = "Synthetic failure \(index)" }
  #expect(model.recentErrors.count == 50)
  let snapshot = model.supportSnapshot
  #expect(!snapshot.text.contains(sensitiveURL))
  #expect(!snapshot.jsonText().contains(sensitiveURL))
  model.clearRecentErrors()
  #expect(model.recentErrors.isEmpty)
}

@Test @MainActor func latencyIsCancelledBeforeDisconnectBecomesNextRuntimeAction() async throws {
  let status = ControlledHelperResponses()
  let latency = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let node = ProxyNodeID(rawValue: "node-latency")
  let laterNode = ProxyNodeID(rawValue: "node-latency-later")
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(id: node, outbound: hardeningConnection("a.example.test").outbound),
        ManagedConnection(
          id: laterNode,
          outbound: hardeningConnection("b.example.test").outbound
        ),
      ])
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: true
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) },
    latencySender: { node in try await latency.send(HelperRequest(action: .testLatency, node: node))
    }
  )
  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "running-before-latency-stop",
      activeProfileID: profile.id,
      activeIPv6Enabled: true,
      message: "running"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "running-before-latency-stop" })

  model.testLatency()
  let firstLatencyRequest = try await latency.nextRequest()
  #expect(firstLatencyRequest.action == .testLatency)
  #expect(firstLatencyRequest.node == node)
  model.setCoreEnabled(false)
  #expect(try await runtime.nextRequest().action == .stop)
  await latency.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeIPv6Enabled: true,
      delays: [NodeDelay(node: node, milliseconds: 10)],
      message: "stale latency"
    )
  )
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.connectionPresentation == .disconnected)
  #expect(!model.latencyTestInProgress)
  #expect(await latency.pendingCount() == 0)
}

@Test @MainActor func localSOCKSApplyFinishesWhenExplicitDisconnectSupersedesIt() async throws {
  let runtime = ControlledHelperResponses()
  var savedLibraries: [ProfileLibrary] = []
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    saver: { savedLibraries.append($0) }
  )
  model.coreRunning = true
  model.localSOCKSEnabledDraft = true
  model.localSOCKSPortDraft = 1083

  #expect(model.applyLocalSOCKSSettings())
  #expect((try await runtime.nextRequest()).action == .start)
  #expect(model.localSOCKSApplyInProgress)

  model.setCoreEnabled(false)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: true, activeProfileID: profile.id, message: "stale")
  )
  #expect((try await runtime.nextRequest()).action == .stop)
  #expect(await waitForHardeningCondition { !(model.localSOCKSApplyInProgress) })
  #expect(!model.localSOCKSApplyInProgress)
  #expect(model.localSOCKSError == nil)

  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.coreIsKnownStopped)
  #expect(model.localSOCKSEnabled)
  #expect(model.localSOCKSPort == 1083)
  #expect(savedLibraries.last?.localSOCKSEnabled == true)
  #expect(savedLibraries.last?.localSOCKSPort == 1083)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func localSOCKSRetryDoesNoWorkAfterDesiredRuntimeIsOff() async throws {
  let runtime = ControlledHelperResponses()
  var savedLibraries: [ProfileLibrary] = []
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    saver: { savedLibraries.append($0) }
  )
  model.coreRunning = true
  model.localSOCKSEnabledDraft = true
  model.localSOCKSPortDraft = 1083

  #expect(model.applyLocalSOCKSSettings())
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "settings failed"
    )
  )
  #expect(await waitForHardeningCondition { !(model.localSOCKSApplyInProgress) })
  #expect(model.canRetryLocalSOCKSSynchronization)
  #expect(model.localSOCKSError != nil)

  model.setCoreEnabled(false)
  #expect((try await runtime.nextRequest()).action == .stop)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  #expect(!model.canRetryLocalSOCKSSynchronization)
  model.retryLocalSOCKSSynchronization()
  #expect(!model.localSOCKSApplyInProgress)
  #expect(model.localSOCKSEnabled)
  #expect(model.localSOCKSPort == 1083)
  #expect(savedLibraries.last?.localSOCKSEnabled == true)
  #expect(savedLibraries.last?.localSOCKSPort == 1083)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func staleLatencyFailureCannotOverwriteNewerRuntimeObservation() async throws {
  let status = ControlledHelperResponses()
  let latency = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let nodeA = ProxyNodeID(rawValue: "node-latency-a")
  let nodeB = ProxyNodeID(rawValue: "node-latency-b")
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(id: nodeA, outbound: hardeningConnection("a.example.test").outbound),
        ManagedConnection(id: nodeB, outbound: hardeningConnection("b.example.test").outbound),
      ])
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) },
    latencySender: { node in
      try await latency.send(HelperRequest(action: .testLatency, node: node))
    }
  )

  model.refresh()
  guard try await waitForRuntimeRequest(status) else {
    Issue.record("Expected the current helper status request")
    return
  }
  _ = try await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "running-before-latency-node-change",
      selectedNode: .auto,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.coreVersion == "running-before-latency-node-change"
    }
  )

  model.testLatency()
  guard try await waitForRuntimeRequest(latency) else {
    Issue.record("Expected the latency request to start")
    return
  }
  #expect((try await latency.nextRequest()).node == nodeA)
  model.setSelectedNode(nodeB)
  guard try await waitForRuntimeRequest(runtime) else {
    Issue.record("Expected the newer node mutation request")
    return
  }
  let mutation = try await runtime.nextRequest()
  #expect(mutation.action == .setNode)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      selectedNode: nodeB,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      nodes: profile.payload?.nodes ?? [],
      message: "new node"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  #expect(await latency.pendingCount() == 1)
  await latency.failNext(URLError(.timedOut))
  #expect(await waitForHardeningCondition { !(model.latencyTestInProgress) })
  #expect(model.coreRunning)
  #expect(model.observedCoreState == .running)
  #expect(model.helperReachable)
  #expect(model.selectedNodeID == nodeB)
  #expect(model.lastError == nil)
  #expect(await latency.pendingCount() == 0)
}

@Test @MainActor func currentLatencyFailureStillPublishesItsRuntimeFailure() async throws {
  let status = ControlledHelperResponses()
  let latency = ControlledHelperResponses()
  let node = ProxyNodeID(rawValue: "node-latency")
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(id: node, outbound: hardeningConnection("a.example.test").outbound)
      ])
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    latencySender: { node in
      try await latency.send(HelperRequest(action: .testLatency, node: node))
    }
  )

  model.refresh()
  guard try await waitForRuntimeRequest(status) else {
    Issue.record("Expected the current helper status request")
    return
  }
  _ = try await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "running-before-latency-error",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "running-before-latency-error" })

  model.testLatency()
  guard try await waitForRuntimeRequest(latency) else {
    Issue.record("Expected the latency request to start")
    return
  }
  #expect((try await latency.nextRequest()).node == node)
  await latency.failNext(URLError(.timedOut))
  #expect(await waitForHardeningCondition { !(model.latencyTestInProgress) })

  #expect(!model.helperReachable)
  #expect(model.observedCoreState == .unknown)
  #expect(model.lastError != nil)
}

@Test @MainActor func staleSaveAndSyncFailureLeavesNewSourceEditorUntouched() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  var savedLibraries: [ProfileLibrary] = []
  let sourceA = ManagedSource(
    name: "A source",
    value: "https://a.example.test/list",
    payload: hardeningPayload("old-a.example.test")
  )
  let sourceB = ManagedSource(
    name: "B source",
    value: "https://b.example.test/list",
    payload: hardeningPayload("old-b.example.test")
  )
  let profileA = ManagedProfile(
    name: "A", sources: [sourceA], payload: hardeningPayload("profile-a.example.test")
  )
  let profileB = ManagedProfile(
    name: "B", sources: [sourceB], payload: hardeningPayload("profile-b.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id
    ),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    saver: { savedLibraries.append($0) }
  )

  #expect(!model.sourceDraftNeedsSaveOrSync)
  model.sourceExcludeRegex = "(?i)blocked"
  #expect(model.sourceDraftNeedsSaveOrSync)
  model.sourceExcludeRegex = ""
  #expect(!model.sourceDraftNeedsSaveOrSync)

  model.saveAndSyncSubscription()
  #expect(try await fetcher.nextRequest() == sourceA.value)
  model.selectProfile(profileB.id)
  model.sourceName = "Unsaved B source"
  model.subscriptionURL = "https://draft-b.example.test/list"
  model.subscriptionUserAgent = "Draft B client"
  let visibleStatus = model.subscriptionStatus
  let visibleError = model.lastError

  await fetcher.fail(sourceA.value)
  #expect(await waitForHardeningCondition { !(model.isSyncing) })

  #expect(model.selectedProfileID == profileB.id)
  #expect(model.selectedSourceID == sourceB.id)
  #expect(model.sourceName == "Unsaved B source")
  #expect(model.subscriptionURL == "https://draft-b.example.test/list")
  #expect(model.subscriptionUserAgent == "Draft B client")
  #expect(model.sourceEditorError == nil)
  #expect(model.subscriptionStatus == visibleStatus)
  #expect(model.lastError == visibleError)
  let savedA = try #require(
    savedLibraries.last?.profiles.first(where: { $0.id == profileA.id })
  )
  #expect(savedA.sources.first?.value == sourceA.value)
  #expect(savedA.sources.first?.payload == sourceA.payload)
  #expect(
    model.profiles.first(where: { $0.id == profileA.id })?.sources.first?.payload == sourceA.payload
  )
}

@Test @MainActor
func unsyncedSourceNeedsSaveOrRefreshWithoutDraftChanges() {
  let source = ManagedSource(value: "https://new.example.test/list")
  let profile = ManagedProfile(name: "New", sources: [source])
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  )

  #expect(model.sourceDraftNeedsSaveOrSync)
  #expect(model.sourceDraftIsValid)
}

@Test @MainActor func sameSourceSyncFailurePreservesCurrentEditorDraft() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let source = ManagedSource(
    name: "Source",
    value: "https://source.example.test/list",
    payload: hardeningPayload("old.example.test")
  )
  let profile = ManagedProfile(
    name: "A", sources: [source], payload: hardeningPayload("profile.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.saveAndSyncSubscription()
  #expect(try await fetcher.nextRequest() == source.value)
  model.sourceName = "Unsaved current name"
  model.subscriptionURL = "https://draft-current.example.test/list"
  model.subscriptionUserAgent = "Unsaved current client"

  await fetcher.fail(source.value)
  #expect(await waitForHardeningCondition { !(model.isSyncing) })

  #expect(model.selectedProfileID == profile.id)
  #expect(model.selectedSourceID == source.id)
  #expect(model.sourceName == "Unsaved current name")
  #expect(model.subscriptionURL == "https://draft-current.example.test/list")
  #expect(model.subscriptionUserAgent == "Unsaved current client")
  #expect(model.sourceEditorError != nil)
  #expect(model.sourceDraftNeedsSaveOrSync)
  #expect(model.subscriptionStatus.localizedCaseInsensitiveContains("sync failed"))
}

@Test @MainActor func quitCancelsManualSyncAtFetchAndDrainsBeforeReturn() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let validator = ControlledValidator()
  let runtime = RuntimeActionRecorder()
  let saves = SaveFailureController(failOnAttempts: [])
  let url = "https://source.example.test/list"
  let payload = hardeningPayload("old.example.test")
  let profile = ManagedProfile(
    name: "A",
    sources: [ManagedSource(name: "Remote", value: url, payload: payload)],
    payload: payload
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    runtimeSender: { request in await runtime.send(request) },
    validator: { try await validator.validate($0) },
    saver: { try saves.save($0) }
  )

  model.saveAndSyncSubscription()
  #expect(try await fetcher.nextRequest() == url)
  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await fetcher.waitForCancellation())
  #expect(saves.attempts == 1)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:]
    )
  )

  #expect(await quit.value)
  #expect(saves.attempts == 1)
  #expect(!(await validator.requestWasMade()))
  #expect(model.profiles[0].sources[0].payload == payload)
  #expect(await runtime.recordedActions() == [.shutdown])
  #expect(model.sourceEditorError == nil)
}

@Test @MainActor func quitCancelsManualSyncAtValidationBeforeCommit() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let validator = ControlledValidator()
  let runtime = RuntimeActionRecorder()
  let saves = SaveFailureController(failOnAttempts: [])
  let url = "https://source.example.test/list"
  let payload = hardeningPayload("old.example.test")
  let profile = ManagedProfile(
    name: "A",
    sources: [ManagedSource(name: "Remote", value: url, payload: payload)],
    payload: payload
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    runtimeSender: { request in await runtime.send(request) },
    validator: { try await validator.validate($0) },
    saver: { try saves.save($0) }
  )

  model.saveAndSyncSubscription()
  #expect(try await fetcher.nextRequest() == url)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:]
    )
  )
  _ = try await validator.nextProfile()
  #expect(saves.attempts == 1)

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await validator.waitForCancellation())
  await validator.complete()

  #expect(await quit.value)
  #expect(saves.attempts == 1)
  #expect(model.profiles[0].sources[0].payload == payload)
  #expect(model.sourceEditorError == nil)
  #expect(await runtime.recordedActions() == [.shutdown])
}

@Test @MainActor func quitDrainsTrackedProfileRefreshBeforeItCanCommit() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let validator = ControlledValidator()
  let runtime = RuntimeActionRecorder()
  let saves = SaveFailureController(failOnAttempts: [])
  let url = "https://source.example.test/list"
  let payload = hardeningPayload("old.example.test")
  let profile = ManagedProfile(
    name: "A",
    sources: [ManagedSource(name: "Remote", value: url, payload: payload)],
    payload: payload
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    runtimeSender: { request in await runtime.send(request) },
    validator: { try await validator.validate($0) },
    saver: { try saves.save($0) }
  )

  model.refreshExternalState()
  #expect(try await fetcher.nextRequest() == url)
  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await fetcher.waitForCancellation())
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:]
    )
  )

  #expect(await quit.value)
  #expect(saves.attempts == 0)
  #expect(!(await validator.requestWasMade()))
  #expect(model.profiles[0].sources[0].payload == payload)
  #expect(!(await runtime.recordedActions().contains(.start)))
}

@Test @MainActor func quitCancelsRoutingValidationAndClearsApplyingPresentationOnRefusal()
  async throws
{
  let validator = ControlledValidator()
  let runtime = RuntimeActionRecorder(
    shutdownResponse: HelperResponse(success: false, coreRunning: true, message: "still running")
  )
  let saves = SaveFailureController(failOnAttempts: [])
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in await runtime.send(request) },
    validator: { try await validator.validate($0) },
    saver: { try saves.save($0) }
  )
  model.coreRunning = true
  model.websiteRoutingInput = "new.example"
  model.addWebsiteRoutingRule()
  _ = try await validator.nextProfile()

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await validator.waitForCancellation())
  await validator.complete()

  #expect(!(await quit.value))
  #expect(model.websiteRoutingStatus.state == .saved)
  #expect(model.websiteRoutingRules.isEmpty)
  #expect(saves.attempts == 0)
  #expect(await runtime.recordedActions() == [.shutdown])
}

@Test @MainActor func quitDrainsMutationFailureReadbackAndUsesItsObservedState() async throws {
  let runtime = ControlledHelperResponses()
  let readback = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: { try await readback.send(HelperRequest(action: .status)) }
  )
  model.coreRunning = true

  model.setRoutingMode(.global)
  #expect(try await runtime.nextRequest().action == .setMode)
  await runtime.failNext()
  #expect(try await readback.nextRequest().action == .status)
  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await readback.waitForCancellation())
  #expect(await runtime.pendingCount() == 0)
  await readback.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "readback reports running"
    )
  )
  #expect(try await runtime.nextRequest().action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )

  #expect(await quit.value)
  #expect(await readback.pendingCount() == 0)
}

@Test @MainActor func connectionPresentationOrdersConnectThenImmediateDisconnect() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  #expect(try await runtime.nextRequest().action == .start)
  #expect(model.connectionPresentation == .connecting)
  model.setCoreEnabled(true)
  #expect(await runtime.pendingCount() == 1)

  model.setCoreEnabled(false)
  #expect(model.connectionPresentation == .disconnecting)
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profile.id, message: "started")
  )
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.connectionPresentation == .disconnected)
}

@Test @MainActor
func failedStartReadbackRunningProjectsStopAndKeepsFailurePresentation() async throws {
  let runtime = ControlledHelperResponses()
  let readback = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: { try await readback.send(HelperRequest(action: .status)) }
  )
  model.observedCoreState = .unknown

  model.setCoreEnabled(true)
  #expect((try #require(try await nextHelperRequest(runtime))).action == .start)
  await runtime.failNext(URLError(.timedOut))
  #expect((try #require(try await nextHelperRequest(readback))).action == .status)
  await readback.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.observedCoreState == .running && model.runtimeApplyStatus == .failed
    })

  #expect(model.observedCoreState == .running)
  #expect(model.connectionPresentation == .failed(previousRuntimePreserved: false))
  #expect(model.connectionPresentation.title == "Connection failed")
  #expect(model.connectionAction == false)
  #expect(model.connectionActionEnabled)
  model.setCoreEnabled(try #require(model.connectionAction as Bool?))
  #expect(model.runtimeApplyStatus == .applying)
  #expect(model.lastError != nil)
  #expect(model.helperEnabled)
  #expect(model.helperReachable)
  #expect((try #require(try await nextHelperRequest(runtime))).action == .stop)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
}

@Test @MainActor
func failedStartReadbackStoppedProjectsConnectAndKeepsFailurePresentation() async throws {
  let runtime = ControlledHelperResponses()
  let readback = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: { try await readback.send(HelperRequest(action: .status)) }
  )
  model.observedCoreState = .unknown

  model.setCoreEnabled(true)
  #expect((try #require(try await nextHelperRequest(runtime))).action == .start)
  await runtime.failNext(URLError(.timedOut))
  #expect((try #require(try await nextHelperRequest(readback))).action == .status)
  await readback.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(
    await waitForHardeningCondition {
      model.observedCoreState == .stopped && model.runtimeApplyStatus == .failed
    })

  #expect(model.observedCoreState == .stopped)
  #expect(model.connectionPresentation == .failed(previousRuntimePreserved: false))
  #expect(model.connectionPresentation.title == "Connection failed")
  #expect(model.connectionAction == true)
  #expect(model.connectionActionEnabled)
  model.setCoreEnabled(try #require(model.connectionAction as Bool?))
  #expect((try #require(try await nextHelperRequest(runtime))).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profile.id, message: "started")
  )
}

@Test @MainActor
func failedStartUnknownReadbackPreservesUnknownAndSafeStopAction() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: { throw URLError(.timedOut) }
  )

  model.setCoreEnabled(true)
  #expect((try #require(try await nextHelperRequest(runtime))).action == .start)
  await runtime.failNext(URLError(.timedOut))
  #expect(
    await waitForHardeningCondition {
      model.runtimeApplyStatus == .failed && model.observedCoreState == .unknown
    })

  #expect(model.runtimeApplyStatus == .failed)
  #expect(model.connectionPresentation == .unknown)
  #expect(model.connectionAction == false)
  #expect(model.connectionActionEnabled)
  #expect(model.safeCurrentError != nil)
  model.setCoreEnabled(try #require(model.connectionAction as Bool?))
  #expect((try #require(try await nextHelperRequest(runtime))).action == .stop)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
}

@Test @MainActor
func menuRuntimeAdmissionRequiresReadyHelperButKeepsCompatibleStopAvailable() {
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let library = ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)

  for state in [HelperRegistrationState.notRegistered, .requiresApproval] {
    let model = hardeningModel(library: library, helperRegistrationState: state)
    model.helperEnabled = false
    model.helperReachable = false
    model.coreRunning = false
    #expect(model.connectionAction == true)
    #expect(!model.connectionActionEnabled)
    #expect(!model.runtimeMenuControlsEnabled)
  }

  let incompatible = hardeningModel(library: library)
  incompatible.helperRevision = HelperConstants.helperRevision - 1
  incompatible.coreRunning = false
  #expect(!incompatible.connectionActionEnabled)
  #expect(!incompatible.runtimeMenuControlsEnabled)

  let ready = hardeningModel(library: library)
  ready.coreRunning = false
  #expect(ready.connectionActionEnabled)
  #expect(ready.runtimeMenuControlsEnabled)
  ready.helperSetupInProgress = true
  #expect(!ready.connectionActionEnabled)
  #expect(!ready.runtimeMenuControlsEnabled)

  let degraded = hardeningModel(library: library)
  degraded.helperReachable = false
  degraded.coreRunning = true
  #expect(degraded.connectionAction == false)
  #expect(degraded.connectionActionEnabled)
  #expect(!degraded.runtimeMenuControlsEnabled)
}

@Test @MainActor
func safeCurrentErrorRedactsBoundsPersistenceFailureAndRetainsSanitizedHistory() throws {
  let profile = ManagedProfile(name: "Before", payload: hardeningPayload("a.example.test"))
  var shouldFail = true
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    saver: { _ in
      if shouldFail {
        throw NSError(
          domain: "ProfileLibraryTest",
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "write failed token=canary-secret " + String(repeating: "x", count: 900)
          ]
        )
      }
    }
  )

  model.profileName = "Failed name"
  model.saveProfileName()
  let visibleError = try #require(model.safeCurrentError)
  #expect(visibleError.contains("Profile name was not saved"))
  #expect(!visibleError.contains("canary-secret"))
  #expect(visibleError.count <= 513)
  #expect(model.recentErrors.last?.message.contains("canary-secret") == false)

  shouldFail = false
  model.profileName = "Saved name"
  model.saveProfileName()
  #expect(model.lastError == nil)
  #expect(model.safeCurrentError == nil)
  #expect(model.recentErrors.last?.message == visibleError)
}

@Test @MainActor
func ipv6PersistenceFailureUsesTheSameSafeCurrentErrorProjection() {
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    saver: { _ in
      throw NSError(
        domain: "IPv6PersistenceTest",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "write failed token=ipv6-canary"]
      )
    }
  )

  model.setIPv6Enabled(true)

  #expect(model.safeCurrentError?.contains("IPv6 setting was not saved") == true)
  #expect(model.safeCurrentError?.contains("ipv6-canary") == false)
}

@Test @MainActor
func runtimeFailureUsesTheSafeCurrentErrorProjection() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  #expect((try #require(try await nextHelperRequest(runtime))).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "runtime rejected password=test-password"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .failed) })

  #expect(model.safeCurrentError?.contains("could not be activated") == true)
  #expect(model.safeCurrentError?.contains("test-password") == false)
}

@Test @MainActor
func explicitDeletionTargetsSurviveProfileAndSourceSelectionChanges() async throws {
  let sourceA = ManagedSource(name: "Source A")
  let sourceB = ManagedSource(name: "Source B")
  let profileA = ManagedProfile(
    name: "Profile A",
    sources: [sourceA, sourceB],
    payload: hardeningPayload("a.example.test")
  )
  let profileB = ManagedProfile(
    name: "Profile B",
    sources: [ManagedSource(name: "Other")],
    payload: hardeningPayload("b.example.test")
  )
  var profileSaves = 0
  let profileRuntime = RuntimeActionRecorder()
  let profileModel = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id
    ),
    runtimeSender: { request in await profileRuntime.send(request) },
    saver: { _ in profileSaves += 1 }
  )

  profileModel.coreRunning = true
  profileModel.selectProfile(profileB.id)
  #expect(
    await waitForHardeningCondition { profileModel.runtimeApplyStatus == .active }
  )
  let actionsBeforeUnselectedDeletion = await profileRuntime.recordedActions()
  #expect(actionsBeforeUnselectedDeletion == [.start])
  let savesBeforeDeletion = profileSaves
  profileModel.deleteSelectedProfile(profileID: profileA.id)
  #expect(profileModel.profiles.map(\.id) == [profileB.id])
  #expect(profileModel.selectedProfileID == profileB.id)
  #expect(profileSaves == savesBeforeDeletion + 1)
  #expect(await profileRuntime.recordedActions() == actionsBeforeUnselectedDeletion)

  var sourceSaves = 0
  let sourceModel = hardeningModel(
    library: ProfileLibrary(profiles: [profileA], selectedProfileID: profileA.id),
    saver: { _ in sourceSaves += 1 }
  )
  sourceModel.selectSource(sourceB.id)
  sourceModel.deleteSelectedSource(profileID: profileA.id, sourceID: sourceA.id)
  #expect(sourceModel.profiles.first?.sources.map(\.id) == [sourceB.id])
  #expect(sourceModel.selectedProfileID == profileA.id)
  #expect(sourceModel.selectedSourceID == sourceB.id)
  #expect(sourceSaves == 1)
}

@Test @MainActor
func disconnectSupersedesInFlightStartAfterHelperReachabilityLoss() async throws {
  let (suite, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  let start = try #require(try await nextHelperRequest(runtime))
  #expect(start.action == .start)
  model.helperReachable = false
  model.setCoreEnabled(false)

  #expect(model.connectionPresentation == .disconnecting)
  #expect(defaults.bool(forKey: "LastExplicitVPNIntentConnected") == false)
  #expect(model.helperProtocolVersion == HelperConstants.protocolVersion)
  #expect(model.helperVersion == HelperConstants.helperVersion)
  #expect(model.helperRevision == HelperConstants.helperRevision)
  #expect(!model.helperUpdateRequired)

  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "stale start"
    )
  )
  let stop = try #require(try await nextHelperRequest(runtime))
  #expect(stop.action == .stop)
  #expect(stop.stopReason == .userDisconnect)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "disconnected")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  #expect(model.runtimeApplyStatus != .applying)
  #expect(!model.coreRunning)
  #expect(model.connectionPresentation == .disconnected)
  #expect(defaults.bool(forKey: "LastExplicitVPNIntentConnected") == false)
}

@Test @MainActor
func disconnectSubmitsStopWithoutSelectedProfilePayload() async throws {
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: .empty,
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(false)
  let stop = try #require(try await nextHelperRequest(runtime))
  #expect(stop.action == .stop)
  #expect(stop.stopReason == .userDisconnect)
  #expect(model.lastError == nil)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "disconnected")
  )
}

@Test @MainActor
func disconnectDoesNotSendStopToKnownIncompatibleHelper() async throws {
  let (suite, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: .empty,
    userDefaults: defaults,
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.helperUpdateRequired = true
  model.helperRevision = HelperConstants.helperRevision - 1
  model.helperReachable = false

  model.setCoreEnabled(false)

  #expect(model.helperEnabled)
  #expect(defaults.object(forKey: "LastExplicitVPNIntentConnected") as? Bool == false)
  #expect(model.lastError?.localizedCaseInsensitiveContains("helper") == true)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func failedDisconnectKeepsExplicitOffIntentAndSurfacesError() async throws {
  let (suite, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: .empty,
    userDefaults: defaults,
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: { throw URLError(.timedOut) }
  )
  model.coreRunning = true

  model.setCoreEnabled(false)
  let stop = try #require(try await nextHelperRequest(runtime))
  #expect(stop.action == .stop)
  #expect(stop.stopReason == .userDisconnect)
  #expect(model.connectionPresentation == .disconnecting)
  #expect(defaults.object(forKey: "LastExplicitVPNIntentConnected") as? Bool == false)
  await runtime.failNext(URLError(.cannotConnectToHost))
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .failed) })

  #expect(model.runtimeApplyStatus == .failed)
  #expect(model.lastError != nil)
  #expect(defaults.object(forKey: "LastExplicitVPNIntentConnected") as? Bool == false)
}

@Test @MainActor
func normalRefreshIsNotAdmittedDuringStartAndWorksAfterCompletion() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  #expect((try #require(try await nextHelperRequest(runtime))).action == .start)
  model.refresh()
  #expect(await status.pendingCount() == 0)

  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "started"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.runtimeApplyStatus != .applying)

  model.refresh()
  #expect((try #require(try await nextHelperRequest(status))).action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "post-start-status",
      message: "post-start status"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "post-start-status" })
}

@Test @MainActor
func normalRefreshIsNotAdmittedDuringStopAndWorksAfterCompletion() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: .empty,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.setCoreEnabled(false)
  #expect((try #require(try await nextHelperRequest(runtime))).action == .stop)
  model.refresh()
  #expect(await status.pendingCount() == 0)

  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.runtimeApplyStatus != .applying)

  model.refresh()
  #expect((try #require(try await nextHelperRequest(status))).action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "post-stop-status",
      message: "post-stop status"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "post-stop-status" })
}

private func isolatedStartupDefaults() throws -> (String, UserDefaults) {
  let suiteName = "SBMTests.StartupLifecycle.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suiteName) else {
    throw CocoaError(.fileReadUnknown)
  }
  defaults.removePersistentDomain(forName: suiteName)
  return (suiteName, defaults)
}

private let restorePreferenceTestKey = "RestoreLastVPNStateEnabled"
private let explicitIntentTestKey = "LastExplicitVPNIntentConnected"

@Test @MainActor func profileLibraryBackupAndRestoreEligibilityUsesStoppedAuthority() {
  let cases: [(HelperRegistrationState, ObservedCoreState, Bool)] = [
    (.enabled, .stopped, true),
    (.enabled, .running, false),
    (.enabled, .unknown, false),
    (.requiresApproval, .unknown, false),
    (.notRegistered, .unknown, true),
    (.notFound, .unknown, true),
    (.notRegistered, .running, true),
    (.notFound, .running, true),
    (.enabled, .running, false),
  ]

  for (registrationState, coreState, restoreAllowed) in cases {
    let model = hardeningModel(
      library: .empty,
      helperRegistrationState: registrationState
    )
    model.observedCoreState = coreState
    #expect(model.canBackUpProfileLibrary)
    #expect(model.canRestoreProfileLibrary == restoreAllowed)
  }

  let connected = hardeningModel(library: .empty)
  connected.observedCoreState = .running
  #expect(connected.canBackUpProfileLibrary)
  #expect(!connected.canRestoreProfileLibrary)
}

@Test @MainActor func startEmptyRecoveryRequiresProvenRuntimeSafety() {
  let cases: [(HelperRegistrationState, ObservedCoreState, Bool)] = [
    (.enabled, .stopped, true),
    (.enabled, .unknown, false),
    (.requiresApproval, .unknown, false),
    (.notRegistered, .unknown, true),
    (.notFound, .unknown, true),
    (.notRegistered, .running, true),
    (.notFound, .running, true),
    (.enabled, .running, false),
  ]

  for (registrationState, coreState, allowed) in cases {
    let model = AppModel(
      helperService: ReadyHelperService(registrationState: registrationState),
      profileLibraryLoader: { throw ProfileStoreFailure.invalidJSON(nil) },
      profileLibrarySaver: { _ in },
      userDefaults: IsolatedTestUserDefaults(),
      performStartup: false
    )
    model.observedCoreState = coreState
    #expect(model.profileRecoveryRequired)
    #expect(model.profileReplacementRuntimeIsSafe == allowed)
    #expect(!model.canRestoreProfileLibrary)
    if !allowed {
      model.resetCorruptProfileLibrary()
      #expect(model.profileRecoveryRequired)
      #expect(model.profiles.isEmpty)
      #expect(
        model.lastError
          == SBMText.localized("Disconnect the VPN before starting with an empty profile library.")
      )
    }
  }

  let unclassified = AppModel(
    helperService: ReadyHelperService(),
    profileLibraryLoader: { throw ProfileStoreFailure.unclassifiedJSON },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  #expect(!unclassified.profileRecoveryRequired)
  unclassified.resetCorruptProfileLibrary()
  #expect(!unclassified.profileRecoveryRequired)
}

@Test @MainActor func profileLibraryActionsDoNoWorkWhenStorageMakesThemUnavailable() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let fetches = AutoSelectionMutationEventLog()
  let manager = SubscriptionManager { value, _ in
    fetches.append(value)
    return SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:]
    )
  }
  let restoreModel = hardeningModel(
    library: .empty,
    userDefaults: defaults,
    manager: manager,
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  restoreModel.observedCoreState = .running
  let unavailableSource = URL(fileURLWithPath: "/tmp/sbm-profile-restore-not-read.json")

  #expect(restoreModel.canBackUpProfileLibrary)
  #expect(!restoreModel.canRestoreProfileLibrary)
  restoreModel.restoreProfileLibrary(from: unavailableSource)

  let backupModel = AppModel(
    helperService: ReadyHelperService(),
    subscriptionManager: manager,
    helperLifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) },
    profileLibraryLoader: { throw ProfileStoreFailure.unsafeStorage },
    profileLibrarySaver: { _ in },
    userDefaults: defaults,
    performStartup: false
  )
  backupModel.backUpProfileLibrary(to: unavailableSource)

  #expect(defaults.bool(forKey: restorePreferenceTestKey))
  #expect(defaults.bool(forKey: explicitIntentTestKey))
  let helperRequests = await status.pendingCount()
  let runtimeRequests = await runtime.pendingCount()
  #expect(helperRequests == 0)
  #expect(runtimeRequests == 0)
  #expect(fetches.snapshot().isEmpty)
}

@Test @MainActor func profileLibraryRestoreStaysBlockedDuringRuntimeAndHelperSetupWork()
  async throws
{
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .stopped

  model.setCoreEnabled(true)
  let request = try await nextHelperRequest(runtime)
  #expect(request?.action == .start)
  #expect(!model.canRestoreProfileLibrary)
  model.restoreProfileLibrary(
    from: URL(fileURLWithPath: "/tmp/sbm-profile-restore-during-runtime.json")
  )
  #expect(await runtime.pendingCount() == 1)

  await runtime.completeNext(
    HelperResponse(success: false, coreRunning: false, message: "synthetic rejection")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(await runtime.pendingCount() == 0)

  model.observedCoreState = .stopped
  model.helperSetupInProgress = true
  #expect(!model.canRestoreProfileLibrary)
  model.helperSetupInProgress = false
  #expect(model.canRestoreProfileLibrary)
}

@Test @MainActor func profileLibraryTransferIsBlockedDuringRoutingMutationQueue() async throws {
  let validator = ControlledValidator()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    validator: { try await validator.validate($0) }
  )
  model.websiteRoutingInput = "example.test"
  model.addWebsiteRoutingRule()
  _ = try await validator.nextProfile()

  #expect(await validator.requestWasMade())
  #expect(!model.canBackUpProfileLibrary)
  model.backUpProfileLibrary(
    to: URL(fileURLWithPath: "/tmp/sbm-profile-backup-during-routing.json")
  )
  #expect(!model.canRestoreProfileLibrary)

  await validator.complete()
  #expect(await waitForHardeningCondition { model.canBackUpProfileLibrary })
  #expect(model.canBackUpProfileLibrary)
}

@Test @MainActor func startupPreferencesDefaultFalseAndEnablingDoesNotRestoreNow() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let fetches = AutoSelectionMutationEventLog()
  let profile = ManagedProfile(
    name: "A",
    sources: [ManagedSource(name: "Remote", value: "https://feed.example.test/list")],
    payload: hardeningPayload("a.example.test")
  )
  let manager = SubscriptionManager { value, _ in
    fetches.append(value)
    return SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:]
    )
  }
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    manager: manager,
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  #expect(!model.restoreLastVPNStateEnabled)
  #expect(defaults.object(forKey: restorePreferenceTestKey) == nil)
  #expect(defaults.object(forKey: explicitIntentTestKey) == nil)
  model.setRestoreLastVPNStateEnabled(true)
  #expect(model.restoreLastVPNStateEnabled)
  #expect(defaults.bool(forKey: restorePreferenceTestKey))
  #expect(defaults.object(forKey: explicitIntentTestKey) == nil)

  model.refresh()
  #expect(try await status.nextRequest().action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "restore-disabled-status",
      message: "stopped"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "restore-disabled-status" })
  #expect(await runtime.pendingCount() == 0)
  #expect(fetches.snapshot().isEmpty)
  #expect(!model.coreRunning)
}

@Test @MainActor func explicitIntentPersistsBeforeHelperReadinessAndQuitDoesNotRewriteIt()
  async throws
{
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    runtimeSender: { request in try await runtime.send(request) })
  model.helperEnabled = false
  model.helperReachable = false

  model.setCoreEnabled(true)
  #expect(defaults.bool(forKey: explicitIntentTestKey))
  #expect(await runtime.pendingCount() == 0)
  model.setCoreEnabled(false)
  #expect(!defaults.bool(forKey: explicitIntentTestKey))
  #expect(await runtime.pendingCount() == 0)

  defaults.set(true, forKey: explicitIntentTestKey)
  model.observedCoreState = .stopped
  let quit = Task { await model.disconnectBeforeQuit() }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "terminal OFF")
  )
  #expect(await quit.value)
  #expect(defaults.bool(forKey: explicitIntentTestKey))
}

@Test @MainActor func isolatedDefaultsSeparateOppositeIntentAndPreserveProcessDefaults()
  async throws
{
  let standard = UserDefaults.standard
  let preferenceKeys = [
    restorePreferenceTestKey,
    explicitIntentTestKey,
    "LastUpdateCheck",
  ]
  let standardBefore = preferenceKeys.map { standard.object(forKey: $0) as? NSObject }
  let defaultsA = IsolatedTestUserDefaults()
  let defaultsB = IsolatedTestUserDefaults()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let runtimeA = ControlledHelperResponses()
  let runtimeB = ControlledHelperResponses()
  let modelA = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaultsA,
    runtimeSender: { request in try await runtimeA.send(request) }
  )
  let modelB = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaultsB,
    runtimeSender: { request in try await runtimeB.send(request) }
  )

  modelA.setCoreEnabled(true)
  #expect(try await runtimeA.nextRequest().action == .start)
  #expect(defaultsA.bool(forKey: explicitIntentTestKey))
  await runtimeA.completeNext(
    HelperResponse(success: true, coreRunning: true, activeProfileID: profile.id, message: "on")
  )
  #expect(await waitForHardeningCondition { modelA.runtimeApplyStatus == .active })

  modelB.setCoreEnabled(false)
  #expect(try await runtimeB.nextRequest().action == .stop)
  #expect(!defaultsB.bool(forKey: explicitIntentTestKey))
  #expect(defaultsA.bool(forKey: explicitIntentTestKey))
  await runtimeB.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "off")
  )
  #expect(await waitForHardeningCondition { modelB.runtimeApplyStatus != .applying })

  for (key, before) in zip(preferenceKeys, standardBefore) {
    let after = standard.object(forKey: key) as? NSObject
    #expect(after == nil ? before == nil : after?.isEqual(before) == true)
  }
}

@Test @MainActor func isolatedDefaultsRemoveTheirPersistentDomainOnDeinit() {
  let suiteName: String = {
    let defaults = IsolatedTestUserDefaults()
    defaults.set("marker", forKey: "cleanup-marker")
    #expect(
      UserDefaults.standard.persistentDomain(forName: defaults.suiteName)?["cleanup-marker"]
        as? String == "marker"
    )
    return defaults.suiteName
  }()

  let domain = UserDefaults.standard.persistentDomain(forName: suiteName)
  #expect(domain?["cleanup-marker"] == nil)
  #expect(domain?.isEmpty ?? true)
}

@Test @MainActor func disablingRestoreCancelsPendingWithoutChangingExplicitIntent() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: .empty,
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setRestoreLastVPNStateEnabled(false)
  #expect(!model.restoreLastVPNStateEnabled)
  #expect(!defaults.bool(forKey: restorePreferenceTestKey))
  #expect(defaults.bool(forKey: explicitIntentTestKey))
  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "restore-cancelled-status",
      message: "stopped"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "restore-cancelled-status" })
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func startupRestoreRequiresEnabledPreferenceAndConnectedIntent() async throws {
  for (restoreEnabled, connectedIntent) in [(false, true), (true, false)] {
    let (suiteName, defaults) = try isolatedStartupDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(restoreEnabled, forKey: restorePreferenceTestKey)
    defaults.set(connectedIntent, forKey: explicitIntentTestKey)
    let status = ControlledHelperResponses()
    let runtime = ControlledHelperResponses()
    let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
    let model = hardeningModel(
      library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
      userDefaults: defaults,
      applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
      lifecycleSender: { request, _ in try await status.send(request) },
      runtimeSender: { request in try await runtime.send(request) }
    )

    model.refresh()
    let initialStatus = try await status.nextRequest()
    #expect(initialStatus.action == .status)
    #expect(initialStatus.recoverDesiredRuntime != true)
    let statusMarker = "restore-intent-status-\(restoreEnabled)-\(connectedIntent)"
    await status.completeNext(
      HelperResponse(
        success: true,
        coreRunning: false,
        coreVersion: statusMarker,
        message: "stopped"
      )
    )
    #expect(await waitForHardeningCondition { model.coreVersion == statusMarker })
    #expect(await runtime.pendingCount() == 0)
    #expect(model.startupRestoreError == nil)
  }
}

@Test @MainActor
func startupRestoreWaitsUntilHelperUpgradeSetupFinishes() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    helperService: ReadyHelperService(registrationState: .enabled),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.enableHelper()
  #expect(try await status.nextRequest().action == .status)
  #expect(await runtime.pendingCount() == 0)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: true,
      message: "current helper is ready"
    )
  )

  #expect(await waitForHardeningCondition { !model.helperSetupInProgress })
  #expect(try await status.nextRequest().action == .status)
  #expect(await runtime.pendingCount() == 0)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: true,
      message: "startup restore status"
    )
  )

  let start = try await runtime.nextRequest()
  #expect(start.action == .start)
  #expect(start.profileID == profile.id)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "restored"
    )
  )
  #expect(await waitForHardeningCondition { model.coreRunning })
  #expect(model.coreRunning)
}

@Test @MainActor func currentStoppedObservationRestoresSelectedPayloadOnceWithoutFetch()
  async throws
{
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let fetches = AutoSelectionMutationEventLog()
  let profile = ManagedProfile(
    name: "A",
    sources: [ManagedSource(name: "Remote", value: "https://feed.example.test/list")],
    payload: hardeningPayload("a.example.test")
  )
  let manager = SubscriptionManager { value, _ in
    fetches.append(value)
    return SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:]
    )
  }
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    manager: manager,
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))
  let start = try await runtime.nextRequest()
  #expect(start.action == .start)
  #expect(start.profileID == profile.id)
  #expect(defaults.bool(forKey: explicitIntentTestKey))
  #expect(fetches.snapshot().isEmpty)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "started"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(await runtime.pendingCount() == 0)
  #expect(fetches.snapshot().isEmpty)
}

@Test @MainActor func incompatibleObservationDefersRestoreUntilCurrentHelperStatus() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(
    try hardeningResponse(
      coreRunning: false, revision: HelperConstants.helperRevision - 1,
      protocolVersion: HelperConstants.protocolVersion - 1,
      message: "incompatible-before-restore"
    )
  )
  #expect(await waitForHardeningCondition { model.helperUpdateRequired })
  #expect(model.helperUpdateRequired)
  #expect(await runtime.pendingCount() == 0)

  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(
    try hardeningResponse(coreRunning: false, revision: HelperConstants.helperRevision)
  )
  #expect((try await runtime.nextRequest()).action == .start)
}

@Test(arguments: [false, true])
@MainActor
func activeCoreWithRestorePreferenceAdoptsWithoutChangingTheCurrentSession(
  _ restoreEnabled: Bool
) async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(restoreEnabled, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  let initialStatus = try await status.nextRequest()
  #expect(initialStatus.recoverDesiredRuntime != true)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "already-running-restore-status",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(
    await waitForHardeningCondition { model.coreVersion == "already-running-restore-status" }
  )
  #expect(model.coreRunning)
  #expect(model.restoreLastVPNStateEnabled == restoreEnabled)
  #expect(await runtime.pendingCount() == 0)

  model.setRestoreLastVPNStateEnabled(!restoreEnabled)
  #expect(model.restoreLastVPNStateEnabled == !restoreEnabled)
  model.setRestoreLastVPNStateEnabled(restoreEnabled)
  #expect(model.restoreLastVPNStateEnabled == restoreEnabled)
  #expect(await runtime.pendingCount() == 0)

  model.refresh()
  let activeStatus = try await status.nextRequest()
  #expect(activeStatus.action == .status)
  #expect(activeStatus.recoverDesiredRuntime == true)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "active-session-after-restore-toggle",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.coreVersion == "active-session-after-restore-toggle"
    }
  )
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func unsuccessfulRunningObservationCannotAuthorizeRecovery() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(false, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  let firstStatus = try await status.nextRequest()
  #expect(firstStatus.recoverDesiredRuntime != true)
  await status.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      coreVersion: "failed-running-observation",
      activeProfileID: profile.id,
      message: "observation failed"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.coreVersion == "failed-running-observation"
    }
  )

  model.refresh()
  let secondStatus = try await status.nextRequest()
  #expect(secondStatus.recoverDesiredRuntime != true)
  #expect(await runtime.pendingCount() == 0)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "confirmed-running-observation",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "running"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.coreVersion == "confirmed-running-observation"
    }
  )
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func missingStartupPayloadConsumesAttemptAndShowsError() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: .empty,
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))
  #expect(await waitForHardeningCondition { model.startupRestoreError != nil })
  #expect(model.startupRestoreError != nil)
  #expect(await runtime.pendingCount() == 0)

  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  model.profiles = [profile]
  model.selectedProfileID = profile.id
  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "missing-payload-second-status",
      message: "stopped"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "missing-payload-second-status" })
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func failedStartupRestoreDoesNotRetryDuringSameProcess() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(HelperResponse(success: false, coreRunning: false, message: "failed"))
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(defaults.bool(forKey: explicitIntentTestKey))

  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "after-failed-startup-status",
      message: "stopped"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "after-failed-startup-status" })
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func explicitDisconnectCancelsPendingStartupRestore() async throws {
  let (suiteName, defaults) = try isolatedStartupDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(true, forKey: restorePreferenceTestKey)
  defaults.set(true, forKey: explicitIntentTestKey)
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(false)
  #expect(!defaults.bool(forKey: explicitIntentTestKey))
  #expect((try await runtime.nextRequest()).action == .stop)
  await runtime.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "after-explicit-disconnect-status",
      message: "stopped"
    )
  )
  #expect(
    await waitForHardeningCondition { model.coreVersion == "after-explicit-disconnect-status" }
  )
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func staleWebsiteApplyCannotRestoreAnOlderRule() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true
  model.websiteRoutingInput = "stepik.org"
  model.addWebsiteRoutingRule()
  #expect(try await runtime.nextRequest().action == .start)
  let ruleID = try #require(model.websiteRoutingRules.first?.id)

  model.setWebsiteRoutingTarget(ruleID, target: .direct)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "old apply failed"
    )
  )
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "new apply active"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.websiteRoutingRules.first?.target == .direct)
}

@Test @MainActor func previousHelperTupleIsRejectedAndCurrentTupleIsAccepted() async throws {
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let unsupportedTuples = [
    (revision: 66, protocolVersion: 12),
    (revision: 63, protocolVersion: HelperConstants.protocolVersion),
    (revision: 62, protocolVersion: HelperConstants.protocolVersion),
    (revision: 1, protocolVersion: HelperConstants.protocolVersion),
  ]
  for tuple in unsupportedTuples {
    let status = ControlledHelperResponses()
    let model = hardeningModel(
      library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
      applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
      lifecycleSender: { request, _ in try await status.send(request) }
    )

    model.refresh()
    _ = try await status.nextRequest()
    await status.completeNext(
      try hardeningResponse(
        coreRunning: false,
        revision: tuple.revision,
        protocolVersion: tuple.protocolVersion
      )
    )
    #expect(await waitForHardeningCondition { model.helperUpdateRequired })
    #expect(!model.helperReachable)
  }

  let currentStatus = ControlledHelperResponses()
  let currentModel = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await currentStatus.send(request) }
  )
  currentModel.refresh()
  _ = try await currentStatus.nextRequest()
  await currentStatus.completeNext(
    try hardeningResponse(coreRunning: false, revision: HelperConstants.helperRevision)
  )
  #expect(await waitForHardeningCondition { currentModel.helperReachable })
  #expect(currentModel.helperRevision == HelperConstants.helperRevision)

  let runtime = ControlledHelperResponses()
  let staleModel = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  staleModel.helperRevision = HelperConstants.helperRevision - 1
  staleModel.helperProtocolVersion = HelperConstants.protocolVersion - 1
  staleModel.setCoreEnabled(true)
  #expect(await runtime.pendingCount() == 0)
  #expect(staleModel.lastError?.contains("repair") == true)
}

@Test @MainActor func disconnectRemainsAuthoritativeAcrossModeNodeWebsiteAndApplicationEdits()
  async throws
{
  let runtime = ControlledHelperResponses()
  let node = ProxyNodeID(rawValue: "node-a")
  let application = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [
          ManagedConnection(id: node, outbound: hardeningConnection("a.example.test").outbound)
        ],
        applicationRoutingRules: [application]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.setCoreEnabled(false)
  #expect(try await runtime.nextRequest().action == .stop)
  model.setRoutingMode(.global)
  model.setSelectedNode(node)
  model.websiteRoutingInput = "stepik.org"
  model.addWebsiteRoutingRule()
  #expect(await waitForHardeningCondition { !(model.websiteRoutingRules.isEmpty) })
  model.setApplicationRoutingTarget(application.id, target: .direct)
  #expect(
    await waitForHardeningCondition { !(model.applicationRoutingRules.first?.target != .direct) })
  #expect(await runtime.pendingCount() == 1)

  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.coreIsKnownStopped)
  #expect(model.websiteRoutingRules.first?.domain == "stepik.org")
  #expect(model.applicationRoutingRules.first?.target == .direct)
  #expect(model.routingMode == .global)
  #expect(await runtime.pendingCount() == 0)

  model.setRoutingMode(.direct)
  model.setSelectedNode(.auto)
  #expect(model.routingMode == .direct)
  #expect(model.selectedNodeID == .auto)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func stoppedStatusAndHelperRepairDoNotStartAvailableProfile() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  #expect((try await status.nextRequest()).action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "helper-repair-stopped-status",
      message: "stopped"
    )
  )
  #expect(
    await waitForHardeningCondition { model.coreVersion == "helper-repair-stopped-status" }
  )
  #expect(model.coreIsKnownStopped)
  #expect(await runtime.pendingCount() == 0)

  model.repairHelper()
  #expect((try await status.nextRequest()).action == .status)
  await status.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "repaired")
  )
  #expect(await waitForHardeningCondition { !(model.helperSetupInProgress) })
  #expect(model.coreIsKnownStopped)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func explicitConnectSubmitsExactlyOneStart() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  let request = try await runtime.nextRequest()
  #expect(request.action == .start)
  #expect(request.profileID == profile.id)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "explicitly connected"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func disconnectInFlightAllowsProfileSelectionWithoutStartingIt() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profileA = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileA.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.setCoreEnabled(false)
  #expect(try await runtime.nextRequest().action == .stop)
  model.selectProfile(profileB.id)
  #expect(model.selectedProfileID == profileB.id)
  #expect(await runtime.pendingCount() == 1)

  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.coreIsKnownStopped)
  #expect(model.selectedProfileID == profileB.id)
  #expect(await runtime.pendingCount() == 0)

  model.refresh()
  #expect((try await status.nextRequest()).action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "still-disconnected-status",
      message: "still disconnected"
    )
  )
  #expect(await waitForHardeningCondition { model.coreVersion == "still-disconnected-status" })
  #expect(model.connectionPresentation == .disconnected)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func explicitConnectAfterStoppedStatusSubmitsOneStart() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  _ = try await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      coreVersion: "explicit-connect-preflight-status",
      message: "stopped"
    )
  )
  #expect(
    await waitForHardeningCondition { model.coreVersion == "explicit-connect-preflight-status" }
  )
  #expect(model.coreIsKnownStopped)
  #expect(await runtime.pendingCount() == 0)

  model.setCoreEnabled(true)
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "explicitly connected"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func shutdownFencesInFlightStartAndRejectsNewConnect() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  #expect(try await runtime.nextRequest().action == .start)
  let shutdown = Task { await model.disconnectBeforeQuit() }
  #expect(await waitForHardeningCondition { !(model.connectionPresentation != .disconnecting) })
  model.setCoreEnabled(true)
  #expect(await runtime.pendingCount() == 1)

  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "stale start"
    )
  )
  #expect(try await runtime.nextRequest().action == .shutdown)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      message: "shutdown"
    )
  )
  #expect(await shutdown.value)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func helperFailureMakesCoreUnknownAndQuitRequiresProvenStop() async throws {
  let status = FailingThenStoppedStatus()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, timeout in try await status.send(request, timeout) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true
  model.helperReachable = true

  model.refresh()
  let initialStatusCompleted = await waitForHardeningCondition {
    !model.helperReachable
  }
  #expect(initialStatusCompleted, "initial status failure did not finish within 2 seconds")
  guard initialStatusCompleted else { return }
  #expect(model.observedCoreState == .unknown)
  #expect(model.connectionPresentation == .unknown)
  #expect(!model.supportSnapshot.statusText.contains("Core: stopped"))

  let quit = Task { await model.disconnectBeforeQuit() }
  let shutdownSubmitted = try await waitForSubmittedRuntimeRequest(runtime)
  #expect(shutdownSubmitted, "Quit did not submit Shutdown within 2 seconds")
  guard shutdownSubmitted else { return }
  let shutdown = try await runtime.nextRequest()
  #expect(shutdown.action == .shutdown)
  #expect(shutdown.stopReason == .appTermination)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "still running"
    )
  )
  #expect(await quit.value == false)
  #expect(await runtime.pendingCount() == 0)
  #expect(model.observedCoreState == .running)
  #expect(!model.coreIsKnownStopped)

  model.helperReachable = true
  model.refresh()
  let laterStatusCompleted = await waitForHardeningCondition { model.coreIsKnownStopped }
  #expect(laterStatusCompleted, "later stopped status did not complete within 2 seconds")
  guard laterStatusCompleted else { return }
  let retryQuit = Task { await model.disconnectBeforeQuit() }
  let retryShutdownSubmitted = try await waitForSubmittedRuntimeRequest(runtime)
  #expect(retryShutdownSubmitted, "stopped readback did not cause a durable Shutdown retry")
  guard retryShutdownSubmitted else { return }
  let retryShutdown = try await runtime.nextRequest()
  #expect(retryShutdown.action == .shutdown)
  #expect(retryShutdown.stopReason == .appTermination)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "durable OFF saved")
  )
  #expect(await retryQuit.value)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func refreshSkipsDeletedChangedAndNewSourcesBeforeFetch() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let urlA = "https://a.example.test/list"
  let urlB = "https://b.example.test/list"
  let sourceA = ManagedSource(
    name: "A", value: urlA, payload: hardeningPayload("old-a.example.test")
  )
  let sourceB = ManagedSource(
    name: "B", value: urlB, payload: hardeningPayload("old-b.example.test")
  )
  let profile = ManagedProfile(
    name: "A",
    sources: [sourceA, sourceB],
    payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  #expect(try await fetcher.nextRequest() == urlA)
  model.profiles[0].sources.removeAll(where: { $0.id == sourceB.id })
  model.profiles[0].sources.append(
    ManagedSource(
      name: "New",
      value: "https://new.example.test/list",
      payload: hardeningPayload("new.example.test")
    )
  )
  await fetcher.complete(
    urlA,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:])
  )
  #expect(await waitForHardeningCondition { !(model.isRefreshing) })
  #expect(await fetcher.requestCount() == 0)

  let fetcher2 = ControlledSubscriptionFetcher()
  let model2 = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher2.fetch(value, headers) }
  )
  model2.refreshExternalState()
  #expect(try await fetcher2.nextRequest() == urlA)
  let bIndex = try #require(model2.profiles[0].sources.firstIndex(where: { $0.id == sourceB.id }))
  model2.profiles[0].sources[bIndex].value = "https://changed.example.test/list"
  model2.profiles[0].sources[bIndex].headers = SubscriptionHeaders(
    userAgent: "Changed/Test",
    appVersion: "9.9",
    deviceOS: "ChangedOS",
    hardwareID: "changed-hwid"
  )
  model2.profiles[0].sources[bIndex].excludeRegex = "changed"
  await fetcher2.complete(
    urlA,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:])
  )
  #expect(await waitForHardeningCondition { !(model2.isRefreshing) })
  #expect(await fetcher2.requestCount() == 0)
}

@Test @MainActor func refreshApplyFailureKeepsNewerSameProfileWebsiteEdit() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let runtime = ControlledHelperResponses()
  let urlA = "https://a.example.test/list"
  let urlB = "https://b.example.test/list"
  let application = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let initialPayload = CoreProfile.compatibility(
    VPNProfile(
      connections: [hardeningConnection("old.example.test")],
      applicationRoutingRules: [application]
    )
  )
  let profile = ManagedProfile(
    name: "A",
    sources: [
      ManagedSource(name: "A", value: urlA, payload: hardeningPayload("old-a.example.test")),
      ManagedSource(name: "B", value: urlB, payload: hardeningPayload("old-b.example.test")),
    ],
    payload: initialPayload
  )
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: true
    ),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    lifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        activeIPv6Enabled: true,
        message: "running"
      )
    },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.refreshExternalState()
  #expect(try await fetcher.nextRequest() == urlA)
  await fetcher.complete(
    urlA,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:])
  )
  #expect(try await fetcher.nextRequest() == urlB)

  model.websiteRoutingInput = "stepik.org"
  model.addWebsiteRoutingRule()
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "website active"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  model.setApplicationRoutingTarget(application.id, target: .direct)
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "application active"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  await fetcher.complete(
    urlB,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-b.example.test"), skippedTransports: [:])
  )
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "candidate failed; previous runtime preserved"
    )
  )
  #expect(
    await waitForHardeningCondition {
      !(model.isRefreshing || model.runtimeApplyStatus == .applying)
    })
  #expect(model.websiteRoutingRules.map(\.domain) == ["stepik.org"])
  #expect(model.applicationRoutingRules.first?.target == .direct)
  #expect(model.subscriptionStatus.contains("Sources saved; apply failed"))
}

@Test @MainActor func rollbackPersistenceFailureIsVisibleAndKeepsDurableCommittedState() async {
  let saver = SaveFailureController(failOnAttempts: [2])
  let rule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("a.example.test")],
        applicationRoutingRules: [rule]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { _ in
      HelperResponse(
        success: false,
        coreRunning: true,
        activeProfileID: profile.id,
        message: "apply failed"
      )
    },
    saver: { try saver.save($0) }
  )
  model.coreRunning = true
  model.setApplicationRoutingTarget(rule.id, target: .direct)
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .failed) })

  #expect(saver.attempts == 2)
  #expect(model.applicationRoutingRules.first?.target == .direct)
  #expect(model.lastError?.contains("Rollback could not be saved") == true)
  #expect(model.recentErrors.last?.message.contains("Rollback could not be saved") == true)
}

@Test @MainActor func addProfileSaveFailureLeavesNoPhantomSelection() {
  let saver = SaveFailureController(failOnAttempts: [1])
  let model = hardeningModel(library: .empty, saver: { try saver.save($0) })
  model.addProfile()
  #expect(model.profiles.isEmpty)
  #expect(model.selectedProfileID == nil)
  #expect(model.lastError != nil)
}

@Test @MainActor func explicitDisconnectCancelsOlderRefreshBeforeValidationOrApply() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let validator = ControlledValidator()
  let runtime = ControlledHelperResponses()
  let url = "https://source.example.test/list"
  let profile = ManagedProfile(
    name: "A",
    sources: [
      ManagedSource(name: "Remote", value: url, payload: hardeningPayload("old.example.test"))
    ],
    payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    lifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        activeIPv6Enabled: true,
        message: "running"
      )
    },
    runtimeSender: { request in try await runtime.send(request) },
    validator: { profile in try await validator.validate(profile) }
  )
  model.coreRunning = true

  model.refreshExternalState()
  #expect(try await fetcher.nextRequest() == url)
  model.setCoreEnabled(false)
  #expect(try await runtime.nextRequest().action == .stop)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(
    await waitForHardeningCondition {
      !(model.isRefreshing || model.runtimeApplyStatus == .applying)
    })
  #expect(!(await validator.requestWasMade()))
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func connectedRefreshKeepsKnownGoodRuntimeWhenActivationIsDeferred() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let runtime = ControlledHelperResponses()
  let url = "https://source.example.test/list"
  let profile = ManagedProfile(
    name: "A",
    sources: [
      ManagedSource(name: "Remote", value: url, payload: hardeningPayload("old.example.test"))
    ],
    payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: true
    ),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    lifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        activeIPv6Enabled: true,
        message: "running"
      )
    },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.refreshExternalState()
  #expect(try await fetcher.nextRequest() == url)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .reconnectRequired) })

  #expect(model.coreRunning)
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")
  #expect(model.subscriptionStatus != DeferredRuntimeApplyPresentation.changesReadyToApply)
  #expect(hardeningServer(model.profiles.first?.payload) == "fresh.example.test")
}

@Test @MainActor func relaunchStatusRestoresDeferredRuntimeFromHelperMarker() async {
  let profile = ManagedProfile(
    name: "A",
    payload: hardeningPayload("active.example.test")
  )
  let deferredResponse = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: profile.id,
    runtimeOutcome: .reconnectRequired,
    message: HelperRuntimeOutcome.reconnectRequired.userMessage!
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { _, _ in deferredResponse },
    runtimeStateReader: { deferredResponse }
  )

  model.refresh()
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .reconnectRequired) })

  #expect(model.coreRunning)
  #expect(model.selectedProfileID == profile.id)
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")
  #expect(model.subscriptionStatus != DeferredRuntimeApplyPresentation.changesReadyToApply)
}

@Test @MainActor func relaunchAfterSuccessfulReconnectDoesNotRestoreStalePendingState() async {
  let profile = ManagedProfile(
    name: "A",
    payload: hardeningPayload("active.example.test")
  )
  let appliedResponse = HelperResponse(
    success: true,
    coreRunning: true,
    coreVersion: "relaunch-active-status",
    activeProfileID: profile.id,
    activeIPv6Enabled: true,
    message: "active"
  )
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: true
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { _, _ in appliedResponse },
    runtimeStateReader: { appliedResponse }
  )

  model.refresh()
  #expect(await waitForHardeningCondition { model.coreVersion == "relaunch-active-status" })

  #expect(model.runtimeApplyStatus == .active)
  #expect(model.deferredRuntimeApplyPresentation == nil)
}

@Test @MainActor func appliedStatusObservationsCannotAcknowledgeDeferredDNS() async throws {
  let runtime = ControlledHelperResponses()
  let status = ControlledHelperResponses()
  let profile = ManagedProfile(
    name: "A",
    payload: hardeningPayload("active.example.test")
  )
  let desiredDNS = ManagedDNSSettings(direct: .google, proxy: .cloudflare)
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: true
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  #expect(model.saveDNSSettings(desiredDNS))
  let start = try await runtime.nextRequest()
  #expect(start.action == .start)
  #expect(start.profileID == profile.id)
  #expect(start.dnsSettings == desiredDNS)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .reconnectRequired) })
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")

  for attempt in 1...2 {
    model.refresh()
    #expect((try await status.nextRequest()).action == .status)
    let appliedResponse = HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "deferred-dns-status-\(attempt)",
      activeProfileID: profile.id,
      activeIPv6Enabled: true,
      runtimeOutcome: .applied,
      message: "applied"
    )
    await status.completeNext(appliedResponse)
    #expect(
      await waitForHardeningCondition { model.coreVersion == appliedResponse.coreVersion }
    )

    #expect(model.coreRunning)
    #expect(model.activeIPv6Enabled == true)
    #expect(model.dnsSettings == desiredDNS)
    #expect(model.runtimeApplyStatus == .reconnectRequired)
    #expect(model.deferredRuntimeApplyPhase == .pending)
    #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")
  }
}

@Test @MainActor func appliedLatencyObservationCannotAcknowledgeDeferredDNS() async throws {
  let runtime = ControlledHelperResponses()
  let latency = ControlledHelperResponses()
  let profile = ManagedProfile(
    name: "Latency while deferred",
    payload: hardeningPayload("active.example.test")
  )
  let node = profile.payload!.nodes.first(where: { $0.id != .auto })!.id
  let desiredDNS = ManagedDNSSettings(direct: .google, proxy: .cloudflare)
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    latencySettleDelay: .zero,
    latencySender: { node in
      try await latency.send(HelperRequest(action: .testLatency, node: node))
    }
  )
  model.coreRunning = true

  #expect(model.saveDNSSettings(desiredDNS))
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .reconnectRequired) })

  model.testLatency()
  #expect((try await latency.nextRequest()).node == node)
  await latency.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      delays: [NodeDelay(node: node, milliseconds: 18)],
      runtimeOutcome: .applied,
      message: "latency node"
    )
  )
  #expect((try await latency.nextRequest()).node == nil)
  await latency.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      delays: [NodeDelay(node: node, milliseconds: 24)],
      runtimeOutcome: .applied,
      message: "latency history"
    )
  )
  #expect(await waitForHardeningCondition { !(model.latencyTestInProgress) })

  #expect(model.latencyTestCompleted)
  #expect(model.nodes.first(where: { $0.id == node })?.delay == 24)
  #expect(model.dnsSettings == desiredDNS)
  #expect(model.runtimeApplyStatus == .reconnectRequired)
  #expect(model.deferredRuntimeApplyPhase == .pending)
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")
}

@Test @MainActor func latestAppliedCurrentStartClearsDeferredRuntimeState() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(
    name: "Latest desired DNS",
    payload: hardeningPayload("active.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  let firstDNS = ManagedDNSSettings(direct: .google, proxy: .cloudflare)
  #expect(model.saveDNSSettings(firstDNS))
  #expect((try await runtime.nextRequest()).dnsSettings == firstDNS)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .reconnectRequired) })

  let latestDNS = ManagedDNSSettings(direct: .yandex, proxy: .adguard)
  #expect(model.saveDNSSettings(latestDNS))
  let latestStart = try await runtime.nextRequest()
  #expect(latestStart.action == .start)
  #expect(latestStart.dnsSettings == latestDNS)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      runtimeOutcome: .applied,
      message: "latest desired configuration applied"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .active) })

  #expect(model.dnsSettings == latestDNS)
  #expect(model.deferredRuntimeApplyPhase == .idle)
  #expect(model.deferredRuntimeApplyPresentation == nil)
}

@Test @MainActor
func explicitDisconnectDuringReconnectStartQueuesStopAndPreservesOffIntent() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "Reconnect", payload: hardeningPayload("a.example.test"))
  let suite = "SBMTests.ReconnectDisconnect.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults,
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.setIPv6Enabled(true)
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      runtimeOutcome: .reconnectRequired,
      message: "deferred"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .reconnectRequired) })

  model.reconnectToApply()
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))
  #expect(try await runtime.nextRequest().action == .start)
  #expect(model.connectionPresentation == .connecting)
  #expect(model.connectionPresentation.nextEnabledState == false)

  model.setCoreEnabled(false)
  #expect(model.connectionPresentation == .disconnecting)
  #expect(model.deferredRuntimeApplyPhase == .pending)
  #expect(!defaults.bool(forKey: "LastExplicitVPNIntentConnected"))
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profile.id, message: "stale start")
  )
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "disconnected"))
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })

  model.setIPv6Enabled(false)
  #expect(await runtime.pendingCount() == 0)
  #expect(!model.coreRunning)
  #expect(model.deferredRuntimeApplyPresentation != nil)
  #expect(model.deferredRuntimeApplyPhase == .pending)
  defaults.removePersistentDomain(forName: suite)
}

@Test @MainActor
func reconnectConfirmationCannotClearNewerDNSOrModeSettings() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "Reconnect basis", payload: hardeningPayload("a.example.test"))
  let applied = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: profile.id,
    runtimeOutcome: .applied,
    message: "active"
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: { applied }
  )
  model.coreRunning = true

  model.setIPv6Enabled(true)
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      runtimeOutcome: .reconnectRequired,
      message: "deferred"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .reconnectRequired) })

  model.reconnectToApply()
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))
  let start = try await runtime.nextRequest()
  #expect(start.action == .start)
  #expect(start.dnsSettings == ManagedDNSSettings.defaults)
  #expect(start.mode == .rule)

  #expect(model.saveDNSSettings(ManagedDNSSettings(direct: .google, proxy: .cloudflare)))
  model.setRoutingMode(.global)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      runtimeOutcome: .applied,
      message: "started old basis"
    )
  )
  #expect(await waitForHardeningCondition { !(model.deferredRuntimeApplyPhase != .pending) })

  #expect(model.deferredRuntimeApplyPresentation != nil)
  #expect(model.runtimeApplyStatus == .reconnectRequired)
  #expect(model.deferredRuntimeApplyError == nil)
  #expect(model.dnsSettings.direct == .google)
  #expect(model.routingMode == .global)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func staleReconnectConfirmationCannotPublishSuccessOrFailureAfterDisconnect() async throws {
  for fails in [false, true] {
    let runtime = ControlledHelperResponses()
    let confirmation = ControlledHelperResponses()
    let profile = ManagedProfile(
      name: "Reconnect race", payload: hardeningPayload("a.example.test"))
    let model = hardeningModel(
      library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
      runtimeSender: { request in try await runtime.send(request) },
      runtimeStateReader: { try await confirmation.send(HelperRequest(action: .status)) }
    )
    model.coreRunning = true

    model.setIPv6Enabled(true)
    #expect(try await runtime.nextRequest().action == .start)
    await runtime.completeNext(
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        runtimeOutcome: .reconnectRequired,
        message: "deferred"
      )
    )
    #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .reconnectRequired) })

    model.reconnectToApply()
    #expect(try await runtime.nextRequest().action == .stop)
    await runtime.completeNext(
      HelperResponse(success: true, coreRunning: false, message: "stopped"))
    #expect(try await runtime.nextRequest().action == .start)
    await runtime.completeNext(
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        runtimeOutcome: .applied,
        message: "started"
      )
    )
    #expect(try await confirmation.nextRequest().action == .status)

    model.setCoreEnabled(false)
    #expect(model.deferredRuntimeApplyPhase == .pending)
    if fails {
      await confirmation.failNext()
    } else {
      await confirmation.completeNext(
        HelperResponse(
          success: true,
          coreRunning: true,
          activeProfileID: profile.id,
          runtimeOutcome: .applied,
          message: "stale confirmation"
        )
      )
    }
    #expect(try await runtime.nextRequest().action == .stop)
    await runtime.completeNext(
      HelperResponse(success: true, coreRunning: false, message: "stopped"))
    #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
    model.setIPv6Enabled(false)
    #expect(!model.coreRunning)
    #expect(model.deferredRuntimeApplyPhase == .pending)
    #expect(model.lastError == nil)
    #expect(await runtime.pendingCount() == 0)
  }
}

@Test @MainActor
func authoritativeStatusAfterDeferredRoutingMutationDoesNotResurrectPendingPresentation()
  async throws
{
  let profileID = UUID()
  let rule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let profile = ManagedProfile(
    id: profileID,
    name: "Applications",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("active.example.test")],
        applicationRoutingRules: [rule]
      )
    )
  )
  let runtime = ControlledHelperResponses()
  let applied = HelperResponse(
    success: true,
    coreRunning: true,
    coreVersion: "deferred-routing-status",
    activeProfileID: profileID,
    activeIPv6Enabled: true,
    runtimeOutcome: .applied,
    message: "active"
  )
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profileID, ipv6Enabled: true
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { _, _ in applied },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.setApplicationRoutingTarget(rule.id, target: .direct)
  #expect(try await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .reconnectRequired) })
  #expect(model.applicationRoutingStatus.state == .reconnectRequired)

  model.websiteRoutingInput = "bad..example"
  model.addWebsiteRoutingRule()
  #expect(model.websiteRoutingStatus.state == .failed)
  #expect(model.websiteRoutingStatus.message?.contains("valid hostname") == true)

  model.refresh()
  #expect(await waitForHardeningCondition { model.coreVersion == applied.coreVersion })

  #expect(model.runtimeApplyStatus == .reconnectRequired)
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")
  #expect(model.applicationRoutingStatus.state == .reconnectRequired)
  #expect(model.applicationRoutingStatus.message == nil)
  #expect(model.websiteRoutingStatus.state == .failed)
  #expect(model.websiteRoutingStatus.message?.contains("valid hostname") == true)
  #expect(model.subscriptionStatus != DeferredRuntimeApplyPresentation.changesReadyToApply)
}

@Test @MainActor
func activeIPv6PolicyStaysAuthoritativeAcrossUnknownAndReconnect() async throws {
  let profile = ManagedProfile(
    name: "IPv6",
    payload: hardeningPayload("active.example.test")
  )
  let runtime = ControlledHelperResponses()
  let statuses = HelperStatusSequence([
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: true,
      message: "recovered"
    )
  ])
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: true
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { _, _ in await statuses.next() },
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: {
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        activeIPv6Enabled: false,
        runtimeOutcome: .applied,
        message: "confirmed"
      )
    }
  )

  model.setCoreEnabled(true)
  #expect((try await runtime.nextRequest()).ipv6Enabled == true)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: true,
      message: "active"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.activeIPv6Enabled == true)

  model.observedCoreState = .unknown
  model.setIPv6Enabled(false)
  #expect(model.activeIPv6Enabled == nil)
  #expect(model.ipv6PolicyDescription.contains("unknown"))
  #expect(await runtime.pendingCount() == 0)

  model.refresh()
  let recoveryRequest = try await runtime.nextRequest()
  #expect(recoveryRequest.action == .start)
  #expect(recoveryRequest.ipv6Enabled == false)
  #expect(model.activeIPv6Enabled == true)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: true,
      runtimeOutcome: .reconnectRequired,
      message: "Changes ready to apply"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.runtimeApplyStatus == .reconnectRequired)
  #expect(model.activeIPv6Enabled == true)
  #expect(model.ipv6PolicyDescription.contains("still enabled"))

  model.reconnectToApply()
  #expect((try await runtime.nextRequest()).action == .stop)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      activeIPv6Enabled: nil,
      message: "stopped"
    )
  )
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      runtimeOutcome: .applied,
      message: "started"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.runtimeApplyStatus == .active && model.deferredRuntimeApplyPresentation == nil
    }
  )
  #expect(model.activeIPv6Enabled == false)
  #expect(model.runtimeApplyStatus == .active)
  #expect(model.deferredRuntimeApplyPresentation == nil)
  #expect(model.ipv6PolicyDescription.contains("rejected"))
}

@Test @MainActor
func relaunchWithSavedIPv6OffConvergesToActiveOnWithoutRedundantSubmission() async throws {
  let profile = ManagedProfile(
    name: "Relaunch",
    payload: hardeningPayload("active.example.test")
  )
  let runtime = ControlledHelperResponses()
  let statuses = HelperStatusSequence([
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: true,
      message: "active"
    )
  ])
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: false
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { _, _ in await statuses.next() },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  let request = try await runtime.nextRequest()
  #expect(request.action == .start)
  #expect(request.ipv6Enabled == false)
  #expect(model.activeIPv6Enabled == true)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "active"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.activeIPv6Enabled == false)
  #expect(model.runtimeApplyStatus == .active)
}

@Test @MainActor
func matchingActiveIPv6PolicyNeedsNoApplyAndStoppedCoreDoesNotStart() async {
  let profile = ManagedProfile(
    name: "Matching",
    payload: hardeningPayload("active.example.test")
  )
  let runtime = ControlledHelperResponses()
  let statuses = HelperStatusSequence([
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "matching-active-ipv6-status",
      activeProfileID: profile.id,
      activeIPv6Enabled: true,
      message: "active"
    )
  ])
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: true
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { _, _ in await statuses.next() },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  #expect(await waitForHardeningCondition { model.coreVersion == "matching-active-ipv6-status" })
  #expect(model.activeIPv6Enabled == true)
  #expect(await runtime.pendingCount() == 0)

  model.observedCoreState = .stopped
  model.setIPv6Enabled(false)
  #expect(await runtime.pendingCount() == 0)
  #expect(model.activeIPv6Enabled == nil)
}

@Test @MainActor
func runningLegacyCoreReceivesOneFullSnapshotAndPublishesKnownIPv6Policy() async throws {
  let profile = ManagedProfile(
    name: "Legacy IPv6",
    payload: hardeningPayload("legacy.example.test")
  )
  let runtime = ControlledHelperResponses()
  let statuses = HelperStatusSequence([
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: nil,
      message: "legacy active policy unknown"
    ),
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "legacy-active-ipv6-status",
      activeProfileID: profile.id,
      activeIPv6Enabled: true,
      message: "active"
    ),
  ])
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profile], selectedProfileID: profile.id, ipv6Enabled: true
    ),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { _, _ in await statuses.next() },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  let request = try await runtime.nextRequest()
  #expect(request.action == .start)
  #expect(request.profile != nil)
  #expect(request.ipv6Enabled == true)
  #expect(model.activeIPv6Enabled == nil)
  #expect(model.ipv6PolicyDescription.contains("reconciling"))

  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: true,
      message: "active"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.activeIPv6Enabled == true)

  model.refresh()
  #expect(await waitForHardeningCondition { model.coreVersion == "legacy-active-ipv6-status" })
  #expect(await runtime.pendingCount() == 0)
  #expect(model.activeIPv6Enabled == true)
}

@Test @MainActor
func runningLegacyCoreKeepsUnknownPolicyUntilExplicitReconnect() async throws {
  let profile = ManagedProfile(
    name: "Legacy reconnect",
    payload: hardeningPayload("legacy-reconnect.example.test")
  )
  let runtime = ControlledHelperResponses()
  let statuses = HelperStatusSequence([
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: nil,
      message: "legacy active policy unknown"
    ),
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "legacy-unknown-policy-status",
      activeProfileID: profile.id,
      activeIPv6Enabled: nil,
      runtimeOutcome: .reconnectRequired,
      message: "legacy active policy unknown"
    ),
  ])
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { _, _ in await statuses.next() },
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: {
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        activeIPv6Enabled: true,
        runtimeOutcome: .applied,
        message: "confirmed"
      )
    }
  )

  model.refresh()
  #expect(try await waitForRuntimeRequest(runtime))
  guard await runtime.pendingCount() > 0 else { return }
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: nil,
      runtimeOutcome: .reconnectRequired,
      message: "Changes ready to apply"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.runtimeApplyStatus == .reconnectRequired)
  #expect(model.activeIPv6Enabled == nil)
  #expect(model.ipv6PolicyDescription.contains("reconciling"))

  model.refresh()
  #expect(
    await waitForHardeningCondition { model.coreVersion == "legacy-unknown-policy-status" }
  )
  #expect(await runtime.pendingCount() == 0)

  model.reconnectToApply()
  #expect(try await waitForRuntimeRequest(runtime))
  guard await runtime.pendingCount() > 0 else { return }
  #expect((try await runtime.nextRequest()).action == .stop)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, activeIPv6Enabled: nil, message: "stopped")
  )
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: true,
      runtimeOutcome: .applied,
      message: "started"
    )
  )
  #expect(await waitForHardeningCondition { model.runtimeApplyStatus == .active })
  #expect(model.activeIPv6Enabled == true)
  #expect(model.runtimeApplyStatus == .active)
}

@Test @MainActor
func autoSelectionToggleQueueComposesByIDAndValidatesBeforeEachPersistence() async throws {
  let firstID = ProxyNodeID(rawValue: "node-first")
  let secondID = ProxyNodeID(rawValue: "node-second")
  let firstSourceID = UUID()
  let secondSourceID = UUID()
  let originalProfile = ManagedProfile(
    name: "Queued",
    payload: .compatibility(
      VPNProfile(
        connections: [
          ManagedConnection(
            id: firstID, outbound: hardeningConnection("first.example.test").outbound),
          ManagedConnection(
            id: secondID, outbound: hardeningConnection("second.example.test").outbound),
        ],
        nodeGroups: [
          ProxyNodeGroup(id: firstSourceID.uuidString, name: "First", nodes: [firstID]),
          ProxyNodeGroup(id: secondSourceID.uuidString, name: "Second", nodes: [secondID]),
        ],
        autoExcludedNodeIDs: [firstID]
      )
    )
  )
  let originalLibrary = ProfileLibrary(
    profiles: [originalProfile], selectedProfileID: originalProfile.id)
  let profile = try JSONDecoder().decode(
    ProfileLibrary.self, from: JSONEncoder().encode(originalLibrary)
  ).profiles[0]
  let events = AutoSelectionMutationEventLog()
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    validator: { payload in
      let count: Int
      if case .compatibility(let profile) = payload {
        count = profile.autoExcludedNodeIDs.count
      } else {
        count = -1
      }
      events.append("validate:\(count)")
      return HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    saver: { library in
      let savedLibrary = try? JSONDecoder().decode(
        ProfileLibrary.self, from: JSONEncoder().encode(library)
      )
      let savedProfile = savedLibrary?.profiles.first.flatMap { managedProfile -> VPNProfile? in
        guard case .compatibility(let vpnProfile) = managedProfile.payload else { return nil }
        return vpnProfile
      }
      let ids =
        savedProfile?.autoExcludedNodeIDs.map(\.rawValue).sorted().joined(separator: ",")
        ?? "invalid"
      events.append("save:\(savedProfile?.autoExcludedNodeIDs.count ?? -1):\(ids)")
    }
  )

  model.setNodeIncludedInAuto(
    firstID, included: false, profileID: profile.id, sourceID: firstSourceID
  )
  model.setNodeIncludedInAuto(
    secondID, included: false, profileID: profile.id, sourceID: secondSourceID
  )
  #expect(
    await waitForHardeningCondition {
      model.autoSelectionExcludedNodeIDs == Set([firstID, secondID])
        && events.snapshot().count == 4
    }
  )
  #expect(model.autoSelectionExcludedNodeIDs == Set([firstID, secondID]))
  #expect(
    events.snapshot() == [
      "validate:1", "save:1:node-first", "validate:2", "save:2:node-first,node-second",
    ]
  )
}

@Test @MainActor
func autoSelectionRejectsNodeOutsideCapturedSourceGroup() async {
  let nodeID = ProxyNodeID(rawValue: "node-first-source")
  let firstSourceID = UUID()
  let secondSourceID = UUID()
  let profile = ManagedProfile(
    name: "Source scoped",
    payload: .compatibility(
      VPNProfile(
        connections: [
          ManagedConnection(
            id: nodeID, outbound: hardeningConnection("first.example.test").outbound)
        ],
        nodeGroups: [
          ProxyNodeGroup(id: firstSourceID.uuidString, name: "First", nodes: [nodeID]),
          ProxyNodeGroup(id: secondSourceID.uuidString, name: "Second", nodes: []),
        ]
      )
    )
  )
  let events = AutoSelectionMutationEventLog()
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    saver: { _ in events.append("save") }
  )

  model.setNodeIncludedInAuto(
    nodeID, included: false, profileID: profile.id, sourceID: secondSourceID
  )
  #expect(await waitForHardeningCondition { model.autoSelectionStatus.state == .failed })
  #expect(model.autoSelectionExcludedNodeIDs.isEmpty)
  #expect(events.snapshot().isEmpty)
}

@Test @MainActor
func connectedAutoExclusionRetainsReconnectToApplyWithoutSendingStop() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let nodeID = ProxyNodeID(rawValue: "node-excluded")
  let sourceID = UUID()
  let profile = ManagedProfile(
    name: "Connected",
    payload: .compatibility(
      VPNProfile(
        connections: [
          ManagedConnection(
            id: nodeID,
            outbound: hardeningConnection("connected.example.test").outbound
          )
        ],
        nodeGroups: [ProxyNodeGroup(id: sourceID.uuidString, name: "Source", nodes: [nodeID])]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.refresh()
  #expect((try await status.nextRequest()).action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: "connected-auto-exclusion-status",
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "active"
    )
  )
  #expect(
    await waitForHardeningCondition { model.coreVersion == "connected-auto-exclusion-status" }
  )

  model.setNodeIncludedInAuto(
    nodeID, included: false, profileID: profile.id, sourceID: sourceID
  )
  let applyRequest = try await runtime.nextRequest()
  #expect(applyRequest.action == .start)
  guard case .compatibility(let candidate)? = applyRequest.profile else {
    Issue.record("Auto exclusion must submit the validated complete profile.")
    return
  }
  #expect(candidate.autoExcludedNodeIDs == [nodeID])
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      runtimeOutcome: .reconnectRequired,
      message: "Changes ready to apply"
    )
  )
  #expect(await waitForHardeningCondition { model.runtimeApplyStatus == .reconnectRequired })
  #expect(model.autoSelectionExcludedNodeIDs == Set([nodeID]))
  #expect(model.runtimeApplyStatus == .reconnectRequired)
  #expect(model.deferredRuntimeApplyPresentation != nil)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func autoSelectionControlsUseDesiredProfileWhileExcludedNodeRemainsManuallySelectable() {
  let desiredID = ProxyNodeID(rawValue: "node-desired")
  let staleRuntimeID = ProxyNodeID(rawValue: "node-stale")
  let profile = ManagedProfile(
    name: "Desired",
    payload: .compatibility(
      VPNProfile(
        connections: [
          ManagedConnection(
            id: desiredID, outbound: hardeningConnection("desired.example.test").outbound)
        ],
        autoExcludedNodeIDs: [desiredID]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  )
  model.nodes = [
    ProxyNode(
      id: staleRuntimeID, name: "Stale runtime", groupID: nil,
      groupName: nil, groupOrder: nil, nodeOrder: nil, delay: nil
    )
  ]

  #expect(model.autoSelectionSections.flatMap(\.nodes).map(\.id) == [desiredID])
  model.nodes.append(
    ProxyNode(
      id: desiredID, name: "Excluded server", groupID: nil,
      groupName: nil, groupOrder: nil, nodeOrder: nil, delay: nil
    )
  )
  #expect(model.nodeSections.flatMap(\.nodes).contains(where: { $0.id == desiredID }))
  model.setSelectedNode(desiredID)
  #expect(model.selectedNodeID == desiredID)
  #expect(model.autoSelectionAllExcluded)
}

@Test @MainActor
func genericLatencySendFailureKeepsNewerRunningObservation() async throws {
  let generic = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperRequestSender: { request in try await generic.send(request) }
  )
  model.latencyTestURLDraft = "https://latency.example.test/check"
  #expect(model.applyLatencySettings())
  #expect((try await generic.nextRequest()).action == .setLatencyTarget)

  model.setCoreEnabled(true)
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus == .applying) })
  #expect(model.observedCoreState == .running)
  #expect(model.helperReachable)

  await generic.failNext(
    NSError(
      domain: "GenericLatencyTest",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "older generic request failed"]
    ))
  #expect(await waitForHardeningCondition { !(model.latencyApplyInProgress) })

  #expect(model.observedCoreState == .running)
  #expect(model.helperReachable)
  #expect(model.latencySettingsError?.contains("older generic request failed") == true)
}

@Test @MainActor
func latencyTargetSynchronizationResendsLatestPersistedTargetAfterStaleFailure() async throws {
  let helper = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperRequestSender: { request in try await helper.send(request) }
  )
  let targetA = try LatencyTargetPolicy.normalized("https://a.example.test/check")
  let targetB = try LatencyTargetPolicy.normalized("https://b.example.test/check")

  model.latencyTestURLDraft = targetA
  #expect(model.applyLatencySettings())
  let requestA = try await helper.nextRequest()
  #expect(requestA.latencyTestURL == targetA)

  model.latencyTestURLDraft = targetB
  #expect(model.applyLatencySettings())
  await helper.failNext(
    NSError(
      domain: "LatencyTargetTest",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "stale A failure"]
    ))
  let requestB = try await helper.nextRequest()
  #expect(requestB.latencyTestURL == targetB)

  await helper.failNext(
    NSError(
      domain: "LatencyTargetTest",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "current B failure"]
    ))
  #expect(await waitForHardeningCondition { !(model.latencyApplyInProgress) })
  #expect(!model.latencyApplyInProgress)
  #expect(model.lastError?.contains("current B failure") == true)
  #expect(model.lastError?.contains("stale A failure") == false)
  #expect(model.latencySettingsError?.contains("current B failure") == true)
  #expect(model.latencySettingsError?.contains("stale A failure") == false)
}

@Test @MainActor
func latencySnapshotAdmittedDuringStartCannotReplaceCompletedStart() async throws {
  let helper = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperRequestSender: { request in try await helper.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.observedCoreState = .stopped
  model.setCoreEnabled(true)
  guard let start = try await nextHelperRequest(runtime) else {
    Issue.record("Start was not submitted.")
    return
  }
  #expect(start.action == .start)

  model.latencyTestURLDraft = try LatencyTargetPolicy.normalized(
    "https://latency.example.test/check"
  )
  #expect(model.applyLatencySettings())
  guard let latency = try await nextHelperRequest(helper) else {
    Issue.record("Latency target was not admitted while Start was pending.")
    await runtime.completeNext(
      HelperResponse(
        success: true, coreRunning: true, activeProfileID: profile.id, message: "started")
    )
    return
  }
  #expect(latency.action == .setLatencyTarget)

  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profile.id, message: "started")
  )
  #expect(
    await waitForHardeningCondition { model.coreRunning && model.runtimeApplyStatus == .active })
  await helper.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "older stopped snapshot")
  )
  #expect(await waitForHardeningCondition { !model.latencyApplyInProgress })
  #expect(model.coreRunning)
  #expect(model.observedCoreState == .running)
  #expect(model.latencySettingsError == nil)

  var quitResult: Bool?
  let quit = Task { quitResult = await model.disconnectBeforeQuit() }
  let shutdownSubmitted = try await waitForSubmittedRuntimeRequest(runtime)
  #expect(shutdownSubmitted, "Quit must submit Shutdown after the older stopped snapshot.")
  guard shutdownSubmitted else {
    #expect(await waitForHardeningCondition { quitResult != nil })
    return
  }
  let shutdown = try await runtime.nextRequest()
  #expect(shutdown.action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "durable OFF")
  )
  #expect(await waitForHardeningCondition { quitResult != nil })
  #expect(quitResult == true)
  _ = await quit.value
}

@Test @MainActor
func latencySnapshotDeliveredDuringStartCannotPublishBeforeStartCompletes() async throws {
  let helper = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperRequestSender: { request in try await helper.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.observedCoreState = .stopped
  model.setCoreEnabled(true)
  guard let start = try await nextHelperRequest(runtime) else {
    Issue.record("Start was not submitted.")
    return
  }
  #expect(start.action == .start)
  model.latencyTestURLDraft = try LatencyTargetPolicy.normalized(
    "https://latency.example.test/check"
  )
  #expect(model.applyLatencySettings())
  guard let latency = try await nextHelperRequest(helper) else {
    Issue.record("Latency target was not admitted while Start was pending.")
    await runtime.completeNext(
      HelperResponse(
        success: true, coreRunning: true, activeProfileID: profile.id, message: "started")
    )
    return
  }
  #expect(latency.action == .setLatencyTarget)

  await helper.completeNext(
    HelperResponse(success: true, coreRunning: true, message: "early running snapshot")
  )
  #expect(await waitForHardeningCondition { !model.latencyApplyInProgress })
  #expect(model.observedCoreState == .stopped)
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profile.id, message: "started")
  )
  #expect(
    await waitForHardeningCondition { model.coreRunning && model.runtimeApplyStatus == .active })

  let quit = Task { await model.disconnectBeforeQuit() }
  guard try await waitForSubmittedRuntimeRequest(runtime) else {
    Issue.record("Quit did not submit Shutdown after the completed Start.")
    return
  }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "durable OFF")
  )
  #expect(await quit.value)
}

@Test @MainActor
func latencySnapshotAdmittedDuringStopCannotResurrectStoppedCore() async throws {
  let helper = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperRequestSender: { request in try await helper.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .running

  model.setCoreEnabled(false)
  guard let stop = try await nextHelperRequest(runtime) else {
    Issue.record("Stop was not submitted.")
    return
  }
  #expect(stop.action == .stop)
  model.latencyTestURLDraft = try LatencyTargetPolicy.normalized(
    "https://latency.example.test/check"
  )
  #expect(model.applyLatencySettings())
  guard let latency = try await nextHelperRequest(helper) else {
    Issue.record("Latency target was not admitted while Stop was pending.")
    await runtime.completeNext(
      HelperResponse(success: true, coreRunning: false, message: "stopped")
    )
    return
  }
  #expect(latency.action == .setLatencyTarget)

  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "durable OFF")
  )
  #expect(await waitForRuntimeApplyStatus(model, .saved))
  await helper.completeNext(
    HelperResponse(success: false, coreRunning: true, message: "latency target rejected")
  )
  #expect(await waitForHardeningCondition { !model.latencyApplyInProgress })
  #expect(model.observedCoreState == .stopped)
  #expect(model.latencySettingsError?.contains("latency target rejected") == true)

  var quitResult: Bool?
  let quit = Task { quitResult = await model.disconnectBeforeQuit() }
  guard try await waitForSubmittedRuntimeRequest(runtime) else {
    Issue.record("Quit did not submit terminal Shutdown after the successful Stop.")
    return
  }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "durable OFF")
  )
  #expect(await waitForHardeningCondition { quitResult != nil })
  #expect(quitResult == true)
  _ = await quit.value
}

@Test @MainActor
func latencySnapshotAdmittedBeforeNewRuntimeGenerationRemainsStale() async throws {
  let helper = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperRequestSender: { request in try await helper.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .stopped

  model.latencyTestURLDraft = try LatencyTargetPolicy.normalized(
    "https://latency.example.test/check"
  )
  #expect(model.applyLatencySettings())
  guard let latency = try await nextHelperRequest(helper) else {
    Issue.record("Latency target was not admitted.")
    return
  }
  #expect(latency.action == .setLatencyTarget)
  model.setCoreEnabled(true)
  guard let start = try await nextHelperRequest(runtime) else {
    Issue.record("Start was not submitted after latency admission.")
    await helper.completeNext(
      HelperResponse(success: true, coreRunning: false, message: "stopped")
    )
    return
  }
  #expect(start.action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profile.id, message: "started")
  )
  #expect(
    await waitForHardeningCondition { model.coreRunning && model.runtimeApplyStatus == .active })
  await helper.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "superseded stopped snapshot")
  )
  #expect(await waitForHardeningCondition { !model.latencyApplyInProgress })
  #expect(model.observedCoreState == .running)

  let quit = Task { await model.disconnectBeforeQuit() }
  guard try await waitForSubmittedRuntimeRequest(runtime) else {
    Issue.record("Quit did not submit Shutdown after Start.")
    return
  }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "durable OFF")
  )
  #expect(await quit.value)
}

@Test @MainActor
func currentIdleLatencyResponseMayPublishRuntimeObservation() async throws {
  let helper = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperRequestSender: { request in try await helper.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .stopped
  model.latencyTestURLDraft = try LatencyTargetPolicy.normalized(
    "https://latency.example.test/check"
  )
  #expect(model.applyLatencySettings())

  guard let latency = try await nextHelperRequest(helper) else {
    Issue.record("Latency target was not admitted while runtime was idle.")
    return
  }
  #expect(latency.action == .setLatencyTarget)
  await helper.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      activeIPv6Enabled: false,
      message: "current runtime snapshot"
    )
  )
  #expect(await waitForHardeningCondition { model.coreRunning && !model.latencyApplyInProgress })
  #expect(model.observedCoreState == .running)
  #expect(model.latencySettingsError == nil)

  let quit = Task { await model.disconnectBeforeQuit() }
  guard try await waitForSubmittedRuntimeRequest(runtime) else {
    Issue.record("Quit did not submit Shutdown after the current runtime observation.")
    return
  }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "durable OFF")
  )
  #expect(await quit.value)
}

@Test @MainActor
func quitWaitsForInFlightStartAndFencesItBeforeProvenShutdown() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    helperRegistrationState: .notRegistered
  )
  model.observedCoreState = .stopped
  model.setCoreEnabled(true)
  #expect((try await runtime.nextRequest()).action == .start)
  model.observedCoreState = .stopped

  var quitReturned = false
  let quit = Task {
    let result = await model.disconnectBeforeQuit()
    quitReturned = true
    return result
  }
  #expect(await runtime.pendingCount() == 1)
  #expect(!quitReturned)

  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "in-flight start completed"
    )
  )
  #expect((try await runtime.nextRequest()).action == .shutdown)
  #expect(!quitReturned)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await quit.value)
  #expect(quitReturned)
}

@MainActor
private func beginHeldReconnectConfirmation(
  runtime: ControlledHelperResponses,
  status: ControlledHelperResponses
) async throws -> (model: AppModel, profileID: UUID) {
  let profile = ManagedProfile(name: "Reconnect", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    runtimeStateReader: { try await status.send(HelperRequest(action: .status)) }
  )

  model.coreRunning = true
  model.setIPv6Enabled(true)
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      runtimeOutcome: .reconnectRequired,
      message: "deferred"
    )
  )
  #expect(await waitForHardeningCondition { !(model.runtimeApplyStatus != .reconnectRequired) })

  model.reconnectToApply()
  #expect((try await runtime.nextRequest()).action == .stop)
  await runtime.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      runtimeOutcome: .applied,
      message: "started"
    )
  )
  #expect((try await status.nextRequest()).action == .status)
  return (model, profile.id)
}

@Test @MainActor
func c13ReconnectConfirmationIsOwnedAndDrainedByQuit() async throws {
  let runtime = ControlledHelperResponses()
  let status = ControlledHelperResponses()
  let (model, profileID) = try await beginHeldReconnectConfirmation(
    runtime: runtime, status: status)
  var quitReturned = false
  let quit = Task {
    let result = await model.disconnectBeforeQuit()
    quitReturned = true
    return result
  }

  #expect(await status.waitForCancellation())
  #expect(!quitReturned)
  #expect(await runtime.pendingCount() == 0)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .applied,
      message: "late confirmation"
    )
  )
  #expect((try await runtime.nextRequest()).action == .shutdown)
  #expect(model.deferredRuntimeApplyPhase == .reconnecting)
  await runtime.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))

  #expect(await quit.value)
  #expect(quitReturned)
  #expect(model.deferredRuntimeApplyPhase == .reconnecting)
  #expect(await status.pendingCount() == 0)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func c14RefusedQuitLeavesCanceledReconnectConfirmationRetryable() async throws {
  let runtime = ControlledHelperResponses()
  let status = ControlledHelperResponses()
  let (model, profileID) = try await beginHeldReconnectConfirmation(
    runtime: runtime, status: status)
  let quit = Task { await model.disconnectBeforeQuit() }

  #expect(await status.waitForCancellation())
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .applied,
      message: "canceled confirmation"
    )
  )
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: false, coreRunning: true, message: "shutdown refused")
  )

  #expect(!(await quit.value))
  #expect(model.deferredRuntimeApplyPhase == .pending)
  #expect(model.runtimeApplyStatus == .reconnectRequired)
  #expect(model.deferredRuntimeApplyPresentation != nil)
  #expect(await status.pendingCount() == 0)

  model.reconnectToApply()
  #expect((try await runtime.nextRequest()).action == .stop)
  await runtime.completeNext(HelperResponse(success: true, coreRunning: false, message: "stopped"))
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .applied,
      message: "reconnected"
    )
  )
  #expect((try await status.nextRequest()).action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .applied,
      message: "confirmed retry"
    )
  )
  #expect(await waitForHardeningCondition { !(model.deferredRuntimeApplyPhase != .idle) })
  #expect(model.deferredRuntimeApplyPhase == .idle)
}

@Test @MainActor
func c15QuitDrainsLatencySyncBeforeTerminalShutdownAndFencesLatestTarget() async throws {
  let runtime = ControlledHelperResponses()
  let helper = ControlledHelperResponses()
  let profile = ManagedProfile(name: "Latency", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperRequestSender: { request in try await helper.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  let targetA = try LatencyTargetPolicy.normalized("https://a.example.test/check")
  let targetB = try LatencyTargetPolicy.normalized("https://b.example.test/check")
  model.observedCoreState = .stopped
  model.latencyTestURLDraft = targetA
  #expect(model.applyLatencySettings())
  #expect((try await helper.nextRequest()).action == .setLatencyTarget)

  var quitReturned = false
  let quit = Task {
    let result = await model.disconnectBeforeQuit()
    quitReturned = true
    return result
  }
  #expect(await helper.waitForCancellation())
  #expect(!quitReturned)
  #expect(await runtime.pendingCount() == 0)

  model.latencyTestURLDraft = targetB
  #expect(model.applyLatencySettings())
  #expect(model.latencyTestURL == targetB)
  model.retryLatencySynchronization()
  #expect(await helper.pendingCount() == 1)
  #expect(!quitReturned)

  await helper.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "target A completed")
  )
  guard try await waitForSubmittedRuntimeRequest(runtime) else {
    Issue.record("Quit did not submit terminal Shutdown after draining latency sync.")
    quit.cancel()
    _ = await quit.value
    return
  }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "terminal OFF")
  )
  #expect(await quit.value)
  #expect(quitReturned)
  #expect(!model.latencyApplyInProgress)
  #expect(model.canRetryLatencySynchronization)
  let pendingIssue = model.latencySettingsError
  #expect(pendingIssue != nil)
  #expect(await helper.pendingCount() == 0)
  #expect(await runtime.pendingCount() == 0)
  #expect(model.latencySettingsError == pendingIssue)
}

@Test @MainActor
func c16RefusedQuitLeavesCanceledLatencySyncRetryableWithoutResurrection() async throws {
  let runtime = ControlledHelperResponses()
  let helper = ControlledHelperResponses()
  let profile = ManagedProfile(name: "Latency", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperRequestSender: { request in try await helper.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  let target = try LatencyTargetPolicy.normalized("https://a.example.test/check")
  model.observedCoreState = .running
  model.latencyTestURLDraft = target
  #expect(model.applyLatencySettings())
  #expect((try await helper.nextRequest()).action == .setLatencyTarget)

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await helper.waitForCancellation())
  #expect(await runtime.pendingCount() == 0)
  await helper.completeNext(
    HelperResponse(success: true, coreRunning: true, message: "target completed")
  )
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: false, coreRunning: true, message: "shutdown refused")
  )

  #expect(!(await quit.value))
  #expect(model.latencyTestURL == target)
  #expect(model.canRetryLatencySynchronization)
  #expect(model.latencySettingsError != nil)
  #expect(!model.latencyApplyInProgress)
  #expect(await helper.pendingCount() == 0)

  model.retryLatencySynchronization()
  let retry = try await helper.nextRequest()
  #expect(retry.action == .setLatencyTarget)
  #expect(retry.latencyTestURL == target)
  #expect(await helper.pendingCount() == 1)
  await helper.completeNext(
    HelperResponse(success: true, coreRunning: true, message: "retry synchronized")
  )
  #expect(await waitForHardeningCondition { !(model.latencyApplyInProgress) })
  #expect(!model.latencyApplyInProgress)
  #expect(!model.canRetryLatencySynchronization)
  #expect(await helper.pendingCount() == 0)
}

@Test @MainActor
func repairRejectsNoncanonicalBundleBeforeNativeWithdrawal() async throws {
  let runtime = ControlledHelperResponses()
  let service = ReadyHelperService(registrationState: .enabled)
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    helperService: service,
    applicationBundleURL: URL(fileURLWithPath: "/private/tmp/SBMTests/NotCanonical.app"),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .running

  model.repairHelper()
  #expect(!model.helperSetupInProgress)
  #expect(service.unregistrationCount == 0)
  #expect(service.registrationCount == 0)
  #expect(model.lastError?.contains("Move SBM.app") == true)

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "durable OFF")
  )
  #expect(await quit.value)
}

@Test(
  .enabled(installedLegacyBundleSkipReason) {
    await MainActor.run { canonicalInstalledBundleHasLegacyTombstone() }
  }
)
@MainActor
func failedLegacyFinishKeepsQuitBlockedForEnableAndInertRepair() async throws {
  for repair in [false, true] {
    let status = ControlledHelperResponses()
    let runtime = RuntimeActionRecorder(
      shutdownResponse: HelperResponse(
        success: false,
        coreRunning: false,
        legacy1115Retired: true,
        message: "Shutdown failed"
      )
    )
    let service = ReadyHelperService(registrationState: .enabled)
    service.legacyRegistrationState = .enabled
    let model = hardeningModel(
      library: .empty,
      helperService: service,
      applicationBundleURL: canonicalLegacyUpgradeBundleURL,
      lifecycleSender: { request, _ in try await status.send(request) },
      runtimeSender: { request in await runtime.send(request) }
    )
    let inert = HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: false,
      message: "authenticated inert helper"
    )

    if repair {
      model.repairHelper()
      #expect(try await status.nextRequest().action == .status)
      await status.completeNext(inert)
    } else {
      model.enableHelper()
    }

    #expect(try await status.nextRequest().action == .status)
    await status.completeNext(inert)
    #expect(try await status.nextRequest().action == .finishLegacy1115Upgrade)
    service.registrationState = .notFound
    await status.failNext(URLError(.timedOut))
    #expect(await waitForHardeningCondition { !model.helperSetupInProgress })
    #expect(service.legacyRegistrationState == .notRegistered)

    #expect(!(await model.disconnectBeforeQuit()))
    #expect(await runtime.recordedActions() == [.shutdown])
    #expect(!(await model.disconnectBeforeQuit()))
    #expect(await runtime.recordedActions() == [.shutdown, .shutdown])
  }
}

@Test(
  .enabled(installedLegacyBundleSkipReason) {
    await MainActor.run { canonicalInstalledBundleHasLegacyTombstone() }
  }
)
@MainActor
func freshLegacyCompletionClearsQuitBarrier() async throws {
  let status = ControlledHelperResponses()
  let runtime = RuntimeActionRecorder()
  let service = ReadyHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let model = hardeningModel(
    library: .empty,
    helperService: service,
    applicationBundleURL: canonicalLegacyUpgradeBundleURL,
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in await runtime.send(request) }
  )

  model.enableHelper()
  #expect(try await status.nextRequest().action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: false,
      message: "authenticated inert helper"
    )
  )
  #expect(try await status.nextRequest().action == .finishLegacy1115Upgrade)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: true,
      message: "fresh terminal OFF proof"
    )
  )

  #expect(await waitForHardeningCondition { !model.helperSetupInProgress })
  service.registrationState = .notFound
  #expect(await model.disconnectBeforeQuit())
  #expect(await runtime.recordedActions().isEmpty)
}

@Test @MainActor
func historicalLegacyCompletionDoesNotLeaveQuitBlocked() async throws {
  let status = ControlledHelperResponses()
  let runtime = RuntimeActionRecorder()
  let service = ReadyHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .notRegistered
  let model = hardeningModel(
    library: .empty,
    helperService: service,
    applicationBundleURL: canonicalLegacyUpgradeBundleURL,
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in await runtime.send(request) }
  )

  model.enableHelper()
  #expect(try await status.nextRequest().action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: true,
      message: "historical retirement receipt"
    )
  )

  #expect(await waitForHardeningCondition { !model.helperSetupInProgress })
  service.registrationState = .notFound
  #expect(await model.disconnectBeforeQuit())
  #expect(await runtime.recordedActions().isEmpty)
}

@Test @MainActor
func quitCancelsLegacyUpgradeBeforeInertProofWithoutWithdrawal() async throws {
  let status = ControlledHelperResponses()
  let runtime = RuntimeActionRecorder(
    shutdownResponse: HelperResponse(
      success: false,
      coreRunning: false,
      legacy1115Retired: true,
      message: "Shutdown failed"
    )
  )
  let service = ReadyHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let model = hardeningModel(
    library: .empty,
    helperService: service,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in await runtime.send(request) }
  )

  model.enableHelper()
  #expect(try await status.nextRequest().action == .status)
  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await status.waitForCancellation())
  await status.failNext(CancellationError())

  #expect(!(await quit.value))
  #expect(service.legacyRegistrationState == .enabled)
  #expect(await status.pendingCount() == 0)
  #expect(await runtime.recordedActions() == [.shutdown])
}

@Test(
  .enabled(installedLegacyBundleSkipReason) {
    await MainActor.run { canonicalInstalledBundleHasLegacyTombstone() }
  }
)
@MainActor
func quitDrainsCancelledLegacyFinishWithoutClearingProofOrStartingRuntime() async throws {
  let status = ControlledHelperResponses()
  let runtime = RuntimeActionRecorder(
    shutdownResponse: HelperResponse(
      success: false,
      coreRunning: false,
      legacy1115Retired: true,
      message: "Shutdown failed"
    )
  )
  let service = ReadyHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let model = hardeningModel(
    library: .empty,
    helperService: service,
    applicationBundleURL: canonicalLegacyUpgradeBundleURL,
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in await runtime.send(request) }
  )

  model.enableHelper()
  #expect(try await status.nextRequest().action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: false,
      message: "authenticated inert helper"
    )
  )
  #expect(try await status.nextRequest().action == .finishLegacy1115Upgrade)
  #expect(service.legacyRegistrationState == .notRegistered)
  service.registrationState = .notFound

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await status.waitForCancellation())
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: true,
      message: "late Finish response"
    )
  )

  #expect(!(await quit.value))
  #expect(await runtime.recordedActions() == [.shutdown])
}

@Test(
  .enabled(installedLegacyBundleSkipReason) {
    await MainActor.run { canonicalInstalledBundleHasLegacyTombstone() }
  }
)
@MainActor
func lateLegacyFinishCannotClearNewerFailedStopProof() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let service = ReadyHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let model = hardeningModel(
    library: .empty,
    helperService: service,
    applicationBundleURL: canonicalLegacyUpgradeBundleURL,
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.enableHelper()
  #expect(try await status.nextRequest().action == .status)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: false,
      message: "authenticated inert helper"
    )
  )
  #expect(try await status.nextRequest().action == .finishLegacy1115Upgrade)

  model.setCoreEnabled(false)
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: false,
      legacy1115Retired: true,
      message: "newer Stop failed"
    )
  )
  #expect(await waitForHardeningCondition { model.runtimeApplyStatus == .failed })
  service.registrationState = .notFound
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: true,
      message: "stale Finish response"
    )
  )
  #expect(await waitForHardeningCondition { !model.helperSetupInProgress })

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(try await runtime.nextRequest().action == .shutdown)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: false,
      legacy1115Retired: true,
      message: "Shutdown failed"
    )
  )
  #expect(!(await quit.value))
}

@Test @MainActor
func staleInertRepairStatusCannotWithdrawLegacyRegistration() async throws {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let service = ReadyHelperService(registrationState: .enabled)
  service.legacyRegistrationState = .enabled
  let model = hardeningModel(
    library: .empty,
    helperService: service,
    applicationBundleURL: URL(fileURLWithPath: "/Applications/SBM.app"),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.repairHelper()
  #expect(try await status.nextRequest().action == .status)
  model.setCoreEnabled(false)
  #expect(try await runtime.nextRequest().action == .stop)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: false,
      legacy1115Retired: true,
      message: "newer Stop failed"
    )
  )
  #expect(await waitForHardeningCondition { model.runtimeApplyStatus == .failed })

  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      legacy1115Retired: false,
      message: "stale inert preflight"
    )
  )
  #expect(await waitForHardeningCondition { !model.helperSetupInProgress })
  #expect(service.legacyRegistrationState == .enabled)
  #expect(await status.pendingCount() == 0)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func registeredStoppedQuitStillRequestsTerminalShutdown() async throws {
  let runtime = ControlledHelperResponses()
  let service = ReadyHelperService(registrationState: .enabled)
  let model = hardeningModel(
    library: .empty,
    helperService: service,
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.helperRevision = HelperConstants.helperRevision
  model.observedCoreState = .stopped

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "terminal OFF")
  )
  #expect(await quit.value)
}

@Test @MainActor
func failedShutdownReportingStoppedRequiresAnotherShutdownBeforeQuit() async throws {
  let runtime = ControlledHelperResponses()
  let defaults = makeIsolatedHardeningDefaults()
  defer { defaults.defaults.removePersistentDomain(forName: defaults.suite) }
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults.defaults,
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .running

  let firstQuit = Task { await model.disconnectBeforeQuit() }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: false, coreRunning: false, message: "save failed after stop")
  )
  #expect(!(await firstQuit.value))
  #expect(model.observedCoreState == .stopped)

  let retryQuit = Task { await model.disconnectBeforeQuit() }
  let submittedRetry = try await waitForSubmittedRuntimeRequest(runtime)
  #expect(submittedRetry)
  guard submittedRetry else {
    #expect(!(await retryQuit.value))
    return
  }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "durable OFF saved")
  )
  #expect(await retryQuit.value)
}

@Test @MainActor
func lostShutdownResponseKeepsProofRequiredAfterStoppedObservation() async throws {
  let runtime = ControlledHelperResponses()
  let defaults = makeIsolatedHardeningDefaults()
  defer { defaults.defaults.removePersistentDomain(forName: defaults.suite) }
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults.defaults,
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .running

  let firstQuit = Task { await model.disconnectBeforeQuit() }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.failNext(URLError(.timedOut))
  #expect(!(await firstQuit.value))
  model.observedCoreState = .stopped

  let retryQuit = Task { await model.disconnectBeforeQuit() }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "retry saved OFF")
  )
  #expect(await retryQuit.value)
}

@Test @MainActor
func failedExplicitStopRequiresTerminalShutdownAndSuccessfulQuitDoesNotReviveWork() async throws {
  let runtime = ControlledHelperResponses()
  let defaults = makeIsolatedHardeningDefaults()
  defer { defaults.defaults.removePersistentDomain(forName: defaults.suite) }
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults.defaults,
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .running

  model.setCoreEnabled(false)
  #expect((try await runtime.nextRequest()).action == .stop)
  await runtime.completeNext(
    HelperResponse(success: false, coreRunning: false, message: "durable save failed")
  )
  #expect(await waitForRuntimeApplyStatus(model, .failed))

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "retry saved OFF")
  )
  #expect(await quit.value)

  model.setCoreEnabled(true)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func laterSuccessfulExplicitStopStillUsesTerminalShutdownOnQuit() async throws {
  let runtime = ControlledHelperResponses()
  let defaults = makeIsolatedHardeningDefaults()
  defer { defaults.defaults.removePersistentDomain(forName: defaults.suite) }
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults.defaults,
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .running

  model.setCoreEnabled(false)
  #expect((try await runtime.nextRequest()).action == .stop)
  await runtime.completeNext(
    HelperResponse(success: false, coreRunning: false, message: "first save failed")
  )
  #expect(await waitForRuntimeApplyStatus(model, .failed))

  model.setCoreEnabled(false)
  #expect((try await runtime.nextRequest()).action == .stop)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "retry saved OFF")
  )
  #expect(await waitForRuntimeApplyStatus(model, .saved))

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "terminal OFF")
  )
  #expect(await quit.value)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func unresolvedStopProofDisablesHelperAbsentQuitShortcut() async throws {
  let runtime = ControlledHelperResponses()
  let defaults = makeIsolatedHardeningDefaults()
  defer { defaults.defaults.removePersistentDomain(forName: defaults.suite) }
  let service = ReadyHelperService(registrationState: .enabled)
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults.defaults,
    helperService: service,
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .running

  model.setCoreEnabled(false)
  #expect((try await runtime.nextRequest()).action == .stop)
  await runtime.completeNext(
    HelperResponse(success: false, coreRunning: false, message: "save failed")
  )
  #expect(await waitForRuntimeApplyStatus(model, .failed))
  service.registrationState = .notFound

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.failNext(URLError(.cannotConnectToHost))
  #expect(!(await quit.value))
}

@Test @MainActor
func staleStopCompletionCannotClearUnresolvedDurableProof() async throws {
  let runtime = ControlledHelperResponses()
  let defaults = makeIsolatedHardeningDefaults()
  defer { defaults.defaults.removePersistentDomain(forName: defaults.suite) }
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    userDefaults: defaults.defaults,
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.observedCoreState = .running

  model.setCoreEnabled(false)
  #expect((try await runtime.nextRequest()).action == .stop)
  model.setCoreEnabled(true)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "superseded stop")
  )
  #expect((try await runtime.nextRequest()).action == .start)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "current start result")
  )
  #expect(await waitForRuntimeApplyStatus(model, .saved))
  #expect(model.observedCoreState == .stopped)

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect((try await runtime.nextRequest()).action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "fresh durable proof")
  )
  #expect(await quit.value)
}

@Test @MainActor
func manualSyncDoesNotPublishProfileAIntoEmptySelectedProfileB() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let runtime = ControlledHelperResponses()
  let url = "https://a.example.test/list"
  let source = ManagedSource(
    name: "A source", value: url, payload: hardeningPayload("old-a.example.test")
  )
  let profileA = ManagedProfile(
    name: "A", sources: [source], payload: hardeningPayload("old-a.example.test")
  )
  let profileB = ManagedProfile(name: "B", payload: nil)
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id
    ),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.saveAndSyncSubscription()
  #expect(try await fetcher.nextRequest() == url)
  model.selectProfile(profileB.id)
  let bStatus = model.subscriptionStatus
  let fresh = hardeningPayload("fresh-a.example.test")
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(profile: fresh, skippedTransports: [:])
  )
  #expect(await waitForHardeningCondition { !model.isSyncing })

  #expect(model.selectedProfileID == profileB.id)
  #expect(model.profiles.first(where: { $0.id == profileA.id })?.sources.first?.payload == fresh)
  #expect(model.profiles.first(where: { $0.id == profileA.id })?.payload != nil)
  #expect(model.profileAvailable == false)
  #expect(model.subscriptionStatus == bStatus)
  #expect(model.profileName == "B")
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func manualSyncDoesNotReplaceCachedSelectedProfileBPresentation() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let runtime = ControlledHelperResponses()
  let url = "https://a.example.test/list"
  let source = ManagedSource(
    name: "A source", value: url, payload: hardeningPayload("old-a.example.test")
  )
  let profileA = ManagedProfile(
    name: "A", sources: [source], payload: hardeningPayload("old-a.example.test")
  )
  let payloadB = hardeningPayload("b.example.test")
  let profileB = ManagedProfile(name: "B", payload: payloadB)
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id
    ),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.saveAndSyncSubscription()
  #expect(try await fetcher.nextRequest() == url)
  model.selectProfile(profileB.id)
  let bStatus = model.subscriptionStatus
  let bNodes = model.nodes.map(\.id)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:]
    )
  )
  #expect(await waitForHardeningCondition { !model.isSyncing })

  #expect(model.selectedProfileID == profileB.id)
  #expect(model.profileAvailable)
  #expect(model.subscriptionStatus == bStatus)
  #expect(model.nodes.map(\.id) == bNodes)
  #expect(model.profiles.first(where: { $0.id == profileA.id })?.payload != nil)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func manualSyncForSourceOneLeavesSelectedSourceTwoEditorAndStatusUntouched() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let sourceOneURL = "https://one.example.test/list"
  let sourceOne = ManagedSource(
    name: "One", value: sourceOneURL, payload: hardeningPayload("old-one.example.test")
  )
  let sourceTwo = ManagedSource(
    name: "Two", value: "https://two.example.test/list",
    payload: hardeningPayload("old-two.example.test")
  )
  let profile = ManagedProfile(
    name: "A", sources: [sourceOne, sourceTwo], payload: hardeningPayload("old.example.test")
  )
  let freshOne = hardeningPayload("fresh-one.example.test")
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.saveAndSyncSubscription()
  #expect(try await fetcher.nextRequest() == sourceOneURL)
  model.selectSource(sourceTwo.id)
  model.sourceName = "Unsaved source two"
  model.subscriptionURL = "https://draft-two.example.test/list"
  model.subscriptionUserAgent = "Draft Source Two"
  let sourceTwoStatus = model.subscriptionStatus
  let sourceTwoLastError = model.lastError
  await fetcher.complete(
    sourceOneURL,
    with: SubscriptionFetchResult(
      profile: freshOne, skippedTransports: [:]
    )
  )
  #expect(await waitForHardeningCondition { !model.isSyncing })

  #expect(model.selectedProfileID == profile.id)
  #expect(model.selectedSourceID == sourceTwo.id)
  #expect(model.profiles[0].sources.first?.payload == freshOne)
  #expect(model.sourceName == "Unsaved source two")
  #expect(model.subscriptionURL == "https://draft-two.example.test/list")
  #expect(model.subscriptionUserAgent == "Draft Source Two")
  #expect(model.subscriptionStatus == sourceTwoStatus)
  #expect(model.lastError == sourceTwoLastError)
}

@Test @MainActor
func manualSyncApplySuccessDoesNotPublishAStatusIntoSelectedProfileB() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let runtime = ControlledHelperResponses()
  let url = "https://a.example.test/list"
  let source = ManagedSource(
    name: "A source", value: url, payload: hardeningPayload("old-a.example.test")
  )
  let profileA = ManagedProfile(
    name: "A", sources: [source], payload: hardeningPayload("old-a.example.test")
  )
  let sourceB = ManagedSource(name: "B source", value: "https://b.example.test/list")
  let profileB = ManagedProfile(
    name: "B", sources: [sourceB], payload: hardeningPayload("b.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileA.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.saveAndSyncSubscription()
  #expect(try await fetcher.nextRequest() == url)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:]
    )
  )
  let apply = try await runtime.nextRequest()
  #expect(apply.action == .start)
  #expect(apply.profileID == profileA.id)
  // Keep A's callback current; selectProfile would submit a newer B runtime request and
  // supersede the completion path this regression is exercising.
  model.selectedProfileID = profileB.id
  model.selectedSourceID = sourceB.id
  model.selectedNodeID = .auto
  model.nodes = (profileB.payload?.nodes ?? []).map {
    ProxyNode(
      id: $0.id, name: $0.name, groupID: nil, groupName: nil,
      groupOrder: nil, nodeOrder: nil, delay: nil
    )
  }
  model.profileAvailable = true
  model.profileName = profileB.name
  model.sourceName = sourceB.name
  model.subscriptionURL = sourceB.value
  model.sourceName = "Unsaved B editor"
  model.subscriptionURL = "https://draft-b.example.test/list"
  model.lastError = "B visible error"
  model.subscriptionStatus = "B visible status"
  model.subscriptionStatusLevel = .warning

  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileA.id, message: "A applied"
    )
  )
  #expect(await waitForHardeningCondition { model.runtimeApplyStatus != .applying })

  #expect(model.selectedProfileID == profileB.id)
  #expect(model.profileAvailable)
  #expect(model.subscriptionStatus == "B visible status")
  #expect(model.subscriptionStatusLevel == .warning)
  #expect(model.lastError == "B visible error")
  #expect(model.sourceName == "Unsaved B editor")
  #expect(model.subscriptionURL == "https://draft-b.example.test/list")
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func manualSyncApplyFailureCompensatesAWithoutPublishingIntoSelectedProfileB() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let runtime = ControlledHelperResponses()
  let url = "https://a.example.test/list"
  let source = ManagedSource(
    name: "A source", value: url, payload: hardeningPayload("old-a.example.test")
  )
  let profileA = ManagedProfile(
    name: "A", sources: [source], payload: hardeningPayload("old-a.example.test")
  )
  let sourceB = ManagedSource(name: "B source", value: "https://b.example.test/list")
  let profileB = ManagedProfile(
    name: "B", sources: [sourceB], payload: hardeningPayload("b.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileA.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.saveAndSyncSubscription()
  #expect(try await fetcher.nextRequest() == url)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:]
    )
  )
  let apply = try await runtime.nextRequest()
  #expect(apply.action == .start)
  #expect(apply.profileID == profileA.id)
  // Keep A's callback current; selectProfile would submit a newer B runtime request and
  // supersede the completion path this regression is exercising.
  model.selectedProfileID = profileB.id
  model.selectedSourceID = sourceB.id
  model.selectedNodeID = .auto
  model.nodes = (profileB.payload?.nodes ?? []).map {
    ProxyNode(
      id: $0.id, name: $0.name, groupID: nil, groupName: nil,
      groupOrder: nil, nodeOrder: nil, delay: nil
    )
  }
  model.profileAvailable = true
  model.profileName = profileB.name
  model.sourceName = sourceB.name
  model.subscriptionURL = sourceB.value
  model.sourceName = "Unsaved B editor"
  model.subscriptionURL = "https://draft-b.example.test/list"
  model.lastError = "B visible error"
  model.subscriptionStatus = "B visible status"
  model.subscriptionStatusLevel = .warning

  await runtime.completeNext(
    HelperResponse(
      success: false, coreRunning: true, activeProfileID: profileA.id, message: "A rejected"
    )
  )
  #expect(await waitForHardeningCondition { model.runtimeApplyStatus == .failed })

  #expect(model.selectedProfileID == profileB.id)
  #expect(model.profiles.first(where: { $0.id == profileA.id })?.payload == profileA.payload)
  #expect(model.profileAvailable)
  #expect(model.subscriptionStatus == "B visible status")
  #expect(model.subscriptionStatusLevel == .warning)
  #expect(model.lastError == "B visible error")
  #expect(model.sourceName == "Unsaved B editor")
  #expect(model.subscriptionURL == "https://draft-b.example.test/list")
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func failedInitialProfileSelectionRestoresManualNodeAndPresentation() async throws {
  let payloadA = hardeningPayload("a.example.test")
  let manualA = try #require(payloadA.nodes.first(where: { $0.id != .auto })?.id)
  let profileA = ManagedProfile(name: "A", payload: payloadA)
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let library = ProfileLibrary(
    profiles: [profileA, profileB], selectedProfileID: profileA.id, selectedNodeID: manualA
  )
  let storeDirectory = try hardeningProfileStoreDirectory()
  defer { try? FileManager.default.removeItem(at: storeDirectory) }
  let storeURL = storeDirectory.appendingPathComponent("profiles.json")
  try ProfileStore.saveProfileLibrary(library, to: storeURL)
  let initialBytes = try Data(contentsOf: storeURL)
  let saves = SaveFailureController(failOnAttempts: [1])
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: library,
    runtimeSender: { request in try await runtime.send(request) },
    saver: { candidate in
      try saves.save(candidate)
      try ProfileStore.saveProfileLibrary(candidate, to: storeURL)
    }
  )
  model.profileAvailable = true
  model.subscriptionStatus = "A presentation"
  model.subscriptionStatusLevel = .warning

  model.selectProfile(profileB.id)

  #expect(model.selectedProfileID == profileA.id)
  #expect(model.selectedNodeID == manualA)
  #expect(model.nodes.map(\.id) == payloadA.nodes.map(\.id))
  #expect(model.profileAvailable)
  #expect(model.subscriptionStatus == "A presentation")
  #expect(model.subscriptionStatusLevel == .warning)
  let durableBytes = try Data(contentsOf: storeURL)
  let loadedDurable = try ProfileStore.loadProfileLibrary(from: storeURL)
  let durable = try #require(loadedDurable)
  #expect(durableBytes == initialBytes)
  #expect(durable.selectedProfileID == profileA.id)
  #expect(durable.selectedNodeID == manualA)
  #expect(saves.attempts == 1)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func successfulProfileSelectionPersistsTheNormalizedBNode() async throws {
  let payloadA = hardeningPayload("a.example.test")
  let manualA = try #require(payloadA.nodes.first(where: { $0.id != .auto })?.id)
  let payloadB = hardeningPayload("b.example.test")
  let profileA = ManagedProfile(name: "A", payload: payloadA)
  let profileB = ManagedProfile(name: "B", payload: payloadB)
  var durable: ProfileLibrary?
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id, selectedNodeID: manualA
    ),
    saver: { durable = $0 }
  )

  model.selectProfile(profileB.id)

  #expect(model.selectedProfileID == profileB.id)
  #expect(model.selectedNodeID == .auto)
  #expect(durable?.selectedProfileID == profileB.id)
  #expect(durable?.selectedNodeID == .auto)
  #expect(model.nodes.map(\.id) == payloadB.nodes.map(\.id))
}

@Test @MainActor
func profileRuntimeFailureCompensatesFullPreviousSelectionAndPresentation() async throws {
  let runtime = ControlledHelperResponses()
  let payloadA = hardeningPayload("a.example.test")
  let manualA = try #require(payloadA.nodes.first(where: { $0.id != .auto })?.id)
  let profileA = ManagedProfile(name: "A", payload: payloadA)
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let initial = ProfileLibrary(
    profiles: [profileA, profileB], selectedProfileID: profileA.id, selectedNodeID: manualA
  )
  let storeDirectory = try hardeningProfileStoreDirectory()
  defer { try? FileManager.default.removeItem(at: storeDirectory) }
  let storeURL = storeDirectory.appendingPathComponent("profiles.json")
  try ProfileStore.saveProfileLibrary(initial, to: storeURL)
  let model = hardeningModel(
    library: initial,
    runtimeSender: { request in try await runtime.send(request) },
    saver: { try ProfileStore.saveProfileLibrary($0, to: storeURL) }
  )
  model.coreRunning = true
  model.profileAvailable = true
  model.subscriptionStatus = "A presentation"
  model.subscriptionStatusLevel = .warning

  model.selectProfile(profileB.id)
  #expect((try await runtime.nextRequest()).profileID == profileB.id)
  await runtime.completeNext(
    HelperResponse(
      success: false, coreRunning: true, activeProfileID: profileA.id,
      message: "selection rejected"
    )
  )
  #expect(await waitForHardeningCondition { model.selectedProfileID == profileA.id })

  #expect(model.selectedNodeID == manualA)
  #expect(model.profileAvailable)
  #expect(model.subscriptionStatus == "A presentation")
  #expect(model.subscriptionStatusLevel == .warning)
  #expect(model.lastError?.contains("selection rejected") == true)
  let loadedDurable = try ProfileStore.loadProfileLibrary(from: storeURL)
  let durable = try #require(loadedDurable)
  #expect(durable.selectedProfileID == profileA.id)
  #expect(durable.selectedNodeID == manualA)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func failedProfileCompensationRestoresCommittedBStateInRam() async throws {
  let runtime = ControlledHelperResponses()
  let payloadA = hardeningPayload("a.example.test")
  let manualA = try #require(payloadA.nodes.first(where: { $0.id != .auto })?.id)
  let profileA = ManagedProfile(name: "A", payload: payloadA)
  let payloadB = hardeningPayload("b.example.test")
  let profileB = ManagedProfile(name: "B", payload: payloadB)
  let initial = ProfileLibrary(
    profiles: [profileA, profileB], selectedProfileID: profileA.id, selectedNodeID: manualA
  )
  let storeDirectory = try hardeningProfileStoreDirectory()
  defer { try? FileManager.default.removeItem(at: storeDirectory) }
  let storeURL = storeDirectory.appendingPathComponent("profiles.json")
  try ProfileStore.saveProfileLibrary(initial, to: storeURL)
  let saves = SaveFailureController(failOnAttempts: [2])
  let model = hardeningModel(
    library: initial,
    runtimeSender: { request in try await runtime.send(request) },
    saver: { candidate in
      try saves.save(candidate)
      try ProfileStore.saveProfileLibrary(candidate, to: storeURL)
    }
  )
  model.coreRunning = true
  model.profileAvailable = true
  model.subscriptionStatus = "A presentation"
  model.subscriptionStatusLevel = .warning

  model.selectProfile(profileB.id)
  #expect((try await runtime.nextRequest()).profileID == profileB.id)
  let committedNode = model.selectedNodeID
  let committedAvailability = model.profileAvailable
  let committedStatus = model.subscriptionStatus
  let committedLevel = model.subscriptionStatusLevel
  let loadedCommitted = try ProfileStore.loadProfileLibrary(from: storeURL)
  let committedLibrary = try #require(loadedCommitted)
  await runtime.completeNext(
    HelperResponse(
      success: false, coreRunning: true, activeProfileID: profileA.id,
      message: "selection rejected"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.lastError?.contains("Rollback could not be saved") == true
    })

  #expect(model.selectedProfileID == profileB.id)
  #expect(model.selectedNodeID == committedNode)
  #expect(model.profileAvailable == committedAvailability)
  #expect(model.subscriptionStatus == committedStatus)
  #expect(model.subscriptionStatusLevel == committedLevel)
  let durable = try ProfileStore.loadProfileLibrary(from: storeURL)
  #expect(durable == committedLibrary)
  #expect(model.lastError?.contains("Rollback could not be saved") == true)
  #expect(saves.attempts == 2)
}

@Test @MainActor
func newerProfileSelectionSupersedesOlderRuntimeFailure() async throws {
  let runtime = ControlledHelperResponses()
  let profileA = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let profileC = ManagedProfile(name: "C", payload: hardeningPayload("c.example.test"))
  var durable: ProfileLibrary?
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB, profileC], selectedProfileID: profileA.id
    ),
    runtimeSender: { request in try await runtime.send(request) },
    saver: { durable = $0 }
  )
  model.coreRunning = true

  model.selectProfile(profileB.id)
  #expect((try await runtime.nextRequest()).profileID == profileB.id)
  model.selectProfile(profileC.id)
  await runtime.completeNext(
    HelperResponse(
      success: false, coreRunning: true, activeProfileID: profileA.id,
      message: "stale B rejection"
    )
  )
  let currentRequest = try await runtime.nextRequest()
  #expect(currentRequest.profileID == profileC.id)
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileC.id, message: "C active"
    )
  )
  #expect(await waitForHardeningCondition { model.runtimeApplyStatus == .active })

  #expect(model.selectedProfileID == profileC.id)
  #expect(durable?.selectedProfileID == profileC.id)
  #expect(model.profileName == "C")
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func failedSelectedProfileDeletionRestoresNodeAndPresentationWithoutApplyingRuntime() async throws {
  let payloadA = hardeningPayload("a.example.test")
  let manualA = try #require(payloadA.nodes.first(where: { $0.id != .auto })?.id)
  let profileA = ManagedProfile(name: "A", payload: payloadA)
  let profileB = ManagedProfile(name: "B")
  let initial = ProfileLibrary(
    profiles: [profileA, profileB], selectedProfileID: profileA.id, selectedNodeID: manualA
  )
  let storeDirectory = try hardeningProfileStoreDirectory()
  defer { try? FileManager.default.removeItem(at: storeDirectory) }
  let storeURL = storeDirectory.appendingPathComponent("profiles.json")
  try ProfileStore.saveProfileLibrary(initial, to: storeURL)
  let initialBytes = try Data(contentsOf: storeURL)
  let saves = SaveFailureController(failOnAttempts: [1])
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: initial,
    runtimeSender: { request in try await runtime.send(request) },
    saver: { candidate in
      try saves.save(candidate)
      try ProfileStore.saveProfileLibrary(candidate, to: storeURL)
    }
  )
  model.coreRunning = true
  model.profileAvailable = true
  model.subscriptionStatus = "A presentation"
  model.subscriptionStatusLevel = .warning

  model.deleteSelectedProfile(profileID: profileA.id)

  #expect(model.profiles == initial.profiles)
  #expect(model.selectedProfileID == profileA.id)
  #expect(model.selectedNodeID == manualA)
  #expect(model.profileAvailable)
  #expect(model.subscriptionStatus == "A presentation")
  #expect(model.subscriptionStatusLevel == .warning)
  #expect(try Data(contentsOf: storeURL) == initialBytes)
  #expect(saves.attempts == 1)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func failedSelectedProfileDeletionRestoresUnavailableStateWithNonemptyFallback() async throws {
  let payloadA = hardeningPayload("a.example.test")
  let manualA = try #require(payloadA.nodes.first(where: { $0.id != .auto })?.id)
  let profileA = ManagedProfile(name: "A", payload: payloadA)
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let initial = ProfileLibrary(
    profiles: [profileA, profileB], selectedProfileID: profileA.id, selectedNodeID: manualA
  )
  let storeDirectory = try hardeningProfileStoreDirectory()
  defer { try? FileManager.default.removeItem(at: storeDirectory) }
  let storeURL = storeDirectory.appendingPathComponent("profiles.json")
  try ProfileStore.saveProfileLibrary(initial, to: storeURL)
  let initialBytes = try Data(contentsOf: storeURL)
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: initial,
    runtimeSender: { request in try await runtime.send(request) },
    saver: { _ in throw CocoaError(.fileWriteNoPermission) }
  )
  model.coreRunning = true
  model.profileAvailable = false
  model.subscriptionStatus = "A unavailable presentation"
  model.subscriptionStatusLevel = .warning

  model.deleteSelectedProfile(profileID: profileA.id)

  #expect(model.profiles == initial.profiles)
  #expect(model.selectedProfileID == profileA.id)
  #expect(model.selectedNodeID == manualA)
  #expect(!model.profileAvailable)
  #expect(model.subscriptionStatus == "A unavailable presentation")
  #expect(model.subscriptionStatusLevel == .warning)
  #expect(try Data(contentsOf: storeURL) == initialBytes)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func deletingSelectedProfilePublishesNonemptyNextProfile() async throws {
  let profileA = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  var durable: ProfileLibrary?
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileA.id),
    runtimeSender: { request in try await runtime.send(request) },
    saver: { durable = $0 }
  )

  model.deleteSelectedProfile(profileID: profileA.id)

  #expect(model.profiles.map(\.id) == [profileB.id])
  #expect(model.selectedProfileID == profileB.id)
  #expect(model.selectedNodeID == .auto)
  #expect(model.profileAvailable)
  #expect(model.subscriptionStatus == SBMText.localized("Ready"))
  #expect(model.subscriptionStatusLevel == .success)
  #expect(durable?.profiles.map(\.id) == [profileB.id])
  #expect(durable?.selectedProfileID == profileB.id)
  #expect(durable?.selectedNodeID == .auto)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func failedProfileDeletionRuntimeApplyCompensatesFullPreviousState() async throws {
  let payloadA = hardeningPayload("a.example.test")
  let manualA = try #require(payloadA.nodes.first(where: { $0.id != .auto })?.id)
  let profileA = ManagedProfile(name: "A", payload: payloadA)
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let initial = ProfileLibrary(
    profiles: [profileA, profileB], selectedProfileID: profileA.id, selectedNodeID: manualA
  )
  let storeDirectory = try hardeningProfileStoreDirectory()
  defer { try? FileManager.default.removeItem(at: storeDirectory) }
  let storeURL = storeDirectory.appendingPathComponent("profiles.json")
  try ProfileStore.saveProfileLibrary(initial, to: storeURL)
  let saves = SaveFailureController(failOnAttempts: [])
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: initial,
    runtimeSender: { request in try await runtime.send(request) },
    saver: { candidate in
      try saves.save(candidate)
      try ProfileStore.saveProfileLibrary(candidate, to: storeURL)
    }
  )
  model.coreRunning = true
  model.profileAvailable = true
  model.subscriptionStatus = "A presentation"
  model.subscriptionStatusLevel = .warning

  model.deleteSelectedProfile(profileID: profileA.id)
  #expect(model.profiles.map(\.id) == [profileB.id])
  let apply = try #require(try await nextHelperRequest(runtime))
  #expect(apply.profileID == profileB.id)
  await runtime.completeNext(
    HelperResponse(
      success: false, coreRunning: true, activeProfileID: profileA.id,
      message: "fallback apply rejected"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.profiles.map(\.id) == [profileA.id, profileB.id]
    })

  #expect(model.selectedProfileID == profileA.id)
  #expect(model.selectedNodeID == manualA)
  #expect(model.profileAvailable)
  #expect(model.subscriptionStatus == "A presentation")
  #expect(model.subscriptionStatusLevel == .warning)
  #expect(model.lastError?.contains("fallback apply rejected") == true)
  let loadedRestored = try ProfileStore.loadProfileLibrary(from: storeURL)
  let restored = try #require(loadedRestored)
  #expect(restored == initial)
  #expect(saves.attempts == 2)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor
func failedProfileDeletionCompensationRetainsCommittedLibraryAndPresentation() async throws {
  let profileA = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let initial = ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileA.id)
  let storeDirectory = try hardeningProfileStoreDirectory()
  defer { try? FileManager.default.removeItem(at: storeDirectory) }
  let storeURL = storeDirectory.appendingPathComponent("profiles.json")
  try ProfileStore.saveProfileLibrary(initial, to: storeURL)
  let saves = SaveFailureController(failOnAttempts: [2])
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: initial,
    runtimeSender: { request in try await runtime.send(request) },
    saver: { candidate in
      try saves.save(candidate)
      try ProfileStore.saveProfileLibrary(candidate, to: storeURL)
    }
  )
  model.coreRunning = true
  model.profileAvailable = true
  model.subscriptionStatus = "A presentation"
  model.subscriptionStatusLevel = .warning

  model.deleteSelectedProfile(profileID: profileA.id)
  let apply = try #require(try await nextHelperRequest(runtime))
  #expect(apply.profileID == profileB.id)
  let committedBytes = try Data(contentsOf: storeURL)
  await runtime.completeNext(
    HelperResponse(
      success: false, coreRunning: true, activeProfileID: profileA.id,
      message: "fallback apply rejected"
    )
  )
  #expect(
    await waitForHardeningCondition {
      model.lastError?.contains("Rollback could not be saved") == true
    })

  #expect(model.profiles.map(\.id) == [profileB.id])
  #expect(model.selectedProfileID == profileB.id)
  #expect(model.selectedNodeID == .auto)
  #expect(model.profileAvailable)
  #expect(model.subscriptionStatus == SBMText.localized("Ready"))
  #expect(model.subscriptionStatusLevel == .success)
  #expect(try Data(contentsOf: storeURL) == committedBytes)
  #expect(model.lastError?.contains("fallback apply rejected") == true)
  #expect(model.lastError?.contains("Rollback could not be saved") == true)
  #expect(saves.attempts == 2)
}

@Test @MainActor
func staleProfileDeletionFailurePreservesNewNodeAndEditorDraft() async throws {
  let profileA = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let payloadB = hardeningPayload("b.example.test")
  let manualB = try #require(payloadB.nodes.first(where: { $0.id != .auto })?.id)
  let sourceB = ManagedSource(name: "B source", value: "https://b.example.test/list")
  let profileB = ManagedProfile(name: "B", sources: [sourceB], payload: payloadB)
  let runtime = ControlledHelperResponses()
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileA.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.deleteSelectedProfile(profileID: profileA.id)
  let apply = try #require(try await nextHelperRequest(runtime))
  #expect(apply.profileID == profileB.id)
  model.selectedNodeID = manualB
  model.profileName = "B draft"
  model.sourceName = "Unsaved source"
  model.subscriptionURL = "https://draft.example.test/list"
  await runtime.completeNext(
    HelperResponse(
      success: false, coreRunning: true, activeProfileID: profileA.id,
      message: "stale deletion apply rejected"
    )
  )
  #expect(await waitForRuntimeApplyStatus(model, .failed))

  #expect(model.profiles.map(\.id) == [profileB.id])
  #expect(model.selectedProfileID == profileB.id)
  #expect(model.selectedNodeID == manualB)
  #expect(model.profileName == "B draft")
  #expect(model.sourceName == "Unsaved source")
  #expect(model.subscriptionURL == "https://draft.example.test/list")
  #expect(model.lastError?.contains("stale deletion apply rejected") == true)
}

@Test @MainActor
func profileRefreshPublishesCacheForLaterFailedSourceSync() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let url = "https://cached.example.test/list"
  let profile = ManagedProfile(
    name: "A", sources: [ManagedSource(name: "Remote", value: url)]
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  #expect(try #require(try await nextSubscriptionRequest(fetcher)) == url)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:]
    )
  )
  #expect(await waitForHardeningCondition { !model.isSyncing })
  #expect(model.profileAvailable)
  #expect(model.profiles.first?.payload != nil)

  model.saveAndSyncSubscription()
  #expect(try #require(try await nextSubscriptionRequest(fetcher)) == url)
  await fetcher.fail(url)
  #expect(await waitForHardeningCondition { !model.isSyncing })

  #expect(model.profileAvailable)
  #expect(model.subscriptionStatus == SBMText.localized("Using cached sources; sync failed"))
}

@Test @MainActor
func profileRefreshWithoutCacheKeepsSelectedProfileUnavailable() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let url = "https://uncached.example.test/list"
  let profile = ManagedProfile(
    name: "A", sources: [ManagedSource(name: "Remote", value: url)]
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  #expect(try #require(try await nextSubscriptionRequest(fetcher)) == url)
  await fetcher.fail(url)
  #expect(await waitForHardeningCondition { !model.isSyncing })
  #expect(!model.profileAvailable)

  model.saveAndSyncSubscription()
  #expect(try #require(try await nextSubscriptionRequest(fetcher)) == url)
  await fetcher.fail(url)
  #expect(await waitForHardeningCondition { !model.isSyncing })

  #expect(!model.profileAvailable)
  #expect(model.subscriptionStatus == SBMText.localized("Sync failed"))
}

@Test @MainActor
func profileRefreshAvailabilityUsesSelectionAtSweepCompletion() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let url = "https://first.example.test/list"
  let profileA = ManagedProfile(
    name: "A", sources: [ManagedSource(name: "Remote", value: url)]
  )
  let profileB = ManagedProfile(name: "Empty B")
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileA.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  #expect(try #require(try await nextSubscriptionRequest(fetcher)) == url)
  model.selectProfile(profileB.id)
  #expect(!model.profileAvailable)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:]
    )
  )
  #expect(await waitForHardeningCondition { !model.isSyncing })

  #expect(model.selectedProfileID == profileB.id)
  #expect(model.profiles.first(where: { $0.id == profileA.id })?.payload != nil)
  #expect(!model.profileAvailable)
  model.selectProfile(profileA.id)
  #expect(model.profileAvailable)
}

@Test @MainActor
func updaterDownloadOpensReturnedPublisherAuthenticatedImageOnce() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let opener = UpdateOpenerRecorder(result: true)
  let model = controlledUpdaterModel(
    updater,
    userDefaults: defaults,
    updateOpener: { opener.open($0) }
  )
  let update = updaterFixture()
  #expect(try await publishUpdaterFixture(update, model: model, updater: updater))

  model.downloadAndOpenUpdate()
  let downloadID = try await updater.nextDownload()
  let image = FileManager.default.temporaryDirectory.appendingPathComponent(
    "sbm-updater-handoff-\(UUID().uuidString).dmg"
  )
  await updater.completeDownload(downloadID, with: image)

  #expect(
    await awaitUpdaterState {
      !model.isDownloadingUpdate
        && model.updateStatus
          == SBMText.localized("DMG authenticated by the SBM project publisher and opened")
    })
  #expect(opener.snapshot() == [image])
  #expect(model.lastError == nil)
  #expect(model.updateDownloadProgress == nil)
}

@Test @MainActor
func updaterOpenerFailurePublishesExistingDownloadFailure() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let opener = UpdateOpenerRecorder(result: false)
  let model = controlledUpdaterModel(
    updater,
    userDefaults: defaults,
    updateOpener: { opener.open($0) }
  )
  let update = updaterFixture()
  #expect(try await publishUpdaterFixture(update, model: model, updater: updater))

  model.downloadAndOpenUpdate()
  let downloadID = try await updater.nextDownload()
  let image = FileManager.default.temporaryDirectory.appendingPathComponent(
    "sbm-updater-opener-failure-\(UUID().uuidString).dmg"
  )
  await updater.completeDownload(downloadID, with: image)

  #expect(
    await awaitUpdaterState {
      !model.isDownloadingUpdate && model.updateStatus == SBMText.localized("Update failed")
    })
  #expect(opener.snapshot() == [image])
  #expect(model.lastError == UpdateFailure.downloadFailed.localizedDescription)
  #expect(
    model.updateStatus
      != SBMText.localized(
        "DMG authenticated by the SBM project publisher and opened"))
}

@Test @MainActor
func updaterDownloaderFailureDoesNotInvokeOpener() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let opener = UpdateOpenerRecorder(result: true)
  let model = controlledUpdaterModel(
    updater,
    userDefaults: defaults,
    updateOpener: { opener.open($0) }
  )
  let update = updaterFixture()
  #expect(try await publishUpdaterFixture(update, model: model, updater: updater))

  model.downloadAndOpenUpdate()
  let downloadID = try await updater.nextDownload()
  await updater.failDownload(downloadID, with: ControlledUpdateFailure())
  #expect(await awaitUpdaterState { !model.isDownloadingUpdate })
  #expect(opener.snapshot().isEmpty)
  #expect(model.updateStatus == SBMText.localized("Update failed"))
}

@Test @MainActor
func updaterCancellationBeforeDownloadReturnCannotOpenOrPublishLateProgress() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let opener = UpdateOpenerRecorder(result: true)
  let model = controlledUpdaterModel(
    updater,
    userDefaults: defaults,
    updateOpener: { opener.open($0) }
  )
  let update = updaterFixture()
  #expect(try await publishUpdaterFixture(update, model: model, updater: updater))

  model.downloadAndOpenUpdate()
  let downloadID = try await updater.nextDownload()
  guard let progress = await updater.progressHandler(downloadID) else {
    Issue.record("AppModel did not pass a progress callback to the controlled downloader.")
    return
  }
  let statusAtClose = model.updateStatus
  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await quit.value)
  #expect(await updater.wasDownloadCancelled(downloadID))
  #expect(!model.isDownloadingUpdate)
  #expect(model.updateDownloadProgress == nil)

  let lateImage = FileManager.default.temporaryDirectory.appendingPathComponent(
    "sbm-updater-late-\(UUID().uuidString).dmg"
  )
  await updater.completeDownload(downloadID, with: lateImage)
  await invokeProgressAndDrain(progress, fraction: 0.9)
  #expect(opener.snapshot().isEmpty)
  #expect(model.updateStatus == statusAtClose)
  #expect(model.updateDownloadProgress == nil)
  #expect(model.lastError == nil)
}

@Test @MainActor
func updaterQuitCancelsAcceptedCheckWithoutPublishingOrRestarting() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let model = controlledUpdaterModel(updater, userDefaults: defaults)

  model.checkForUpdates()
  let completedCheckID = try await updater.nextCheck()
  await updater.completeCheck(completedCheckID, with: nil)
  #expect(
    await awaitUpdaterState {
      !model.isCheckingForUpdates && model.updateStatus == SBMText.localized("SBM is up to date")
    })
  #expect(defaults.object(forKey: "LastUpdateCheck") != nil)

  model.checkForUpdates()
  let checkID = try await updater.nextCheck()
  #expect(model.isCheckingForUpdates)
  #expect(model.updateStatus == SBMText.localized("SBM is up to date"))

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await quit.value)
  #expect(await updater.wasCheckCancelled(checkID))
  #expect(defaults.object(forKey: "LastUpdateCheck") != nil)
  #expect(model.availableUpdateVersion == nil)
  #expect(model.updateStatus == SBMText.localized("SBM is up to date"))
  #expect(model.lastError == nil)

  model.checkForUpdates()
  model.downloadAndOpenUpdate()
  #expect(await updater.checkCount() == 2)
  #expect(await updater.downloadCount() == 0)
}

@Test @MainActor
func updaterPublishesCompletedNoUpdateAndAvailableStatuses() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let model = controlledUpdaterModel(updater, userDefaults: defaults)

  #expect(model.updateStatus.isEmpty)

  model.checkForUpdates()
  let noUpdateID = try await updater.nextCheck()
  #expect(model.isCheckingForUpdates)
  #expect(model.updateStatus.isEmpty)
  await updater.completeCheck(noUpdateID, with: nil)
  #expect(
    await awaitUpdaterState {
      !model.isCheckingForUpdates && model.updateStatus == SBMText.localized("SBM is up to date")
    })

  let update = updaterFixture()
  model.checkForUpdates()
  let availableID = try await updater.nextCheck()
  await updater.completeCheck(availableID, with: update)
  #expect(
    await awaitUpdaterState {
      !model.isCheckingForUpdates
        && model.updateStatus == SBMText.format("Version %@ is available", update.version)
    })
}

@Test @MainActor
func automaticUpdaterFailurePublishesStatusWithoutUserError() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let model = controlledUpdaterModel(updater, userDefaults: defaults)

  model.checkForUpdates(userInitiated: false)
  let checkID = try await updater.nextCheck()
  await updater.failCheck(checkID, with: UpdateFailure.publisherProofInvalid)

  #expect(
    await awaitUpdaterState {
      !model.isCheckingForUpdates && model.updateStatus == SBMText.localized("Update check failed")
    })
  #expect(model.lastError == nil)
}

@Test @MainActor
func updaterPublisherProofFailureDoesNotPublishOrDownloadCandidate() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let model = controlledUpdaterModel(updater, userDefaults: defaults)

  model.checkForUpdates()
  let checkID = try await updater.nextCheck()
  await updater.failCheck(checkID, with: UpdateFailure.publisherProofInvalid)
  #expect(
    await awaitUpdaterState {
      !model.isCheckingForUpdates && model.updateStatus == SBMText.localized("Update check failed")
    })

  #expect(model.availableUpdateVersion == nil)
  #expect(
    model.lastError
      == SBMText.localized("SBM could not authenticate this update from its publisher."))
  #expect(await updater.downloadCount() == 0)
}

@Test @MainActor
func updaterCheckAdmissionRejectsDownloadWhileKeepingExistingCandidate() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let model = controlledUpdaterModel(updater, userDefaults: defaults)
  let update = updaterFixture()
  #expect(try await publishUpdaterFixture(update, model: model, updater: updater))

  model.checkForUpdates()
  let checkID = try await updater.nextCheck()
  model.checkForUpdates()
  model.downloadAndOpenUpdate()
  #expect(await updater.checkCount() == 2)
  #expect(await updater.downloadCount() == 0)
  #expect(model.availableUpdateVersion == update.version)
  #expect(model.isCheckingForUpdates)

  await updater.completeCheck(checkID, with: nil)
  #expect(
    await awaitUpdaterState {
      !model.isCheckingForUpdates && model.availableUpdateVersion == nil
    })
}

@Test @MainActor
func updaterDownloadAdmissionRejectsCheckAndDuplicateDownload() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let model = controlledUpdaterModel(updater, userDefaults: defaults)
  let update = updaterFixture()
  #expect(try await publishUpdaterFixture(update, model: model, updater: updater))

  model.downloadAndOpenUpdate()
  let downloadID = try await updater.nextDownload()
  model.checkForUpdates()
  model.downloadAndOpenUpdate()
  #expect(await updater.checkCount() == 1)
  #expect(await updater.downloadCount() == 1)
  #expect(model.isDownloadingUpdate)
  #expect(model.availableUpdateVersion == update.version)

  await updater.failDownload(downloadID, with: ControlledUpdateFailure())
  #expect(await awaitUpdaterState { !model.isDownloadingUpdate })
  #expect(model.updateStatus == SBMText.localized("Update failed"))
}

@Test @MainActor
func updaterProgressAfterCompletedDownloadCannotReopenAttemptPresentation() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let model = controlledUpdaterModel(updater, userDefaults: defaults)
  let update = updaterFixture()
  #expect(try await publishUpdaterFixture(update, model: model, updater: updater))

  model.downloadAndOpenUpdate()
  let downloadID = try await updater.nextDownload()
  guard let progress = await updater.progressHandler(downloadID) else {
    Issue.record("AppModel did not pass a progress callback to the controlled downloader.")
    return
  }
  await updater.failDownload(downloadID, with: ControlledUpdateFailure())
  #expect(
    await awaitUpdaterState {
      !model.isDownloadingUpdate && model.updateStatus == SBMText.localized("Update failed")
    })
  let terminalStatus = model.updateStatus

  await invokeProgressAndDrain(progress, fraction: 0.8)
  #expect(model.updateStatus == terminalStatus)
  #expect(model.updateDownloadProgress == nil)
}

@Test @MainActor
func updaterRejectsOldProgressFromSameVersionPriorAttempt() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let model = controlledUpdaterModel(updater, userDefaults: defaults)
  let update = updaterFixture()
  #expect(try await publishUpdaterFixture(update, model: model, updater: updater))

  model.downloadAndOpenUpdate()
  let firstID = try await updater.nextDownload()
  guard let oldProgress = await updater.progressHandler(firstID) else {
    Issue.record("AppModel did not pass a progress callback for attempt A.")
    return
  }
  await invokeProgressAndDrain(oldProgress, fraction: 0.4)
  #expect(model.updateDownloadProgress == 0.4)
  await updater.failDownload(firstID, with: ControlledUpdateFailure())
  #expect(await awaitUpdaterState { !model.isDownloadingUpdate })

  model.downloadAndOpenUpdate()
  let secondID = try await updater.nextDownload()
  #expect(firstID != secondID)
  #expect(model.availableUpdateVersion == update.version)
  await invokeProgressAndDrain(oldProgress, fraction: 0.9)
  #expect(model.updateDownloadProgress == 0)
  #expect(model.updateStatus == SBMText.format("Downloading %@…", update.version))

  guard let currentProgress = await updater.progressHandler(secondID) else {
    Issue.record("AppModel did not pass a progress callback for attempt B.")
    return
  }
  await invokeProgressAndDrain(currentProgress, fraction: 0.25)
  #expect(model.updateDownloadProgress == 0.25)
  await updater.failDownload(secondID, with: ControlledUpdateFailure())
  #expect(await awaitUpdaterState { !model.isDownloadingUpdate })
}

@Test @MainActor
func updaterQuitDrainsDownloadAndFencesLateProgress() async throws {
  let (defaults, defaultsName) = updaterTestDefaults()
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let updater = ControlledUpdater()
  let model = controlledUpdaterModel(updater, userDefaults: defaults)
  let update = updaterFixture()
  #expect(try await publishUpdaterFixture(update, model: model, updater: updater))

  model.downloadAndOpenUpdate()
  let downloadID = try await updater.nextDownload()
  guard let progress = await updater.progressHandler(downloadID) else {
    Issue.record("AppModel did not pass a progress callback for the active download.")
    return
  }
  await invokeProgressAndDrain(progress, fraction: 0.4)
  #expect(model.updateDownloadProgress == 0.4)
  let statusAtQuit = model.updateStatus

  #expect(await model.disconnectBeforeQuit())
  #expect(await updater.wasDownloadCancelled(downloadID))
  #expect(!model.isDownloadingUpdate)
  #expect(model.updateDownloadProgress == nil)
  #expect(model.updateStatus == statusAtQuit)
  #expect(model.lastError == nil)
  await invokeProgressAndDrain(progress, fraction: 0.9)
  #expect(model.updateStatus == statusAtQuit)
  #expect(model.updateDownloadProgress == nil)

  model.checkForUpdates()
  model.downloadAndOpenUpdate()
  #expect(await updater.checkCount() == 1)
  #expect(await updater.downloadCount() == 1)
}
