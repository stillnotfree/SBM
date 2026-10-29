import Darwin
import Foundation
import SBMShared
import Testing

@testable import SBMShared

private func temporaryRegularFile() throws -> URL {
  var template = Array(
    FileManager.default.temporaryDirectory
      .appendingPathComponent("sbm-cold-off-test-XXXXXX").path.utf8CString
  )
  let descriptor = mkstemp(&template)
  guard descriptor >= 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  close(descriptor)
  let path = template.dropLast().map { UInt8(bitPattern: $0) }
  return URL(fileURLWithPath: String(decoding: path, as: UTF8.self))
}

private func temporaryPrivateDirectoryPath() throws -> String {
  var template = Array("/private/tmp/sbm-cold-off-test-XXXXXX".utf8CString)
  guard mkdtemp(&template) != nil else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  let path = template.dropLast().map { UInt8(bitPattern: $0) }
  return String(decoding: path, as: UTF8.self)
}

private func childLockStatus(path: String) throws -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
  process.arguments = [
    "-MFcntl=:flock", "-e",
    "open(my $f, '<', $ARGV[0]) or exit 70; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 73);",
    path,
  ]
  try process.run()
  process.waitUntilExit()
  return process.terminationStatus
}

private func childDescriptorAccessStatus(_ descriptor: Int32) throws -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
  process.arguments = [
    "-e", "open(my $f, '<&=' . $ARGV[0]) or exit 0; exit 1;", String(descriptor),
  ]
  try process.run()
  process.waitUntilExit()
  return process.terminationStatus
}

@Test func coldOffLockUsesIndependentReadOnlyDescriptorsAndReleasesAcrossProcesses() throws {
  let url = try temporaryRegularFile()
  defer { try? FileManager.default.removeItem(at: url) }

  let first = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
  let second = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
  #expect(first >= 0)
  #expect(second >= 0)
  defer {
    close(first)
    close(second)
  }
  for descriptor in [first, second] {
    let flags = fcntl(descriptor, F_GETFD)
    #expect(flags >= 0 && flags & FD_CLOEXEC != 0)
  }
  #expect(try childDescriptorAccessStatus(first) == 0)

  var metadata = stat()
  #expect(fstat(first, &metadata) == 0)
  #expect((metadata.st_mode & S_IFMT) == S_IFREG)
  #expect(metadata.st_nlink == 1)
  #expect(metadata.st_uid == geteuid())

  try ColdOffProof.lockExclusiveNonblocking(first)
  var blockedOnIndependentDescriptor = false
  do {
    try ColdOffProof.lockExclusiveNonblocking(second)
  } catch ColdOffProofFailure.busy {
    blockedOnIndependentDescriptor = true
  }
  #expect(blockedOnIndependentDescriptor)
  #expect(try childLockStatus(path: url.path) == 73)

  #expect(flock(first, LOCK_UN) == 0)
  try ColdOffProof.lockExclusiveNonblocking(second)
  #expect(try childLockStatus(path: url.path) == 73)
  #expect(flock(second, LOCK_UN) == 0)
  #expect(try childLockStatus(path: url.path) == 0)
}

@Test func coldOffClaimRejectsTemporaryUserOwnedPathWithoutImpersonatingRoot() throws {
  let url = try temporaryRegularFile()
  defer { try? FileManager.default.removeItem(at: url) }

  do {
    let claim = try ColdOffProof.acquireClaim(at: url.path)
    claim.release()
    Issue.record("A user-owned temporary file must not satisfy the protected Cold OFF claim.")
  } catch ColdOffProofFailure.unsafeParent {
    // The temporary directory is not owned by root on the normal GUI test account.
  } catch ColdOffProofFailure.unsafeFile {
    // A root-run test still rejects the non-admin, non-0640 file metadata.
  }
}

@Test func coldOffClaimKeepsExistingPrivateTemporaryPathLexical() throws {
  let parentPath = try temporaryPrivateDirectoryPath()
  defer { try? FileManager.default.removeItem(atPath: parentPath) }

  let path = parentPath + "/proof.off"
  guard FileManager.default.createFile(atPath: path, contents: Data()) else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }

  do {
    let claim = try ColdOffProof.acquireClaim(at: path)
    claim.release()
    Issue.record("A user-owned temporary path must not satisfy the protected Cold OFF claim.")
  } catch ColdOffProofFailure.invalidPath {
    Issue.record("Existing /private/tmp path must reach metadata checks.")
  } catch ColdOffProofFailure.unsafeParent {
    // The temporary directory is not root-owned on the normal GUI test account.
  } catch ColdOffProofFailure.unsafeFile {
    // A root-run test still rejects the non-admin, non-0640 file metadata.
  }
}

@Test func coldOffProofRejectsMalformedLexicalPathsBeforeFilesystemAccess() throws {
  let paths = [
    "",
    "relative/proof.off",
    "/private/tmp/sbm-cold-off-invalid/./proof.off",
    "/private/tmp/sbm-cold-off-invalid/../proof.off",
    "/private/tmp/sbm-cold-off-invalid//proof.off",
    "/private/tmp/sbm-cold-off-invalid/proof.off/",
    "/private/tmp/sbm-cold-off-invalid/\0proof.off",
  ]

  for path in paths {
    do {
      let claim = try ColdOffProof.acquireClaim(at: path)
      claim.release()
      Issue.record("Malformed path unexpectedly acquired a Cold OFF claim: \(path)")
    } catch ColdOffProofFailure.invalidPath {
      // Reject malformed lexical paths before any file-system operation.
    } catch {
      Issue.record("Expected invalidPath for malformed input, got \(error)")
    }
  }
}
