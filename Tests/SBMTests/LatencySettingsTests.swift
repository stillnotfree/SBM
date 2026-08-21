import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

@Test func latencyTargetNormalizesHTTPSQueryAndCustomPort() throws {
  let target = try LatencyTargetPolicy.normalized(
    "  HTTPS://latency.example.test:8443/generate?region=eu&probe=1  "
  )
  #expect(target == "https://latency.example.test:8443/generate?region=eu&probe=1")
}

@Test func latencyTargetRejectsUnsafeOrMalformedURLs() {
  let oversized = "https://example.test/" + String(repeating: "a", count: 2_048)
  let rejected = [
    "http://example.test/generate",
    "https://user:password@example.test/generate",
    "https://example.test/generate#fragment",
    "https://example.test/generate\nnext",
    "https://example.test:0/generate",
    oversized,
    "https:///generate",
  ]

  for value in rejected {
    #expect(throws: LatencyTargetFailure.self) {
      try LatencyTargetPolicy.normalized(value)
    }
  }
}

@Test func olderLatencyStoresDecodeToTheDefaultTarget() throws {
  let libraryData = Data(
    """
    {
      "profiles": [],
      "selectedProfileID": null,
      "localSOCKSEnabled": false,
      "localSOCKSPort": 1082,
      "latencyIntervalMinutes": 10
    }
    """.utf8
  )
  let helperData = Data(
    """
    {
      "mode": "Rule",
      "selectedNode": "auto",
      "selectorTag": "proxy-selector",
      "nodes": [],
      "desiredRunning": false,
      "localSOCKSEnabled": false,
      "localSOCKSPort": 1082,
      "apiSecret": "test-secret"
    }
    """.utf8
  )

  let library = try JSONDecoder().decode(ProfileLibrary.self, from: libraryData)
  let state = try JSONDecoder().decode(PersistentState.self, from: helperData)

  #expect(library.latencyTestURL == LatencyTargetPolicy.defaultURL)
  #expect(state.latencyTestURL == LatencyTargetPolicy.defaultURL)
}

@Test func latencyTargetPersistsAndInvalidApplyPreservesTheSavedValue() throws {
  let valid = try LatencyTargetPolicy.normalized("https://latency.example.test/check")
  let library = ProfileLibrary(profiles: [], selectedProfileID: nil, latencyTestURL: valid)
  let encoded = try JSONEncoder().encode(library)
  let decoded = try JSONDecoder().decode(ProfileLibrary.self, from: encoded)
  #expect(decoded.latencyTestURL == valid)

  var saved = valid
  #expect(throws: LatencyTargetFailure.self) {
    _ = try LatencyTargetSettings.apply(draft: "http://invalid.example.test") { target in
      saved = target
    }
  }
  #expect(saved == valid)
}

@Test func latencyTargetStateUpdatesManualDelayWithoutLifecycleAction() throws {
  var state = PersistentState()
  let target = try LatencyTargetPolicy.normalized(
    "https://latency.example.test:8443/check?token=one%20two&mode=full"
  )
  try state.setLatencyTestURL(target)
  #expect(state.latencyTestURL == target)
  let restored = try JSONDecoder().decode(
    PersistentState.self,
    from: JSONEncoder().encode(state)
  )
  #expect(restored.latencyTestURL == target)

  let path = LatencyDelayRequest.path(
    for: ProxyNodeID(rawValue: "proxy/one"),
    target: state.latencyTestURL
  )
  let url = try #require(URL(string: "http://localhost\(path)"))
  let queryItems = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
  #expect(queryItems.first(where: { $0.name == "url" })?.value == target)
  #expect(!path.contains("&mode=full"))
  #expect(!path.contains("#"))

  let request = HelperRequest(action: .setLatencyTarget, latencyTestURL: target)
  #expect(request.action == .setLatencyTarget)
  #expect(request.profile == nil)
  #expect(request.latencyTestURL == target)
}

@Test func latencyRefreshSchedulingPreservesExistingDelays() {
  let now = Date(timeIntervalSinceReferenceDate: 10_000)
  #expect(LatencyRefreshSchedule.isDue(lastTestAt: nil, now: now, intervalMinutes: 10))
  #expect(
    !LatencyRefreshSchedule.isDue(
      lastTestAt: now.addingTimeInterval(-599),
      now: now,
      intervalMinutes: 10
    )
  )
  #expect(
    LatencyRefreshSchedule.nextDelay(
      lastTestAt: now.addingTimeInterval(-120),
      now: now,
      intervalMinutes: 10
    ) == 480
  )
  #expect(
    LatencyRefreshSchedule.nextDelay(
      lastTestAt: now.addingTimeInterval(-700),
      now: now,
      intervalMinutes: 10
    ) == 1
  )
}

@Test func latencyTargetEditorUsesAlignedTargetRowAndSectionActions() throws {
  let packageRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let source = try String(
    contentsOf: packageRoot.appending(path: "Sources/SBM/SettingsView.swift"), encoding: .utf8)
  let latencyStart = try #require(source.range(of: #"Section("Latency")"#))
  let latencyEnd = try #require(
    source.range(of: #"Section("Local SOCKS5")"#, range: latencyStart.upperBound..<source.endIndex)
  )
  let section = source[latencyStart.lowerBound..<latencyEnd.lowerBound]
  let field = try #require(
    section.range(of: #"settingsRow("Test target")"#)
  )
  let actions = try #require(
    section.range(of: "HStack(spacing: 8)", range: field.upperBound..<section.endIndex)
  )
  let fieldRow = section[field.lowerBound..<actions.lowerBound]
  let actionRow = section[actions.lowerBound..<section.endIndex]

  #expect(fieldRow.contains(#"TextField("Test target", text: $model.latencyTestURLDraft)"#))
  #expect(!section.contains("HTTPS test target"))
  #expect(!section.contains("Ping target"))
  #expect(actionRow.contains(#"Button("Apply")"#))
  #expect(actionRow.contains(#"Button("Reset to Default")"#))
}

@Test @MainActor func applyConfirmationOnlyFollowsSuccessfulPersistence() throws {
  let initialTarget = try LatencyTargetPolicy.normalized(
    "https://initial.example.test/check"
  )
  var savedLibraries: [ProfileLibrary] = []
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [],
        selectedProfileID: nil,
        localSOCKSEnabled: false,
        localSOCKSPort: 1082,
        latencyTestURL: initialTarget
      )
    },
    profileLibrarySaver: { savedLibraries.append($0) },
    performStartup: false
  )

  model.latencyTestURLDraft = "https://changed.example.test/check"
  model.localSOCKSPortDraft = 1083
  #expect(model.applyLatencyTestURL())
  #expect(savedLibraries.last?.latencyTestURL == "https://changed.example.test/check")
  #expect(model.applyLocalSOCKSSettings())
  #expect(savedLibraries.last?.localSOCKSPort == 1083)

  let failingModel = AppModel(
    profileLibraryLoader: { .empty },
    profileLibrarySaver: { _ in throw ApplyConfirmationTestFailure.persistence },
    performStartup: false
  )
  failingModel.latencyTestURLDraft = "https://changed.example.test/check"
  #expect(!failingModel.applyLatencyTestURL())
  #expect(!failingModel.applyLocalSOCKSSettings())
}

private enum ApplyConfirmationTestFailure: Error {
  case persistence
}

@Test func settingsUseOneImporterAndNativePendingFeedbackAndCurrentRoutingCopy() throws {
  let packageRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let source = try String(
    contentsOf: packageRoot.appending(path: "Sources/SBM/SettingsView.swift"), encoding: .utf8)

  #expect(source.components(separatedBy: ".fileImporter(").count - 1 == 1)
  #expect(source.contains(#"Button("Import Full JSON as New Profile…")"#))
  #expect(source.contains(#"Button("Import Routing…")"#))
  #expect(source.contains(#"Button("Open Current…")"#))
  #expect(source.contains("model.openCurrentRoutingPolicy()"))
  #expect(source.contains("model.latencyApplyInProgress"))
  #expect(source.contains("model.localSOCKSApplyInProgress"))
  #expect(source.contains("if model.latencyApplyInProgress"))
  #expect(source.contains("if model.localSOCKSApplyInProgress"))
  #expect(source.contains("if model.canRetryLatencySynchronization"))
  #expect(source.contains("if model.canRetryLocalSOCKSSynchronization"))
  #expect(!source.contains("Saved"))
  #expect(!source.contains("Task.sleep"))
}

@Test func currentRoutingCopyIsValidJSONWithPrivatePermissions() throws {
  let configuration = Data(
    """
    {"route":{"rules":[{"domain_suffix":["example.test"],"outbound":"direct"}]}}
    """.utf8
  )
  let url = try RoutingPolicyDocument.makeTemporaryCopy(configuration)
  let directory = url.deletingLastPathComponent()
  defer { try? FileManager.default.removeItem(at: directory) }

  let copied = try Data(contentsOf: url)
  let originalObject = try JSONSerialization.jsonObject(with: configuration) as? NSDictionary
  let copiedObject = try JSONSerialization.jsonObject(with: copied) as? NSDictionary
  let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
  let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)

  #expect(copiedObject == originalObject)
  #expect(url.pathExtension == "json")
  #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}
