import Darwin
import Foundation
import SBMShared
import Testing

@testable import SBMHelper

@Test func legacyOFFByteEditPreservesUnrelatedJSONAndNumericLexemes() throws {
  let input = Data(
    #"{"largeInteger":9007199254740993,"exponent":1.2300e+10,"desiredRunning":true,"nested":{"desiredRunning":true},"text":"desiredRunning:true"}"#
      .utf8
  )
  let expected = Data(
    #"{"largeInteger":9007199254740993,"exponent":1.2300e+10,"desiredRunning":false,"nested":{"desiredRunning":true},"text":"desiredRunning:true"}"#
      .utf8
  )

  #expect(try Legacy1115Retirement.stateBySettingDesiredOff(input) == expected)
}

@Test func legacyOFFByteEditFindsEscapedTopLevelKeyAndPreservesSurroundingBytes() throws {
  let input = Data(
    #"{"largeInteger":9007199254740993,"exponent":1.2300e+10,"des\u0069redRunning":true,"nested":{"desiredRunning":true},"text":"desiredRunning:true"}"#
      .utf8
  )
  let expected = Data(
    #"{"largeInteger":9007199254740993,"exponent":1.2300e+10,"des\u0069redRunning":false,"nested":{"desiredRunning":true},"text":"desiredRunning:true"}"#
      .utf8
  )

  let updated = try Legacy1115Retirement.stateBySettingDesiredOff(input)
  #expect(updated == expected)
  #expect(try Legacy1115Retirement.stateBySettingDesiredOff(updated) == expected)
}

@Test func legacyOFFByteEditIsIdempotentWhenAlreadyOff() throws {
  let input = Data(#"{"desiredRunning":false,"number":1.000e3}"#.utf8)

  #expect(try Legacy1115Retirement.stateBySettingDesiredOff(input) == input)
}

@Test func legacyStateOnlyOFFFixtureHasNoCoreAndPreservesStateBytes() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("sbm-legacy-state-only-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }

  let stateURL = root.appendingPathComponent(Legacy1115Retirement.stateName)
  let coreURL = root.appendingPathComponent(Legacy1115Retirement.coreName)
  let original = Data(#"{"desiredRunning":false,"sequence":9007199254740993}"#.utf8)
  try original.write(to: stateURL, options: .atomic)

  #expect(!FileManager.default.fileExists(atPath: coreURL.path))
  #expect(try Legacy1115Retirement.stateBySettingDesiredOff(Data(contentsOf: stateURL)) == original)
  #expect(try Data(contentsOf: stateURL) == original)
  #expect(!FileManager.default.fileExists(atPath: coreURL.path))
}

@Test func currentHelperRetirementReceiptDefaultsFalseAndRoundTrips() throws {
  let oldState = try JSONDecoder().decode(PersistentState.self, from: Data("{}".utf8))
  #expect(!oldState.legacy1115RetirementComplete)

  var completed = PersistentState()
  completed.legacy1115RetirementComplete = true
  let encoded = try JSONEncoder().encode(completed)
  let decoded = try JSONDecoder().decode(PersistentState.self, from: encoded)
  #expect(decoded.legacy1115RetirementComplete)
}

// Tuple fixture only; the source-contract test below pins the private production predicate.
private func legacyMappingIdentityFixtureMatches(
  _ observed: (UInt32, UInt64, UInt32)?,
  expected: (UInt32, UInt64, UInt32)
) -> Bool {
  guard let observed, observed.1 != 0 else { return false }
  return observed == expected
}

@Test func legacyPinnedMappingIdentityFixtureAcceptsExactZeroGeneration() {
  let expected: (UInt32, UInt64, UInt32) = (16_777_232, 86_453, 0)

  #expect(legacyMappingIdentityFixtureMatches(expected, expected: expected))
}

@Test func legacyPinnedMappingIdentityFixtureRejectsTupleMismatchesAndMissingIdentity() {
  let expected: (UInt32, UInt64, UInt32) = (16_777_232, 86_453, 0)

  #expect(!legacyMappingIdentityFixtureMatches((16_777_233, 86_453, 0), expected: expected))
  #expect(!legacyMappingIdentityFixtureMatches((16_777_232, 86_454, 0), expected: expected))
  #expect(!legacyMappingIdentityFixtureMatches((16_777_232, 86_453, 1), expected: expected))
  let nonzeroGeneration: (UInt32, UInt64, UInt32) = (16_777_232, 86_453, 1)
  #expect(
    !legacyMappingIdentityFixtureMatches((16_777_232, 86_453, 0), expected: nonzeroGeneration))
  #expect(!legacyMappingIdentityFixtureMatches((16_777_232, 0, 0), expected: expected))
  #expect(!legacyMappingIdentityFixtureMatches(nil, expected: expected))
}

@Test func legacyMappingProductionPredicateAllowsExactZeroAndKeepsEnumerationFailClosed() throws {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let source = try String(
    contentsOf: packageRoot.appendingPathComponent("Sources/SBMHelper/Legacy1115Retirement.swift"),
    encoding: .utf8
  )
  let start = try #require(source.range(of: "private static func mappedPathIdentity("))
  let end = try #require(source.range(of: "private static func openProtectedParent()"))
  let mappingIdentity = source[start.lowerBound..<end.lowerBound]

  #expect(mappingIdentity.contains("if stat.vst_ino != 0,"))
  #expect(mappingIdentity.contains("(stat.vst_dev, stat.vst_ino, stat.vst_gen) == expected"))
  #expect(!mappingIdentity.contains("stat.vst_gen != 0"))
  #expect(mappingIdentity.contains("for _ in 0..<maximumRegions"))
  #expect(mappingIdentity.contains("if result == 0 { return false }"))
  #expect(mappingIdentity.contains("result == MemoryLayout<proc_regionwithpathinfo>.size"))
  #expect(mappingIdentity.contains("Unable to inspect a legacy executable mapping."))
  #expect(mappingIdentity.contains("Legacy executable mapping enumeration did not advance."))
  #expect(mappingIdentity.contains("Legacy executable mapping enumeration exceeded its bound."))
}

@Test(arguments: [
  #"{"desiredRunning":true,"desiredRunning":false}"#,
  #"{"desiredRunning":true,"des\u0069redRunning":false}"#,
  #"{"desiredRunning":1}"#,
  #"{"nested":{"desiredRunning":true}}"#,
  #"{"desiredRunning":true,"broken":}"#,
])
func legacyOFFByteEditRejectsDuplicateMalformedOrNonBooleanState(_ json: String) {
  #expect(throws: (any Error).self) {
    try Legacy1115Retirement.stateBySettingDesiredOff(Data(json.utf8))
  }
}

@Test(arguments: ["[]", "null", "true", #""not an object""#])
func legacyOFFByteEditRejectsNonObjectRoot(_ json: String) {
  #expect(throws: (any Error).self) {
    try Legacy1115Retirement.stateBySettingDesiredOff(Data(json.utf8))
  }
}

@Test(arguments: [
  #"{"desiredRunning":true,"legacy1115RetirementComplete":"false"}"#,
  #"{"desiredRunning":true,"legacy1115RetirementComplete":0}"#,
])
func legacyOFFByteEditRejectsNonBooleanCompletion(_ json: String) {
  #expect(throws: (any Error).self) {
    try Legacy1115Retirement.stateBySettingDesiredOff(Data(json.utf8))
  }
}

@Test func legacyOFFByteEditRejectsInputAboveItsSizeBound() {
  let maximumStateBytes = 4 * 1_024 * 1_024
  var input = Data(#"{"desiredRunning":true}"#.utf8)
  input.append(Data(repeating: 0x20, count: maximumStateBytes + 1 - input.count))

  #expect(throws: (any Error).self) {
    try Legacy1115Retirement.stateBySettingDesiredOff(input)
  }
}

private func startRetirementTestChild(_ arguments: [String] = ["30"]) throws -> Process {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sleep")
  process.arguments = arguments
  try process.run()
  return process
}

private func waitForRetirementTestChild(_ process: Process, timeout: TimeInterval = 5) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while process.isRunning, Date() < deadline {
    usleep(10_000)
  }
  guard !process.isRunning else { return false }
  process.waitUntilExit()
  return true
}

private func terminateRetirementTestChild(_ process: Process) {
  if process.isRunning {
    process.terminate()
    _ = waitForRetirementTestChild(process, timeout: 1)
  }
}

@Test(.disabled(if: geteuid() != 0, "task_name_for_pid requires the helper's root test context"))
func auditTokenTERMTargetsOnlyTheTestOwnedChild() throws {
  let target = try startRetirementTestChild()
  let peer = try startRetirementTestChild()
  defer {
    terminateRetirementTestChild(target)
    terminateRetirementTestChild(peer)
  }
  let targetPID = target.processIdentifier
  let token = try Legacy1115Retirement.auditToken(for: targetPID)

  try Legacy1115Retirement.sendSignal(to: token, signal: SIGTERM)

  #expect(waitForRetirementTestChild(target))
  #expect(peer.isRunning)
}

@Test(.disabled(if: geteuid() != 0, "task_name_for_pid requires the helper's root test context"))
func auditTokenKILLTargetsOnlyTheTestOwnedChild() throws {
  let target = try startRetirementTestChild()
  let peer = try startRetirementTestChild()
  defer {
    terminateRetirementTestChild(target)
    terminateRetirementTestChild(peer)
  }
  let token = try Legacy1115Retirement.auditToken(for: target.processIdentifier)

  try Legacy1115Retirement.sendSignal(to: token, signal: SIGKILL)

  #expect(waitForRetirementTestChild(target))
  #expect(peer.isRunning)
}

@Test(.disabled(if: geteuid() != 0, "task_name_for_pid requires the helper's root test context"))
func staleAuditTokenCannotSignalAReplacementTestChild() throws {
  let original = try startRetirementTestChild()
  let staleToken = try Legacy1115Retirement.auditToken(for: original.processIdentifier)
  defer { terminateRetirementTestChild(original) }
  try Legacy1115Retirement.sendSignal(to: staleToken, signal: SIGTERM)
  #expect(waitForRetirementTestChild(original))

  let replacement = try startRetirementTestChild()
  defer { terminateRetirementTestChild(replacement) }
  #expect(throws: CoreFailure.self) {
    try Legacy1115Retirement.sendSignal(to: staleToken, signal: SIGTERM)
  }
  #expect(replacement.isRunning)
}

@Test func invalidAuditTokenFailsWithoutCollateralSignal() throws {
  let peer = try startRetirementTestChild()
  defer { terminateRetirementTestChild(peer) }

  #expect(throws: CoreFailure.self) {
    try Legacy1115Retirement.sendSignal(to: audit_token_t(), signal: SIGTERM)
  }
  #expect(peer.isRunning)
}
