import Darwin
import Foundation
import SBMShared
import Testing

// Default test responses represent a current helper after retirement. Tests
// that model an inert or legacy response use the production initializer and
// pass its optional receipt explicitly.
extension HelperResponse {
  init(
    success: Bool,
    coreRunning: Bool,
    coreVersion: String? = nil,
    mode: RoutingMode = .rule,
    selectedNode: ProxyNodeID = .auto,
    effectiveAutoNode: ProxyNodeID? = nil,
    activeProfileID: UUID? = nil,
    activeIPv6Enabled: Bool? = nil,
    nodes: [ProxyNodeDescriptor] = [],
    delays: [NodeDelay] = [],
    automaticRecoveryExhausted: Bool = false,
    runtimeOutcome: HelperRuntimeOutcome = .applied,
    message: String
  ) {
    self.init(
      success: success,
      coreRunning: coreRunning,
      coreVersion: coreVersion,
      mode: mode,
      selectedNode: selectedNode,
      effectiveAutoNode: effectiveAutoNode,
      activeProfileID: activeProfileID,
      activeIPv6Enabled: activeIPv6Enabled,
      nodes: nodes,
      delays: delays,
      automaticRecoveryExhausted: automaticRecoveryExhausted,
      runtimeOutcome: runtimeOutcome,
      legacy1115Retired: true,
      message: message
    )
  }
}

enum TestProcessFailure: Error {
  case timedOut
}

struct TestProcessResult {
  let status: Int32
  let output: String
}

enum TestProcessSupport {
  static func run(
    executableURL: URL,
    arguments: [String],
    timeoutSeconds: TimeInterval = 10,
    currentDirectoryURL: URL? = nil,
    environment: [String: String]? = nil
  ) throws -> TestProcessResult {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("SBMTestProcess-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    try process.run()

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning, Date() < deadline {
      usleep(10_000)
    }
    if process.isRunning {
      process.terminate()
      let terminationDeadline = Date().addingTimeInterval(0.25)
      while process.isRunning, Date() < terminationDeadline {
        usleep(10_000)
      }
      if process.isRunning {
        _ = kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(0.25)
        while process.isRunning, Date() < killDeadline {
          usleep(10_000)
        }
      }
      guard !process.isRunning else { throw TestProcessFailure.timedOut }
      throw TestProcessFailure.timedOut
    }

    process.waitUntilExit()
    try output.synchronize()
    return TestProcessResult(
      status: process.terminationStatus,
      output: String(
        data: try Data(contentsOf: outputURL),
        encoding: .utf8
      ) ?? ""
    )
  }
}

@Test func boundedTestProcessHelperFailsOnTimeout() {
  #expect(throws: TestProcessFailure.self) {
    try TestProcessSupport.run(
      executableURL: URL(fileURLWithPath: "/bin/sleep"),
      arguments: ["2"],
      timeoutSeconds: 0.02
    )
  }
}
