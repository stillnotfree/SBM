import CryptoKit
import Darwin
import Foundation
import SBMShared

enum Legacy1115Retirement {
  static let supportPath = "/Library/Application Support/SBM"
  static let retiredPath = "/Library/Application Support/SBM.legacy-1.1.15.retired"
  static let coreName = "sing-box"
  static let stateName = "state.json"
  static let oldCoreSHA256 = "b57bc9ac266dd1169f7c429765cf918264d46652a6ca04d6f9ce548ddfb368ce"
  static let oldCoreCDHash = "127f90aca27088e72614b238272d21b6a5d0e86e"
  static let oldCoreSigningIdentifier = "io.nekohasekai.sing-box"

  private static let maximumStateBytes = 4 * 1_024 * 1_024
  private static let maximumCensusBytes = 32 * 1_024 * 1_024
  private static let maximumCensusRetries = 4
  private static let maximumRegions = 131_072
  private static let operationLimit: Duration = .seconds(25)

  static func completionIsValid() -> Bool {
    guard let parent = try? openProtectedParent() else { return false }
    defer { close(parent) }
    let descriptor = openat(parent, "SBM", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    guard secureDirectory(descriptor) else { return false }
    let receipt = openat(descriptor, stateName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard receipt >= 0 else { return false }
    defer { close(receipt) }
    guard secureState(receipt), let state = try? readState(at: descriptor),
      let value = try? desiredAndCompletion(from: state),
      value.complete
    else { return false }
    var pathInfo = stat()
    var receiptInfo = stat()
    guard fstatat(descriptor, stateName, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
      fstat(receipt, &receiptInfo) == 0,
      pathInfo.st_dev == receiptInfo.st_dev,
      pathInfo.st_ino == receiptInfo.st_ino,
      pathInfo.st_gen == receiptInfo.st_gen,
      fsync(receipt) == 0,
      fsync(descriptor) == 0
    else { return false }
    return true
  }

  static func finish() throws {
    guard geteuid() == 0, getuid() == 0 else {
      throw CoreFailure.coreIntegrity("Legacy helper retirement requires real and effective root.")
    }
    if completionIsValid() { return }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: operationLimit)
    let parent = try openProtectedParent()
    defer { close(parent) }

    let currentExists = try entryExists(parent, name: "SBM")
    let retiredExists = try entryExists(parent, name: "SBM.legacy-1.1.15.retired")
    if currentExists && retiredExists {
      guard let current = openDirectory(at: supportPath) else {
        throw CoreFailure.coreIntegrity("The current root is not a no-follow directory.")
      }
      defer { close(current) }
      guard secureDirectory(current), try directoryIsEmpty(current) else {
        throw CoreFailure.coreIntegrity(
          "Both legacy and retired SBM roots contain unexplained data.")
      }
    }

    let useRetiredRoot = retiredExists
    if useRetiredRoot, fsync(parent) != 0 {
      throw CoreFailure.coreIntegrity("Unable to sync the preserved legacy-root entry.")
    }

    let legacyPath = useRetiredRoot ? retiredPath : supportPath
    let legacyFD: Int32?
    if try entryExists(parent, name: useRetiredRoot ? "SBM.legacy-1.1.15.retired" : "SBM") {
      guard let descriptor = openDirectory(at: legacyPath) else {
        throw CoreFailure.coreIntegrity("The selected legacy root is not a no-follow directory.")
      }
      guard secureDirectory(descriptor) else {
        close(descriptor)
        throw CoreFailure.coreIntegrity(
          "The legacy support root has unsafe ownership or permissions.")
      }
      legacyFD = descriptor
    } else {
      legacyFD = nil
    }
    defer { if let legacyFD { close(legacyFD) } }

    let rootIdentity = try legacyFD.map(nodeIdentity)
    let legacyRootIsEmpty = try legacyFD.map(directoryIsEmpty) ?? true
    let coreFD: Int32?
    if let legacyFD, !legacyRootIsEmpty {
      let descriptor = openat(legacyFD, coreName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      if descriptor < 0 {
        let openError = errno
        guard openError == ENOENT, try !entryExists(legacyFD, name: coreName) else {
          throw CoreFailure.coreIntegrity(
            "The legacy core is present but cannot be opened as a pinned image.")
        }
        coreFD = nil
      } else {
        guard secureCore(descriptor) else {
          close(descriptor)
          throw CoreFailure.coreIntegrity("The legacy core does not match the pinned 1.1.15 image.")
        }
        do {
          guard try sha256(descriptor) == oldCoreSHA256 else {
            throw CoreFailure.coreIntegrity(
              "The legacy core does not match the pinned 1.1.15 image.")
          }
        } catch {
          close(descriptor)
          throw error
        }
        coreFD = descriptor
      }
    } else {
      coreFD = nil
    }
    defer { if let coreFD { close(coreFD) } }

    var stateBytes: Data?
    var legacyDesiredRunning = false
    if let legacyFD, !legacyRootIsEmpty {
      let bytes = try readState(at: legacyFD)
      let state = try desiredAndCompletion(from: bytes)
      guard !state.complete else {
        throw CoreFailure.coreIntegrity(
          "The old support root unexpectedly contains a current completion bit.")
      }
      stateBytes = bytes
      legacyDesiredRunning = state.desiredRunning
    }

    let candidate = try census(
      legacyCorePath: supportPath + "/" + coreName,
      legacyRootIdentity: rootIdentity,
      coreIdentity: try coreFD.map(nodeIdentity),
      deadline: deadline,
      clock: clock
    )
    if let legacyFD, let originalStateBytes = stateBytes {
      stateBytes = try writeDesiredOffIfNeeded(
        originalStateBytes,
        at: legacyFD,
        desiredRunning: legacyDesiredRunning
      )
    }
    if let candidate {
      try terminate(candidate, deadline: deadline, clock: clock)
    }

    let finalCandidate = try census(
      legacyCorePath: supportPath + "/" + coreName,
      legacyRootIdentity: rootIdentity,
      coreIdentity: try coreFD.map(nodeIdentity),
      deadline: deadline,
      clock: clock
    )
    guard finalCandidate == nil else {
      throw CoreFailure.coreIntegrity("A legacy helper or pinned core remains after retirement.")
    }

    if let legacyFD, !useRetiredRoot, !legacyRootIsEmpty {
      guard let rootIdentity, let stateBytes else {
        throw CoreFailure.coreIntegrity("Legacy root identity or OFF state is unavailable.")
      }
      let preservedState = try desiredAndCompletion(from: stateBytes)
      guard !preservedState.desiredRunning, !preservedState.complete else {
        throw CoreFailure.coreIntegrity("Legacy OFF state changed before preservation.")
      }
      try verifyCore(coreFD, in: legacyFD)
      try renameLegacyRoot(parent: parent, descriptor: legacyFD, identity: rootIdentity)
      try verifyPreservedRoot(
        parent: parent,
        descriptor: legacyFD,
        identity: rootIdentity,
        stateBytes: stateBytes,
        coreFD: coreFD
      )
    }

    if useRetiredRoot {
      guard let legacyFD, let rootIdentity, let stateBytes,
        try nodeIdentity(legacyFD) == rootIdentity,
        try readState(at: legacyFD) == stateBytes
      else {
        throw CoreFailure.coreIntegrity("The retired root changed before completion publication.")
      }
      let preservedState = try desiredAndCompletion(from: stateBytes)
      guard !preservedState.desiredRunning, !preservedState.complete else {
        throw CoreFailure.coreIntegrity("The retired root does not contain a validated OFF state.")
      }
      try verifyCore(coreFD, in: legacyFD)
      try verifyPreservedRoot(
        parent: parent,
        descriptor: legacyFD,
        identity: rootIdentity,
        stateBytes: stateBytes,
        coreFD: coreFD
      )
    }
  }

  static func sendSignal(to auditToken: audit_token_t, signal: Int32) throws {
    var token = auditToken
    let result = proc_signal_with_audittoken(&token, signal)
    guard result == 0 else {
      throw CoreFailure.coreIntegrity("Audit-token process signal failed with errno \(result).")
    }
  }

  static func auditToken(for pid: pid_t) throws -> audit_token_t {
    guard pid > 0 else { throw CoreFailure.coreIntegrity("Invalid process identifier.") }
    var task = mach_port_name_t(MACH_PORT_NULL)
    let lookup = task_name_for_pid(mach_task_self_, pid, &task)
    guard lookup == KERN_SUCCESS, task != mach_port_name_t(MACH_PORT_NULL) else {
      throw CoreFailure.coreIntegrity("Unable to bind a process audit identity.")
    }
    defer { _ = mach_port_deallocate(mach_task_self_, task) }
    var token = audit_token_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &token) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
      }
    }
    guard result == KERN_SUCCESS,
      count
        == mach_msg_type_number_t(
          MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
        ),
      audit_token_to_pid(token) == pid
    else { throw CoreFailure.coreIntegrity("Unable to read a complete process audit identity.") }
    return token
  }

  static func stateBySettingDesiredOff(_ data: Data) throws -> Data {
    try StrictJSONDuplicateValidator.validate(
      data,
      maximumBytes: maximumStateBytes,
      maximumDepth: 32,
      maximumStringBytes: 2 * 1_024 * 1_024
    )
    let fields = try desiredAndCompletion(from: data)
    guard fields.desiredRunning else { return data }
    guard let range = try topLevelBooleanRange("desiredRunning", in: data),
      Array(data[range]) == Array("true".utf8)
    else { throw CoreFailure.coreIntegrity("Legacy desiredRunning is not a top-level Boolean.") }
    var updated = data
    updated.replaceSubrange(range, with: Data("false".utf8))
    guard try desiredAndCompletion(from: updated).desiredRunning == false else {
      throw CoreFailure.coreIntegrity("Legacy OFF edit did not validate.")
    }
    return updated
  }

  private static func census(
    legacyCorePath: String,
    legacyRootIdentity: (UInt32, UInt64, UInt32)?,
    coreIdentity: (UInt32, UInt64, UInt32)?,
    deadline: ContinuousClock.Instant,
    clock: ContinuousClock
  ) throws -> (pid: pid_t, token: audit_token_t)? {
    guard clock.now < deadline else {
      throw CoreFailure.coreIntegrity("Legacy process census timed out.")
    }
    let records = try rootProcessRecords()
    var candidate: (pid_t, audit_token_t)?
    for record in records {
      guard clock.now < deadline else {
        throw CoreFailure.coreIntegrity("Legacy process census timed out.")
      }
      let pid = record.kp_proc.p_pid
      guard pid > 0, record.kp_proc.p_stat != SIDL else { continue }
      let name = processName(record.kp_proc.p_comm)
      if name == "SBMHelper", pid != getpid() {
        throw CoreFailure.coreIntegrity(
          "An additional privileged SBMHelper remains after the native fence.")
      }
      guard name == "sing-box" else { continue }
      guard let path = processPath(pid) else {
        throw CoreFailure.coreIntegrity("Unable to classify a root sing-box process.")
      }
      let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
      if canonicalPath == retiredPath + "/" + coreName {
        throw CoreFailure.coreIntegrity("A process is executing the archived legacy core.")
      }
      if canonicalPath != legacyCorePath {
        // A root process with the same short name but another exact executable
        // path is unrelated to this fixed historical support root.
        continue
      }
      let token = try auditToken(for: pid)
      guard let legacyRootIdentity, let coreIdentity,
        processPath(pid).map({ URL(fileURLWithPath: $0).standardizedFileURL.path })
          == legacyCorePath,
        try mappedPathIdentity(pid, matching: coreIdentity, deadline: deadline, clock: clock)
      else {
        throw CoreFailure.coreIntegrity(
          "A root sing-box at the legacy path has an unverifiable image.")
      }
      let codeIdentity = try HelperPeerIdentityResolver.dynamicCodeIdentity(for: token)
      guard audit_token_to_ruid(token) == 0, audit_token_to_euid(token) == 0,
        codeIdentity.signingIdentifier == oldCoreSigningIdentifier,
        codeIdentity.cdHash == oldCoreCDHash,
        URL(fileURLWithPath: codeIdentity.executablePath).standardizedFileURL.path
          == legacyCorePath,
        try exactArguments(pid) == [legacyCorePath, "run", "-c", supportPath + "/config.json"],
        try currentDirectoryIdentity(pid) == legacyRootIdentity,
        processPath(pid).map({ URL(fileURLWithPath: $0).standardizedFileURL.path })
          == legacyCorePath,
        try auditToken(for: pid).withUnsafeBytesEqual(to: token)
      else {
        throw CoreFailure.coreIntegrity(
          "A legacy core candidate did not match its pinned audit identity and invocation.")
      }
      guard candidate == nil else {
        throw CoreFailure.coreIntegrity("Multiple exact legacy core candidates are present.")
      }
      candidate = (pid, token)
    }
    return candidate
  }

  private static func terminate(
    _ candidate: (pid: pid_t, token: audit_token_t),
    deadline: ContinuousClock.Instant,
    clock: ContinuousClock
  ) throws {
    guard try auditToken(for: candidate.pid).withUnsafeBytesEqual(to: candidate.token) else {
      return
    }
    let queue = kqueue()
    guard queue >= 0 else { throw CoreFailure.coreIntegrity("Unable to observe legacy core exit.") }
    defer { close(queue) }
    var change = kevent()
    change.ident = UInt(candidate.pid)
    change.filter = Int16(EVFILT_PROC)
    change.flags = UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT)
    change.fflags = UInt32(NOTE_EXIT)
    guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
      throw CoreFailure.coreIntegrity("Unable to register exact legacy core exit observation.")
    }
    guard try auditToken(for: candidate.pid).withUnsafeBytesEqual(to: candidate.token) else {
      throw CoreFailure.coreIntegrity("The legacy process identity changed before termination.")
    }
    try sendSignal(to: candidate.token, signal: SIGTERM)
    if try waitForExit(
      queue, deadline: min(deadline, clock.now.advanced(by: .seconds(6))), clock: clock)
    {
      return
    }
    guard clock.now < deadline,
      try auditToken(for: candidate.pid).withUnsafeBytesEqual(to: candidate.token)
    else { throw CoreFailure.coreIntegrity("The legacy core exit could not be proven after TERM.") }
    try sendSignal(to: candidate.token, signal: SIGKILL)
    guard
      try waitForExit(
        queue, deadline: min(deadline, clock.now.advanced(by: .seconds(6))), clock: clock)
    else {
      throw CoreFailure.coreIntegrity("The legacy core did not exit after audit-token KILL.")
    }
  }

  private static func waitForExit(
    _ queue: Int32,
    deadline: ContinuousClock.Instant,
    clock: ContinuousClock
  ) throws -> Bool {
    while clock.now < deadline {
      let remaining = clock.now.duration(to: deadline)
      let parts = remaining.components
      var timeout = timespec(
        tv_sec: Int(parts.seconds),
        tv_nsec: Int(parts.attoseconds / 1_000_000_000)
      )
      var event = kevent()
      let result = kevent(queue, nil, 0, &event, 1, &timeout)
      if result < 0 {
        if errno == EINTR { continue }
        throw CoreFailure.coreIntegrity("Unable to wait for exact legacy core exit.")
      }
      if result == 0 { return false }
      guard event.filter == Int16(EVFILT_PROC),
        event.ident > 0,
        event.fflags & UInt32(NOTE_EXIT) != 0
      else { throw CoreFailure.coreIntegrity("The legacy exit event was incomplete.") }
      return true
    }
    return false
  }

  private static func rootProcessRecords() throws -> [kinfo_proc] {
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_UID, 0]
    var requestedSize = 0
    guard
      mib.withUnsafeMutableBufferPointer({ pointer in
        sysctl(pointer.baseAddress, u_int(pointer.count), nil, &requestedSize, nil, 0)
      }) == 0,
      requestedSize > 0,
      requestedSize <= maximumCensusBytes
    else { throw CoreFailure.coreIntegrity("Unable to size the complete root process census.") }

    for _ in 0..<maximumCensusRetries {
      guard requestedSize <= maximumCensusBytes else {
        throw CoreFailure.coreIntegrity("The root process census exceeds its memory bound.")
      }
      var buffer = Data(count: requestedSize)
      var returnedSize = buffer.count
      let result = mib.withUnsafeMutableBufferPointer { mibPointer in
        buffer.withUnsafeMutableBytes { bytes in
          sysctl(
            mibPointer.baseAddress,
            u_int(mibPointer.count),
            bytes.baseAddress,
            &returnedSize,
            nil,
            0
          )
        }
      }
      if result != 0 {
        guard errno == ENOMEM else {
          throw CoreFailure.coreIntegrity(
            "The complete root process census failed with errno \(errno).")
        }
        requestedSize = max(requestedSize * 2, returnedSize)
        continue
      }
      guard returnedSize > 0,
        returnedSize <= buffer.count,
        returnedSize % MemoryLayout<kinfo_proc>.stride == 0
      else { throw CoreFailure.coreIntegrity("The root process census returned a partial record.") }
      buffer.count = returnedSize
      return buffer.withUnsafeBytes { bytes in
        stride(from: 0, to: bytes.count, by: MemoryLayout<kinfo_proc>.stride).map {
          bytes.loadUnaligned(fromByteOffset: $0, as: kinfo_proc.self)
        }
      }
    }
    throw CoreFailure.coreIntegrity(
      "The root process census remained incomplete after bounded ENOMEM retries.")
  }

  private static func processName<Value>(_ value: Value) -> String {
    withUnsafeBytes(of: value) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  private static func processPath(_ pid: pid_t) -> String? {
    var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
    guard count > 0 else { return nil }
    return String(
      decoding: bytes.prefix(Int(count)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
  }

  private static func exactArguments(_ pid: pid_t) throws -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
    var size = 0
    guard
      mib.withUnsafeMutableBufferPointer({ pointer in
        sysctl(pointer.baseAddress, u_int(pointer.count), nil, &size, nil, 0)
      }) == 0, size >= MemoryLayout<Int32>.size, size <= 256 * 1_024
    else {
      throw CoreFailure.coreIntegrity("Unable to read bounded legacy process arguments.")
    }
    var data = Data(count: size)
    var actual = data.count
    let result = mib.withUnsafeMutableBufferPointer { pointer in
      data.withUnsafeMutableBytes { bytes in
        sysctl(pointer.baseAddress, u_int(pointer.count), bytes.baseAddress, &actual, nil, 0)
      }
    }
    guard result == 0, actual >= MemoryLayout<Int32>.size, actual <= data.count else {
      throw CoreFailure.coreIntegrity("Legacy process arguments were incomplete.")
    }
    data.count = actual
    return try parseArguments(data)
  }

  private static func parseArguments(_ data: Data) throws -> [String] {
    let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc == 4 else {
      throw CoreFailure.coreIntegrity("Legacy core argument count is not exact.")
    }
    let bytes = Array(data.dropFirst(MemoryLayout<Int32>.size))
    guard let executableEnd = bytes.firstIndex(of: 0), executableEnd > 0,
      String(bytes: bytes[..<executableEnd], encoding: .utf8) == supportPath + "/" + coreName
    else { throw CoreFailure.coreIntegrity("Legacy process executable path is not exact.") }
    var cursor = executableEnd + 1
    while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
    var arguments: [String] = []
    for _ in 0..<argc {
      guard cursor < bytes.count else {
        throw CoreFailure.coreIntegrity("Legacy process arguments are truncated.")
      }
      let start = cursor
      while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
      guard cursor > start,
        let value = String(bytes: bytes[start..<cursor], encoding: .utf8)
      else { throw CoreFailure.coreIntegrity("Legacy process arguments are invalid UTF-8.") }
      arguments.append(value)
      cursor += 1
    }
    return arguments
  }

  private static func currentDirectoryIdentity(_ pid: pid_t) throws -> (UInt32, UInt64, UInt32) {
    var info = proc_vnodepathinfo()
    let result = proc_pidinfo(
      pid,
      PROC_PIDVNODEPATHINFO,
      0,
      &info,
      Int32(MemoryLayout<proc_vnodepathinfo>.size)
    )
    guard result == MemoryLayout<proc_vnodepathinfo>.size else {
      throw CoreFailure.coreIntegrity("Unable to inspect the legacy process working directory.")
    }
    let stat = info.pvi_cdir.vip_vi.vi_stat
    return (stat.vst_dev, stat.vst_ino, stat.vst_gen)
  }

  private static func mappedPathIdentity(
    _ pid: pid_t,
    matching expected: (UInt32, UInt64, UInt32),
    deadline: ContinuousClock.Instant,
    clock: ContinuousClock
  ) throws -> Bool {
    var address: UInt64 = 0
    for _ in 0..<maximumRegions {
      guard clock.now < deadline else {
        throw CoreFailure.coreIntegrity("Legacy mapping inspection timed out.")
      }
      var info = proc_regionwithpathinfo()
      let result = proc_pidinfo(
        pid,
        PROC_PIDREGIONPATHINFO,
        address,
        &info,
        Int32(MemoryLayout<proc_regionwithpathinfo>.size)
      )
      if result == 0 { return false }
      guard result == MemoryLayout<proc_regionwithpathinfo>.size else {
        throw CoreFailure.coreIntegrity("Unable to inspect a legacy executable mapping.")
      }
      let region = info.prp_prinfo
      let nextAddress = region.pri_address.addingReportingOverflow(region.pri_size)
      guard region.pri_size > 0, !nextAddress.overflow, nextAddress.partialValue > address else {
        throw CoreFailure.coreIntegrity("Legacy executable mapping enumeration did not advance.")
      }
      let stat = info.prp_vip.vip_vi.vi_stat
      if stat.vst_ino != 0,
        (stat.vst_dev, stat.vst_ino, stat.vst_gen) == expected
      {
        return true
      }
      address = nextAddress.partialValue
    }
    throw CoreFailure.coreIntegrity("Legacy executable mapping enumeration exceeded its bound.")
  }

  private static func openProtectedParent() throws -> Int32 {
    let library = "/Library"
    let applicationSupport = "/Library/Application Support"
    var info = stat()
    guard lstat(library, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == 0, (info.st_mode & 0o022) == 0,
      lstat(applicationSupport, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == 0, (info.st_mode & 0o022) == 0
    else {
      throw CoreFailure.coreIntegrity("The fixed support parent is not a protected root directory.")
    }
    let descriptor = open(applicationSupport, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw CoreFailure.coreIntegrity("Unable to open the fixed support parent.")
    }
    return descriptor
  }

  private static func openDirectory(at path: String) -> Int32? {
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    return descriptor >= 0 ? descriptor : nil
  }

  private static func secureDirectory(_ descriptor: Int32) -> Bool {
    var info = stat()
    return fstat(descriptor, &info) == 0
      && (info.st_mode & S_IFMT) == S_IFDIR
      && info.st_uid == 0
      && (info.st_mode & 0o022) == 0
  }

  private static func secureCore(_ descriptor: Int32) -> Bool {
    var info = stat()
    return fstat(descriptor, &info) == 0
      && (info.st_mode & S_IFMT) == S_IFREG
      && info.st_uid == 0
      && info.st_nlink == 1
      && (info.st_mode & 0o022) == 0
      && (info.st_mode & 0o111) != 0
      && info.st_size > 0
      && info.st_size <= 256 * 1_024 * 1_024
  }

  private static func secureState(_ descriptor: Int32) -> Bool {
    var info = stat()
    return fstat(descriptor, &info) == 0
      && (info.st_mode & S_IFMT) == S_IFREG
      && info.st_uid == 0
      && info.st_nlink == 1
      && (info.st_mode & 0o022) == 0
      && info.st_size >= 0
      && info.st_size <= maximumStateBytes
  }

  private static func nodeIdentity(_ descriptor: Int32) throws -> (UInt32, UInt64, UInt32) {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw CoreFailure.coreIntegrity("Unable to identify a protected legacy file-system object.")
    }
    return (UInt32(truncatingIfNeeded: info.st_dev), UInt64(info.st_ino), info.st_gen)
  }

  private static func nodeIdentity(at directory: Int32, name: String) throws -> (
    UInt32, UInt64, UInt32
  ) {
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw CoreFailure.coreIntegrity("Unable to re-open a protected legacy file-system object.")
    }
    defer { close(descriptor) }
    return try nodeIdentity(descriptor)
  }

  private static func sha256(_ descriptor: Int32) throws -> String {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_size > 0,
      info.st_size <= 256 * 1_024 * 1_024,
      lseek(descriptor, 0, SEEK_SET) == 0
    else { throw CoreFailure.coreIntegrity("Unable to hash the pinned legacy core.") }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var total: Int64 = 0
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw CoreFailure.coreIntegrity("Unable to read the pinned legacy core.")
      }
      if count == 0 { break }
      total += Int64(count)
      guard total <= info.st_size else {
        throw CoreFailure.coreIntegrity("The pinned legacy core changed while hashing.")
      }
      hasher.update(data: Data(buffer.prefix(count)))
    }
    guard total == info.st_size else {
      throw CoreFailure.coreIntegrity("The pinned legacy core changed while hashing.")
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func readState(at directory: Int32) throws -> Data {
    let descriptor = openat(directory, stateName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw CoreFailure.coreIntegrity("A nonempty legacy root has no state file.")
    }
    defer { close(descriptor) }
    guard secureState(descriptor) else {
      throw CoreFailure.coreIntegrity("The legacy state file has unsafe ownership or permissions.")
    }
    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
      throw CoreFailure.coreIntegrity("Unable to identify legacy state.")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while data.count <= maximumStateBytes {
      let count = Darwin.read(
        descriptor, &buffer, min(buffer.count, maximumStateBytes + 1 - data.count))
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw CoreFailure.coreIntegrity("Unable to read legacy state.") }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= maximumStateBytes else {
        throw CoreFailure.coreIntegrity("Legacy state exceeds its size bound.")
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_gen == after.st_gen,
      before.st_size == after.st_size,
      Int64(data.count) == before.st_size
    else { throw CoreFailure.coreIntegrity("Legacy state changed while it was read.") }
    try StrictJSONDuplicateValidator.validate(
      data,
      maximumBytes: maximumStateBytes,
      maximumDepth: 32,
      maximumStringBytes: 2 * 1_024 * 1_024
    )
    return data
  }

  private static func desiredAndCompletion(from data: Data) throws -> (
    desiredRunning: Bool, complete: Bool
  ) {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let desired = object["desiredRunning"] as? NSNumber,
      CFGetTypeID(desired) == CFBooleanGetTypeID()
    else { throw CoreFailure.coreIntegrity("Legacy state lacks exact Boolean retirement fields.") }
    guard let completeValue = object["legacy1115RetirementComplete"] else {
      return (desired.boolValue, false)
    }
    guard let completion = completeValue as? NSNumber,
      CFGetTypeID(completion) == CFBooleanGetTypeID()
    else { throw CoreFailure.coreIntegrity("Legacy completion field is not a Boolean.") }
    return (desired.boolValue, completion.boolValue)
  }

  private static func writeDesiredOffIfNeeded(
    _ data: Data,
    at directory: Int32,
    desiredRunning: Bool
  ) throws -> Data {
    guard desiredRunning else {
      let existing = openat(directory, stateName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard existing >= 0 else {
        throw CoreFailure.coreIntegrity("Unable to reopen legacy state for durable OFF proof.")
      }
      defer { close(existing) }
      guard secureState(existing),
        try nodeIdentity(existing) == nodeIdentity(at: directory, name: stateName),
        try readState(at: directory) == data,
        try desiredAndCompletion(from: data).desiredRunning == false,
        fsync(existing) == 0,
        fsync(directory) == 0
      else {
        throw CoreFailure.coreIntegrity("Unable to sync the existing legacy OFF state.")
      }
      let readback = try readState(at: directory)
      guard readback == data,
        try nodeIdentity(existing) == nodeIdentity(at: directory, name: stateName),
        try desiredAndCompletion(from: readback).desiredRunning == false
      else {
        throw CoreFailure.coreIntegrity("Legacy OFF state changed during durable readback.")
      }
      return readback
    }
    let updated = try stateBySettingDesiredOff(data)

    let original = openat(directory, stateName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard original >= 0 else {
      throw CoreFailure.coreIntegrity("Unable to reopen legacy state for OFF.")
    }
    defer { close(original) }
    guard secureState(original), try readState(at: directory) == data else {
      throw CoreFailure.coreIntegrity("Legacy state changed before the protected OFF write.")
    }
    let temporaryName = ".state.json.sbm-off-\(UUID().uuidString)"
    let temporary = openat(
      directory,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    guard temporary >= 0 else {
      throw CoreFailure.coreIntegrity("Unable to create protected OFF state.")
    }
    defer {
      close(temporary)
      _ = unlinkat(directory, temporaryName, 0)
    }
    guard fchown(temporary, 0, 0) == 0, fchmod(temporary, 0o600) == 0 else {
      throw CoreFailure.coreIntegrity("Unable to protect the OFF state copy.")
    }
    try writeAll(updated, to: temporary)
    guard fsync(temporary) == 0 else {
      throw CoreFailure.coreIntegrity("Unable to sync legacy OFF state.")
    }
    var current = stat()
    var originalInfo = stat()
    guard fstatat(directory, stateName, &current, AT_SYMLINK_NOFOLLOW) == 0,
      fstat(original, &originalInfo) == 0,
      current.st_dev == originalInfo.st_dev,
      current.st_ino == originalInfo.st_ino,
      current.st_gen == originalInfo.st_gen,
      renameat(directory, temporaryName, directory, stateName) == 0,
      fsync(directory) == 0
    else {
      throw CoreFailure.coreIntegrity("Unable to atomically publish durable legacy OFF state.")
    }
    let readback = try readState(at: directory)
    guard readback == updated, try desiredAndCompletion(from: readback).desiredRunning == false
    else {
      throw CoreFailure.coreIntegrity("Legacy OFF readback did not match the durable edit.")
    }
    return readback
  }

  private static func topLevelBooleanRange(_ key: String, in data: Data) throws -> Range<
    Data.Index
  >? {
    let bytes = Array(data)
    var index = 0
    func whitespace(_ byte: UInt8) -> Bool {
      byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
    func skipWhitespace() { while index < bytes.count, whitespace(bytes[index]) { index += 1 } }
    func stringEnd(from start: Int) throws -> Int {
      guard start < bytes.count, bytes[start] == 0x22 else {
        throw CoreFailure.coreIntegrity("Legacy state JSON key is invalid.")
      }
      var cursor = start + 1
      while cursor < bytes.count {
        if bytes[cursor] == 0x5C {
          cursor += 2
          continue
        }
        if bytes[cursor] == 0x22 { return cursor + 1 }
        cursor += 1
      }
      throw CoreFailure.coreIntegrity("Legacy state JSON string is unterminated.")
    }
    func skipValue(from start: Int) throws -> Int {
      guard start < bytes.count else {
        throw CoreFailure.coreIntegrity("Legacy state JSON value is missing.")
      }
      if bytes[start] == 0x22 { return try stringEnd(from: start) }
      if bytes[start] == 0x7B || bytes[start] == 0x5B {
        var stack: [UInt8] = [bytes[start] == 0x7B ? 0x7D : 0x5D]
        var cursor = start + 1
        while cursor < bytes.count, !stack.isEmpty {
          if bytes[cursor] == 0x22 {
            cursor = try stringEnd(from: cursor)
            continue
          }
          if bytes[cursor] == 0x7B {
            stack.append(0x7D)
          } else if bytes[cursor] == 0x5B {
            stack.append(0x5D)
          } else if bytes[cursor] == 0x7D || bytes[cursor] == 0x5D {
            guard stack.popLast() == bytes[cursor] else {
              throw CoreFailure.coreIntegrity("Legacy state JSON nesting is invalid.")
            }
          }
          cursor += 1
        }
        guard stack.isEmpty else {
          throw CoreFailure.coreIntegrity("Legacy state JSON value is incomplete.")
        }
        return cursor
      }
      var cursor = start
      while cursor < bytes.count,
        bytes[cursor] != 0x2C, bytes[cursor] != 0x7D, bytes[cursor] != 0x5D,
        !whitespace(bytes[cursor])
      { cursor += 1 }
      return cursor
    }

    skipWhitespace()
    guard index < bytes.count, bytes[index] == 0x7B else {
      throw CoreFailure.coreIntegrity("Legacy state is not a top-level object.")
    }
    index += 1
    while true {
      skipWhitespace()
      guard index < bytes.count else {
        throw CoreFailure.coreIntegrity("Legacy state object is incomplete.")
      }
      if bytes[index] == 0x7D { return nil }
      let keyStart = index
      let keyEnd = try stringEnd(from: keyStart)
      let keyBytes = Data(bytes[keyStart..<keyEnd])
      let decodedKey = try JSONDecoder().decode(String.self, from: keyBytes)
      index = keyEnd
      skipWhitespace()
      guard index < bytes.count, bytes[index] == 0x3A else {
        throw CoreFailure.coreIntegrity("Legacy state object field is malformed.")
      }
      index += 1
      skipWhitespace()
      let valueStart = index
      let valueEnd = try skipValue(from: valueStart)
      if decodedKey == key, valueEnd > valueStart,
        bytes[valueStart] == 0x74 || bytes[valueStart] == 0x66
      {
        return data.index(
          data.startIndex, offsetBy: valueStart)..<data.index(data.startIndex, offsetBy: valueEnd)
      }
      index = valueEnd
      skipWhitespace()
      guard index < bytes.count else {
        throw CoreFailure.coreIntegrity("Legacy state object is incomplete.")
      }
      if bytes[index] == 0x7D { return nil }
      guard bytes[index] == 0x2C else {
        throw CoreFailure.coreIntegrity("Legacy state object separator is malformed.")
      }
      index += 1
    }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw CoreFailure.coreIntegrity("Unable to write protected state bytes.")
        }
        offset += count
      }
    }
  }

  private static func verifyCore(_ descriptor: Int32?, in directory: Int32) throws {
    guard let descriptor else {
      guard try !entryExists(directory, name: coreName) else {
        throw CoreFailure.coreIntegrity("An unpinned legacy core appeared during retirement.")
      }
      return
    }
    guard secureCore(descriptor),
      try nodeIdentity(descriptor) == nodeIdentity(at: directory, name: coreName),
      try sha256(descriptor) == oldCoreSHA256
    else {
      throw CoreFailure.coreIntegrity("The pinned legacy core changed during retirement.")
    }
  }

  private static func verifyPreservedRoot(
    parent: Int32,
    descriptor: Int32,
    identity: (UInt32, UInt64, UInt32),
    stateBytes: Data,
    coreFD: Int32?
  ) throws {
    let archivedRootName = "SBM.legacy-1.1.15.retired"
    let archived = openat(
      parent, archivedRootName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard archived >= 0 else {
      throw CoreFailure.coreIntegrity("The preserved legacy root cannot be reopened for readback.")
    }
    defer { close(archived) }
    guard secureDirectory(archived),
      try nodeIdentity(archived) == identity,
      try nodeIdentity(descriptor) == identity,
      fsync(archived) == 0,
      fsync(parent) == 0
    else {
      throw CoreFailure.coreIntegrity("The preserved legacy root failed durable identity readback.")
    }
    let readback = try readState(at: archived)
    let state = try desiredAndCompletion(from: readback)
    guard readback == stateBytes, !state.desiredRunning, !state.complete else {
      throw CoreFailure.coreIntegrity("The archived legacy state failed OFF readback.")
    }
    try verifyCore(coreFD, in: archived)
    guard try nodeIdentity(at: parent, name: archivedRootName) == identity else {
      throw CoreFailure.coreIntegrity("The archived legacy-root path changed during readback.")
    }
  }

  private static func renameLegacyRoot(
    parent: Int32,
    descriptor: Int32,
    identity: (UInt32, UInt64, UInt32)
  ) throws {
    guard try nodeIdentity(descriptor) == identity,
      !(try entryExists(parent, name: "SBM.legacy-1.1.15.retired"))
    else {
      throw CoreFailure.coreIntegrity("The legacy root changed before exclusive preservation.")
    }
    var pathInfo = stat()
    guard fstatat(parent, "SBM", &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
      UInt32(truncatingIfNeeded: pathInfo.st_dev) == identity.0,
      UInt64(pathInfo.st_ino) == identity.1,
      pathInfo.st_gen == identity.2,
      fsync(descriptor) == 0,
      renameatx_np(parent, "SBM", parent, "SBM.legacy-1.1.15.retired", UInt32(RENAME_EXCL)) == 0,
      fsync(parent) == 0
    else {
      throw CoreFailure.coreIntegrity("Unable to exclusively preserve the complete legacy root.")
    }
  }

  private static func entryExists(_ parent: Int32, name: String) throws -> Bool {
    var info = stat()
    if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
    guard errno == ENOENT else {
      throw CoreFailure.coreIntegrity("Unable to classify fixed support path entry \(name).")
    }
    return false
  }

  private static func directoryIsEmpty(_ descriptor: Int32) throws -> Bool {
    let identity = try nodeIdentity(descriptor)
    let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard copy >= 0 else {
      throw CoreFailure.coreIntegrity("Unable to open an independent view of the legacy root.")
    }
    var copyOwnedByCaller = true
    defer { if copyOwnedByCaller { close(copy) } }
    guard secureDirectory(copy), try nodeIdentity(copy) == identity else {
      throw CoreFailure.coreIntegrity("The independent legacy-root descriptor changed identity.")
    }
    guard let directory = fdopendir(copy) else {
      throw CoreFailure.coreIntegrity("Unable to enumerate the protected legacy root.")
    }
    copyOwnedByCaller = false
    defer { closedir(directory) }
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else {
          throw CoreFailure.coreIntegrity("Unable to finish enumerating the protected legacy root.")
        }
        return true
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
      }
      if name != "." && name != ".." { return false }
    }
  }
}

extension audit_token_t {
  fileprivate func withUnsafeBytesEqual(to other: audit_token_t) -> Bool {
    withUnsafeBytes(of: self) { left in
      withUnsafeBytes(of: other) { right in left.elementsEqual(right) }
    }
  }
}
