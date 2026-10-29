import Foundation
import SBMShared
import Testing

@testable import SBM

@MainActor
private final class CP09HelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState
  var legacyRegistrationState: HelperRegistrationState = .notRegistered
  private(set) var registrationCount = 0
  private(set) var unregistrationCount = 0

  init(registrationState: HelperRegistrationState = .enabled) {
    self.registrationState = registrationState
  }

  func register() throws {
    registrationCount += 1
    registrationState = .enabled
  }

  func unregister() async throws {
    unregistrationCount += 1
    registrationState = .notRegistered
  }

  func unregisterLegacy() async throws {
    legacyRegistrationState = .notRegistered
  }

  func openSystemSettings() {}
}

private actor CP09LifecycleTransport {
  private let responses: [HelperResponse]
  private var responseIndex = 0
  private var actions: [HelperAction] = []

  init(responses: [HelperResponse]) {
    self.responses = responses
  }

  func send(_ request: HelperRequest, _: Int) throws -> HelperResponse {
    actions.append(request.action)
    guard responseIndex < responses.count else { throw URLError(.badServerResponse) }
    defer { responseIndex += 1 }
    return responses[responseIndex]
  }

  func recordedActions() -> [HelperAction] { actions }
}

private actor CP09RuntimeTransport {
  private var actions: [HelperAction] = []

  func send(_ request: HelperRequest) -> HelperResponse {
    actions.append(request.action)
    return HelperResponse(success: true, coreRunning: false, message: "stopped")
  }

  func recordedActions() -> [HelperAction] { actions }
}

@MainActor
private struct CP09Fixture {
  let model: AppModel
  let helperService: CP09HelperService
  let lifecycle: CP09LifecycleTransport
  let runtime: CP09RuntimeTransport
  let defaults: UserDefaults
  let suite: String

  func cleanUp() {
    defaults.removePersistentDomain(forName: suite)
  }
}

private func cp09Response(
  success: Bool,
  revision: Int = HelperConstants.helperRevision,
  message: String
) throws -> HelperResponse {
  let response = HelperResponse(success: success, coreRunning: false, message: message)
  guard
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response))
      as? [String: Any]
  else {
    throw CocoaError(.coderInvalidValue)
  }
  object["helperRevision"] = revision
  return try JSONDecoder().decode(
    HelperResponse.self,
    from: JSONSerialization.data(withJSONObject: object)
  )
}

@MainActor
private func cp09Fixture(
  applicationBundleURL: URL,
  responses: [HelperResponse] = [],
  registrationState: HelperRegistrationState = .enabled,
  helperEnabled: Bool = true,
  performStartup: Bool = false
) -> CP09Fixture {
  let suite = "SBMTests.CP09HelperSetup.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  let helperService = CP09HelperService(registrationState: registrationState)
  let lifecycle = CP09LifecycleTransport(responses: responses)
  let runtime = CP09RuntimeTransport()
  let model = AppModel(
    helperService: helperService,
    helperLifecycleSender: { request, timeout in
      try await lifecycle.send(request, timeout)
    },
    applicationBundleURL: applicationBundleURL,
    runtimeSender: { request in await runtime.send(request) },
    profileLibraryLoader: { .empty },
    profileLibrarySaver: { _ in },
    userDefaults: defaults,
    performStartup: performStartup
  )
  model.helperEnabled = helperEnabled
  model.helperReachable = false
  model.helperVersion = HelperConstants.helperVersion
  model.helperProtocolVersion = HelperConstants.protocolVersion
  model.helperRevision = HelperConstants.helperRevision
  return CP09Fixture(
    model: model,
    helperService: helperService,
    lifecycle: lifecycle,
    runtime: runtime,
    defaults: defaults,
    suite: suite
  )
}

@MainActor
private func cp09WaitForSetup(_ model: AppModel) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while model.helperSetupInProgress, ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
  return !model.helperSetupInProgress
}

@MainActor
private func cp09WaitForSuccessfulRefresh(_ fixture: CP09Fixture) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while ContinuousClock.now < deadline {
    if fixture.model.helperReachable,
      await fixture.lifecycle.recordedActions() == [.status]
    {
      return true
    }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return false
}

private func canonicalAppURL() -> URL {
  URL(fileURLWithPath: "/Applications/SBM.app", isDirectory: true)
}

private func installGuidance() -> String {
  SBMText.localized(
    "Move SBM.app to the Applications folder, eject the DMG, then open the installed copy."
  )
}

@Test @MainActor
func cp09CanonicalInstallPathEnablesNormally() async throws {
  let response = try cp09Response(success: true, message: "ready")
  let fixture = cp09Fixture(applicationBundleURL: canonicalAppURL(), responses: [response])
  defer { fixture.cleanUp() }

  fixture.model.enableHelper()

  #expect(await cp09WaitForSetup(fixture.model))
  #expect(await fixture.lifecycle.recordedActions() == [.status])
  #expect(fixture.helperService.registrationCount == 0)
  #expect(fixture.helperService.unregistrationCount == 0)
  #expect(fixture.model.helperReachable)
  #expect(!fixture.model.helperUpdateRequired)
  #expect(fixture.model.lastError == nil)
}

@Test @MainActor
func cp09CanonicalRefreshUsesStatusNormally() async throws {
  let response = try cp09Response(success: true, message: "ready")
  let fixture = cp09Fixture(applicationBundleURL: canonicalAppURL(), responses: [response])
  defer { fixture.cleanUp() }

  fixture.model.refresh()

  #expect(await cp09WaitForSuccessfulRefresh(fixture))
  #expect(fixture.model.observedCoreState == .stopped)
  #expect(await fixture.runtime.recordedActions().isEmpty)
}

@Test @MainActor
func cp09NonCanonicalRefreshSkipsHelperAndRuntimeAdmission() async {
  let fixture = cp09Fixture(
    applicationBundleURL: URL(fileURLWithPath: "/tmp/SBM.app"),
    responses: [HelperResponse(success: true, coreRunning: false, message: "unexpected status")]
  )
  defer { fixture.cleanUp() }

  fixture.model.refresh()
  fixture.model.refresh(observeAutoNode: true)
  try? await Task.sleep(for: .milliseconds(50))

  #expect(await fixture.lifecycle.recordedActions().isEmpty)
  #expect(await fixture.runtime.recordedActions().isEmpty)
  #expect(fixture.helperService.registrationCount == 0)
  #expect(fixture.helperService.unregistrationCount == 0)
  #expect(fixture.model.observedCoreState == .unknown)
  #expect(!fixture.model.coreIsKnownStopped)
}

@Test @MainActor
func cp09NonCanonicalLaunchAtLoginShowsInstallGuidanceWithoutChangingSetting() {
  let fixture = cp09Fixture(applicationBundleURL: URL(fileURLWithPath: "/tmp/SBM.app"))
  defer { fixture.cleanUp() }

  let previousSetting = fixture.model.launchAtLoginEnabled
  fixture.model.setLaunchAtLoginEnabled(true)

  #expect(fixture.model.launchAtLoginEnabled == previousSetting)
  #expect(fixture.model.launchAtLoginError == installGuidance())
}

@Test @MainActor
func cp09RenamedInstallPathRejectsEnable() async {
  let fixture = cp09Fixture(
    applicationBundleURL: URL(fileURLWithPath: "/Applications/OtherName.app"),
    responses: [HelperResponse(success: true, coreRunning: false, message: "unexpected status")]
  )
  defer { fixture.cleanUp() }

  fixture.model.enableHelper()

  #expect(await cp09WaitForSetup(fixture.model))
  #expect(!fixture.model.helperSetupInProgress)
  #expect(await fixture.lifecycle.recordedActions().isEmpty)
  #expect(fixture.helperService.registrationCount == 0)
  #expect(fixture.helperService.unregistrationCount == 0)
  #expect(fixture.model.lastError == installGuidance())
}

@Test @MainActor
func cp09NonCanonicalInstallPathsRejectEnable() async {
  let paths = [
    "/Applications/Nested/SBM.app",
    "/Applications/SBM.app-copy",
    "/tmp/SBM.app",
  ]

  for path in paths {
    let fixture = cp09Fixture(applicationBundleURL: URL(fileURLWithPath: path))
    defer { fixture.cleanUp() }

    fixture.model.enableHelper()

    #expect(!fixture.model.helperSetupInProgress)
    #expect(await fixture.lifecycle.recordedActions().isEmpty)
    #expect(fixture.helperService.registrationCount == 0)
    #expect(fixture.model.lastError == installGuidance())
  }
}

@Test @MainActor
func cp09RepairRejectsNonCanonicalPathsBeforeSideEffects() async {
  let paths = [
    "/Applications/OtherName.app",
    "/Applications/Nested/SBM.app",
    "/tmp/SBM.app",
  ]

  for path in paths {
    let fixture = cp09Fixture(applicationBundleURL: URL(fileURLWithPath: path))
    defer { fixture.cleanUp() }

    fixture.model.repairHelper()

    #expect(!fixture.model.helperSetupInProgress)
    #expect(fixture.model.lastError == installGuidance())
    #expect(await fixture.lifecycle.recordedActions().isEmpty)
    #expect(await fixture.runtime.recordedActions().isEmpty)
    #expect(fixture.helperService.registrationCount == 0)
    #expect(fixture.helperService.unregistrationCount == 0)
  }
}

@Test @MainActor
func cp09SymlinkResolvingToCanonicalInstallIsAccepted() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-CP09-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let alias = root.appendingPathComponent("Alias.app", isDirectory: true)
  try FileManager.default.createSymbolicLink(
    atPath: alias.path,
    withDestinationPath: "/Applications/SBM.app"
  )

  let resolvedAlias = alias.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
  let applicationURL =
    resolvedAlias.path == canonicalAppURL().path
    ? alias
    : URL(fileURLWithPath: "/Applications/Nested/../SBM.app", isDirectory: true)
  #expect(
    applicationURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
      == canonicalAppURL().path
  )

  let response = try cp09Response(success: true, message: "ready")
  let fixture = cp09Fixture(applicationBundleURL: applicationURL, responses: [response])
  defer { fixture.cleanUp() }

  fixture.model.enableHelper()

  #expect(await cp09WaitForSetup(fixture.model))
  #expect(await fixture.lifecycle.recordedActions() == [.status])
  #expect(fixture.model.helperReachable)
}

@Test @MainActor
func cp09CanonicalNamedSymlinkResolvingElsewhereIsRejected() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-CP09-\(UUID().uuidString)", isDirectory: true)
  let applications = root.appendingPathComponent("Applications", isDirectory: true)
  let target = root.appendingPathComponent("Elsewhere.app", isDirectory: true)
  try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let canonicalNamedLink = applications.appendingPathComponent("SBM.app", isDirectory: true)
  try FileManager.default.createSymbolicLink(
    atPath: canonicalNamedLink.path,
    withDestinationPath: target.path
  )

  let fixture = cp09Fixture(applicationBundleURL: canonicalNamedLink)
  defer { fixture.cleanUp() }

  fixture.model.enableHelper()

  #expect(!fixture.model.helperSetupInProgress)
  #expect(await fixture.lifecycle.recordedActions().isEmpty)
  #expect(fixture.model.lastError == installGuidance())
  #expect(fixture.helperService.registrationCount == 0)
}

@Test @MainActor
func cp09StartupUsesExactInstallPredicate() async {
  let fixture = cp09Fixture(
    applicationBundleURL: URL(fileURLWithPath: "/Applications/Nested/SBM.app"),
    helperEnabled: false,
    performStartup: true
  )
  defer { fixture.cleanUp() }

  #expect(fixture.model.lastError == installGuidance())
  #expect(!fixture.model.helperSetupInProgress)
  #expect(await fixture.lifecycle.recordedActions().isEmpty)
  #expect(await fixture.runtime.recordedActions().isEmpty)
  #expect(fixture.helperService.registrationCount == 0)
  #expect(fixture.helperService.unregistrationCount == 0)
}

@Test @MainActor
func cp09EnablePreservesCompatibleRuntimeFailure() async throws {
  let failure = "Core bootstrap failed: unsafe ownership"
  let response = try cp09Response(success: false, message: failure)
  let fixture = cp09Fixture(applicationBundleURL: canonicalAppURL(), responses: [response])
  defer { fixture.cleanUp() }

  fixture.model.enableHelper()

  #expect(await cp09WaitForSetup(fixture.model))
  #expect(await fixture.lifecycle.recordedActions() == [.status])
  #expect(await fixture.runtime.recordedActions().isEmpty)
  #expect(fixture.helperService.registrationCount == 0)
  #expect(fixture.helperService.unregistrationCount == 0)
  #expect(fixture.model.helperReachable)
  #expect(!fixture.model.helperUpdateRequired)
  #expect(fixture.model.lastError == SBMText.localized(failure))
  #expect(!fixture.model.helperApprovalPending)
}

@Test @MainActor
func cp09AlreadyCurrentRuntimeFailureDoesNotReplaceHelper() async throws {
  let failure = "Core bootstrap failed: unsafe ownership"
  let current = try cp09Response(success: false, message: failure)
  let fixture = cp09Fixture(
    applicationBundleURL: canonicalAppURL(),
    responses: [current]
  )
  defer { fixture.cleanUp() }

  fixture.model.repairHelper()

  #expect(await cp09WaitForSetup(fixture.model))
  #expect(await fixture.lifecycle.recordedActions() == [.status])
  #expect(await fixture.runtime.recordedActions().isEmpty)
  #expect(fixture.helperService.unregistrationCount == 0)
  #expect(fixture.helperService.registrationCount == 0)
  #expect(fixture.model.helperReachable)
  #expect(!fixture.model.helperUpdateRequired)
  #expect(fixture.model.lastError == SBMText.localized(failure))
}
