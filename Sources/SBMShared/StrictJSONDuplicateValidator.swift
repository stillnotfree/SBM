import Foundation

/// A bounded JSON syntax pass that also treats repeated object keys as a
/// protocol error.  JSONSerialization and Codable otherwise accept the last
/// value for a duplicate key, which is unsafe at security-sensitive wire and
/// state boundaries.
public enum StrictJSONValidationError: Error, Equatable, Sendable {
  case invalidJSON
  case duplicateField(String)
  case oversized
}

public enum StrictJSONDuplicateValidator {
  public static func validate(
    _ data: Data,
    maximumBytes: Int,
    maximumDepth: Int,
    maximumStringBytes: Int
  ) throws {
    var parser = try Parser(
      data: data,
      maximumBytes: maximumBytes,
      maximumDepth: maximumDepth,
      maximumStringBytes: maximumStringBytes
    )
    try parser.validate()
  }

  private struct Parser {
    let bytes: [UInt8]
    let maximumDepth: Int
    let maximumStringBytes: Int
    var index = 0

    init(
      data: Data,
      maximumBytes: Int,
      maximumDepth: Int,
      maximumStringBytes: Int
    ) throws {
      guard maximumBytes >= 0, maximumDepth >= 0, maximumStringBytes >= 0 else {
        throw StrictJSONValidationError.invalidJSON
      }
      guard data.count <= maximumBytes else {
        throw StrictJSONValidationError.oversized
      }
      bytes = Array(data)
      self.maximumDepth = maximumDepth
      self.maximumStringBytes = maximumStringBytes
    }

    mutating func validate() throws {
      try parseValue(depth: 0)
      skipWhitespace()
      guard index == bytes.count else {
        throw StrictJSONValidationError.invalidJSON
      }
    }

    private mutating func parseValue(depth: Int) throws {
      guard depth <= maximumDepth else {
        throw StrictJSONValidationError.invalidJSON
      }
      skipWhitespace()
      guard index < bytes.count else {
        throw StrictJSONValidationError.invalidJSON
      }
      switch bytes[index] {
      case 0x7B:
        try parseObject(depth: depth + 1)
      case 0x5B:
        try parseArray(depth: depth + 1)
      case 0x22:
        _ = try parseString()
      case 0x2D, 0x30...0x39:
        try parseNumber()
      case 0x74:
        try consumeLiteral(Array("true".utf8))
      case 0x66:
        try consumeLiteral(Array("false".utf8))
      case 0x6E:
        try consumeLiteral(Array("null".utf8))
      default:
        throw StrictJSONValidationError.invalidJSON
      }
    }

    private mutating func parseObject(depth: Int) throws {
      guard depth <= maximumDepth else {
        throw StrictJSONValidationError.invalidJSON
      }
      index += 1
      skipWhitespace()
      var keys = Set<String>()
      if consumeIf(0x7D) { return }
      while true {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x22 else {
          throw StrictJSONValidationError.invalidJSON
        }
        let key = try parseString()
        guard keys.insert(key).inserted else {
          throw StrictJSONValidationError.duplicateField(key)
        }
        skipWhitespace()
        guard consumeIf(0x3A) else {
          throw StrictJSONValidationError.invalidJSON
        }
        try parseValue(depth: depth)
        skipWhitespace()
        if consumeIf(0x7D) { return }
        guard consumeIf(0x2C) else {
          throw StrictJSONValidationError.invalidJSON
        }
      }
    }

    private mutating func parseArray(depth: Int) throws {
      guard depth <= maximumDepth else {
        throw StrictJSONValidationError.invalidJSON
      }
      index += 1
      skipWhitespace()
      if consumeIf(0x5D) { return }
      while true {
        try parseValue(depth: depth)
        skipWhitespace()
        if consumeIf(0x5D) { return }
        guard consumeIf(0x2C) else {
          throw StrictJSONValidationError.invalidJSON
        }
      }
    }

    private mutating func parseString() throws -> String {
      let start = index
      guard consumeIf(0x22) else {
        throw StrictJSONValidationError.invalidJSON
      }
      while index < bytes.count {
        let byte = bytes[index]
        if byte == 0x22 {
          index += 1
          let data = Data(bytes[start..<index])
          guard
            let value = try? JSONSerialization.jsonObject(
              with: data,
              options: [.fragmentsAllowed]
            ) as? String
          else {
            throw StrictJSONValidationError.invalidJSON
          }
          guard value.utf8.count <= maximumStringBytes else {
            throw StrictJSONValidationError.oversized
          }
          return value
        }
        if byte < 0x20 {
          throw StrictJSONValidationError.invalidJSON
        }
        if byte == 0x5C {
          index += 1
          guard index < bytes.count else {
            throw StrictJSONValidationError.invalidJSON
          }
          if bytes[index] == 0x75 {
            guard index + 4 < bytes.count else {
              throw StrictJSONValidationError.invalidJSON
            }
            for offset in 1...4 where !isHex(bytes[index + offset]) {
              throw StrictJSONValidationError.invalidJSON
            }
            index += 4
          }
        }
        index += 1
      }
      throw StrictJSONValidationError.invalidJSON
    }

    private mutating func parseNumber() throws {
      if consumeIf(0x2D) {}
      guard index < bytes.count else {
        throw StrictJSONValidationError.invalidJSON
      }
      if consumeIf(0x30) {
        if index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
          throw StrictJSONValidationError.invalidJSON
        }
      } else {
        guard consumeDigits() else {
          throw StrictJSONValidationError.invalidJSON
        }
      }
      if consumeIf(0x2E), !consumeDigits() {
        throw StrictJSONValidationError.invalidJSON
      }
      if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
        index += 1
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
          index += 1
        }
        guard consumeDigits() else {
          throw StrictJSONValidationError.invalidJSON
        }
      }
    }

    private mutating func consumeDigits() -> Bool {
      let start = index
      while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
        index += 1
      }
      return index > start
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) throws {
      guard index + literal.count <= bytes.count,
        bytes[index..<(index + literal.count)].elementsEqual(literal)
      else {
        throw StrictJSONValidationError.invalidJSON
      }
      index += literal.count
    }

    private mutating func skipWhitespace() {
      while index < bytes.count
        && (bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A
          || bytes[index] == 0x0D)
      {
        index += 1
      }
    }

    private mutating func consumeIf(_ byte: UInt8) -> Bool {
      guard index < bytes.count, bytes[index] == byte else { return false }
      index += 1
      return true
    }

    private func isHex(_ byte: UInt8) -> Bool {
      (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70)
        || (byte >= 97 && byte <= 102)
    }
  }
}
