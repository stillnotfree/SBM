import Foundation
import Testing

@testable import SBMHelper

@Test func ruleSetCacheReaderExtractsExactSavedContentAndFailsClosed() throws {
  let expected = Data(#"{"version":4,"rules":[{"domain_suffix":[".ru"]}]}"#.utf8)
  let database = makeRuleSetCacheFixture(tag: "geosite-ru", content: expected)
  #expect(try RuleSetCacheReader.content(in: database, tag: "geosite-ru") == expected)
  #expect(throws: RuleSetCacheFailure.self) {
    try RuleSetCacheReader.content(in: database, tag: "missing")
  }

  var corrupted = database
  corrupted[16] = 0
  corrupted[4096 + 16] = 0
  #expect(throws: RuleSetCacheFailure.self) {
    try RuleSetCacheReader.content(in: corrupted, tag: "geosite-ru")
  }
}

@Test func exactBundledCoreMatchesExtractedRuleSetContent() throws {
  let content = Data(#"{"version":4,"rules":[{"domain_suffix":[".ru"]}]}"#.utf8)
  let extracted = try RuleSetCacheReader.content(
    in: makeRuleSetCacheFixture(tag: "geosite-ru", content: content),
    tag: "geosite-ru"
  )
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMRuleSetMatch-\(UUID().uuidString).json")
  try extracted.write(to: temporary)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".vendor/sing-box")

  func output(for destination: String) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = core
    process.arguments = ["rule-set", "match", "-f", "source", temporary.path, destination]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(
      data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }

  #expect(try !output(for: "gosuslugi.ru").isEmpty)
  #expect(try output(for: "google.com").isEmpty)
}

@Test func ruleSetCacheReaderTraversesExternalBranchBucket() throws {
  let expected = Data(#"{"version":4,"rules":[{"domain_suffix":[".ru"]}]}"#.utf8)
  let database = makeExternalRuleSetCacheFixture(tag: "geosite-ru", content: expected)
  #expect(try RuleSetCacheReader.content(in: database, tag: "geosite-ru") == expected)
}

private func makeRuleSetCacheFixture(tag: String, content: Data) -> Data {
  let pageSize = 4096
  var data = Data(repeating: 0, count: pageSize * 4)
  let saved =
    Data([1]) + encodedVarint(UInt64(content.count)) + content + Data(repeating: 0, count: 9)

  for (page, transaction) in [(0, UInt64(1)), (1, UInt64(2))] {
    let offset = page * pageSize
    put(UInt64(page), in: &data, at: offset)
    put(UInt16(0x04), in: &data, at: offset + 8)
    put(UInt32(0xED0C_DAED), in: &data, at: offset + 16)
    put(UInt32(2), in: &data, at: offset + 20)
    put(UInt32(pageSize), in: &data, at: offset + 24)
    put(UInt64(3), in: &data, at: offset + 32)
    put(UInt64(4), in: &data, at: offset + 56)
    put(transaction, in: &data, at: offset + 64)
    let checksum = fnv1a64(data[(offset + 16)..<(offset + 72)])
    put(checksum, in: &data, at: offset + 72)
  }

  let root = pageSize * 3
  put(UInt64(3), in: &data, at: root)
  put(UInt16(0x02), in: &data, at: root + 8)
  put(UInt16(1), in: &data, at: root + 10)
  let rootElement = root + 16
  put(UInt32(1), in: &data, at: rootElement)
  put(UInt32(16), in: &data, at: rootElement + 4)
  put(UInt32(8), in: &data, at: rootElement + 8)

  var bucket = Data(repeating: 0, count: 16 + 16 + 16)
  put(UInt16(0x02), in: &bucket, at: 16 + 8)
  put(UInt16(1), in: &bucket, at: 16 + 10)
  let inlineElement = 32
  put(UInt32(0), in: &bucket, at: inlineElement)
  put(UInt32(16), in: &bucket, at: inlineElement + 4)
  put(UInt32(tag.utf8.count), in: &bucket, at: inlineElement + 8)
  put(UInt32(saved.count), in: &bucket, at: inlineElement + 12)
  bucket.append(Data(tag.utf8))
  bucket.append(saved)

  put(UInt32(bucket.count), in: &data, at: rootElement + 12)
  data.replaceSubrange((rootElement + 16)..<(rootElement + 24), with: Data("rule_set".utf8))
  let bucketOffset = rootElement + 24
  data.replaceSubrange(bucketOffset..<(bucketOffset + bucket.count), with: bucket)
  return data
}

private func makeExternalRuleSetCacheFixture(tag: String, content: Data) -> Data {
  let pageSize = 4096
  var data = Data(repeating: 0, count: pageSize * 6)
  let saved =
    Data([1]) + encodedVarint(UInt64(content.count)) + content + Data(repeating: 0, count: 9)

  for (page, transaction) in [(0, UInt64(1)), (1, UInt64(2))] {
    let offset = page * pageSize
    put(UInt64(page), in: &data, at: offset)
    put(UInt16(0x04), in: &data, at: offset + 8)
    put(UInt32(0xED0C_DAED), in: &data, at: offset + 16)
    put(UInt32(2), in: &data, at: offset + 20)
    put(UInt32(pageSize), in: &data, at: offset + 24)
    put(UInt64(3), in: &data, at: offset + 32)
    put(UInt64(6), in: &data, at: offset + 56)
    put(transaction, in: &data, at: offset + 64)
    let checksum = fnv1a64(data[(offset + 16)..<(offset + 72)])
    put(checksum, in: &data, at: offset + 72)
  }

  let root = pageSize * 3
  put(UInt64(3), in: &data, at: root)
  put(UInt16(0x02), in: &data, at: root + 8)
  put(UInt16(1), in: &data, at: root + 10)
  let rootElement = root + 16
  put(UInt32(1), in: &data, at: rootElement)
  put(UInt32(16), in: &data, at: rootElement + 4)
  put(UInt32(8), in: &data, at: rootElement + 8)
  put(UInt32(16), in: &data, at: rootElement + 12)
  data.replaceSubrange((rootElement + 16)..<(rootElement + 24), with: Data("rule_set".utf8))
  put(UInt64(4), in: &data, at: rootElement + 24)

  let branch = pageSize * 4
  put(UInt64(4), in: &data, at: branch)
  put(UInt16(0x01), in: &data, at: branch + 8)
  put(UInt16(1), in: &data, at: branch + 10)
  let branchElement = branch + 16
  put(UInt32(16), in: &data, at: branchElement)
  put(UInt32(tag.utf8.count), in: &data, at: branchElement + 4)
  put(UInt64(5), in: &data, at: branchElement + 8)
  data.replaceSubrange(
    (branchElement + 16)..<(branchElement + 16 + tag.utf8.count), with: Data(tag.utf8))

  let leaf = pageSize * 5
  put(UInt64(5), in: &data, at: leaf)
  put(UInt16(0x02), in: &data, at: leaf + 8)
  put(UInt16(1), in: &data, at: leaf + 10)
  let leafElement = leaf + 16
  put(UInt32(0), in: &data, at: leafElement)
  put(UInt32(16), in: &data, at: leafElement + 4)
  put(UInt32(tag.utf8.count), in: &data, at: leafElement + 8)
  put(UInt32(saved.count), in: &data, at: leafElement + 12)
  let leafKey = leafElement + 16
  data.replaceSubrange(leafKey..<(leafKey + tag.utf8.count), with: Data(tag.utf8))
  data.replaceSubrange(
    (leafKey + tag.utf8.count)..<(leafKey + tag.utf8.count + saved.count), with: saved)
  return data
}

private func encodedVarint(_ value: UInt64) -> Data {
  var value = value
  var bytes: [UInt8] = []
  repeat {
    var byte = UInt8(value & 0x7f)
    value >>= 7
    if value != 0 { byte |= 0x80 }
    bytes.append(byte)
  } while value != 0
  return Data(bytes)
}

private func put<T: FixedWidthInteger>(_ value: T, in data: inout Data, at offset: Int) {
  var littleEndian = value.littleEndian
  withUnsafeBytes(of: &littleEndian) { bytes in
    data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
  }
}

private func fnv1a64(_ data: Data.SubSequence) -> UInt64 {
  data.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
}
