import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

private enum SettingsBehaviorFailure: Error, Sendable {
  case persistence
  case runtime
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

@Test @MainActor func blankOptionalExcludeRegexKeepsSaveAndSyncApplicable() {
  let source = ManagedSource(name: "Original", value: "https://old.example.test/list")
  let profile = ManagedProfile(name: "Profile", sources: [source])
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
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

@Test @MainActor func sourceValidationAndPersistenceFailuresPreserveEditorDraft() {
  let source = ManagedSource(name: "Original", value: "https://old.example.test/list")
  let profile = ManagedProfile(name: "Profile", sources: [source])
  let failingModel = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in throw SettingsBehaviorFailure.persistence },
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
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.latencyTestURLDraft = "https://latency.example.test/check"

  #expect(model.applyLatencySettings())
  while model.latencySettingsError == nil { await Task.yield() }
  #expect(model.latencyTestURL == "https://latency.example.test/check")
  #expect(model.latencyTestURLDraft == model.latencyTestURL)
  #expect(saved.count == 1)
  #expect(model.canRetryLatencySynchronization)

  model.retryLatencySynchronization()
  while model.latencyApplyInProgress { await Task.yield() }
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
  for _ in 0..<1_000 {
    if model.localSOCKSError != nil { break }
    await Task.yield()
  }
  #expect(model.localSOCKSError != nil)
  #expect(model.localSOCKSEnabled)
  #expect(model.localSOCKSPort == 1083)
  #expect(saved.count == 1)
  #expect(model.canRetryLocalSOCKSSynchronization)

  model.retryLocalSOCKSSynchronization()
  for _ in 0..<1_000 {
    if !model.localSOCKSApplyInProgress { break }
    await Task.yield()
  }
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
