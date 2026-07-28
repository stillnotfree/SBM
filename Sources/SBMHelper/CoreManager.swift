import CryptoKit
import Darwin
import Foundation
import SBMShared

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

struct PersistentState: Codable {
  var profile: CoreProfile?
  var activeProfileID: UUID?
  var mode: RoutingMode = .rule
  var selectedNode: ProxyNodeID = .auto
  var selectorTag = "proxy-selector"
  var nodes: [ProxyNodeDescriptor] = []
  var desiredRunning = false
  var localSOCKSEnabled = false
  var localSOCKSPort: UInt16 = 1082
  var apiSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")

  init() {}
}

private struct CoreMetadata: Codable {
  let digest: String
  let size: Int64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let inode: UInt64
  let version: String
}

final class CoreManager: @unchecked Sendable {
  private let fileManager = FileManager.default
  private let supportDirectory = URL(
    fileURLWithPath: "/Library/Application Support/SBM", isDirectory: true)
  private lazy var configURL = supportDirectory.appendingPathComponent("config.json")
  private lazy var stateURL = supportDirectory.appendingPathComponent("state.json")
  private lazy var pidURL = supportDirectory.appendingPathComponent("sing-box.pid")
  private lazy var logURL = supportDirectory.appendingPathComponent("sing-box.log")
  private lazy var cacheURL = supportDirectory.appendingPathComponent("cache.db")
  private lazy var coreMetadataURL = supportDirectory.appendingPathComponent("core-metadata.json")
  private let resourcesDirectory: URL
  private let bundledCoreURL: URL
  private lazy var coreURL = supportDirectory.appendingPathComponent("sing-box")
  private let expectedCoreSHA256 =
    "a74ca72d18f7fbf5756170927f257e0a27e51ba8a590d1a8388bffd2300cee4f"

  private var state = PersistentState()
  private var coreProcess: Process?

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
    } catch {
      FileHandle.standardError.write(
        Data("Core bootstrap failed: \(error.localizedDescription)\n".utf8))
    }
  }

  func status(message: String = "Helper connected") -> HelperResponse {
    HelperResponse(
      success: true,
      coreRunning: isCoreRunning,
      coreVersion: cachedCoreVersion(),
      mode: state.mode,
      selectedNode: state.selectedNode,
      activeProfileID: state.activeProfileID,
      nodes: state.nodes,
      message: message
    )
  }

  func start(
    profile: CoreProfile?,
    profileID: UUID? = nil,
    localSOCKSEnabled: Bool? = nil,
    localSOCKSPort: UInt16? = nil
  ) throws -> HelperResponse {
    let previousState = state
    let wasRunning = isCoreRunning
    var configurationReplaced = false
    let profileChanged = profile.map { $0 != state.profile } ?? false
    do {
      if let profile {
        state.profile = profile
        state.activeProfileID = profileID
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
      guard let activeProfile = state.profile else {
        throw CoreFailure.profileMissing
      }

      try prepareFilesystem()
      let previousConfiguration = try? Data(contentsOf: configURL)
      let built = try writeValidatedConfiguration(profile: activeProfile)
      configurationReplaced = true
      let configurationChanged = previousConfiguration != built.data
      state.selectorTag = built.selectorTag
      state.nodes = built.nodes
      state.selectedNode = built.selectedNode

      if isCoreRunning, !profileChanged, !configurationChanged {
        state.desiredRunning = true
        try saveState()
        return status(message: "VPN already connected")
      }
      if isCoreRunning {
        terminateCore()
      }

      try launchCore()
      try waitForAPI()
      try applyMode(state.mode)
      try applyNode(state.selectedNode)
      state.desiredRunning = true
      try saveState()
      return status(message: "VPN connected")
    } catch {
      if !configurationReplaced {
        state = previousState
        if !fileManager.fileExists(atPath: configURL.path) {
          try? restoreBackupConfiguration()
        }
        try? saveState()
        throw error
      }
      terminateCore()
      state = previousState
      if wasRunning {
        do {
          try restoreBackupConfiguration()
          try launchCore()
          try waitForAPI()
          try applyMode(state.mode)
          try applyNode(state.selectedNode)
          state.desiredRunning = true
        } catch {
          terminateCore()
          state.desiredRunning = false
        }
      }
      try? saveState()
      throw error
    }
  }

  func stop() throws -> HelperResponse {
    state.desiredRunning = false
    try saveState()
    terminateCore()
    guard !isCoreRunning else {
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

  func testLatency() throws -> HelperResponse {
    guard isCoreRunning else { throw CoreFailure.coreNotRunning }
    let descriptors = state.nodes
    let results = DelayResults()
    DispatchQueue.concurrentPerform(iterations: descriptors.count) { index in
      let descriptor = descriptors[index]
      let node = descriptor.id
      let encodedURL = "https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
      let component = apiPathComponent(node.rawValue)
      let path = "/proxies/\(component)/delay?timeout=5000&url=\(encodedURL)"
      let data = try? apiRequest(method: "GET", path: path, body: nil)
      let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      results.set(object?["delay"] as? Int, for: node)
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
    let built = try ConfigBuilder(
      cachePath: cacheURL.path,
      apiSecret: state.apiSecret
    ).makeConfiguration(
      profile: profile,
      mode: state.mode,
      selectedNode: state.selectedNode,
      localSOCKSPort: state.localSOCKSEnabled ? state.localSOCKSPort : nil
    )
    let candidate = supportDirectory.appendingPathComponent(
      "validation-\(UUID().uuidString).json")
    try built.data.write(to: candidate, options: .atomic)
    try secureFile(candidate)
    defer { try? fileManager.removeItem(at: candidate) }
    try runCore(arguments: ["check", "-c", candidate.path])
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
    if !fileManager.fileExists(atPath: supportDirectory.path) {
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
      try saveCoreMetadata(for: coreURL)
      return
    }
    guard fileManager.isExecutableFile(atPath: bundledCoreURL.path) else {
      throw CoreFailure.coreMissing
    }
    let bundledDigest = try sha256(of: bundledCoreURL)
    guard bundledDigest == expectedCoreSHA256 else {
      throw CoreFailure.coreIntegrity("The bundled sing-box checksum does not match this build.")
    }
    let candidate = supportDirectory.appendingPathComponent("sing-box.candidate")
    try? fileManager.removeItem(at: candidate)
    try fileManager.copyItem(at: bundledCoreURL, to: candidate)
    try secureExecutable(candidate)
    guard try sha256(of: candidate) == expectedCoreSHA256 else {
      try? fileManager.removeItem(at: candidate)
      throw CoreFailure.coreIntegrity("The root-owned sing-box copy failed verification.")
    }
    try? fileManager.removeItem(at: coreURL)
    try fileManager.moveItem(at: candidate, to: coreURL)
    try secureExecutable(coreURL)
    try saveCoreMetadata(for: coreURL)
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
    try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
  }

  private func cachedMetadataMatchesInstalledCore() -> Bool {
    guard isSecureRootRegularFile(coreURL),
      isSecureRootRegularFile(coreMetadataURL),
      let data = try? Data(contentsOf: coreMetadataURL),
      let metadata = try? JSONDecoder().decode(CoreMetadata.self, from: data),
      metadata.digest == expectedCoreSHA256,
      let info = fileIdentity(coreURL)
    else { return false }
    return metadata.size == info.size
      && metadata.modificationSeconds == info.modificationSeconds
      && metadata.modificationNanoseconds == info.modificationNanoseconds
      && metadata.inode == info.inode
  }

  private func saveCoreMetadata(for url: URL) throws {
    guard let info = fileIdentity(url),
      let version = readCoreVersionFromProcess()
    else {
      throw CoreFailure.coreIntegrity("Unable to identify the verified sing-box core.")
    }
    let metadata = CoreMetadata(
      digest: expectedCoreSHA256,
      size: info.size,
      modificationSeconds: info.modificationSeconds,
      modificationNanoseconds: info.modificationNanoseconds,
      inode: info.inode,
      version: version
    )
    try JSONEncoder().encode(metadata).write(to: coreMetadataURL, options: .atomic)
    try secureFile(coreMetadataURL)
  }

  private func fileIdentity(_ url: URL) -> (
    size: Int64,
    modificationSeconds: Int64,
    modificationNanoseconds: Int64,
    inode: UInt64
  )? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return (
      info.st_size,
      Int64(info.st_mtimespec.tv_sec),
      Int64(info.st_mtimespec.tv_nsec),
      UInt64(info.st_ino)
    )
  }

  private func isSecureRootDirectory(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFDIR
      && info.st_uid == 0
      && (info.st_mode & 0o077) == 0
  }

  private func isSecureRootRegularFile(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFREG
      && info.st_uid == 0
      && (info.st_mode & 0o022) == 0
  }

  private func writeValidatedConfiguration(profile: CoreProfile) throws -> BuiltConfiguration {
    let builder = ConfigBuilder(
      cachePath: cacheURL.path,
      apiSecret: state.apiSecret
    )
    let built = try builder.makeConfiguration(
      profile: profile,
      mode: state.mode,
      selectedNode: state.selectedNode,
      localSOCKSPort: state.localSOCKSEnabled ? state.localSOCKSPort : nil
    )
    let candidate = supportDirectory.appendingPathComponent("config.json.candidate")
    try built.data.write(to: candidate, options: .atomic)
    try secureFile(candidate)
    defer { try? fileManager.removeItem(at: candidate) }
    try runCore(arguments: ["check", "-c", candidate.path])

    let backup = supportDirectory.appendingPathComponent("config.json.backup")
    if fileManager.fileExists(atPath: configURL.path) {
      try? fileManager.removeItem(at: backup)
      try fileManager.copyItem(at: configURL, to: backup)
      try secureFile(backup)
    }
    try? fileManager.removeItem(at: configURL)
    try fileManager.moveItem(at: candidate, to: configURL)
    try secureFile(configURL)
    return built
  }

  private func restoreBackupConfiguration() throws {
    let backup = supportDirectory.appendingPathComponent("config.json.backup")
    guard fileManager.fileExists(atPath: backup.path) else {
      throw CoreFailure.configurationRejected(
        "No previous configuration is available for rollback.")
    }
    try? fileManager.removeItem(at: configURL)
    try fileManager.copyItem(at: backup, to: configURL)
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
      throw CoreFailure.coreExited(process.terminationStatus, recentLog())
    }
  }

  private func loadState() throws -> PersistentState {
    guard fileManager.fileExists(atPath: stateURL.path) else {
      let initial = PersistentState()
      state = initial
      try saveState()
      return initial
    }
    return try JSONDecoder().decode(PersistentState.self, from: Data(contentsOf: stateURL))
  }

  private func saveState() throws {
    let data = try JSONEncoder().encode(state)
    try data.write(to: stateURL, options: .atomic)
    try secureFile(stateURL)
  }

  private func secureFile(_ url: URL) throws {
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func writableLogHandle() throws -> FileHandle {
    if !fileManager.fileExists(atPath: logURL.path) {
      fileManager.createFile(
        atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    try secureFile(logURL)
    let descriptor = open(logURL.path, O_WRONLY | O_APPEND)
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private func enforceLogLimit() throws {
    let limit: off_t = 5 * 1_024 * 1_024
    guard fileManager.fileExists(atPath: logURL.path) else { return }
    let descriptor = open(logURL.path, O_WRONLY)
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

  private func runCore(arguments: [String]) throws {
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
    process.executableURL = coreURL
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(10)
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
      let data = (try? Data(contentsOf: outputURL)) ?? Data()
      let message =
        String(data: data.suffix(16 * 1_024), encoding: .utf8) ?? "Unknown sing-box error"
      throw CoreFailure.configurationRejected(message)
    }
  }

  private func cachedCoreVersion() -> String? {
    guard let data = try? Data(contentsOf: coreMetadataURL),
      let metadata = try? JSONDecoder().decode(CoreMetadata.self, from: data)
    else { return nil }
    return metadata.version
  }

  private func readCoreVersionFromProcess() -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = coreURL
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
    for _ in 0..<30 {
      if (try? apiRequest(method: "GET", path: "/version", body: nil)) != nil {
        return
      }
      if !isCoreRunning { break }
      usleep(100_000)
    }
    throw CoreFailure.apiUnavailable
  }

  private func terminateCore() {
    if let pid = currentPID(), isProcessRunning(pid) {
      _ = kill(pid, SIGTERM)
      for _ in 0..<30 where isProcessRunning(pid) {
        usleep(100_000)
      }
      if isProcessRunning(pid) {
        _ = kill(pid, SIGKILL)
      }
    }
    coreProcess = nil
    try? fileManager.removeItem(at: pidURL)
  }

  private func applyNode(_ node: ProxyNodeID) throws {
    let body = try JSONSerialization.data(withJSONObject: ["name": node.rawValue])
    let selector = apiPathComponent(state.selectorTag)
    _ = try apiRequest(method: "PUT", path: "/proxies/\(selector)", body: body)
  }

  private func apiPathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  private func apiRequest(method: String, path: String, body: Data?) throws -> Data {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CoreFailure.apiUnavailable }
    defer { close(descriptor) }
    try configureSocketTimeouts(descriptor, seconds: 7)

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(19090).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
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
        guard count > 0 else { throw CoreFailure.apiUnavailable }
        offset += count
      }
    }
  }

  private func configureSocketTimeouts(_ descriptor: Int32, seconds: Int) throws {
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

  private func recentLog() -> String {
    guard let handle = try? FileHandle(forReadingFrom: logURL) else {
      return "No core log available."
    }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return "No core log available." }
    let start = size > 4096 ? size - 4096 : 0
    guard (try? handle.seek(toOffset: start)) != nil,
      let data = try? handle.read(upToCount: 4096),
      let text = String(data: data, encoding: .utf8)
    else { return "No core log available." }
    return text
  }
}

enum CoreFailure: LocalizedError {
  case coreMissing
  case coreIntegrity(String)
  case profileMissing
  case invalidProfile(String)
  case configurationRejected(String)
  case coreExited(Int32, String)
  case coreNotRunning
  case coreStopFailed
  case apiUnavailable
  case configurationCheckTimedOut

  var errorDescription: String? {
    switch self {
    case .coreMissing: "The bundled sing-box core is missing."
    case .coreIntegrity(let message): message
    case .profileMissing: "Add a subscription before connecting."
    case .invalidProfile(let message): message
    case .configurationRejected(let message): "sing-box rejected the configuration: \(message)"
    case .coreExited(let status, let log): "sing-box exited with status \(status): \(log)"
    case .coreNotRunning: "Connect the VPN before testing latency."
    case .coreStopFailed: "sing-box did not stop after SIGTERM and SIGKILL."
    case .apiUnavailable: "The local sing-box control API is unavailable."
    case .configurationCheckTimedOut: "sing-box configuration validation timed out."
    }
  }
}
