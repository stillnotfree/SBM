import Foundation

final class IsolatedTestUserDefaults: UserDefaults {
  let suiteName: String

  init() {
    let suiteName = "SBMTests.\(UUID().uuidString)"
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    self.suiteName = suiteName
    super.init(suiteName: suiteName)!
  }

  deinit {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
  }
}
