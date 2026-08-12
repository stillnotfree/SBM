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

private final class DelayResults: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ProxyNodeID: Int] = [:]

  func set(_ value: Int?, for node: ProxyNodeID) {
    guard let value else { return }
    lock.lock()
    values[node] = value
    lock.unlock()
  }

  func value(for node: ProxyNodeID) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    return values[node]
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

struct PersistentState: Codable {
  var profile: CoreProfile?
  var activeProfileID: UUID?
  var mode: RoutingMode = .rule
  var selectedNode: ProxyNodeID = .auto
  var selectorTag = "proxy-selector"
  var nodes: [ProxyNodeDescriptor] = []
  var desiredRunning = false
  var automaticRecoveryAttempted = false
  var localSOCKSEnabled = false
  var localSOCKSPort: UInt16 = 1082
  var latencyTestURL = LatencyTargetPolicy.defaultURL
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
    case automaticRecoveryAttempted
    case localSOCKSEnabled
    case localSOCKSPort
    case latencyTestURL
    case apiSecret
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    profile = try container.decodeIfPresent(CoreProfile.self, forKey: .profile)
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
    automaticRecoveryAttempted =
      try container.decodeIfPresent(Bool.self, forKey: .automaticRecoveryAttempted) ?? false
    localSOCKSEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .localSOCKSEnabled) ?? false
    localSOCKSPort =
      try container.decodeIfPresent(UInt16.self, forKey: .localSOCKSPort) ?? 1082
    let storedTarget =
      try container.decodeIfPresent(String.self, forKey: .latencyTestURL)
      ?? LatencyTargetPolicy.defaultURL
    latencyTestURL = try LatencyTargetPolicy.normalized(storedTarget)
    apiSecret =
      try container.decodeIfPresent(String.self, forKey: .apiSecret)
      ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  mutating func setLatencyTestURL(_ value: String) throws {
    latencyTestURL = try LatencyTargetPolicy.normalized(value)
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
    desiredRunning: Bool,
    coreRunning: Bool,
    profileAvailable: Bool,
    configurationAvailable: Bool,
    recoveryAlreadyAttempted: Bool
  ) -> DesiredRuntimeRecoveryDecision {
    guard desiredRunning else { return .stop }
    guard !coreRunning else { return .noAction }
    guard profileAvailable, configurationAvailable, !recoveryAlreadyAttempted else {
      return .disableDesiredState
    }
    return .attemptRecovery
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
  private lazy var pidURL = supportDirectory.appendingPathComponent("sing-box.pid")
  private lazy var logURL = supportDirectory.appendingPathComponent("sing-box.log")
  private lazy var cacheURL = supportDirectory.appendingPathComponent("cache.db")
  private lazy var coreMetadataURL = supportDirectory.appendingPathComponent("core-metadata.json")
  private lazy var coreBackupURL = supportDirectory.appendingPathComponent("sing-box.backup")
  private let resourcesDirectory: URL
  private let bundledCoreURL: URL
  private lazy var coreURL = supportDirectory.appendingPathComponent("sing-box")
  private let expectedCoreSHA256 = CoreBuildInfo.signedSHA256

  private var state = PersistentState()
  private var coreProcess: Process?
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
    do {
      try prepareFilesystem()
      try enforceLogLimit()
      state = try loadState()
      if !state.desiredRunning {
        terminateCore()
      }
      bootstrapFailure = nil
    } catch {
      bootstrapFailure = error.localizedDescription
      FileHandle.standardError.write(
        Data("Core bootstrap failed: \(error.localizedDescription)\n".utf8))
    }
  }

  func status(
    message: String = "Helper connected",
    ruleSetMatches: [RuleSetMatch] = []
  ) -> HelperResponse {
    let recoveryExhausted = state.automaticRecoveryAttempted && !state.desiredRunning
    let effectiveMessage =
      bootstrapFailure.map { "Core bootstrap failed: \($0)" }
      ?? (recoveryExhausted
        ? "Automatic VPN recovery is exhausted; connect manually to retry"
        : message)
    return HelperResponse(
      success: bootstrapFailure == nil && !recoveryExhausted,
      coreRunning: isCoreRunning,
      coreVersion: cachedCoreVersion(),
      mode: state.mode,
      selectedNode: state.selectedNode,
      activeProfileID: state.activeProfileID,
      nodes: state.nodes,
      automaticRecoveryExhausted: recoveryExhausted,
      ruleSetMatches: ruleSetMatches,
      message: effectiveMessage
    )
  }

  func reconcileDesiredRuntime() throws -> String? {
    guard bootstrapFailure == nil else { return nil }
    let recoveryDecision = DesiredRuntimeRecoveryPolicy.decision(
      desiredRunning: state.desiredRunning,
      coreRunning: isCoreRunning,
      profileAvailable: state.profile != nil,
      configurationAvailable: pathExistsWithoutFollowingSymlinks(configURL),
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
    latencyTestURL: String? = nil
  ) throws -> HelperResponse {
    let normalizedLatencyTestURL = try latencyTestURL.map(LatencyTargetPolicy.normalized)
    let previousState = state
    let wasRunning = isCoreRunning
    do {
      if let profile {
        state.profile = profile
        state.activeProfileID = profileID
      }
      if let mode {
        state.mode = mode
      }
      if let selectedNode {
        state.selectedNode = selectedNode
      }
      if let localSOCKSEnabled {
        state.localSOCKSEnabled = localSOCKSEnabled
      }
      if let localSOCKSPort {
        guard (1024...65535).contains(Int(localSOCKSPort)), localSOCKSPort != 19090 else {
          throw CoreFailure.invalidProfile("The local SOCKS5 port is not allowed.")
        }
        state.localSOCKSPort = localSOCKSPort
      }
      if let normalizedLatencyTestURL {
        state.latencyTestURL = normalizedLatencyTestURL
      }
      guard let activeProfile = state.profile else {
        throw CoreFailure.profileMissing
      }

      try prepareFilesystem()
      let previousConfiguration = try configurationSnapshot()
      let preview = try configuration(
        profile: activeProfile,
        apiSecret: state.apiSecret
      )
      let configurationChanged = previousConfiguration != preview.data

      if isCoreRunning, !configurationChanged {
        state.desiredRunning = true
        state.automaticRecoveryAttempted = false
        try saveState()
        return status(message: "VPN already connected")
      }
      let candidateSecret = Self.makeAPISecret()
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
    state.desiredRunning = false
    state.automaticRecoveryAttempted = false
    try saveState()
    guard terminateCore(), !isCoreRunning else {
      throw CoreFailure.coreStopFailed
    }
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

  func testLatency() throws -> HelperResponse {
    guard isCoreRunning else { throw CoreFailure.coreNotRunning }
    let descriptors = state.nodes
    let results = DelayResults()
    let workerCount = min(8, descriptors.count)
    DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
      for index in stride(from: worker, to: descriptors.count, by: workerCount) {
        let descriptor = descriptors[index]
        let node = descriptor.id
        let path = LatencyDelayRequest.path(for: node, target: state.latencyTestURL)
        let data = try? apiRequest(method: "GET", path: path, body: nil)
        let object = data.flatMap {
          try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        results.set(object?["delay"] as? Int, for: node)
      }
    }
    let delays = descriptors.map { descriptor in
      NodeDelay(node: descriptor.id, milliseconds: results.value(for: descriptor.id))
    }
    return HelperResponse(
      success: true,
      coreRunning: true,
      coreVersion: cachedCoreVersion(),
      mode: state.mode,
      selectedNode: state.selectedNode,
      activeProfileID: state.activeProfileID,
      nodes: state.nodes,
      delays: delays,
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
      nodes: built.nodes,
      message: "Profile validated"
    )
  }

  func matchRuleSets(tags: [String], destination: String) throws -> HelperResponse {
    guard isCoreRunning, state.profile != nil,
      !tags.isEmpty, tags.count <= 8, Set(tags).count == tags.count,
      !destination.isEmpty, destination.utf8.count <= 512,
      !destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw CoreFailure.invalidRuleSetQuery }
    try requireSecureManagedFileIfPresent(cacheURL)
    try requireSecureManagedFileIfPresent(configURL)
    let attributes = try fileManager.attributesOfItem(atPath: configURL.path)
    guard let size = attributes[.size] as? NSNumber,
      size.intValue > 0, size.intValue <= 2 * 1_048_576
    else { throw CoreFailure.invalidRuleSetQuery }
    let activeConfiguration = try Data(contentsOf: configURL)
    guard activeConfiguration.count <= 2 * 1_048_576 else {
      throw CoreFailure.invalidRuleSetQuery
    }
    guard
      let root = try JSONSerialization.jsonObject(with: activeConfiguration) as? [String: Any],
      let route = root["route"] as? [String: Any]
    else { throw CoreFailure.invalidRuleSetQuery }
    let definitions: [String: String] = Dictionary(
      uniqueKeysWithValues: (route["rule_set"] as? [[String: Any]] ?? []).compactMap { item in
        guard (item["type"] as? String) == "remote",
          let tag = item["tag"] as? String,
          let format = item["format"] as? String,
          ["source", "binary"].contains(format)
        else { return nil }
        return (tag, format)
      }
    )
    let temporaryDirectory = supportDirectory.appendingPathComponent(
      "rule-set-match-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? fileManager.removeItem(at: temporaryDirectory) }
    var matches: [RuleSetMatch] = []
    for (index, tag) in tags.enumerated() {
      guard let format = definitions[tag] else { throw CoreFailure.invalidRuleSetQuery }
      let content: Data
      do {
        content = try RuleSetCacheReader.content(at: cacheURL, tag: tag)
      } catch {
        throw CoreFailure.ruleSetUnavailable(tag)
      }
      let ruleSetURL = temporaryDirectory.appendingPathComponent(
        "rule-set-\(index).\(format == "binary" ? "srs" : "json")")
      try content.write(to: ruleSetURL, options: .atomic)
      try secureFile(ruleSetURL)
      let matched = try runCore(
        arguments: [
          "rule-set", "match", "-f", format, ruleSetURL.path, destination,
        ], timeoutSeconds: 5)
      matches.append(RuleSetMatch(tag: tag, matches: matched))
    }
    return status(message: "Routing rule sets matched", ruleSetMatches: matches)
  }

  private var isCoreRunning: Bool {
    guard let pid = currentPID() else { return false }
    return isProcessRunning(pid)
  }

  private func currentPID() -> pid_t? {
    guard let value = try? String(contentsOf: pidURL, encoding: .utf8),
      let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)),
      pid > 1
    else { return nil }
    return pid
  }

  private func isProcessRunning(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 || errno == EPERM else { return false }
    var buffer = [CChar](repeating: 0, count: 4096)
    let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard count > 0 else { return false }
    let pathBytes = buffer.prefix(Int(count)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: pathBytes, as: UTF8.self) == coreURL.path
  }

  private func prepareFilesystem() throws {
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
      configURL, configBackupURL, stateURL, pidURL, logURL, cacheURL, coreMetadataURL,
      coreBackupURL,
    ] {
      try requireSecureManagedFileIfPresent(url)
    }
    try installBundledCoreIfNeeded()
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
    guard fileManager.isExecutableFile(atPath: bundledCoreURL.path) else {
      throw CoreFailure.coreMissing
    }
    let bundledDigest = try sha256(of: bundledCoreURL)
    guard bundledDigest == expectedCoreSHA256 else {
      throw CoreFailure.coreIntegrity("The bundled sing-box checksum does not match this build.")
    }
    let candidate = supportDirectory.appendingPathComponent(
      "sing-box.candidate-\(UUID().uuidString)")
    try fileManager.copyItem(at: bundledCoreURL, to: candidate)
    defer { try? fileManager.removeItem(at: candidate) }
    try takeRootOwnershipOfCopiedRegularFile(candidate)
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
    guard let metadata = cachedMetadataMatchingInstalledCoreIdentity() else { return false }
    return metadata.digest == expectedCoreSHA256
      && metadata.version == "sing-box version \(CoreBuildInfo.version)"
  }

  private func verifiedInstalledCoreMetadata() throws -> CoreMetadata? {
    guard let metadata = cachedMetadataMatchingInstalledCoreIdentity() else { return nil }
    guard try sha256(of: coreURL) == metadata.digest,
      readCoreVersion(at: coreURL) == metadata.version
    else { return nil }
    return metadata
  }

  private func cachedMetadataMatchingInstalledCoreIdentity() -> CoreMetadata? {
    guard isSecureRootRegularFile(coreURL),
      isSecureRootRegularFile(coreMetadataURL),
      let data = try? Data(contentsOf: coreMetadataURL),
      let metadata = try? JSONDecoder().decode(CoreMetadata.self, from: data),
      let info = CoreFileIdentity.read(coreURL)
    else { return nil }
    guard metadata.matches(info) else { return nil }
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
    apiSecret: String
  ) throws -> BuiltConfiguration {
    let built = try configuration(profile: profile, apiSecret: apiSecret)
    try validateConfiguration(built)
    return built
  }

  private func configuration(
    profile: CoreProfile,
    apiSecret: String
  ) throws -> BuiltConfiguration {
    let builder = ConfigBuilder(
      cachePath: cacheURL.path,
      apiSecret: apiSecret
    )
    return try builder.makeConfiguration(
      profile: profile,
      mode: state.mode,
      selectedNode: state.selectedNode,
      localSOCKSPort: state.localSOCKSEnabled ? state.localSOCKSPort : nil,
      latencyTestURL: state.latencyTestURL
    )
  }

  private func validateConfiguration(_ built: BuiltConfiguration) throws {
    let candidate = supportDirectory.appendingPathComponent(
      "validation-\(UUID().uuidString).json"
    )
    try built.data.write(to: candidate, options: .atomic)
    try secureFile(candidate)
    defer { try? fileManager.removeItem(at: candidate) }
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
    try secureFile(candidate)
    defer { try? fileManager.removeItem(at: candidate) }
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
    try enforceLogLimit()
    let logHandle = try writableLogHandle()
    let process = Process()
    process.executableURL = coreURL
    process.arguments = ["run", "-c", configURL.path]
    process.currentDirectoryURL = supportDirectory
    process.standardOutput = logHandle
    process.standardError = logHandle
    try process.run()
    coreProcess = process
    try Data("\(process.processIdentifier)\n".utf8).write(to: pidURL, options: .atomic)
    try secureFile(pidURL)

    usleep(100_000)
    guard process.isRunning else {
      process.waitUntilExit()
      try? fileManager.removeItem(at: pidURL)
      throw CoreFailure.coreExited(process.terminationStatus)
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
    try saveState()
  }

  private func loadState() throws -> PersistentState {
    guard fileManager.fileExists(atPath: stateURL.path) else {
      let initial = PersistentState()
      state = initial
      try saveState()
      return initial
    }
    do {
      return try JSONDecoder().decode(
        PersistentState.self,
        from: Data(contentsOf: stateURL)
      )
    } catch {
      let timestamp = Int(Date().timeIntervalSince1970)
      let quarantined = supportDirectory.appendingPathComponent(
        "state.corrupt-\(timestamp).json"
      )
      try? fileManager.moveItem(at: stateURL, to: quarantined)
      if fileManager.fileExists(atPath: quarantined.path) {
        try? secureFile(quarantined)
      }
      FileHandle.standardError.write(
        Data(
          "Preserved unreadable state as \(quarantined.lastPathComponent): "
            .appending(error.localizedDescription)
            .appending("\n")
            .utf8
        )
      )
      let initial = PersistentState()
      state = initial
      try saveState()
      return initial
    }
  }

  private func saveState() throws {
    let data = try JSONEncoder().encode(state)
    try data.write(to: stateURL, options: .atomic)
    try secureFile(stateURL)
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

  private func writableLogHandle() throws -> FileHandle {
    if !fileManager.fileExists(atPath: logURL.path) {
      fileManager.createFile(
        atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    try secureFile(logURL)
    let descriptor = open(logURL.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private func enforceLogLimit() throws {
    let limit: off_t = 5 * 1_024 * 1_024
    guard pathExistsWithoutFollowingSymlinks(logURL) else { return }
    try requireSecureManagedFileIfPresent(logURL)
    let descriptor = open(logURL.path, O_WRONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw CocoaError(.fileReadUnknown)
    }
    if metadata.st_size > limit, ftruncate(descriptor, 0) != 0 {
      throw CocoaError(.fileWriteUnknown)
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
    guard let data = try? Data(contentsOf: coreMetadataURL),
      let metadata = try? JSONDecoder().decode(CoreMetadata.self, from: data)
    else { return nil }
    return metadata.version
  }

  private func readCoreVersionFromProcess() -> String? {
    readCoreVersion(at: coreURL)
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
    if let pid = currentPID(), isProcessRunning(pid) {
      _ = kill(pid, SIGTERM)
      for _ in 0..<30 where isProcessRunning(pid) {
        usleep(100_000)
      }
      if isProcessRunning(pid) {
        _ = kill(pid, SIGKILL)
        for _ in 0..<10 where isProcessRunning(pid) {
          usleep(100_000)
        }
      }
      guard !isProcessRunning(pid) else { return false }
    }
    coreProcess = nil
    try? fileManager.removeItem(at: pidURL)
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
    timeoutSeconds: Int = 2
  ) throws -> Data {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CoreFailure.apiUnavailable }
    defer { close(descriptor) }
    try configureSocketTimeouts(descriptor, seconds: timeoutSeconds)

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(19090).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    var result: Int32
    repeat {
      result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    } while result != 0 && errno == EINTR
    guard result == 0 else { throw CoreFailure.apiUnavailable }

    let payload = body ?? Data()
    var request = "\(method) \(path) HTTP/1.1\r\n"
    request += "Host: 127.0.0.1\r\n"
    request += "Authorization: Bearer \(state.apiSecret)\r\n"
    request += "Content-Type: application/json\r\n"
    request += "Content-Length: \(payload.count)\r\n"
    request += "Connection: close\r\n\r\n"
    var bytes = Data(request.utf8)
    bytes.append(payload)
    try writeAll(bytes, to: descriptor)

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while response.count < 1_048_576 {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      if count < 0 { throw CoreFailure.apiUnavailable }
      if count == 0 { break }
      response.append(contentsOf: buffer.prefix(count))
    }
    guard let separator = response.range(of: Data("\r\n\r\n".utf8)),
      let head = String(data: response[..<separator.lowerBound], encoding: .utf8),
      let statusLine = head.split(separator: "\r\n").first,
      let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "0"),
      (200..<300).contains(status)
    else { throw CoreFailure.apiUnavailable }
    return Data(response[separator.upperBound...])
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    var offset = 0
    try data.withUnsafeBytes { bytes in
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw CoreFailure.apiUnavailable }
        offset += count
      }
    }
  }

  private func configureSocketTimeouts(_ descriptor: Int32, seconds: Int) throws {
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
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
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
      throw CoreFailure.apiUnavailable
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
      throw CoreFailure.apiUnavailable
    }
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
  case coreNotRunning
  case coreStopFailed
  case apiUnavailable
  case apiPortUnavailable
  case invalidRuleSetQuery
  case ruleSetUnavailable(String)
  case configurationCheckTimedOut

  var errorDescription: String? {
    switch self {
    case .coreMissing: "The bundled sing-box core is missing."
    case .coreIntegrity(let message): message
    case .profileMissing: "Add a subscription before connecting."
    case .invalidProfile(let message): message
    case .configurationRejected(let message): "sing-box rejected the configuration: \(message)"
    case .coreExited(let status): "sing-box exited with status \(status)."
    case .coreNotRunning: "Connect the VPN before testing latency."
    case .coreStopFailed: "sing-box did not stop after SIGTERM and SIGKILL."
    case .apiUnavailable: "The local sing-box control API is unavailable."
    case .apiPortUnavailable:
      "Local control port 19090 is already in use. Stop the conflicting process and try again."
    case .invalidRuleSetQuery:
      "The routing rule-set query is unavailable for the active profile."
    case .ruleSetUnavailable(let tag):
      "The active rule-set cache does not contain a usable \(tag) entry."
    case .configurationCheckTimedOut: "sing-box configuration validation timed out."
    }
  }
}
