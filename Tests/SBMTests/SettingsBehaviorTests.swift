import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

private enum SettingsBehaviorFailure: Error, Sendable {
  case persistence
  case runtime
}

@MainActor
private func waitForSettingsCondition(
  timeout: Duration = .seconds(2),
  _ condition: @MainActor () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !condition(), clock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return condition()
}

private actor SequencedSettingsHelperSender {
  private var shouldFail = true
  private(set) var requestCount = 0

  func send(_ request: HelperRequest) throws -> HelperResponse {
    requestCount += 1
    if shouldFail {
      shouldFail = false
      return HelperResponse(
        success: false,
        coreRunning: true,
        message: SettingsBehaviorFailure.runtime.localizedDescription
      )
    }
    return HelperResponse(
      success: true,
      coreRunning: request.action == .start || request.action == .setLatencyTarget,
      message: "settings applied"
    )
  }
}

@Test @MainActor func profileNameSaveUsesCleanAndValidDraftState() {
  let profile = ManagedProfile(name: "Original")
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  #expect(!model.profileNameSaveEnabled)
  model.profileName = "   "
  #expect(!model.profileNameSaveEnabled)
  model.profileName = "Edited"
  #expect(model.profileNameSaveEnabled)
  model.saveProfileName()
  #expect(model.profileName == "Edited")
  #expect(model.profiles.first?.name == "Edited")
  #expect(!model.profileNameSaveEnabled)
}

@Test @MainActor func profileNamePersistenceFailurePreservesDraftAndCommittedName() {
  let profile = ManagedProfile(name: "Original")
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in throw SettingsBehaviorFailure.persistence },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  model.profileName = "Edited draft"
  model.saveProfileName()
  #expect(model.profileName == "Edited draft")
  #expect(model.profiles.first?.name == "Original")
  #expect(model.profileNameError != nil)
  #expect(model.lastError != nil)
  #expect(model.profileNameSaveEnabled)
}

@Test @MainActor func dnsValidationFeedbackTracksValidDraftWithoutSavingIt() {
  var savedLibraries: [ProfileLibrary] = []
  let model = AppModel(
    profileLibraryLoader: { .empty },
    profileLibrarySaver: { savedLibraries.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  let invalid = ManagedDNSSettings(
    direct: .customDoH("not a URL"), proxy: .cloudflare
  )
  let validCustom = ManagedDNSSettings(
    direct: .customDoH("https://dns.example.test/dns-query"), proxy: .cloudflare
  )

  #expect(!model.saveDNSSettings(invalid))
  #expect(model.lastError == SBMText.localized("DNS settings are invalid"))
  #expect(model.dnsSettings == .defaults)
  #expect(savedLibraries.isEmpty)

  model.clearStaleDNSValidationError(for: .defaults)
  #expect(model.lastError == nil)
  #expect(model.dnsSettings == .defaults)
  #expect(savedLibraries.isEmpty)

  #expect(!model.saveDNSSettings(invalid))
  #expect(model.lastError == SBMText.localized("DNS settings are invalid"))
  model.clearStaleDNSValidationError(for: invalid)
  #expect(model.lastError == SBMText.localized("DNS settings are invalid"))

  // Returning to the already-saved preset is valid, but requires no Apply write.
  #expect(model.saveDNSSettings(.defaults))
  #expect(model.lastError == nil)
  #expect(model.dnsSettings == .defaults)
  #expect(savedLibraries.isEmpty)

  #expect(!model.saveDNSSettings(invalid))
  #expect(model.lastError == SBMText.localized("DNS settings are invalid"))
  #expect(model.saveDNSSettings(validCustom))
  #expect(model.lastError == nil)
  #expect(model.dnsSettings == validCustom)
  #expect(savedLibraries.count == 1)
  #expect(savedLibraries.last?.dnsSettings == validCustom)

  model.lastError = "Unrelated failure"
  model.clearStaleDNSValidationError(for: .defaults)
  #expect(model.lastError == "Unrelated failure")
}

@Test @MainActor func blankOptionalExcludeRegexKeepsSaveAndSyncApplicable() {
  let source = ManagedSource(name: "Original", value: "https://old.example.test/list")
  let profile = ManagedProfile(name: "Profile", sources: [source])
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  model.sourceName = "Edited source"
  model.subscriptionURL = "https://new.example.test/list"
  for filter in ["", "   ", "(?i)lte|russia"] {
    model.sourceExcludeRegex = filter
    #expect(model.sourceDraftIsValid)
  }
  model.sourceExcludeRegex = "(?i)("
  #expect(!model.sourceDraftIsValid)
}

@Test @MainActor func sourceEditorLoadsAndSavesOptionalPlatformHeaders() throws {
  let oldSource = ManagedSource(
    name: "Old source",
    value: "https://old.example.test/list",
    headers: SubscriptionHeaders(
      userAgent: "Old Client/1.0",
      appVersion: nil,
      deviceOS: "iOS",
      deviceOSVersion: nil,
      deviceModel: nil,
      hardwareID: "old-hwid"
    )
  )
  let currentSource = ManagedSource(
    name: "Current source",
    value: "https://current.example.test/list",
    headers: SubscriptionHeaders(
      userAgent: "Current Client/1.0",
      appVersion: nil,
      deviceOS: "iOS",
      deviceOSVersion: "26.7",
      deviceModel: "iPhone",
      hardwareID: "current-hwid"
    )
  )
  let profile = ManagedProfile(name: "Profile", sources: [oldSource, currentSource])
  var savedLibraries: [ProfileLibrary] = []
  let model = AppModel(
    subscriptionManager: SubscriptionManager { _, _ in
      throw SettingsBehaviorFailure.runtime
    },
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { savedLibraries.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  #expect(model.subscriptionDeviceOSVersion.isEmpty)
  #expect(model.subscriptionDeviceModel.isEmpty)
  model.selectSource(currentSource.id)
  #expect(model.subscriptionDeviceOSVersion == "26.7")
  #expect(model.subscriptionDeviceModel == "iPhone")

  model.subscriptionDeviceOSVersion = " 26.7 \n"
  model.subscriptionDeviceModel = " iPhone "
  model.saveAndSyncSubscription()
  let savedCurrent = try #require(
    savedLibraries.last?.profiles.first?.sources.first(where: {
      $0.id == currentSource.id
    }))
  #expect(savedCurrent.headers.deviceOSVersion == "26.7")
  #expect(savedCurrent.headers.deviceModel == "iPhone")

  model.selectSource(oldSource.id)
  #expect(model.subscriptionDeviceOSVersion.isEmpty)
  #expect(model.subscriptionDeviceModel.isEmpty)
  model.subscriptionAppVersion = "  \n"
  model.subscriptionDeviceOSVersion = " \t"
  model.subscriptionDeviceModel = "\n"
  #expect(model.sourceDraftIsValid)
  model.saveAndSyncSubscription()
  let savedOld = try #require(
    savedLibraries.last?.profiles.first?.sources.first(where: {
      $0.id == oldSource.id
    }))
  #expect(savedOld.headers.appVersion == nil)
  #expect(savedOld.headers.deviceOSVersion == nil)
  #expect(savedOld.headers.deviceModel == nil)
}

@Test @MainActor func resetSourcePresetUpdatesEditorAndPreservesHWID() {
  let source = ManagedSource(name: "Source", value: "https://example.test/list")
  let profile = ManagedProfile(name: "Profile", sources: [source])
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.subscriptionUserAgent = "Custom/1.0"
  model.subscriptionAppVersion = "Custom"
  model.subscriptionDeviceOS = "CustomOS"
  model.subscriptionDeviceOSVersion = "CustomVersion"
  model.subscriptionDeviceModel = "CustomModel"
  model.subscriptionHWID = "stable-hwid"

  model.resetSubscriptionRequestPreset()

  #expect(model.subscriptionUserAgent == SubscriptionHeaders.defaultUserAgent)
  #expect(model.subscriptionAppVersion.isEmpty)
  #expect(model.subscriptionDeviceOS == "iOS")
  #expect(model.subscriptionDeviceOSVersion == "26.7")
  #expect(model.subscriptionDeviceModel == "iPhone")
  #expect(model.subscriptionHWID == "stable-hwid")
}

@Test @MainActor func sourceValidationAndPersistenceFailuresPreserveEditorDraft() {
  let source = ManagedSource(name: "Original", value: "https://old.example.test/list")
  let profile = ManagedProfile(name: "Profile", sources: [source])
  let failingModel = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in throw SettingsBehaviorFailure.persistence },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  failingModel.sourceName = "Edited source"
  failingModel.subscriptionURL = "https://new.example.test/list"
  failingModel.saveAndSyncSubscription()
  #expect(failingModel.sourceName == "Edited source")
  #expect(failingModel.subscriptionURL == "https://new.example.test/list")
  #expect(failingModel.profiles.first?.sources.first?.name == "Original")
  #expect(failingModel.profiles.first?.sources.first?.value == "https://old.example.test/list")
  #expect(failingModel.sourceEditorError != nil)
  #expect(failingModel.sourceEditorError?.contains("new.example.test") == false)
  #expect(failingModel.lastError != nil)

  let invalidModel = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  invalidModel.sourceName = "Invalid draft"
  invalidModel.subscriptionURL = "http://not-allowed.example.test/list"
  invalidModel.saveAndSyncSubscription()
  #expect(invalidModel.sourceName == "Invalid draft")
  #expect(invalidModel.subscriptionURL == "http://not-allowed.example.test/list")
  #expect(invalidModel.profiles.first?.sources.first?.name == "Original")
}

@Test @MainActor func latencyRuntimeFailureKeepsCommittedTargetAndRetriesWithoutRewrite() async {
  let sender = SequencedSettingsHelperSender()
  var saved: [ProfileLibrary] = []
  let profile = ManagedProfile(name: "Profile")
  let model = AppModel(
    helperRequestSender: { request in
      try await sender.send(request)
    },
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { saved.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.latencyTestURLDraft = "https://latency.example.test/check"

  #expect(model.applyLatencySettings())
  #expect(await waitForSettingsCondition { !(model.latencySettingsError == nil) })
  #expect(model.latencyTestURL == "https://latency.example.test/check")
  #expect(model.latencyTestURLDraft == model.latencyTestURL)
  #expect(saved.count == 1)
  #expect(model.canRetryLatencySynchronization)

  model.retryLatencySynchronization()
  #expect(await waitForSettingsCondition { !(model.latencyApplyInProgress) })
  #expect(model.latencySettingsError == nil)
  #expect(!model.canRetryLatencySynchronization)
  #expect(await sender.requestCount == 2)
  #expect(saved.count == 1)
}

@Test @MainActor func localSOCKSRuntimeFailureKeepsDesiredStateAndRetriesWithoutRewrite() async {
  let sender = SequencedSettingsHelperSender()
  var saved: [ProfileLibrary] = []
  let profile = ManagedProfile(name: "Profile")
  let model = AppModel(
    runtimeSender: { request in
      try await sender.send(request)
    },
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { saved.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.coreRunning = true
  model.localSOCKSEnabledDraft = true
  model.localSOCKSPortDraft = 1083

  #expect(model.applyLocalSOCKSSettings())
  #expect(await waitForSettingsCondition { model.localSOCKSError != nil })
  #expect(model.localSOCKSError != nil)
  #expect(model.localSOCKSEnabled)
  #expect(model.localSOCKSPort == 1083)
  #expect(saved.count == 1)
  #expect(model.canRetryLocalSOCKSSynchronization)

  model.retryLocalSOCKSSynchronization()
  #expect(await waitForSettingsCondition { !model.localSOCKSApplyInProgress })
  #expect(model.localSOCKSError == nil)
  #expect(!model.canRetryLocalSOCKSSynchronization)
  #expect(await sender.requestCount == 2)
  #expect(saved.count == 1)
}

@Test @MainActor func stagedLatencyApplyAndResetKeepDraftSeparateFromCommittedValues() {
  let committedURL = "https://committed.example.test/check"
  var saved: [ProfileLibrary] = []
  let profile = ManagedProfile(name: "Profile")
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [profile],
        selectedProfileID: profile.id,
        latencyIntervalMinutes: 20,
        latencyTestURL: committedURL
      )
    },
    profileLibrarySaver: { saved.append($0) },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  model.latencyIntervalMinutesDraft = 30
  model.latencyTestURLDraft = "https://draft.example.test/check"
  #expect(model.latencySettingsDirty)
  #expect(model.latencySettingsValid)
  model.resetLatencySettings()
  #expect(model.latencyIntervalMinutes == 20)
  #expect(model.latencyTestURL == committedURL)
  #expect(model.latencyIntervalMinutesDraft == 10)
  #expect(model.latencyTestURLDraft == LatencyTargetPolicy.defaultURL)
  #expect(model.latencySettingsDirty)
  #expect(model.applyLatencySettings())
  #expect(model.latencyIntervalMinutes == 10)
  #expect(model.latencyTestURL == LatencyTargetPolicy.defaultURL)
  #expect(!model.latencySettingsDirty)
  #expect(saved.last?.latencyIntervalMinutes == 10)
  #expect(saved.last?.latencyTestURL == LatencyTargetPolicy.defaultURL)
}

@Test @MainActor func failedLatencyAndSOCKSApplyPreserveDraftAndCommittedState() {
  let profile = ManagedProfile(name: "Profile")
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [profile],
        selectedProfileID: profile.id,
        localSOCKSEnabled: false,
        localSOCKSPort: 1082,
        latencyIntervalMinutes: 10,
        latencyTestURL: LatencyTargetPolicy.defaultURL
      )
    },
    profileLibrarySaver: { _ in throw SettingsBehaviorFailure.persistence },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  model.latencyIntervalMinutesDraft = 15
  model.latencyTestURLDraft = "https://failed.example.test/check"
  #expect(!model.applyLatencySettings())
  #expect(model.latencyIntervalMinutes == 10)
  #expect(model.latencyTestURL == LatencyTargetPolicy.defaultURL)
  #expect(model.latencyIntervalMinutesDraft == 15)
  #expect(model.latencyTestURLDraft == "https://failed.example.test/check")
  #expect(!model.canRetryLatencySynchronization)

  model.localSOCKSEnabledDraft = true
  model.localSOCKSPortDraft = 1083
  #expect(!model.applyLocalSOCKSSettings())
  #expect(!model.localSOCKSEnabled)
  #expect(model.localSOCKSPort == 1082)
  #expect(model.localSOCKSEnabledDraft)
  #expect(model.localSOCKSPortDraft == 1083)
  #expect(!model.canRetryLocalSOCKSSynchronization)
}

@Test @MainActor func persistenceFailuresDoNotOfferOrPerformRuntimeRetry() async {
  let latencySender = SequencedSettingsHelperSender()
  let latencyModel = AppModel(
    helperRequestSender: { request in try await latencySender.send(request) },
    profileLibraryLoader: { .empty },
    profileLibrarySaver: { _ in throw SettingsBehaviorFailure.persistence },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  latencyModel.latencyTestURLDraft = "https://failed.example.test/check"
  #expect(!latencyModel.applyLatencySettings())
  let latencyError = latencyModel.latencySettingsError
  #expect(!latencyModel.canRetryLatencySynchronization)
  latencyModel.retryLatencySynchronization()
  #expect(await latencySender.requestCount == 0)
  #expect(latencyModel.latencySettingsError == latencyError)

  let socksSender = SequencedSettingsHelperSender()
  let socksModel = AppModel(
    runtimeSender: { request in try await socksSender.send(request) },
    profileLibraryLoader: { .empty },
    profileLibrarySaver: { _ in throw SettingsBehaviorFailure.persistence },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  socksModel.localSOCKSEnabledDraft = true
  socksModel.localSOCKSPortDraft = 1083
  #expect(!socksModel.applyLocalSOCKSSettings())
  let socksError = socksModel.localSOCKSError
  #expect(!socksModel.canRetryLocalSOCKSSynchronization)
  socksModel.retryLocalSOCKSSynchronization()
  #expect(await socksSender.requestCount == 0)
  #expect(socksModel.localSOCKSError == socksError)
}
