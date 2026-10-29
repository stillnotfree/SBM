import Darwin
import Foundation

public enum ColdOffProofFailure: LocalizedError, Sendable {
  case invalidPath
  case unsafeParent
  case unsafeFile
  case busy
  case invalidMarker
  case readOnly
  case systemCall(String, Int32)

  public var errorDescription: String? {
    switch self {
    case .invalidPath: "The Cold OFF proof path is invalid."
    case .unsafeParent: "The Cold OFF proof directory is not protected."
    case .unsafeFile: "The Cold OFF proof file has unsafe metadata."
    case .busy: "The Cold OFF proof is currently locked."
    case .invalidMarker: "The Cold OFF proof marker is missing or malformed."
    case .readOnly: "The Cold OFF proof descriptor is read-only."
    case .systemCall(let name, let code): "\(name) failed with errno \(code)."
    }
  }
}

public final class ColdOffProof {
  public static let path = "/private/var/db/com.stillnotfree.sbm.helper.v12.off"
  public static let offMarker = Data("SBM-COLD-OFF-v1\n".utf8)

  private let descriptor: Int32
  private let parentDescriptor: Int32
  private let parentPath: String
  private let leafName: String
  private let writable: Bool
  private var closed = false

  private init(
    descriptor: Int32,
    parentDescriptor: Int32,
    parentPath: String,
    leafName: String,
    writable: Bool
  ) {
    self.descriptor = descriptor
    self.parentDescriptor = parentDescriptor
    self.parentPath = parentPath
    self.leafName = leafName
    self.writable = writable
  }

  public static func acquireLifetime() throws -> ColdOffProof {
    try acquireLifetime(at: path)
  }

  public static func acquireClaim() throws -> ColdOffProof {
    try acquireClaim(at: path)
  }

  static func acquireLifetime(at path: String) throws -> ColdOffProof {
    try acquire(at: path, writable: true, create: true)
  }

  static func acquireClaim(at path: String) throws -> ColdOffProof {
    let proof = try acquire(at: path, writable: false, create: false)
    do {
      try proof.requireOFFMarker()
      return proof
    } catch {
      proof.release()
      throw error
    }
  }

  private static func acquire(
    at path: String,
    writable: Bool,
    create: Bool
  ) throws -> ColdOffProof {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.hasPrefix("/"),
      !path.utf8.contains(0),
      components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      let separator = path.lastIndex(of: "/")
    else {
      throw ColdOffProofFailure.invalidPath
    }
    let parentComponent = String(path[..<separator])
    let parentPath = parentComponent.isEmpty ? "/" : parentComponent
    let leafName = String(path[path.index(after: separator)...])

    let parent = open(parentPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    guard parent >= 0 else { throw ColdOffProofFailure.systemCall("open proof directory", errno) }
    do {
      try validateParent(parent, path: parentPath)
      var descriptor: Int32 = -1
      var created = false
      if create {
        descriptor = openat(
          parent,
          leafName,
          O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_CREAT | O_EXCL,
          mode_t(0o640)
        )
        if descriptor >= 0 {
          created = true
        } else if errno == EEXIST {
          descriptor = openat(
            parent, leafName, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0)
        }
      } else {
        descriptor = openat(
          parent, leafName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0)
      }
      guard descriptor >= 0 else {
        throw ColdOffProofFailure.systemCall("open proof file", errno)
      }
      do {
        if created {
          guard let admin = getgrnam("admin") else {
            throw ColdOffProofFailure.unsafeFile
          }
          guard fchown(descriptor, 0, admin.pointee.gr_gid) == 0,
            fchmod(descriptor, 0o640) == 0,
            fsync(descriptor) == 0
          else { throw ColdOffProofFailure.systemCall("initialize proof file", errno) }
          guard fsync(parent) == 0 || errno == EINVAL else {
            throw ColdOffProofFailure.systemCall("sync proof directory", errno)
          }
        }
        try validateFile(descriptor, parent: parent, leafName: leafName)
        try lockExclusiveNonblocking(descriptor)
        let proof = ColdOffProof(
          descriptor: descriptor,
          parentDescriptor: parent,
          parentPath: parentPath,
          leafName: leafName,
          writable: writable
        )
        return proof
      } catch {
        close(descriptor)
        throw error
      }
    } catch {
      close(parent)
      throw error
    }
  }

  static func lockExclusiveNonblocking(_ descriptor: Int32) throws {
    guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else { return }
    if errno == EWOULDBLOCK || errno == EAGAIN { throw ColdOffProofFailure.busy }
    throw ColdOffProofFailure.systemCall("flock", errno)
  }

  public func clearAndSync() throws {
    guard writable, !closed else { throw ColdOffProofFailure.readOnly }
    try validateIdentity()
    guard ftruncate(descriptor, 0) == 0, fsync(descriptor) == 0 else {
      throw ColdOffProofFailure.systemCall("clear and sync proof file", errno)
    }
    try validateIdentity()
  }

  public func publishOFFAndSync() throws {
    guard writable, !closed else { throw ColdOffProofFailure.readOnly }
    try validateIdentity()
    guard ftruncate(descriptor, 0) == 0 else {
      throw ColdOffProofFailure.systemCall("truncate proof file", errno)
    }
    try Self.writeAll(Self.offMarker, to: descriptor)
    guard fsync(descriptor) == 0 else {
      throw ColdOffProofFailure.systemCall("sync proof marker", errno)
    }
    try requireOFFMarker()
  }

  public func requireOFFMarker() throws {
    guard !closed else { throw ColdOffProofFailure.unsafeFile }
    try validateIdentity()
    var bytes = [UInt8](repeating: 0, count: Self.offMarker.count + 1)
    let count = pread(descriptor, &bytes, bytes.count, 0)
    guard count == Self.offMarker.count,
      Data(bytes.prefix(count)) == Self.offMarker
    else { throw ColdOffProofFailure.invalidMarker }
    try validateIdentity()
  }

  public func release() {
    guard !closed else { return }
    closed = true
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
    close(parentDescriptor)
  }

  deinit {
    release()
  }

  private func validateIdentity() throws {
    try Self.validateParent(parentDescriptor, path: parentPath)
    try Self.validateFile(descriptor, parent: parentDescriptor, leafName: leafName)
  }

  private static func validateParent(_ descriptor: Int32, path: String) throws {
    var opened = stat()
    var linked = stat()
    guard fstat(descriptor, &opened) == 0,
      lstat(path, &linked) == 0,
      sameInode(opened, linked),
      (opened.st_mode & S_IFMT) == S_IFDIR,
      opened.st_uid == 0,
      opened.st_mode & 0o022 == 0
    else { throw ColdOffProofFailure.unsafeParent }
  }

  private static func validateFile(
    _ descriptor: Int32,
    parent: Int32,
    leafName: String
  ) throws {
    guard let admin = getgrnam("admin") else { throw ColdOffProofFailure.unsafeFile }
    var opened = stat()
    var linked = stat()
    guard fstat(descriptor, &opened) == 0,
      fstatat(parent, leafName, &linked, AT_SYMLINK_NOFOLLOW) == 0,
      sameInode(opened, linked),
      (opened.st_mode & S_IFMT) == S_IFREG,
      opened.st_uid == 0,
      opened.st_gid == admin.pointee.gr_gid,
      opened.st_nlink == 1,
      opened.st_mode & 0o7777 == 0o640
    else { throw ColdOffProofFailure.unsafeFile }
    let flags = fcntl(descriptor, F_GETFD)
    guard flags >= 0, flags & FD_CLOEXEC != 0 else {
      throw ColdOffProofFailure.unsafeFile
    }
  }

  private static func sameInode(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = pwrite(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset,
          off_t(offset)
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw ColdOffProofFailure.systemCall("write proof marker", errno)
        }
        offset += count
      }
    }
  }
}
