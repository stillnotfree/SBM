import Foundation
import SBMShared

enum LatencyRefreshSchedule {
  static func isDue(lastTestAt: Date?, now: Date, intervalMinutes: Int) -> Bool {
    guard let lastTestAt else { return true }
    return now.timeIntervalSince(lastTestAt) >= interval(intervalMinutes)
  }

  static func nextDelay(lastTestAt: Date?, now: Date, intervalMinutes: Int) -> TimeInterval {
    let elapsed = lastTestAt.map { now.timeIntervalSince($0) } ?? 0
    return max(1, interval(intervalMinutes) - elapsed)
  }

  private static func interval(_ minutes: Int) -> TimeInterval {
    TimeInterval(max(minutes, 1)) * 60
  }
}
