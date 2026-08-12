#!/usr/bin/env swift
import Darwin
import Foundation

private enum BaselineError: LocalizedError {
  case help
  case usage(String)
  case sampling(String)

  var errorDescription: String? {
    switch self {
    case .help:
      Options.help
    case .usage(let message):
      "performance baseline: \(message)"
    case .sampling(let message):
      "performance baseline: \(message)"
    }
  }
}

private struct Target: Codable, Hashable {
  let label: String
  let pid: Int32
}

private struct Options {
  static let maximumTargets = 3
  static let maximumDurationSeconds = 3_600
  static let maximumIntervalSeconds = 60

  let durationSeconds: Int
  let intervalSeconds: Int
  let targets: [Target]

  init(arguments: [String]) throws {
    var durationSeconds: Int?
    var intervalSeconds: Int?
    var targets: [Target] = []
    var labels = Set<String>()
    var pids = Set<Int32>()
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--duration":
        index += 1
        guard index < arguments.count, durationSeconds == nil,
          let value = Int(arguments[index])
        else {
          throw BaselineError.usage("--duration requires one integer value.")
        }
        durationSeconds = value
      case "--interval":
        index += 1
        guard index < arguments.count, intervalSeconds == nil,
          let value = Int(arguments[index])
        else {
          throw BaselineError.usage("--interval requires one integer value.")
        }
        intervalSeconds = value
      case "--target":
        index += 1
        guard index < arguments.count else {
          throw BaselineError.usage("--target requires LABEL=PID.")
        }
        let target = try Self.parseTarget(arguments[index])
        guard labels.insert(target.label).inserted else {
          throw BaselineError.usage("target label \(target.label) was supplied more than once.")
        }
        guard pids.insert(target.pid).inserted else {
          throw BaselineError.usage("PID \(target.pid) was supplied more than once.")
        }
        targets.append(target)
      case "--help", "-h":
        throw BaselineError.help
      default:
        throw BaselineError.usage("unknown argument: \(argument)")
      }
      index += 1
    }

    guard let durationSeconds else {
      throw BaselineError.usage("--duration is required.")
    }
    guard let intervalSeconds else {
      throw BaselineError.usage("--interval is required.")
    }
    guard !targets.isEmpty else {
      throw BaselineError.usage("supply at least one --target LABEL=PID.")
    }
    guard targets.count <= Self.maximumTargets else {
      throw BaselineError.usage("at most \(Self.maximumTargets) targets may be sampled.")
    }
    guard (1...Self.maximumDurationSeconds).contains(durationSeconds) else {
      throw BaselineError.usage(
        "--duration must be between 1 and \(Self.maximumDurationSeconds) seconds.")
    }
    guard (1...Self.maximumIntervalSeconds).contains(intervalSeconds) else {
      throw BaselineError.usage(
        "--interval must be between 1 and \(Self.maximumIntervalSeconds) seconds.")
    }
    guard intervalSeconds <= durationSeconds else {
      throw BaselineError.usage("--interval must not exceed --duration.")
    }

    self.durationSeconds = durationSeconds
    self.intervalSeconds = intervalSeconds
    self.targets = targets
  }

  private static func parseTarget(_ value: String) throws -> Target {
    let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else {
      throw BaselineError.usage("--target must use LABEL=PID, not \(value).")
    }
    let label = String(parts[0])
    guard matches(label, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#) else {
      throw BaselineError.usage(
        "target label \(label) must be 1...64 ASCII letters, digits, dot, underscore, or hyphen.")
    }
    guard let pid = Int32(parts[1]), pid > 0 else {
      throw BaselineError.usage("target PID for \(label) must be a positive 32-bit integer.")
    }
    return Target(label: label, pid: pid)
  }

  static let help = """
    Usage: performance-baseline.swift --duration SECONDS --interval SECONDS --target LABEL=PID [--target LABEL=PID ...]

    Samples caller-supplied PIDs with public macOS proc_pid_rusage APIs and writes JSONL to stdout.
    Limits: 1...3 targets, duration 1...3600 seconds, interval 1...60 seconds, interval <= duration.
    Labels use 1...64 ASCII letters, digits, dot, underscore, or hyphen. The script never discovers processes.
    """
}

private struct RunHeader: Codable {
  let type = "header"
  let schemaVersion = 1
  let startedAt: String
  let durationSeconds: Int
  let intervalSeconds: Int
  let targets: [Target]
  let metrics: [String]

  enum CodingKeys: String, CodingKey {
    case type
    case schemaVersion = "schema_version"
    case startedAt = "started_at"
    case durationSeconds = "duration_seconds"
    case intervalSeconds = "interval_seconds"
    case targets
    case metrics
  }
}

private struct Sample: Codable {
  let type = "sample"
  let timestamp: String
  let elapsedSeconds: Int
  let label: String
  let pid: Int32
  let processUUID: String
  let processStartAbstime: UInt64
  let residentMemoryBytes: UInt64
  let cpuUserNanoseconds: UInt64
  let cpuSystemNanoseconds: UInt64
  let cpuTotalNanoseconds: UInt64
  let packageIdleWakeups: UInt64
  let interruptWakeups: UInt64

  enum CodingKeys: String, CodingKey {
    case type
    case timestamp
    case elapsedSeconds = "elapsed_seconds"
    case label
    case pid
    case processUUID = "process_uuid"
    case processStartAbstime = "process_start_abstime"
    case residentMemoryBytes = "resident_memory_bytes"
    case cpuUserNanoseconds = "cpu_user_nanoseconds"
    case cpuSystemNanoseconds = "cpu_system_nanoseconds"
    case cpuTotalNanoseconds = "cpu_total_nanoseconds"
    case packageIdleWakeups = "package_idle_wakeups"
    case interruptWakeups = "interrupt_wakeups"
  }
}

private struct ProcessIdentity: Equatable {
  let uuid: String
  let startAbstime: UInt64
}

private let encoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return encoder
}()

private let timestampFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  return formatter
}()

private func matches(_ value: String, pattern: String) -> Bool {
  value.range(of: pattern, options: .regularExpression) != nil
}

private func writeJSONLine<T: Encodable>(_ value: T) throws {
  let data = try encoder.encode(value)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([0x0A]))
}

private func sample(target: Target, elapsedSeconds: Int) throws -> (Sample, ProcessIdentity) {
  var usage = rusage_info_v2()
  errno = 0
  let result = withUnsafeMutablePointer(to: &usage) { pointer in
    let buffer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
    return proc_pid_rusage(target.pid, RUSAGE_INFO_V2, buffer)
  }
  guard result == 0 else {
    let reason: String
    switch errno {
    case ESRCH:
      reason = "PID exited or does not exist"
    case EPERM, EACCES:
      reason = "metric access is unavailable to this user"
    default:
      reason = String(cString: strerror(errno))
    }
    throw BaselineError.sampling("cannot sample \(target.label)=\(target.pid): \(reason).")
  }
  guard usage.ri_proc_exit_abstime == 0 else {
    throw BaselineError.sampling("cannot sample \(target.label)=\(target.pid): process has exited.")
  }

  let processUUID = withUnsafeBytes(of: usage.ri_uuid) { bytes in
    bytes.map { String(format: "%02x", $0) }.joined()
  }
  let identity = ProcessIdentity(uuid: processUUID, startAbstime: usage.ri_proc_start_abstime)
  let user = usage.ri_user_time
  let system = usage.ri_system_time
  guard UInt64.max - user >= system else {
    throw BaselineError.sampling("CPU counters overflowed for \(target.label)=\(target.pid).")
  }
  return (
    Sample(
      timestamp: timestampFormatter.string(from: Date()),
      elapsedSeconds: elapsedSeconds,
      label: target.label,
      pid: target.pid,
      processUUID: processUUID,
      processStartAbstime: usage.ri_proc_start_abstime,
      residentMemoryBytes: usage.ri_resident_size,
      cpuUserNanoseconds: user,
      cpuSystemNanoseconds: system,
      cpuTotalNanoseconds: user + system,
      packageIdleWakeups: usage.ri_pkg_idle_wkups,
      interruptWakeups: usage.ri_interrupt_wkups
    ),
    identity
  )
}

private func run(options: Options) throws {
  let startedAt = Date()
  var identities = [Target: ProcessIdentity]()
  var initialSamples = [Sample]()
  for target in options.targets {
    let (reading, identity) = try sample(target: target, elapsedSeconds: 0)
    identities[target] = identity
    initialSamples.append(reading)
  }

  try writeJSONLine(
    RunHeader(
      startedAt: timestampFormatter.string(from: startedAt),
      durationSeconds: options.durationSeconds,
      intervalSeconds: options.intervalSeconds,
      targets: options.targets,
      metrics: [
        "resident_memory_bytes",
        "cpu_user_nanoseconds",
        "cpu_system_nanoseconds",
        "cpu_total_nanoseconds",
        "package_idle_wakeups",
        "interrupt_wakeups",
      ]
    ))
  for reading in initialSamples {
    try writeJSONLine(reading)
  }

  var elapsedSeconds = options.intervalSeconds
  while elapsedSeconds <= options.durationSeconds {
    let deadline = startedAt.addingTimeInterval(TimeInterval(elapsedSeconds))
    let remaining = deadline.timeIntervalSinceNow
    if remaining > 0 {
      Thread.sleep(forTimeInterval: remaining)
    }
    for target in options.targets {
      let (reading, identity) = try sample(target: target, elapsedSeconds: elapsedSeconds)
      guard identity == identities[target] else {
        throw BaselineError.sampling(
          "PID \(target.pid) was reused while sampling label \(target.label); discard this run.")
      }
      try writeJSONLine(reading)
    }
    elapsedSeconds += options.intervalSeconds
  }
}

do {
  let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
  try run(options: options)
} catch let error as BaselineError {
  let text = error.errorDescription ?? "performance baseline failed."
  FileHandle.standardError.write(Data((text + "\n").utf8))
  if case .help = error {
    exit(0)
  }
  exit(2)
} catch {
  FileHandle.standardError.write(Data(("performance baseline: \(error)\n").utf8))
  exit(2)
}
