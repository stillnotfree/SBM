import Foundation

enum RuleSetCacheFailure: Error {
  case invalidDatabase
  case missingRuleSet
  case invalidSavedValue
}

/// A bounded, read-only reader for the two bbolt keys used by sing-box's
/// cache file: the `rule_set` bucket and one requested tag. It does not parse
/// rule-set semantics; the exact bundled sing-box binary does that.
struct RuleSetCacheReader {
  private static let maximumCacheBytes = 64 * 1_024 * 1_024
  private static let maximumRuleSetBytes = 16 * 1_024 * 1_024
  private static let pageHeaderSize = 16
  private static let bucketHeaderSize = 16

  static func content(at url: URL, tag: String) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber,
      size.intValue >= 4 * 4096,
      size.intValue <= maximumCacheBytes
    else { throw RuleSetCacheFailure.invalidDatabase }
    let snapshot = try Data(contentsOf: url)
    guard snapshot.count <= maximumCacheBytes else {
      throw RuleSetCacheFailure.invalidDatabase
    }
    let pageSize = try validatedPageSize(snapshot)
    let snapshotMeta = try selectedMetadata(in: snapshot, pageSize: pageSize)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let currentHeader = try handle.read(upToCount: pageSize * 2) ?? Data()
    guard try selectedMetadata(in: currentHeader, pageSize: pageSize) == snapshotMeta else {
      throw RuleSetCacheFailure.invalidDatabase
    }
    return try content(in: snapshot, tag: tag)
  }

  static func content(in data: Data, tag: String) throws -> Data {
    guard !tag.isEmpty, tag.utf8.count <= 128 else {
      throw RuleSetCacheFailure.missingRuleSet
    }
    let pageSize = try validatedPageSize(data)
    let meta = try selectedMetadata(in: data, pageSize: pageSize)
    let bucketEntry = try lookup(
      key: Data("rule_set".utf8), rootPage: meta.rootPage, data: data, pageSize: pageSize)
    guard bucketEntry.flags & 1 == 1, bucketEntry.value.count >= bucketHeaderSize else {
      throw RuleSetCacheFailure.missingRuleSet
    }
    let bucketRoot = try unsigned64(bucketEntry.value, at: 0)
    let saved: Entry
    if bucketRoot == 0 {
      saved = try lookup(
        key: Data(tag.utf8), inlinePage: bucketEntry.value.dropFirst(bucketHeaderSize))
    } else {
      saved = try lookup(
        key: Data(tag.utf8), rootPage: bucketRoot, data: data, pageSize: pageSize)
    }
    guard saved.flags & 1 == 0 else { throw RuleSetCacheFailure.missingRuleSet }
    return try savedContent(saved.value)
  }

  private struct Metadata: Equatable {
    let rootPage: UInt64
    let transactionID: UInt64
  }

  private static func selectedMetadata(in data: Data, pageSize: Int) throws -> Metadata {
    let metas = [0, pageSize].compactMap { try? metadata(in: data, at: $0, pageSize: pageSize) }
    guard let selected = metas.max(by: { $0.transactionID < $1.transactionID }) else {
      throw RuleSetCacheFailure.invalidDatabase
    }
    return selected
  }

  private struct Entry {
    let flags: UInt32
    let value: Data
  }

  private static func validatedPageSize(_ data: Data) throws -> Int {
    let pageSize = Int(try unsigned32(data, at: pageHeaderSize + 8))
    guard pageSize >= 4096, pageSize <= 65536, pageSize.nonzeroBitCount == 1,
      data.count >= pageSize * 2
    else { throw RuleSetCacheFailure.invalidDatabase }
    return pageSize
  }

  private static func metadata(in data: Data, at pageOffset: Int, pageSize: Int) throws
    -> Metadata
  {
    guard try unsigned64(data, at: pageOffset) <= 1,
      try unsigned16(data, at: pageOffset + 8) == 0x04,
      try unsigned32(data, at: pageOffset + pageHeaderSize) == 0xED0C_DAED,
      try unsigned32(data, at: pageOffset + pageHeaderSize + 4) == 2,
      try unsigned32(data, at: pageOffset + pageHeaderSize + 8) == UInt32(pageSize)
    else { throw RuleSetCacheFailure.invalidDatabase }
    let checksumOffset = pageOffset + pageHeaderSize + 56
    let expected = try unsigned64(data, at: checksumOffset)
    let checksumBytes = data[(pageOffset + pageHeaderSize)..<checksumOffset]
    guard fnv1a64(checksumBytes) == expected else {
      throw RuleSetCacheFailure.invalidDatabase
    }
    let rootPage = try unsigned64(data, at: pageOffset + pageHeaderSize + 16)
    let highWaterMark = try unsigned64(data, at: pageOffset + pageHeaderSize + 40)
    guard rootPage > 1, rootPage < highWaterMark,
      rootPage <= UInt64(data.count / pageSize)
    else { throw RuleSetCacheFailure.invalidDatabase }
    return Metadata(
      rootPage: rootPage,
      transactionID: try unsigned64(data, at: pageOffset + pageHeaderSize + 48)
    )
  }

  private static func lookup(key: Data, rootPage: UInt64, data: Data, pageSize: Int) throws
    -> Entry
  {
    var pageID = rootPage
    var visited = Set<UInt64>()
    while visited.insert(pageID).inserted {
      let offset = try pageOffset(pageID, pageSize: pageSize, dataCount: data.count)
      let flags = try unsigned16(data, at: offset + 8)
      let count = Int(try unsigned16(data, at: offset + 10))
      if flags == 0x02 {
        return try leafLookup(key: key, page: data[offset...], count: count)
      }
      guard flags == 0x01, count > 0 else { throw RuleSetCacheFailure.invalidDatabase }
      var selected: UInt64?
      for index in 0..<count {
        let element = offset + pageHeaderSize + index * 16
        let position = Int(try unsigned32(data, at: element))
        let keySize = Int(try unsigned32(data, at: element + 4))
        let branchKey = try slice(data, at: element + position, count: keySize)
        if branchKey.lexicographicallyPrecedes(key) || branchKey == key {
          selected = try unsigned64(data, at: element + 8)
        } else {
          break
        }
      }
      if let selected {
        pageID = selected
      } else {
        pageID = try unsigned64(data, at: offset + pageHeaderSize + 8)
      }
    }
    throw RuleSetCacheFailure.invalidDatabase
  }

  private static func lookup(key: Data, inlinePage: Data.SubSequence) throws -> Entry {
    let page = Data(inlinePage)
    guard try unsigned16(page, at: 8) == 0x02 else {
      throw RuleSetCacheFailure.invalidDatabase
    }
    return try leafLookup(key: key, page: page[...], count: Int(try unsigned16(page, at: 10)))
  }

  private static func leafLookup(key: Data, page: Data.SubSequence, count: Int) throws -> Entry {
    let page = Data(page)
    guard count >= 0, count <= 65535,
      page.count >= pageHeaderSize + count * 16
    else { throw RuleSetCacheFailure.invalidDatabase }
    for index in 0..<count {
      let element = pageHeaderSize + index * 16
      let flags = try unsigned32(page, at: element)
      let position = Int(try unsigned32(page, at: element + 4))
      let keySize = Int(try unsigned32(page, at: element + 8))
      let valueSize = Int(try unsigned32(page, at: element + 12))
      let storedKey = try slice(page, at: element + position, count: keySize)
      if storedKey == key {
        return Entry(
          flags: flags,
          value: try slice(page, at: element + position + keySize, count: valueSize)
        )
      }
      if key.lexicographicallyPrecedes(storedKey) { break }
    }
    throw RuleSetCacheFailure.missingRuleSet
  }

  private static func savedContent(_ data: Data) throws -> Data {
    guard data.first == 1 else { throw RuleSetCacheFailure.invalidSavedValue }
    var offset = 1
    let length = try readVarint(data, offset: &offset)
    guard length <= maximumRuleSetBytes else { throw RuleSetCacheFailure.invalidSavedValue }
    return try slice(data, at: offset, count: Int(length))
  }

  private static func readVarint(_ data: Data, offset: inout Int) throws -> UInt64 {
    var value: UInt64 = 0
    for shift in stride(from: 0, through: 63, by: 7) {
      guard offset < data.count else { throw RuleSetCacheFailure.invalidSavedValue }
      let byte = data[offset]
      offset += 1
      if byte < 0x80 { return value | UInt64(byte) << shift }
      value |= UInt64(byte & 0x7f) << shift
    }
    throw RuleSetCacheFailure.invalidSavedValue
  }

  private static func pageOffset(_ page: UInt64, pageSize: Int, dataCount: Int) throws -> Int {
    let (offset, overflow) = page.multipliedReportingOverflow(by: UInt64(pageSize))
    guard !overflow, offset <= UInt64(Int.max), Int(offset) + pageHeaderSize <= dataCount else {
      throw RuleSetCacheFailure.invalidDatabase
    }
    return Int(offset)
  }

  private static func slice(_ data: Data, at offset: Int, count: Int) throws -> Data {
    guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
      throw RuleSetCacheFailure.invalidDatabase
    }
    return data.subdata(in: offset..<(offset + count))
  }

  private static func unsigned16(_ data: Data, at offset: Int) throws -> UInt16 {
    let bytes = try slice(data, at: offset, count: 2)
    return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
  }

  private static func unsigned32(_ data: Data, at offset: Int) throws -> UInt32 {
    let bytes = try slice(data, at: offset, count: 4)
    return bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
  }

  private static func unsigned64(_ data: Data, at offset: Int) throws -> UInt64 {
    let bytes = try slice(data, at: offset, count: 8)
    return bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
  }

  private static func fnv1a64(_ data: Data.SubSequence) -> UInt64 {
    data.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
  }
}
