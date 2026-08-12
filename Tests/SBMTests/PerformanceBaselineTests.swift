import Darwin
import Foundation
import Testing

@Suite(.serialized) struct PerformanceBaselineTests {
  @Test func performanceBaselineWritesVersionedJSONLForCurrentTestProcess() throws {
    let result = try PerformanceBaselineFixture.run(
      [
        "--duration", "1", "--interval", "1",
        "--target", "test=\(getpid())",
      ])

    #expect(result.status == 0)
    let lines = result.output.split(separator: "\n")
    #expect(lines.count == 3)
    let header = try #require(jsonObject(lines[0]))
    #expect(header["type"] as? String == "header")
    #expect(header["schema_version"] as? Int == 1)
    let initial = try #require(jsonObject(lines[1]))
    let final = try #require(jsonObject(lines[2]))
    #expect(initial["type"] as? String == "sample")
    #expect(initial["elapsed_seconds"] as? Int == 0)
    #expect(final["elapsed_seconds"] as? Int == 1)
    #expect(initial["pid"] as? Int == Int(getpid()))
    #expect(initial["label"] as? String == "test")
    #expect(initial["resident_memory_bytes"] is NSNumber)
    #expect(initial["cpu_total_nanoseconds"] is NSNumber)
    #expect(initial["package_idle_wakeups"] is NSNumber)
    #expect(initial["interrupt_wakeups"] is NSNumber)
  }

  @Test func performanceBaselineRejectsInvalidBoundsAndDuplicateLabels() throws {
    let zeroInterval = try PerformanceBaselineFixture.run(
      ["--duration", "1", "--interval", "0", "--target", "test=1"])
    #expect(zeroInterval.status != 0)
    #expect(zeroInterval.output.contains("--interval must be between 1 and 60 seconds"))

    let duplicateLabel = try PerformanceBaselineFixture.run(
      [
        "--duration", "1", "--interval", "1",
        "--target", "app=1", "--target", "app=2",
      ])
    #expect(duplicateLabel.status != 0)
    #expect(duplicateLabel.output.contains("target label app was supplied more than once"))
  }

  @Test func performanceBaselineHelpDoesNotRequireAPID() throws {
    let result = try PerformanceBaselineFixture.run(["--help"])

    #expect(result.status == 0)
    #expect(result.output.contains("Usage: performance-baseline.swift"))
    #expect(result.output.contains("The script never discovers processes."))
  }
}

private enum PerformanceBaselineFixture {
  static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments =
      [
        FileManager.default.currentDirectoryPath + "/scripts/performance-baseline.swift"
      ] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
  }
}

private func jsonObject(_ line: Substring) -> [String: Any]? {
  guard let data = line.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data),
    let dictionary = object as? [String: Any]
  else {
    return nil
  }
  return dictionary
}
