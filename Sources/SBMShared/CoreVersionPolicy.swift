import Foundation

public enum StableCoreVersionPolicy {
  public static func compare(_ lhs: String, _ rhs: String) -> Int? {
    guard let left = components(lhs), let right = components(rhs) else { return nil }
    for index in 0..<3 where left[index] != right[index] {
      return left[index] < right[index] ? -1 : 1
    }
    return 0
  }

  private static func components(_ value: String) -> [Int]? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    let values = parts.compactMap { part -> Int? in
      guard !part.isEmpty,
        part.unicodeScalars.allSatisfy({ (48...57).contains($0.value) })
      else { return nil }
      return Int(part)
    }
    return values.count == 3 ? values : nil
  }
}
