import Testing

@testable import SBM

@Test func updateVersionNormalization() {
  #expect(UpdateService.normalizedVersion("v1.0.0") == "1.0.0")
  #expect(UpdateService.normalizedVersion(" 1.0.0\n") == "1.0.0")
  #expect(UpdateService.normalizedVersion("../1.0.0") == nil)
  #expect(UpdateService.normalizedVersion("1.0") == nil)
  #expect(UpdateService.normalizedVersion("1.0.0-beta") == nil)
  #expect(UpdateService.normalizedVersion("01.0.0") == nil)
}

@Test func updateVersionComparison() {
  #expect(UpdateService.isNewer("0.5.0", than: "0.4.9"))
  #expect(UpdateService.isNewer("0.5.1", than: "0.5.0"))
  #expect(UpdateService.isNewer("1.0.0", than: "0.99.99"))
  #expect(!UpdateService.isNewer("1.0", than: "0.99.99"))
  #expect(!UpdateService.isNewer("0.5.0", than: "0.5.0"))
  #expect(!UpdateService.isNewer("0.4.9", than: "0.5.0"))
}
