import CryptoKit
import Darwin
import Foundation
import OSLog
import SBMShared

private let runtimeLogger = Logger(
  subsystem: "com.stillnotfree.sbm.helper",
  category: "runtime-activation"
)

enum LocalTCPPortProbe {
  static func isAvailable(_ port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    // Go's TCP listener enables SO_REUSEADDR on Darwin. Mirror that behavior
    // so a connection from the just-stopped Clash API cannot leave a TIME_WAIT
    // socket that is mistaken for a conflicting listener.
    var reuseAddress: Int32 = 1
    guard
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_REUSEADDR,
        &reuseAddress,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else { return false }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    } == 0
  }
}

final class ManagedCoreChild: @unchecked Sendable {
  private let lock = NSLock()
  private let exitNotification = DispatchSemaphore(value: 0)
  private var processIdentifier: pid_t?
  private var exitStatus: Int32?
  private var exitSource: DispatchSourceProcess?

  private init(processIdentifier: pid_t) {
    self.processIdentifier = processIdentifier
  }

  static func launch(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL
  ) throws -> ManagedCoreChild {
    var fileActions: posix_spawn_file_actions_t?
    try checkSpawnResult(posix_spawn_file_actions_init(&fileActions))
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    try checkSpawnResult(
      currentDirectoryURL.path.withCString {
        posix_spawn_file_actions_addchdir(&fileActions, $0)
      })
    try checkSpawnResult(
      posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
    try checkSpawnResult(
      posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0))
    try checkSpawnResult(
      posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))

    var attributes: posix_spawnattr_t?
    try checkSpawnResult(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    var defaultSignals = sigset_t()
    _ = sigemptyset(&defaultSignals)
    _ = sigaddset(&defaultSignals, SIGTERM)
    try checkSpawnResult(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
    var signalMask = sigset_t()
    _ = sigemptyset(&signalMask)
    try checkSpawnResult(posix_spawnattr_setsigmask(&attributes, &signalMask))
    try checkSpawnResult(
      posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)
      ))

    var argumentPointers = ([executableURL.path] + arguments).map { strdup($0) }
    guard argumentPointers.allSatisfy({ $0 != nil }) else {
      for pointer in argumentPointers {
        if let pointer { free(pointer) }
      }
      throw CoreFailure.coreLaunchFailed(ENOMEM)
    }
    defer {
      for pointer in argumentPointers {
        if let pointer { free(pointer) }
      }
    }
    argumentPointers.append(nil)

    var childPID: pid_t = 0
    let spawnResult = executableURL.path.withCString { executablePath in
      argumentPointers.withUnsafeBufferPointer { argv in
        posix_spawn(
          &childPID,
          executablePath,
          &fileActions,
          &attributes,
          argv.baseAddress,
          environ
        )
      }
    }
    try checkSpawnResult(spawnResult)

    let child = ManagedCoreChild(processIdentifier: childPID)
    child.monitorExit()
    _ = child.isRunning
    return child
  }

  private static func checkSpawnResult(_ result: Int32) throws {
    guard result == 0 else { throw CoreFailure.coreLaunchFailed(result) }
  }

  var pid: pid_t? {
    lock.withLock { processIdentifier }
  }

  var isRunning: Bool {
    lock.withLock {
      reapIfExitedLocked()
      return processIdentifier != nil
    }
  }

  func waitUntilExit(timeout: TimeInterval) -> Int32? {
    let currentStatus = lock.withLock { exitStatus }
    if let currentStatus { return currentStatus }

    if exitNotification.wait(timeout: .now() + timeout) == .timedOut {
      lock.withLock { reapIfExitedLocked() }
    }
    return lock.withLock { exitStatus }
  }

  @discardableResult
  func terminate() -> Bool {
    guard sendSignal(SIGTERM) else { return false }
    if waitUntilExit(timeout: 3) != nil { return true }
    guard sendSignal(SIGKILL) else { return false }
    return waitUntilExit(timeout: 1) != nil
  }

  private func monitorExit() {
    guard let processIdentifier = pid else { return }
    let source = DispatchSource.makeProcessSource(
      identifier: processIdentifier,
      eventMask: .exit,
      queue: .global(qos: .utility)
    )
    source.setEventHandler { [weak self] in
      self?.reapAfterExitEvent()
    }
    exitSource = source
    source.activate()
  }

  private func sendSignal(_ signal: Int32) -> Bool {
    lock.withLock {
      reapIfExitedLocked()
      guard let processIdentifier else { return true }
      let result = kill(processIdentifier, signal)
      return result == 0 || errno == ESRCH
    }
  }

  private func reapAfterExitEvent() {
    lock.withLock { reapIfExitedLocked(blocking: true) }
  }

  private func reapIfExitedLocked(blocking: Bool = false) {
    guard let processIdentifier else { return }
    var waitStatus: Int32 = 0
    let options = blocking ? 0 : WNOHANG
    var result: pid_t
    repeat {
      result = waitpid(processIdentifier, &waitStatus, options)
    } while result < 0 && errno == EINTR
    if result == 0 { return }

    if result == processIdentifier {
      let terminatingSignal = waitStatus & 0x7f
      exitStatus = terminatingSignal == 0 ? (waitStatus >> 8) & 0xff : 128 + terminatingSignal
    } else if result == -1 && errno == ECHILD {
      // The exact child is no longer waitable; do not retain stale PID authority.
      exitStatus = -1
    } else {
      // An unrecognized observation error is not proof that the child has exited.
      return
    }

    self.processIdentifier = nil
    let source = exitSource
    exitSource = nil
    source?.cancel()
    exitNotification.signal()
  }
}

enum LatencyDelayRequest {
  static func path(for node: ProxyNodeID, target: String) -> String {
    var components = URLComponents()
    components.queryItems = [
      URLQueryItem(name: "timeout", value: "5000"),
      URLQueryItem(name: "url", value: target),
    ]
    let unreserved = Set(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8
    )
    let component = node.rawValue.utf8.map { byte in
      unreserved.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
    }.joined()
    return "/proxies/\(component)/delay?\(components.percentEncodedQuery ?? "")"
  }
}

func parseLatencyHistory(_ data: Data, nodes: [ProxyNodeDescriptor]) throws -> [NodeDelay] {
  guard data.count <= 1_048_576,
    let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
    let proxies = response["proxies"] as? [String: Any]
  else { throw CoreFailure.apiUnavailable }

  return nodes.map { node in
    let history = (proxies[node.id.rawValue] as? [String: Any])?["history"] as? [[String: Any]]
    let milliseconds = history?.last?["delay"] as? Int
    return NodeDelay(node: node.id, milliseconds: milliseconds)
  }
}

struct PersistentState: Codable {
  var profile: CoreProfile?
  var activeProfileID: UUID?
  var mode: RoutingMode = .rule
  var selectedNode: ProxyNodeID = .auto
  var selectorTag = "proxy-selector"
  var nodes: [ProxyNodeDescriptor] = []
  var desiredRunning = false
  var legacy1115RetirementComplete = false
  var automaticRecoveryAttempted = false
  /// Metadata only: the desired app configuration was validated but deferred
  /// because a known-good core is still running with different bytes.
  var deferredRuntimeApplyPending = false
  var localSOCKSEnabled = false
  var localSOCKSPort: UInt16 = 1082
  var latencyTestURL = LatencyTargetPolicy.defaultURL
  var dnsSettings = ManagedDNSSettings.defaults
  /// Desired policy persisted by the app. This is intentionally separate from
  /// the policy known to be active in a running core.
  var ipv6Enabled = false
  /// The active policy is absent when the state predates IPv6 persistence or
  /// when the helper has not yet observed a successful activation.
  var activeIPv6Enabled: Bool?
  var activeIPv6PolicyKnown = false
  var apiSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")

  init() {}

  private enum CodingKeys: String, CodingKey {
    case profile
    case activeProfileID
    case mode
    case selectedNode
    case selectorTag
    case nodes
    case desiredRunning
    case legacy1115RetirementComplete
    case automaticRecoveryAttempted
    case deferredRuntimeApplyPending
    case localSOCKSEnabled
    case localSOCKSPort
    case latencyTestURL
    case dnsSettings
    case ipv6Enabled
    case activeIPv6Enabled
    case activeIPv6PolicyKnown
    case apiSecret
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.profile) {
      profile = try container.decode(CoreProfile.self, forKey: .profile)
    } else {
      profile = nil
    }
    activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
    mode = try container.decodeIfPresent(RoutingMode.self, forKey: .mode) ?? .rule
    selectedNode =
      try container.decodeIfPresent(ProxyNodeID.self, forKey: .selectedNode) ?? .auto
    selectorTag =
      try container.decodeIfPresent(String.self, forKey: .selectorTag) ?? "proxy-selector"
    let storedNodes =
      try container.decodeIfPresent([ProxyNodeDescriptor].self, forKey: .nodes) ?? []
    if let profile {
      let kinds = Dictionary(grouping: profile.nodes, by: \ProxyNodeDescriptor.id)
        .compactMapValues { descriptors in
          descriptors.count == 1 ? descriptors[0].kind : nil
        }
      nodes = storedNodes.map { descriptor in
        ProxyNodeDescriptor(
          id: descriptor.id,
          name: descriptor.name,
          kind: kinds[descriptor.id] ?? descriptor.kind
        )
      }
      if selectedNode != .auto, kinds[selectedNode] == nil {
        selectedNode = .auto
      }
    } else {
      nodes = storedNodes
      if selectedNode != .auto, !nodes.contains(where: { $0.id == selectedNode }) {
        selectedNode = .auto
      }
    }
    desiredRunning = try container.decodeIfPresent(Bool.self, forKey: .desiredRunning) ?? false
    legacy1115RetirementComplete =
      try container.decodeIfPresent(Bool.self, forKey: .legacy1115RetirementComplete) ?? false
    automaticRecoveryAttempted =
      try container.decodeIfPresent(Bool.self, forKey: .automaticRecoveryAttempted) ?? false
    deferredRuntimeApplyPending =
      try container.decodeIfPresent(Bool.self, forKey: .deferredRuntimeApplyPending) ?? false
    localSOCKSEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .localSOCKSEnabled) ?? false
    localSOCKSPort =
      try container.decodeIfPresent(UInt16.self, forKey: .localSOCKSPort) ?? 1082
    let storedTarget =
      try container.decodeIfPresent(String.self, forKey: .latencyTestURL)
      ?? LatencyTargetPolicy.defaultURL
    latencyTestURL = try LatencyTargetPolicy.normalized(storedTarget)
    dnsSettings =
      container.contains(.dnsSettings)
      ? try container.decode(ManagedDNSSettings.self, forKey: .dnsSettings).validated()
      : .defaults
    let storedIPv6Enabled = try container.decodeIfPresent(Bool.self, forKey: .ipv6Enabled)
    ipv6Enabled = storedIPv6Enabled ?? false
    if let storedPolicyKnown =
      try container.decodeIfPresent(Bool.self, forKey: .activeIPv6PolicyKnown)
    {
      let storedActiveIPv6Enabled =
        try container.decodeIfPresent(Bool.self, forKey: .activeIPv6Enabled)
      activeIPv6PolicyKnown = storedPolicyKnown && storedActiveIPv6Enabled != nil
      activeIPv6Enabled = activeIPv6PolicyKnown ? storedActiveIPv6Enabled : nil
    } else if let storedActiveIPv6Enabled =
      try container.decodeIfPresent(Bool.self, forKey: .activeIPv6Enabled)
    {
      activeIPv6PolicyKnown = true
      activeIPv6Enabled = storedActiveIPv6Enabled
    } else {
      activeIPv6PolicyKnown = false
      activeIPv6Enabled = nil
    }
    apiSecret =
      try container.decodeIfPresent(String.self, forKey: .apiSecret)
      ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  var activeIPv6Policy: Bool? {
    guard activeIPv6PolicyKnown else { return nil }
    return activeIPv6Enabled
  }

  mutating func setLatencyTestURL(_ value: String) throws {
    latencyTestURL = try LatencyTargetPolicy.normalized(value)
  }
}

enum ActiveIPv6PolicyTransition {
  static func afterFreshActivation(desired: Bool) -> (known: Bool, value: Bool?) {
    (known: true, value: desired)
  }

  static func afterValidatedByteIdenticalSnapshot(
    desired: Bool,
    configurationMatches: Bool
  ) -> (known: Bool, value: Bool?) {
    guard configurationMatches else { return (known: false, value: nil) }
    return (known: true, value: desired)
  }

  static func afterExistingConfigurationRecovery(
    activePolicyKnown: Bool,
    activePolicy: Bool?
  ) -> (known: Bool, value: Bool?) {
    guard activePolicyKnown, let activePolicy else {
      return (known: false, value: nil)
    }
    return (known: true, value: activePolicy)
  }
}

enum DeferredRuntimeMarkerPolicy {
  static func deferValidatedCandidate(
    validate: () throws -> Void,
    persistMarker: () throws -> Void
  ) throws -> HelperRuntimeOutcome {
    try validate()
    try persistMarker()
    return .reconnectRequired
  }

  static func outcome(
    coreRunning: Bool,
    marker: Bool
  ) -> HelperRuntimeOutcome {
    coreRunning && marker ? .reconnectRequired : .applied
  }

  static func persist(
    _ marker: Bool,
    in state: inout PersistentState,
    save: (PersistentState) throws -> Void
  ) throws {
    let previous = state
    state.deferredRuntimeApplyPending = marker
    do {
      try save(state)
    } catch {
      state = previous
      throw error
    }
  }
}

enum DesiredRuntimeRecoveryDecision: Equatable {
  case stop
  case noAction
  case attemptRecovery
  case disableDesiredState
}

enum DesiredRuntimeRecoveryPolicy {
  static func decision(
    recoveryAuthorized: Bool,
    desiredRunning: Bool,
    coreRunning: Bool,
    profileAvailable: Bool,
    configurationAvailable: Bool,
    recoveryAlreadyAttempted: Bool
  ) -> DesiredRuntimeRecoveryDecision {
    guard recoveryAuthorized else { return .noAction }
    guard desiredRunning else { return .stop }
    guard !coreRunning else { return .noAction }
    guard profileAvailable, configurationAvailable, !recoveryAlreadyAttempted else {
      return .disableDesiredState
    }
    return .attemptRecovery
  }
}

enum CoreActivationDisposition: Equatable {
  case activate
  case reconnectRequired
}

enum CoreActivationPolicy {
  static func disposition(
    wasRunning: Bool,
    configurationChanged: Bool
  ) -> CoreActivationDisposition {
    wasRunning && configurationChanged ? .reconnectRequired : .activate
  }
}

struct CoreActivationTransactionFailure: Error, LocalizedError {
  let activationError: any Error
  let recoveryError: (any Error)?

  var errorDescription: String? {
    guard let recoveryError else { return activationError.localizedDescription }
    let activationDescription = activationError.localizedDescription
    let recoveryDescription = recoveryError.localizedDescription
    return "\(activationDescription) Runtime cleanup also failed: \(recoveryDescription)"
  }
}

struct CoreActivationTransaction<Candidate> {
  let prepare: () throws -> Candidate
  let stopKnownGood: () throws -> Void
  let commit: (Candidate) throws -> Void
  let startCandidate: () throws -> Void
  let restoreKnownGood: () throws -> Void
  let restoreDisconnected: (_ candidateLaunchAttempted: Bool) throws -> Void

  func run(wasRunning: Bool) throws {
    let candidate = try prepare()
    var candidateLaunchAttempted = false
    do {
      if wasRunning { try stopKnownGood() }
      try commit(candidate)
      candidateLaunchAttempted = true
      try startCandidate()
    } catch {
      var recoveryError: (any Error)?
      do {
        if wasRunning {
          try restoreKnownGood()
        } else {
          try restoreDisconnected(candidateLaunchAttempted)
        }
      } catch {
        recoveryError = error
      }
      throw CoreActivationTransactionFailure(
        activationError: error,
        recoveryError: recoveryError
      )
    }
  }
}

struct CoreStopTransaction {
  static func run(
    state: inout PersistentState,
    stopKnownGood: () throws -> Void,
    save: (PersistentState) throws -> Void
  ) throws {
    try stopKnownGood()
    state.desiredRunning = false
    state.automaticRecoveryAttempted = false
    state.deferredRuntimeApplyPending = false
    try save(state)
  }
}

struct CoreFileIdentity: Equatable {
  let size: Int64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let inode: UInt64

  static func read(_ url: URL) -> CoreFileIdentity? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return CoreFileIdentity(
      size: info.st_size,
      modificationSeconds: Int64(info.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      inode: UInt64(info.st_ino)
    )
  }
}

struct CoreMetadata: Codable, Equatable {
  let digest: String
  let size: Int64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let inode: UInt64
  let version: String

  init(digest: String, identity: CoreFileIdentity, version: String) {
    self.digest = digest
    size = identity.size
    modificationSeconds = identity.modificationSeconds
    modificationNanoseconds = identity.modificationNanoseconds
    inode = identity.inode
    self.version = version
  }

  func matches(_ identity: CoreFileIdentity) -> Bool {
    size == identity.size
      && modificationSeconds == identity.modificationSeconds
      && modificationNanoseconds == identity.modificationNanoseconds
      && inode == identity.inode
  }
}

final class CoreManager: @unchecked Sendable {
  private let fileManager = FileManager.default
  private let supportDirectory = URL(
    fileURLWithPath: "/Library/Application Support/SBM", isDirectory: true)
  private lazy var configURL = supportDirectory.appendingPathComponent("config.json")
  private lazy var configBackupURL = supportDirectory.appendingPathComponent("config.json.backup")
  private lazy var stateURL = supportDirectory.appendingPathComponent("state.json")
  private lazy var cacheURL = supportDirectory.appendingPathComponent("cache.db")
  private lazy var coreMetadataURL = supportDirectory.appendingPathComponent("core-metadata.json")
  private lazy var coreBackupURL = supportDirectory.appendingPathComponent("sing-box.backup")
  private let resourcesDirectory: URL
  private let bundledCoreURL: URL
  private lazy var coreURL = supportDirectory.appendingPathComponent("sing-box")
  private let expectedCoreSHA256 = CoreBuildInfo.signedSHA256

  private var state = PersistentState()
  private var coreProcess: ManagedCoreChild?
  private var coreMetadata: CoreMetadata?
  private var bootstrapFailure: String?

  init() {
    resourcesDirectory = Self.executableURL
      .deletingLastPathComponent()
    bundledCoreURL = resourcesDirectory.appendingPathComponent("sing-box")
  }

  private static var executableURL: URL {
    var buffer = [CChar](repeating: 0, count: 4096)
    let count = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
    if count > 0 {
      let bytes = buffer.prefix(Int(count)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }
    return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
  }

  func bootstrap() {
    guard Legacy1115Retirement.completionIsValid() else {
      state = PersistentState()
      bootstrapFailure = "The one-time legacy helper retirement has not completed."
      return
    }
    do {
      // Socket activation is not an authenticated lifecycle request.  Load
      // only safe persisted state here; core installation and reconciliation
      // happen after HelperServer has authenticated and parsed an action.
      try prepareFilesystem(installBundledCore: false)
      coreMetadata = loadCachedMetadataMatchingInstalledCoreIdentity()
      let loadedState = try loadState()
      guard loadedState.legacy1115RetirementComplete else {
        throw CoreFailure.coreIntegrity(
          "The current helper state has no valid retired-OFF receipt.")
      }
      state = loadedState
      bootstrapFailure = nil
    } catch {
      bootstrapFailure = error.localizedDescription
      FileHandle.standardError.write(
        Data("Core bootstrap failed: \(error.localizedDescription)\n".utf8))
    }
  }

  func auditSnapshot() -> HelperCoreAuditState {
    let coreRunning = isCoreRunning
    return HelperCoreAuditState(
      coreRunning: coreRunning,
      desiredRunning: state.desiredRunning
    )
  }

  var legacy1115Retired: Bool {
    state.legacy1115RetirementComplete
  }

  func inertLegacyUpgradeResponse(
    success: Bool = true,
    message: String = "Waiting for authenticated legacy helper retirement."
  ) -> HelperResponse {
    HelperResponse(
      success: success,
      coreRunning: false,
      legacy1115Retired: false,
      message: message
    )
  }

  func finishLegacy1115Upgrade() throws -> HelperResponse {
    if Legacy1115Retirement.completionIsValid() {
      let completedState = try loadState()
      guard completedState.legacy1115RetirementComplete else {
        throw CoreFailure.coreIntegrity("The current helper did not load its retirement receipt.")
      }
      state = completedState
      bootstrapFailure = nil
      return status(message: "Legacy helper retired; current helper is stopped.")
    }

    try Legacy1115Retirement.finish()
    var completedState = PersistentState()
    completedState.desiredRunning = false
    completedState.legacy1115RetirementComplete = true
    try prepareFilesystem(installBundledCore: false)
    try saveState(completedState)
    guard Legacy1115Retirement.completionIsValid() else {
      throw CoreFailure.coreIntegrity("The durable current retirement receipt failed readback.")
    }
    state = completedState
    bootstrapFailure = nil
    return status(message: "Legacy helper retired; current helper is stopped.")
  }

  func status(
    message: String = "Helper connected",
    runtimeOutcome: HelperRuntimeOutcome? = nil,
    observeAutoNode: Bool = false
  ) -> HelperResponse {
    let coreRunning = isCoreRunning
    let effectiveRuntimeOutcome =
      runtimeOutcome
      ?? DeferredRuntimeMarkerPolicy.outcome(
        coreRunning: coreRunning,
        marker: state.deferredRuntimeApplyPending
      )
    let recoveryExhausted = state.automaticRecoveryAttempted && !state.desiredRunning
    let effectiveMessage =
      bootstrapFailure.map { "Core bootstrap failed: \($0)" }
      ?? (recoveryExhausted
        ? "Automatic VPN recovery is exhausted; connect manually to retry"
        : effectiveRuntimeOutcome.userMessage ?? message)
    var effectiveAutoNode: ProxyNodeID?
    if observeAutoNode, coreRunning, state.selectedNode == .auto,
      case .compatibility(let activeProfile)? = state.profile,
      let data = try? apiRequest(
        method: "GET",
        path: "/proxies/auto",
        body: nil,
        timeoutSeconds: 0.25,
        totalPhaseTimeout: true
      ),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let rawID = object["now"] as? String
    {
      let nodeID = ProxyNodeID(rawValue: rawID)
      if activeProfile.connections.contains(where: { $0.id == nodeID }),
        !activeProfile.autoExcludedNodeIDs.contains(nodeID)
      {
        effectiveAutoNode = nodeID
      }
    }
    return HelperResponse(
      success: bootstrapFailure == nil && !recoveryExhausted,
      coreRunning: coreRunning,
      coreVersion: cachedCoreVersion(),
      mode: state.mode,
      selectedNode: state.selectedNode,
      effectiveAutoNode: effectiveAutoNode,
      activeProfileID: state.activeProfileID,
      activeIPv6Enabled: coreRunning ? state.activeIPv6Policy : nil,
      nodes: state.nodes,
      automaticRecoveryExhausted: recoveryExhausted,
      runtimeOutcome: effectiveRuntimeOutcome,
      legacy1115Retired: state.legacy1115RetirementComplete,
      message: effectiveMessage
    )
  }

  func reconcileDesiredRuntime(recoveryAuthorized: Bool) throws -> String? {
    guard recoveryAuthorized else { return nil }
    guard bootstrapFailure == nil else { return nil }
    let coreRunning = isCoreRunning
    if state.desiredRunning && !coreRunning {
      try prepareFilesystem()
    }
    let configurationAvailable =
      state.desiredRunning && !coreRunning
      && pathExistsWithoutFollowingSymlinks(configURL)
    let recoveryDecision = DesiredRuntimeRecoveryPolicy.decision(
      recoveryAuthorized: recoveryAuthorized,
      desiredRunning: state.desiredRunning,
      coreRunning: coreRunning,
      profileAvailable: state.profile != nil,
      configurationAvailable: configurationAvailable,
      recoveryAlreadyAttempted: state.automaticRecoveryAttempted
    )
    switch recoveryDecision {
    case .stop:
      terminateCore()
      return nil
    case .noAction:
      return nil
    case .disableDesiredState:
      state.desiredRunning = false
      try saveState()
      return "Automatic VPN recovery is exhausted; connect manually to retry"
    case .attemptRecovery:
      state.automaticRecoveryAttempted = true
      try saveState()
      do {
        try recoverDesiredRuntime()
        return "VPN recovered after an unexpected core exit"
      } catch {
        terminateCore()
        state.desiredRunning = false
        try? saveState()
        return "Automatic VPN recovery failed; connect manually to retry"
      }
    }
  }

  func start(
    profile: CoreProfile?,
    profileID: UUID? = nil,
    mode: RoutingMode? = nil,
    selectedNode: ProxyNodeID? = nil,
    localSOCKSEnabled: Bool? = nil,
    localSOCKSPort: UInt16? = nil,
    latencyTestURL: String? = nil,
    ipv6Enabled: Bool? = nil,
    dnsSettings: ManagedDNSSettings = .defaults
  ) throws -> HelperResponse {
    let normalizedLatencyTestURL = try latencyTestURL.map(LatencyTargetPolicy.normalized)
    let previousState = state
    let wasRunning = isCoreRunning
    do {
      var requestedState = previousState
      if let profile {
        requestedState.profile = profile
        requestedState.activeProfileID = profileID
      }
      if let mode {
        requestedState.mode = mode
      }
      if let selectedNode {
        requestedState.selectedNode = selectedNode
      }
      if let localSOCKSEnabled {
        requestedState.localSOCKSEnabled = localSOCKSEnabled
      }
      if let localSOCKSPort {
        guard (1024...65535).contains(Int(localSOCKSPort)), localSOCKSPort != 19090 else {
          throw CoreFailure.invalidProfile("The local SOCKS5 port is not allowed.")
        }
        requestedState.localSOCKSPort = localSOCKSPort
      }
      if let normalizedLatencyTestURL {
        requestedState.latencyTestURL = normalizedLatencyTestURL
      }
      if let ipv6Enabled {
        requestedState.ipv6Enabled = ipv6Enabled
      }
      requestedState.dnsSettings = try dnsSettings.validated()
      guard let activeProfile = requestedState.profile else {
        throw CoreFailure.profileMissing
      }

      try prepareFilesystem()
      let previousConfiguration = try configurationSnapshot()
      let preview = try configuration(
        profile: activeProfile,
        apiSecret: requestedState.apiSecret,
        state: requestedState
      )
      let configurationChanged = previousConfiguration != preview.data

      let candidateSecret: String
      switch CoreActivationPolicy.disposition(
        wasRunning: wasRunning,
        configurationChanged: configurationChanged
      ) {
      case .reconnectRequired:
        let candidateSecret = Self.makeAPISecret()
        let runtimeOutcome = try DeferredRuntimeMarkerPolicy.deferValidatedCandidate(
          validate: { [self] in
            _ = try validatedConfiguration(
              profile: activeProfile,
              apiSecret: candidateSecret,
              state: requestedState
            )
          },
          persistMarker: { [self] in
            try persistDeferredRuntimeMarker(true)
          }
        )
        runtimeLogger.notice(
          "Changed runtime candidate validated; keeping known-good core active until reconnect"
        )
        return status(
          message: runtimeOutcome.userMessage
            ?? "Changes ready to apply",
          runtimeOutcome: runtimeOutcome
        )
      case .activate:
        candidateSecret = Self.makeAPISecret()
      }

      state = requestedState
      state.deferredRuntimeApplyPending = false
      if isCoreRunning, !configurationChanged {
        let validated = try validatedConfiguration(
          profile: activeProfile,
          apiSecret: requestedState.apiSecret,
          state: requestedState
        )
        let transition = ActiveIPv6PolicyTransition.afterValidatedByteIdenticalSnapshot(
          desired: requestedState.ipv6Enabled,
          configurationMatches: validated.data == previousConfiguration
        )
        guard transition.known else {
          throw CoreFailure.configurationRejected(
            "The validated runtime snapshot did not match the active configuration."
          )
        }
        state.desiredRunning = true
        state.automaticRecoveryAttempted = false
        state.activeIPv6PolicyKnown = transition.known
        state.activeIPv6Enabled = transition.value
        try saveState()
        return status(message: "VPN already connected")
      }
      var knownGoodWasStopped = false
      let transaction = CoreActivationTransaction<BuiltConfiguration>(
        prepare: { [self] in
          let candidate = try validatedConfiguration(
            profile: activeProfile,
            apiSecret: candidateSecret
          )
          if wasRunning { try backupActiveConfiguration() }
          runtimeLogger.info("Runtime candidate validated before transition")
          return candidate
        },
        stopKnownGood: { [self] in
          runtimeLogger.notice("Runtime activation transition starting")
          guard terminateCore() else { throw CoreFailure.coreStopFailed }
          knownGoodWasStopped = true
          try ensureAPIPortAvailable()
        },
        commit: { [self] built in
          state.apiSecret = candidateSecret
          try writeValidatedConfiguration(built)
          state.selectorTag = built.selectorTag
          state.nodes = built.nodes
          state.selectedNode = built.selectedNode
        },
        startCandidate: { [self] in
          try launchCore()
          try waitForAPI()
          try applyMode(state.mode)
          try applyNode(state.selectedNode)
          let transition = ActiveIPv6PolicyTransition.afterFreshActivation(
            desired: state.ipv6Enabled
          )
          state.activeIPv6PolicyKnown = transition.known
          state.activeIPv6Enabled = transition.value
          state.desiredRunning = true
          state.automaticRecoveryAttempted = false
          try saveState()
          runtimeLogger.notice("Runtime activation succeeded")
        },
        restoreKnownGood: { [self] in
          state = previousState
          if knownGoodWasStopped {
            guard terminateCore() else { throw CoreFailure.coreStopFailed }
            try restoreBackupConfiguration()
            try ensureAPIPortAvailable()
            try launchCore()
            try waitForAPI()
            try applyMode(state.mode)
            try applyNode(state.selectedNode)
          }
          state.desiredRunning = true
          try saveState()
        },
        restoreDisconnected: { [self] candidateLaunchAttempted in
          state = previousState
          if candidateLaunchAttempted {
            guard terminateCore() else { throw CoreFailure.coreStopFailed }
          }
          try restoreConfigurationSnapshot(previousConfiguration)
          try saveState()
        }
      )
      try transaction.run(wasRunning: wasRunning)
      return status(message: "VPN connected")
    } catch let failure as CoreActivationTransactionFailure {
      if failure.recoveryError != nil {
        runtimeLogger.error("Runtime activation and known-good recovery failed")
        _ = terminateCore()
        state = previousState
        state.desiredRunning = false
      } else if !wasRunning {
        runtimeLogger.error("Runtime activation failed without a prior active core")
        state = previousState
      } else {
        runtimeLogger.notice("Runtime activation failed; known-good runtime restored")
      }
      try? saveState()
      if failure.recoveryError != nil { throw failure }
      throw failure.activationError
    } catch {
      runtimeLogger.error("Runtime candidate preparation failed before transition")
      state = previousState
      try? saveState()
      throw error
    }
  }

  func stop() throws -> HelperResponse {
    try CoreStopTransaction.run(
      state: &state,
      stopKnownGood: { [self] in
        guard terminateCore(), !isCoreRunning else {
          throw CoreFailure.coreStopFailed
        }
      },
      save: { [self] snapshot in
        try saveState(snapshot)
      }
    )
    return status(message: "VPN disconnected")
  }

  func setMode(_ mode: RoutingMode) throws -> HelperResponse {
    let previous = state.mode
    do {
      if isCoreRunning {
        try applyMode(mode)
      }
      state.mode = mode
      try saveState()
    } catch {
      if isCoreRunning {
        try? applyMode(previous)
      }
      state.mode = previous
      try? saveState()
      throw error
    }
    return status(message: "Mode: \(mode.rawValue)")
  }

  func setNode(_ node: ProxyNodeID) throws -> HelperResponse {
    guard state.nodes.contains(where: { $0.id == node }) else {
      throw CoreFailure.invalidProfile("The selected server is not part of the active profile.")
    }
    let previous = state.selectedNode
    do {
      if isCoreRunning {
        try applyNode(node)
      }
      state.selectedNode = node
      try saveState()
    } catch {
      if isCoreRunning {
        try? applyNode(previous)
      }
      state.selectedNode = previous
      try? saveState()
      throw error
    }
    return status(message: "Server: \(node.rawValue)")
  }

  func setLatencyTarget(_ value: String) throws -> HelperResponse {
    let previous = state.latencyTestURL
    do {
      try state.setLatencyTestURL(value)
      try saveState()
    } catch {
      state.latencyTestURL = previous
      try? saveState()
      throw error
    }
    return status(message: "Latency target updated")
  }

  func testLatency(node requestedNode: ProxyNodeID? = nil) throws -> HelperResponse {
    guard requestedNode != .auto else {
      throw CoreFailure.invalidProfile("Auto latency is owned by sing-box.")
    }
    guard isCoreRunning else { throw CoreFailure.coreNotRunning }
    let delays: [NodeDelay]
    if let requestedNode {
      guard state.nodes.contains(where: { $0.id == requestedNode }) else {
        throw CoreFailure.invalidProfile("The requested latency node is not active.")
      }
      _ = try apiRequest(
        method: "GET",
        path: LatencyDelayRequest.path(for: requestedNode, target: state.latencyTestURL),
        body: nil,
        timeoutSeconds: 0.25,
        totalPhaseTimeout: true,
        waitForResponse: false
      )
      delays = []
    } else {
      let data = try apiRequest(
        method: "GET",
        path: "/proxies",
        body: nil,
        timeoutSeconds: 0.25,
        totalPhaseTimeout: true
      )
      delays = try parseLatencyHistory(data, nodes: state.nodes)
    }
    return HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: cachedCoreVersion(),
      mode: state.mode,
      selectedNode: state.selectedNode,
      activeProfileID: state.activeProfileID,
      activeIPv6Enabled: state.activeIPv6Policy,
      nodes: state.nodes,
      delays: delays,
      runtimeOutcome: DeferredRuntimeMarkerPolicy.outcome(
        coreRunning: true,
        marker: state.deferredRuntimeApplyPending
      ),
      legacy1115Retired: state.legacy1115RetirementComplete,
      message: "Latency updated"
    )
  }

  func validate(profile: CoreProfile) throws -> HelperResponse {
    try prepareFilesystem()
    let built = try validatedConfiguration(
      profile: profile,
      apiSecret: state.apiSecret
    )
    return HelperResponse(
      success: true,
      coreRunning: isCoreRunning,
      coreVersion: cachedCoreVersion(),
      mode: state.mode,
      selectedNode: built.selectedNode,
      activeProfileID: state.activeProfileID,
      activeIPv6Enabled: isCoreRunning ? state.activeIPv6Policy : nil,
      nodes: built.nodes,
      legacy1115Retired: state.legacy1115RetirementComplete,
      message: "Profile validated"
    )
  }

  private var isCoreRunning: Bool {
    coreProcess?.isRunning == true
  }

  private func prepareFilesystem(installBundledCore: Bool = true) throws {
    if pathExistsWithoutFollowingSymlinks(supportDirectory) {
      guard isRootOwnedDirectory(supportDirectory) else {
        throw CoreFailure.coreIntegrity(
          "The root support path has unsafe ownership or file type.")
      }
    } else {
      try fileManager.createDirectory(
        at: supportDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
    guard isSecureRootDirectory(supportDirectory) else {
      throw CoreFailure.coreIntegrity(
        "The root support directory has unsafe ownership, permissions, or file type.")
    }
    for url in [
      configURL, configBackupURL, stateURL, cacheURL, coreMetadataURL, coreBackupURL,
    ] {
      try requireSecureManagedFileIfPresent(url)
    }
    if installBundledCore {
      try installBundledCoreIfNeeded()
    }
  }

  private func installBundledCoreIfNeeded() throws {
    if cachedMetadataMatchesInstalledCore() {
      return
    }
    if fileManager.isExecutableFile(atPath: coreURL.path),
      isSecureRootRegularFile(coreURL),
      try sha256(of: coreURL) == expectedCoreSHA256
    {
      try secureExecutable(coreURL)
      guard readCoreVersion(at: coreURL) == "sing-box version \(CoreBuildInfo.version)" else {
        throw CoreFailure.coreIntegrity("The installed sing-box version does not match this build.")
      }
      if pathExistsWithoutFollowingSymlinks(configURL) {
        try requireSecureManagedFileIfPresent(configURL)
        try runCore(arguments: ["check", "-c", configURL.path])
      }
      let wasCoreRunning = isCoreRunning
      try saveCoreMetadata(
        for: coreURL,
        expectedDigest: expectedCoreSHA256,
        expectedVersion: "sing-box version \(CoreBuildInfo.version)"
      )
      if wasCoreRunning {
        terminateCore()
      }
      return
    }
    let candidate = supportDirectory.appendingPathComponent(
      "sing-box.candidate-\(UUID().uuidString)")
    var candidateCaptured = false
    defer {
      if candidateCaptured {
        try? fileManager.removeItem(at: candidate)
      }
    }
    try Self.captureBundledCore(
      from: bundledCoreURL,
      to: candidate,
      expectedSize: CoreBuildInfo.signedSize
    )
    candidateCaptured = true
    try secureExecutable(candidate)
    guard try sha256(of: candidate) == expectedCoreSHA256 else {
      throw CoreFailure.coreIntegrity("The root-owned sing-box copy failed verification.")
    }
    guard readCoreVersion(at: candidate) == "sing-box version \(CoreBuildInfo.version)" else {
      throw CoreFailure.coreIntegrity("The bundled sing-box version does not match this build.")
    }
    if pathExistsWithoutFollowingSymlinks(configURL) {
      try requireSecureManagedFileIfPresent(configURL)
      try runCore(executable: candidate, arguments: ["check", "-c", configURL.path])
    }
    let wasCoreRunning = isCoreRunning
    var rollbackMetadata: CoreMetadata?
    if pathExistsWithoutFollowingSymlinks(coreURL) {
      guard isRegularFileWithoutFollowingSymlinks(coreURL) else {
        throw CoreFailure.coreIntegrity(
          "The existing managed executable has an unsafe file type.")
      }
      if let metadata = try verifiedInstalledCoreMetadata() {
        let backupCandidate = supportDirectory.appendingPathComponent(
          "sing-box.backup-\(UUID().uuidString)")
        try fileManager.copyItem(at: coreURL, to: backupCandidate)
        defer { try? fileManager.removeItem(at: backupCandidate) }
        try secureExecutable(backupCandidate)
        try atomicReplace(backupCandidate, at: coreBackupURL)
        rollbackMetadata = metadata
      }
    }
    do {
      try atomicReplace(candidate, at: coreURL, replacingLegacyCore: true)
      try secureExecutable(coreURL)
      try saveCoreMetadata(
        for: coreURL,
        expectedDigest: expectedCoreSHA256,
        expectedVersion: "sing-box version \(CoreBuildInfo.version)"
      )
    } catch {
      if let rollbackMetadata {
        try restoreBackupCore(expectedMetadata: rollbackMetadata)
      }
      throw error
    }
    if wasCoreRunning {
      terminateCore()
    }
  }

  static func captureBundledCore(
    from source: URL,
    to destination: URL,
    expectedSize: Int64
  ) throws {
    guard expectedSize > 0 else {
      throw CoreFailure.coreIntegrity("Invalid signed core size.")
    }
    let sourcePath = source.path
    let destinationPath = destination.path
    var sourceDescriptor: Int32 = -1
    var destinationDescriptor: Int32 = -1
    var removeCandidateOnFailure = false
    defer {
      if destinationDescriptor >= 0 { _ = Darwin.close(destinationDescriptor) }
      if sourceDescriptor >= 0 { _ = Darwin.close(sourceDescriptor) }
      if removeCandidateOnFailure { _ = Darwin.unlink(destinationPath) }
    }
    sourceDescriptor = sourcePath.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    }
    guard sourceDescriptor >= 0 else {
      if errno == ENOENT { throw CoreFailure.coreMissing }
      throw CoreFailure.coreIntegrity("Unable to open bundled sing-box core (errno \(errno)).")
    }
    var sourceInfo = stat()
    var statResult = Darwin.fstat(sourceDescriptor, &sourceInfo)
    while statResult != 0 && errno == EINTR {
      statResult = Darwin.fstat(sourceDescriptor, &sourceInfo)
    }
    guard statResult == 0, sourceInfo.st_mode & S_IFMT == S_IFREG,
      sourceInfo.st_size == expectedSize
    else {
      throw CoreFailure.coreIntegrity("Bundled sing-box is not a regular file of signed size.")
    }
    destinationDescriptor = destinationPath.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    }
    guard destinationDescriptor >= 0 else {
      throw CoreFailure.coreIntegrity("Unable to create sing-box candidate (errno \(errno)).")
    }
    removeCandidateOnFailure = true
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var copied: Int64 = 0
    while copied < expectedSize {
      let readLimit = min(buffer.count, Int(expectedSize - copied))
      var readCount = buffer.withUnsafeMutableBytes {
        Darwin.read(sourceDescriptor, $0.baseAddress, size_t(readLimit))
      }
      while readCount < 0 && errno == EINTR {
        readCount = buffer.withUnsafeMutableBytes {
          Darwin.read(sourceDescriptor, $0.baseAddress, size_t(readLimit))
        }
      }
      guard readCount > 0 else {
        throw CoreFailure.coreIntegrity("Bundled sing-box ended before its signed size.")
      }
      var written = 0
      while written < readCount {
        var writeCount = buffer.withUnsafeBytes {
          Darwin.write(
            destinationDescriptor,
            $0.baseAddress?.advanced(by: written),
            size_t(readCount - written)
          )
        }
        while writeCount < 0 && errno == EINTR {
          writeCount = buffer.withUnsafeBytes {
            Darwin.write(
              destinationDescriptor,
              $0.baseAddress?.advanced(by: written),
              size_t(readCount - written)
            )
          }
        }
        guard writeCount > 0 else {
          throw CoreFailure.coreIntegrity("Unable to write sing-box candidate.")
        }
        written += writeCount
      }
      copied += Int64(readCount)
    }
    var extraByte: UInt8 = 0
    var extraRead = withUnsafeMutableBytes(of: &extraByte) {
      Darwin.read(sourceDescriptor, $0.baseAddress, 1)
    }
    while extraRead < 0 && errno == EINTR {
      extraRead = withUnsafeMutableBytes(of: &extraByte) {
        Darwin.read(sourceDescriptor, $0.baseAddress, 1)
      }
    }
    guard extraRead == 0 else {
      throw CoreFailure.coreIntegrity("Bundled sing-box did not end at its signed size.")
    }
    guard copied == expectedSize else {
      throw CoreFailure.coreIntegrity("Sing-box candidate size differs from signed size.")
    }
    removeCandidateOnFailure = false
  }

  private func restoreBackupCore(expectedMetadata: CoreMetadata) throws {
    try requireSecureManagedFileIfPresent(coreBackupURL)
    let candidate = supportDirectory.appendingPathComponent(
      "sing-box.rollback-\(UUID().uuidString)")
    try fileManager.copyItem(at: coreBackupURL, to: candidate)
    defer { try? fileManager.removeItem(at: candidate) }
    try takeRootOwnershipOfCopiedRegularFile(candidate)
    try secureExecutable(candidate)
    guard try sha256(of: candidate) == expectedMetadata.digest,
      readCoreVersion(at: candidate) == expectedMetadata.version
    else {
      throw CoreFailure.coreIntegrity("The rollback sing-box copy failed verification.")
    }
    try atomicReplace(candidate, at: coreURL, replacingLegacyCore: true)
    try secureExecutable(coreURL)
    try saveCoreMetadata(
      for: coreURL,
      expectedDigest: expectedMetadata.digest,
      expectedVersion: expectedMetadata.version
    )
  }

  private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func secureExecutable(_ url: URL) throws {
    guard isRootOwnedRegularFile(url) else {
      throw CoreFailure.coreIntegrity(
        "A managed executable has unsafe ownership or file type.")
    }
    try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
    guard isSecureRootRegularFile(url) else {
      throw CoreFailure.coreIntegrity("Unable to secure a managed executable.")
    }
  }

  private func cachedMetadataMatchesInstalledCore() -> Bool {
    guard let metadata = coreMetadataMatchingInstalledIdentity() else { return false }
    return metadata.digest == expectedCoreSHA256
      && metadata.version == "sing-box version \(CoreBuildInfo.version)"
  }

  private func verifiedInstalledCoreMetadata() throws -> CoreMetadata? {
    guard let metadata = coreMetadataMatchingInstalledIdentity() else { return nil }
    do {
      guard try sha256(of: coreURL) == metadata.digest,
        readCoreVersion(at: coreURL) == metadata.version
      else {
        coreMetadata = nil
        return nil
      }
      return metadata
    } catch {
      coreMetadata = nil
      throw error
    }
  }

  private func loadCachedMetadataMatchingInstalledCoreIdentity() -> CoreMetadata? {
    guard isSecureRootRegularFile(coreURL),
      isSecureRootRegularFile(coreMetadataURL),
      let data = try? Data(contentsOf: coreMetadataURL),
      let metadata = try? JSONDecoder().decode(CoreMetadata.self, from: data),
      let info = CoreFileIdentity.read(coreURL)
    else { return nil }
    guard metadata.matches(info),
      metadata.digest == expectedCoreSHA256,
      metadata.version == "sing-box version \(CoreBuildInfo.version)"
    else { return nil }
    return metadata
  }

  private func coreMetadataMatchingInstalledIdentity() -> CoreMetadata? {
    guard let metadata = coreMetadata,
      isSecureRootRegularFile(coreURL),
      let identity = CoreFileIdentity.read(coreURL),
      metadata.matches(identity)
    else {
      coreMetadata = nil
      return nil
    }
    return metadata
  }

  private func saveCoreMetadata(
    for url: URL,
    expectedDigest: String,
    expectedVersion: String
  ) throws {
    guard let identity = CoreFileIdentity.read(url),
      let version = readCoreVersion(at: url)
    else {
      throw CoreFailure.coreIntegrity("Unable to identify the verified sing-box core.")
    }
    let digest = try sha256(of: url)
    guard digest == expectedDigest, version == expectedVersion else {
      throw CoreFailure.coreIntegrity(
        "The verified sing-box core changed before metadata was saved.")
    }
    let metadata = CoreMetadata(digest: digest, identity: identity, version: version)
    try JSONEncoder().encode(metadata).write(to: coreMetadataURL, options: .atomic)
    try secureFile(coreMetadataURL)
    coreMetadata = metadata
  }

  private func isSecureRootDirectory(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFDIR
      && info.st_uid == 0
      && (info.st_mode & 0o077) == 0
  }

  private func isRootOwnedDirectory(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == 0
  }

  private func isRootOwnedRegularFile(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == 0
  }

  private func isRegularFileWithoutFollowingSymlinks(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFREG
  }

  private func takeRootOwnershipOfCopiedRegularFile(_ url: URL) throws {
    guard isRegularFileWithoutFollowingSymlinks(url), lchown(url.path, 0, 0) == 0 else {
      throw CoreFailure.coreIntegrity(
        "Unable to take ownership of the verified sing-box copy.")
    }
  }

  private func isSecureRootRegularFile(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFREG
      && info.st_uid == 0
      && (info.st_mode & 0o022) == 0
  }

  private func pathExistsWithoutFollowingSymlinks(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
  }

  private func requireSecureManagedFileIfPresent(_ url: URL) throws {
    guard pathExistsWithoutFollowingSymlinks(url) else { return }
    guard isSecureRootRegularFile(url) else {
      throw CoreFailure.coreIntegrity(
        "Managed file \(url.lastPathComponent) has unsafe ownership, permissions, or file type."
      )
    }
  }

  private func synchronizeFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
  }

  private func synchronizeSupportDirectory() throws {
    let descriptor = open(supportDirectory.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 || errno == EINVAL else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private func atomicReplace(
    _ candidate: URL,
    at destination: URL,
    replacingLegacyCore: Bool = false
  ) throws {
    try requireSecureManagedFileIfPresent(candidate)
    if pathExistsWithoutFollowingSymlinks(destination) {
      if replacingLegacyCore {
        guard isRegularFileWithoutFollowingSymlinks(destination) else {
          throw CoreFailure.coreIntegrity(
            "The existing managed executable has an unsafe file type.")
        }
      } else {
        try requireSecureManagedFileIfPresent(destination)
      }
    }
    try synchronizeFile(candidate)
    guard rename(candidate.path, destination.path) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    try synchronizeSupportDirectory()
  }

  private func validatedConfiguration(
    profile: CoreProfile,
    apiSecret: String,
    state runtimeState: PersistentState? = nil
  ) throws -> BuiltConfiguration {
    let built = try configuration(profile: profile, apiSecret: apiSecret, state: runtimeState)
    try validateConfiguration(built)
    return built
  }

  private func configuration(
    profile: CoreProfile,
    apiSecret: String,
    state runtimeState: PersistentState? = nil
  ) throws -> BuiltConfiguration {
    let effectiveState = runtimeState ?? state
    let builder = ConfigBuilder(
      cachePath: cacheURL.path,
      apiSecret: apiSecret
    )
    return try builder.makeConfiguration(
      profile: profile,
      mode: effectiveState.mode,
      selectedNode: effectiveState.selectedNode,
      localSOCKSPort: effectiveState.localSOCKSEnabled ? effectiveState.localSOCKSPort : nil,
      latencyTestURL: effectiveState.latencyTestURL,
      ipv6Enabled: effectiveState.ipv6Enabled,
      dnsSettings: effectiveState.dnsSettings
    )
  }

  private func validateConfiguration(_ built: BuiltConfiguration) throws {
    let candidate = supportDirectory.appendingPathComponent(
      "validation-\(UUID().uuidString).json"
    )
    try built.data.write(to: candidate, options: .atomic)
    defer { try? fileManager.removeItem(at: candidate) }
    try secureFile(candidate)
    try runCore(arguments: ["check", "-c", candidate.path])
  }

  private func backupActiveConfiguration() throws {
    guard pathExistsWithoutFollowingSymlinks(configURL) else {
      throw CoreFailure.configurationRejected(
        "No active configuration is available for rollback.")
    }
    try requireSecureManagedFileIfPresent(configURL)
    let backupCandidate = supportDirectory.appendingPathComponent(
      "config.json.backup-\(UUID().uuidString)")
    try fileManager.copyItem(at: configURL, to: backupCandidate)
    defer { try? fileManager.removeItem(at: backupCandidate) }
    try secureFile(backupCandidate)
    try atomicReplace(backupCandidate, at: configBackupURL)
  }

  private func configurationSnapshot() throws -> Data? {
    guard pathExistsWithoutFollowingSymlinks(configURL) else { return nil }
    try requireSecureManagedFileIfPresent(configURL)
    return try Data(contentsOf: configURL)
  }

  private func restoreConfigurationSnapshot(_ snapshot: Data?) throws {
    guard let snapshot else {
      guard pathExistsWithoutFollowingSymlinks(configURL) else { return }
      try requireSecureManagedFileIfPresent(configURL)
      try fileManager.removeItem(at: configURL)
      return
    }
    let candidate = supportDirectory.appendingPathComponent(
      "config.json.restore-\(UUID().uuidString)")
    try snapshot.write(to: candidate, options: .atomic)
    defer { try? fileManager.removeItem(at: candidate) }
    try secureFile(candidate)
    try atomicReplace(candidate, at: configURL)
    try secureFile(configURL)
  }

  private func writeValidatedConfiguration(_ built: BuiltConfiguration) throws {
    let candidate = supportDirectory.appendingPathComponent(
      "config.json.candidate-\(UUID().uuidString)")
    try built.data.write(to: candidate, options: .atomic)
    defer { try? fileManager.removeItem(at: candidate) }
    try secureFile(candidate)
    try atomicReplace(candidate, at: configURL)
    try secureFile(configURL)
  }

  private func restoreBackupConfiguration() throws {
    guard pathExistsWithoutFollowingSymlinks(configBackupURL) else {
      throw CoreFailure.configurationRejected(
        "No previous configuration is available for rollback.")
    }
    try requireSecureManagedFileIfPresent(configBackupURL)
    let candidate = supportDirectory.appendingPathComponent(
      "config.json.restore-\(UUID().uuidString)")
    try fileManager.copyItem(at: configBackupURL, to: candidate)
    defer { try? fileManager.removeItem(at: candidate) }
    try secureFile(candidate)
    try atomicReplace(candidate, at: configURL)
    try secureFile(configURL)
  }

  private func launchCore() throws {
    if let existing = coreProcess {
      guard !existing.isRunning else { throw CoreFailure.coreAlreadyRunning }
      coreProcess = nil
    }
    let process = try ManagedCoreChild.launch(
      executableURL: coreURL,
      arguments: ["run", "-c", configURL.path],
      currentDirectoryURL: supportDirectory
    )
    coreProcess = process

    if let status = process.waitUntilExit(timeout: 0.1) {
      coreProcess = nil
      throw CoreFailure.coreExited(status)
    }
  }

  private func recoverDesiredRuntime() throws {
    guard state.profile != nil else { throw CoreFailure.profileMissing }
    guard pathExistsWithoutFollowingSymlinks(configURL) else {
      throw CoreFailure.configurationRejected(
        "No known-good configuration is available for automatic recovery.")
    }
    try requireSecureManagedFileIfPresent(configURL)
    try runCore(arguments: ["check", "-c", configURL.path])
    try ensureAPIPortAvailable()
    try launchCore()
    try waitForAPI()
    try applyMode(state.mode)
    try applyNode(state.selectedNode)
    let transition = ActiveIPv6PolicyTransition.afterExistingConfigurationRecovery(
      activePolicyKnown: state.activeIPv6PolicyKnown,
      activePolicy: state.activeIPv6Enabled
    )
    state.activeIPv6PolicyKnown = transition.known
    state.activeIPv6Enabled = transition.value
    try saveState()
  }

  private func loadState() throws -> PersistentState {
    guard fileManager.fileExists(atPath: stateURL.path) else {
      throw CoreFailure.coreIntegrity("The completed current helper state is missing.")
    }
    let data = try Data(contentsOf: stateURL)
    try StrictJSONDuplicateValidator.validate(
      data,
      maximumBytes: 4 * 1_024 * 1_024,
      maximumDepth: 32,
      maximumStringBytes: 2 * 1_024 * 1_024
    )
    let decoded = try JSONDecoder().decode(PersistentState.self, from: data)
    guard decoded.legacy1115RetirementComplete else {
      throw CoreFailure.coreIntegrity("The current helper state has no valid retired-OFF receipt.")
    }
    return decoded
  }

  private func persistDeferredRuntimeMarker(_ marker: Bool) throws {
    try DeferredRuntimeMarkerPolicy.persist(marker, in: &state) { snapshot in
      try saveState(snapshot)
    }
  }

  private func saveState(_ snapshot: PersistentState? = nil) throws {
    let data = try JSONEncoder().encode(snapshot ?? state)
    try data.write(to: stateURL, options: .atomic)
    try secureFile(stateURL)
    try synchronizeFile(stateURL)
    try synchronizeSupportDirectory()
  }

  private func secureFile(_ url: URL) throws {
    guard isRootOwnedRegularFile(url) else {
      throw CoreFailure.coreIntegrity("A managed file has unsafe ownership or file type.")
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    guard isSecureRootRegularFile(url) else {
      throw CoreFailure.coreIntegrity("Unable to secure a managed file.")
    }
  }

  @discardableResult
  private func runCore(
    executable: URL? = nil,
    arguments: [String],
    timeoutSeconds: TimeInterval = 10
  ) throws -> Bool {
    let outputURL = supportDirectory.appendingPathComponent(
      "core-check-\(UUID().uuidString).log")
    guard
      fileManager.createFile(
        atPath: outputURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw CoreFailure.configurationRejected("Unable to create the validation log.")
    }
    defer { try? fileManager.removeItem(at: outputURL) }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = executable ?? coreURL
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning, Date() < deadline {
      usleep(50_000)
    }
    if process.isRunning {
      process.terminate()
      usleep(250_000)
      if process.isRunning {
        _ = kill(process.processIdentifier, SIGKILL)
      }
      process.waitUntilExit()
      throw CoreFailure.configurationCheckTimedOut
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      try? output.synchronize()
      throw CoreFailure.configurationRejected(
        "The generated profile did not pass the bundled core check.")
    }
    try? output.synchronize()
    let attributes = try? fileManager.attributesOfItem(atPath: outputURL.path)
    return (attributes?[.size] as? NSNumber)?.intValue ?? 0 > 0
  }

  private func cachedCoreVersion() -> String? {
    coreMetadata?.version
  }

  private func readCoreVersion(at executable: URL) -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = ["version"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      let line = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .split(separator: "\n").first
      return line.map(String.init)
    } catch {
      return nil
    }
  }

  private func applyMode(_ mode: RoutingMode) throws {
    let body = try JSONSerialization.data(withJSONObject: ["mode": mode.rawValue])
    _ = try apiRequest(method: "PATCH", path: "/configs", body: body)
  }

  private func waitForAPI() throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      if (try? apiRequest(
        method: "GET",
        path: "/version",
        body: nil,
        timeoutSeconds: 1
      )) != nil {
        return
      }
      if !isCoreRunning { break }
      usleep(100_000)
    }
    throw CoreFailure.apiUnavailable
  }

  @discardableResult
  private func terminateCore() -> Bool {
    guard let process = coreProcess else { return true }
    guard process.terminate(), !process.isRunning else { return false }
    coreProcess = nil
    return true
  }

  private func applyNode(_ node: ProxyNodeID) throws {
    let body = try JSONSerialization.data(withJSONObject: ["name": node.rawValue])
    let selector = apiPathComponent(state.selectorTag)
    _ = try apiRequest(method: "PUT", path: "/proxies/\(selector)", body: body)
  }

  private func apiPathComponent(_ value: String) -> String {
    let unreserved = Set(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8
    )
    return value.utf8.map { byte in
      unreserved.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
    }.joined()
  }

  private func apiRequest(
    method: String,
    path: String,
    body: Data?,
    timeoutSeconds: TimeInterval = 2,
    totalPhaseTimeout: Bool = false,
    waitForResponse: Bool = true
  ) throws -> Data {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CoreFailure.apiUnavailable }
    defer { close(descriptor) }
    try configureSocketTimeouts(descriptor, seconds: timeoutSeconds)
    let deadline =
      totalPhaseTimeout
      ? ProcessInfo.processInfo.systemUptime + timeoutSeconds
      : nil

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(19090).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    try connectAPISocket(descriptor, address: &address, deadline: deadline)

    let payload = body ?? Data()
    var request = "\(method) \(path) HTTP/1.1\r\n"
    request += "Host: 127.0.0.1\r\n"
    request += "Authorization: Bearer \(state.apiSecret)\r\n"
    request += "Content-Type: application/json\r\n"
    request += "Content-Length: \(payload.count)\r\n"
    request += "Connection: close\r\n\r\n"
    var bytes = Data(request.utf8)
    bytes.append(payload)
    try writeAll(bytes, to: descriptor, deadline: deadline)
    guard waitForResponse else { return Data() }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let maximumResponseBytes = 1_048_576
    while true {
      if let deadline {
        try configureSocketTimeout(
          descriptor,
          option: SO_RCVTIMEO,
          seconds: deadline - ProcessInfo.processInfo.systemUptime
        )
      }
      if response.count == maximumResponseBytes {
        var extraByte: UInt8 = 0
        let count = Darwin.read(descriptor, &extraByte, 1)
        if count < 0, errno == EINTR { continue }
        guard count == 0 else { throw CoreFailure.apiUnavailable }
        break
      }
      let requested = min(buffer.count, maximumResponseBytes - response.count)
      let count = Darwin.read(descriptor, &buffer, requested)
      if count < 0, errno == EINTR { continue }
      if count < 0 { throw CoreFailure.apiUnavailable }
      if count == 0 { break }
      response.append(contentsOf: buffer.prefix(count))
    }
    return try Self.parseAPIResponse(response)
  }

  static func parseAPIResponse(_ response: Data) throws -> Data {
    let maximumResponseBytes = 1_048_576
    guard response.count <= maximumResponseBytes,
      let separator = response.range(of: Data("\r\n\r\n".utf8)),
      let head = String(data: response[..<separator.lowerBound], encoding: .ascii)
    else { throw CoreFailure.apiUnavailable }

    let lines = head.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else { throw CoreFailure.apiUnavailable }
    let statusParts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
    guard statusParts.count >= 2,
      statusParts[0] == "HTTP/1.1",
      statusParts[1].count == 3,
      statusParts[1].allSatisfy(\.isNumber),
      let status = Int(statusParts[1]),
      (200..<300).contains(status)
    else { throw CoreFailure.apiUnavailable }

    var contentLength: Int?
    var transferEncoding: String?
    for line in lines.dropFirst() {
      let (name, value) = try parseHTTPHeader(line)
      switch name {
      case "content-length":
        let trimmed = trimHTTPWhitespace(value)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
          let parsed = Int(trimmed)
        else { throw CoreFailure.apiUnavailable }
        if let contentLength, contentLength != parsed {
          throw CoreFailure.apiUnavailable
        }
        contentLength = parsed
      case "transfer-encoding":
        guard transferEncoding == nil else { throw CoreFailure.apiUnavailable }
        let parsed = trimHTTPWhitespace(value).lowercased()
        guard parsed == "chunked" else { throw CoreFailure.apiUnavailable }
        transferEncoding = parsed
      default:
        break
      }
    }
    guard contentLength == nil || transferEncoding == nil else {
      throw CoreFailure.apiUnavailable
    }

    let body = Data(response[separator.upperBound...])
    if transferEncoding == "chunked" {
      return try decodeChunkedAPIResponseBody(body)
    }
    if let contentLength {
      guard body.count == contentLength else { throw CoreFailure.apiUnavailable }
      return body
    }
    return body
  }

  private static func parseHTTPHeader(_ line: String) throws -> (String, String) {
    guard let colon = line.firstIndex(of: ":") else { throw CoreFailure.apiUnavailable }
    let name = String(line[..<colon])
    let value = String(line[line.index(after: colon)...])
    guard !name.isEmpty, name.utf8.allSatisfy(isHTTPTokenByte),
      value.utf8.allSatisfy({ $0 == 0x09 || (0x20...0x7e).contains($0) })
    else { throw CoreFailure.apiUnavailable }
    return (name.lowercased(), value)
  }

  private static func isHTTPTokenByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
      || Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
  }

  private static func trimHTTPWhitespace(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
  }

  private static func decodeChunkedAPIResponseBody(_ body: Data) throws -> Data {
    let bytes = Array(body)
    var cursor = 0
    var decoded = Data()
    while true {
      guard let (sizeLine, nextCursor) = readHTTPLine(bytes, from: cursor),
        !sizeLine.isEmpty,
        sizeLine.utf8.allSatisfy(isHexByte),
        let chunkSize = UInt64(sizeLine, radix: 16),
        chunkSize <= UInt64(Int.max)
      else { throw CoreFailure.apiUnavailable }
      cursor = nextCursor
      if chunkSize == 0 {
        while true {
          guard let (trailer, trailerEnd) = readHTTPLine(bytes, from: cursor) else {
            throw CoreFailure.apiUnavailable
          }
          cursor = trailerEnd
          if trailer.isEmpty {
            guard cursor == bytes.count else { throw CoreFailure.apiUnavailable }
            return decoded
          }
          _ = try parseHTTPHeader(trailer)
        }
      }

      let count = Int(chunkSize)
      guard count <= 1_048_576 - decoded.count,
        cursor <= bytes.count,
        count <= bytes.count - cursor,
        bytes.count - cursor - count >= 2
      else { throw CoreFailure.apiUnavailable }
      let chunkEnd = cursor + count
      guard bytes[chunkEnd] == 0x0d, bytes[chunkEnd + 1] == 0x0a else {
        throw CoreFailure.apiUnavailable
      }
      decoded.append(contentsOf: bytes[cursor..<chunkEnd])
      cursor = chunkEnd + 2
    }
  }

  private static func readHTTPLine(_ bytes: [UInt8], from start: Int) -> (String, Int)? {
    guard start >= 0, start <= bytes.count - 2 else { return nil }
    var index = start
    while index < bytes.count {
      if bytes[index] == 0x0d {
        guard index + 1 < bytes.count, bytes[index + 1] == 0x0a,
          let line = String(bytes: bytes[start..<index], encoding: .ascii)
        else { return nil }
        return (line, index + 2)
      }
      guard bytes[index] != 0x0a else { return nil }
      index += 1
    }
    return nil
  }

  private static func isHexByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
  }

  private func connectAPISocket(
    _ descriptor: Int32,
    address: inout sockaddr_in,
    deadline: TimeInterval?
  ) throws {
    guard let deadline else {
      var result: Int32
      repeat {
        result = withUnsafePointer(to: &address) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
      } while result != 0 && errno == EINTR
      guard result == 0 else { throw CoreFailure.apiUnavailable }
      return
    }

    let originalFlags = fcntl(descriptor, F_GETFL)
    guard originalFlags >= 0,
      fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) >= 0
    else { throw CoreFailure.apiUnavailable }
    defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result != 0 else { return }
    guard errno == EINPROGRESS || errno == EINTR || errno == EALREADY else {
      throw CoreFailure.apiUnavailable
    }

    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    while true {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { throw CoreFailure.apiUnavailable }
      let timeoutMilliseconds = Int32((remaining * 1_000).rounded(.up))
      let pollResult = poll(&pollDescriptor, 1, timeoutMilliseconds)
      if pollResult < 0, errno == EINTR { continue }
      guard pollResult > 0 else { throw CoreFailure.apiUnavailable }
      var socketError: Int32 = 0
      var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
      guard
        getsockopt(
          descriptor,
          SOL_SOCKET,
          SO_ERROR,
          &socketError,
          &socketErrorSize
        ) == 0, socketError == 0
      else {
        throw CoreFailure.apiUnavailable
      }
      return
    }
  }

  private func writeAll(_ data: Data, to descriptor: Int32, deadline: TimeInterval?) throws {
    var offset = 0
    try data.withUnsafeBytes { bytes in
      while offset < bytes.count {
        if let deadline {
          try configureSocketTimeout(
            descriptor,
            option: SO_SNDTIMEO,
            seconds: deadline - ProcessInfo.processInfo.systemUptime
          )
        }
        let count = Darwin.write(
          descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw CoreFailure.apiUnavailable }
        offset += count
      }
    }
  }

  private func configureSocketTimeouts(_ descriptor: Int32, seconds: TimeInterval) throws {
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
      throw CoreFailure.apiUnavailable
    }
    try configureSocketTimeout(descriptor, option: SO_RCVTIMEO, seconds: seconds)
    try configureSocketTimeout(descriptor, option: SO_SNDTIMEO, seconds: seconds)
  }

  private func configureSocketTimeout(
    _ descriptor: Int32,
    option: Int32,
    seconds: TimeInterval
  ) throws {
    guard seconds > 0, seconds.isFinite else { throw CoreFailure.apiUnavailable }
    let microseconds = Int((seconds * 1_000_000).rounded(.up))
    var timeout = timeval(
      tv_sec: microseconds / 1_000_000,
      tv_usec: Int32(microseconds % 1_000_000)
    )
    let result = withUnsafePointer(to: &timeout) { pointer in
      setsockopt(
        descriptor,
        SOL_SOCKET,
        option,
        pointer,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }
    guard result == 0 else { throw CoreFailure.apiUnavailable }
  }

  private func ensureAPIPortAvailable() throws {
    guard LocalTCPPortProbe.isAvailable(19090) else {
      throw CoreFailure.apiPortUnavailable
    }
  }

  private static func makeAPISecret() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

}

enum CoreFailure: LocalizedError {
  case coreMissing
  case coreIntegrity(String)
  case profileMissing
  case invalidProfile(String)
  case configurationRejected(String)
  case coreExited(Int32)
  case coreLaunchFailed(Int32)
  case coreAlreadyRunning
  case coreNotRunning
  case coreStopFailed
  case apiUnavailable
  case apiPortUnavailable
  case configurationCheckTimedOut

  var errorDescription: String? {
    switch self {
    case .coreMissing: "The bundled sing-box core is missing."
    case .coreIntegrity(let message): message
    case .profileMissing: "Add a subscription before connecting."
    case .invalidProfile(let message): message
    case .configurationRejected(let message): "sing-box rejected the configuration: \(message)"
    case .coreExited(let status): "sing-box exited with status \(status)."
    case .coreLaunchFailed(let code):
      "Unable to launch sing-box: \(String(cString: strerror(code)))."
    case .coreAlreadyRunning: "The managed sing-box core is already running."
    case .coreNotRunning: "Connect the VPN before testing latency."
    case .coreStopFailed: "sing-box did not stop after SIGTERM and SIGKILL."
    case .apiUnavailable: "The local sing-box control API is unavailable."
    case .apiPortUnavailable:
      "Local control port 19090 is already in use. Stop the conflicting process and try again."
    case .configurationCheckTimedOut: "sing-box configuration validation timed out."
    }
  }
}
