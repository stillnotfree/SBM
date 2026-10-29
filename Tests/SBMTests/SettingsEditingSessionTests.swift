import Foundation
import SBMShared
import Testing

@testable import SBM

@Test @MainActor func settingsCloseDiscardsDraftsWithoutSavingOrTouchingRuntime() {
  let source = ManagedSource(name: "Saved source", value: "https://saved.example.test/list")
  let profile = ManagedProfile(name: "Saved profile", sources: [source])
  let library = ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  var saves = 0
  let model = AppModel(
    profileLibraryLoader: { library },
    profileLibrarySaver: { _ in saves += 1 },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.coreRunning = true
  model.helperEnabled = true
  model.helperReachable = true
  model.profileName = "Unapplied profile"
  model.sourceName = "Unapplied source"
  model.sourceExcludeRegex = "unsaved"
  model.subscriptionURL = "https://unapplied.example.test/list"
  model.subscriptionUserAgent = "Unapplied agent"
  model.subscriptionAppVersion = "Unapplied version"
  model.subscriptionDeviceOS = "Unapplied OS"
  model.subscriptionDeviceOSVersion = "Unapplied OS version"
  model.subscriptionDeviceModel = "Unapplied device"
  model.subscriptionHWID = "Unapplied credential"
  model.localSOCKSEnabledDraft = true
  model.localSOCKSPortDraft = 1083
  model.latencyIntervalMinutesDraft = 30
  model.latencyTestURLDraft = "https://unapplied.example.test/check"
  model.websiteRoutingInput = "unapplied.example.test"
  model.websiteRoutingTarget = .reject
  model.websiteRoutingEditingRuleID = UUID()
  model.routingInspectorInput = "unapplied.example.test"
  model.routingInspectorApplicationID = UUID()
  model.lastError = "Unrelated runtime failure"

  for _ in 0..<3 { model.endSettingsEditing() }

  #expect(model.profileName == profile.name)
  #expect(model.sourceName == source.name)
  #expect(model.sourceExcludeRegex.isEmpty)
  #expect(model.subscriptionURL == source.value)
  #expect(model.subscriptionUserAgent == source.headers.userAgent)
  #expect(model.subscriptionAppVersion == (source.headers.appVersion ?? ""))
  #expect(model.subscriptionDeviceOS == source.headers.deviceOS)
  #expect(model.subscriptionDeviceOSVersion == (source.headers.deviceOSVersion ?? ""))
  #expect(model.subscriptionDeviceModel == (source.headers.deviceModel ?? ""))
  #expect(model.subscriptionHWID == source.headers.hardwareID)
  #expect(!model.localSOCKSSettingsDirty)
  #expect(!model.latencySettingsDirty)
  #expect(model.websiteRoutingInput.isEmpty)
  #expect(model.websiteRoutingTarget == .selectedProxy)
  #expect(model.websiteRoutingEditingRuleID == nil)
  #expect(model.routingInspectorInput.isEmpty)
  #expect(model.routingInspectorApplicationID == nil)
  #expect(model.profiles == library.profiles)
  #expect(model.selectedProfileID == profile.id)
  #expect(model.selectedSourceID == source.id)
  #expect(model.coreRunning && model.helperEnabled && model.helperReachable)
  #expect(model.lastError == "Unrelated runtime failure")
  #expect(saves == 0)
}

@Test @MainActor func settingsCloseClearsInvalidDraftFeedbackAndKeepsDiagnostics() {
  let model = AppModel(
    profileLibraryLoader: { .empty },
    profileLibrarySaver: { _ in Issue.record("Closing must not save") },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.latencyTestURLDraft = "invalid"
  #expect(!model.applyLatencySettings())
  model.localSOCKSPortDraft = 19090
  #expect(!model.applyLocalSOCKSSettings())
  let invalidDNS = ManagedDNSSettings(direct: .customDoH("invalid"), proxy: .cloudflare)
  #expect(!model.saveDNSSettings(invalidDNS))
  let history = model.recentErrors

  model.endSettingsEditing()

  #expect(model.latencySettingsError == nil)
  #expect(model.localSOCKSError == nil)
  #expect(model.lastError == nil)
  #expect(!model.latencySettingsDirty)
  #expect(!model.localSOCKSSettingsDirty)
  #expect(model.dnsSettings == .defaults)
  #expect(model.recentErrors == history)
  model.lastError = "Unrelated failure"
  model.endSettingsEditing()
  #expect(model.lastError == "Unrelated failure")
}

@Test @MainActor func settingsCloseRestoresSuccessfullyCommittedValues() {
  let profile = ManagedProfile(name: "Original")
  var saved: [ProfileLibrary] = []
  let model = AppModel(
    profileLibraryLoader: { ProfileLibrary(profiles: [profile], selectedProfileID: profile.id) },
    profileLibrarySaver: { saved.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.profileName = "Committed"
  model.saveProfileName()
  model.latencyIntervalMinutesDraft = 20
  model.latencyTestURLDraft = "https://committed.example.test/check"
  #expect(model.applyLatencySettings())
  model.localSOCKSEnabledDraft = true
  model.localSOCKSPortDraft = 1083
  #expect(model.applyLocalSOCKSSettings())
  let dns = ManagedDNSSettings(direct: .customDoH("https://dns.example.test/query"), proxy: .google)
  #expect(model.saveDNSSettings(dns))
  let committed = saved.last
  let saveCount = saved.count
  model.profileName = "Unapplied"
  model.latencyIntervalMinutesDraft = 50
  model.latencyTestURLDraft = "https://unapplied.example.test/check"
  model.localSOCKSEnabledDraft = false
  model.localSOCKSPortDraft = 1084

  model.endSettingsEditing()

  #expect(model.profileName == "Committed")
  #expect(model.latencyIntervalMinutesDraft == 20)
  #expect(model.latencyTestURLDraft == "https://committed.example.test/check")
  #expect(model.localSOCKSEnabledDraft)
  #expect(model.localSOCKSPortDraft == 1083)
  #expect(model.dnsSettings == dns)
  #expect(saved.count == saveCount)
  #expect(saved.last == committed)
}

@Test @MainActor func settingsClosePreservesCommittedSynchronizationFailure() async {
  let model = AppModel(
    helperRequestSender: { _ in
      HelperResponse(success: false, coreRunning: false, message: "Runtime sync failed")
    },
    profileLibraryLoader: { .empty },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.latencyTestURLDraft = "https://committed.example.test/check"
  #expect(model.applyLatencySettings())
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while model.latencyApplyInProgress && ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(model.canRetryLatencySynchronization)
  let issue = model.latencySettingsIssue
  let error = model.lastError
  model.latencyTestURLDraft = "https://unapplied.example.test/check"

  model.endSettingsEditing()

  #expect(model.latencySettingsIssue == issue)
  #expect(model.lastError == error)
  #expect(model.canRetryLatencySynchronization)
  #expect(model.latencyTestURLDraft == "https://committed.example.test/check")
}

@Test @MainActor func settingsCloseDoesNotApplyUncommittedTextAfterAnAcceptedSave() async {
  var saved: [ProfileLibrary] = []
  let model = AppModel(
    helperRequestSender: { _ in
      try await Task.sleep(for: .milliseconds(20))
      return HelperResponse(success: true, coreRunning: false, message: "Applied")
    },
    profileLibraryLoader: { .empty },
    profileLibrarySaver: { saved.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.latencyTestURLDraft = "https://committed.example.test/check"
  #expect(model.applyLatencySettings())
  #expect(model.latencyApplyInProgress)
  model.latencyTestURLDraft = "https://discarded.example.test/check"
  model.endSettingsEditing()
  #expect(model.latencyTestURLDraft == model.latencyTestURL)
  model.latencyTestURLDraft = "https://new-session.example.test/check"
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while model.latencyApplyInProgress && ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(!model.latencyApplyInProgress)
  #expect(model.latencySettingsError == nil)
  #expect(saved.count == 1)
  #expect(saved.last?.latencyTestURL == "https://committed.example.test/check")
  #expect(model.latencyTestURL == "https://committed.example.test/check")
  #expect(model.latencyTestURLDraft == "https://new-session.example.test/check")
}

@Test func nativeSettingsSceneReleasesViewStateOnClose() throws {
  let root = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let app = try String(
    contentsOf: root.appendingPathComponent("Sources/SBM/SBMApp.swift"), encoding: .utf8)
  let start = try #require(app.range(of: "    Window(\"Settings\""))
  let end = try #require(
    app.range(of: "\n\n    Window(\"Diagnostics\"", range: start.upperBound..<app.endIndex))
  let scene = String(app[start.lowerBound..<end.lowerBound])
  #expect(app.contains("openWindow(id: target.rawValue)"))
  #expect(app.contains("@State private var settingsEditing = false"))
  let template = try String(
    contentsOf: root.appendingPathComponent("Tests/SBMTests/Fixtures/SettingsWindowLifetime.swift"),
    encoding: .utf8
  )
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
    "SBMSettingsLifetime-\(UUID())")
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let source = temporary.appendingPathComponent("Harness.swift")
  let binary = temporary.appendingPathComponent("Harness")
  try template.replacingOccurrences(of: "// SETTINGS_SCENE", with: scene)
    .write(to: source, atomically: true, encoding: .utf8)
  let build = try TestProcessSupport.run(
    executableURL: URL(filePath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc", "-parse-as-library", "-module-cache-path",
      temporary.appendingPathComponent("cache").path,
      source.path, "-o", binary.path,
    ],
    timeoutSeconds: 60
  )
  try #require(build.status == 0, "\(build.output)")
  let native = try TestProcessSupport.run(executableURL: binary, arguments: [], timeoutSeconds: 20)
  #expect(native.status == 0, "\(native.output)")
  #expect(
    native.output.contains(
      "PASS: 3 native close/reopen cycles; singleton window and released view state"))
}
