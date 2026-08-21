import Foundation
import SBMShared
import Testing

@testable import SBM

@MainActor
private final class ReadyHelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState = .enabled
  func register() throws {}
  func unregister() async throws {}
  func openSystemSettings() {}
}

private actor ControlledSubscriptionFetcher {
  private struct Pending {
    let value: String
    let continuation: CheckedContinuation<SubscriptionFetchResult, any Error>
  }
  private var pending: [Pending] = []
  private var announced: [String] = []
  private var waiters: [CheckedContinuation<String, Never>] = []

  func fetch(_ value: String, _ headers: SubscriptionHeaders) async throws
    -> SubscriptionFetchResult
  {
    if waiters.isEmpty {
      announced.append(value)
    } else {
      waiters.removeFirst().resume(returning: value)
    }
    return try await withCheckedThrowingContinuation { continuation in
      pending.append(Pending(value: value, continuation: continuation))
    }
  }

  func nextRequest() async -> String {
    if !announced.isEmpty { return announced.removeFirst() }
    return await withCheckedContinuation { waiters.append($0) }
  }

  func complete(_ value: String, with result: SubscriptionFetchResult) {
    let index = pending.firstIndex(where: { $0.value == value })!
    pending.remove(at: index).continuation.resume(returning: result)
  }

  func fail(_ value: String) {
    let index = pending.firstIndex(where: { $0.value == value })!
    pending.remove(at: index).continuation.resume(throwing: URLError(.cannotConnectToHost))
  }

  func requestCount() -> Int { pending.count + announced.count }
}

private actor ControlledHelperResponses {
  private struct Pending {
    let request: HelperRequest
    let continuation: CheckedContinuation<HelperResponse, any Error>
  }
  private var pending: [Pending] = []
  private var announced: [HelperRequest] = []
  private var waiters: [CheckedContinuation<HelperRequest, Never>] = []

  func send(_ request: HelperRequest) async throws -> HelperResponse {
    if waiters.isEmpty {
      announced.append(request)
    } else {
      waiters.removeFirst().resume(returning: request)
    }
    return try await withCheckedThrowingContinuation { continuation in
      pending.append(Pending(request: request, continuation: continuation))
    }
  }

  func nextRequest() async -> HelperRequest {
    if !announced.isEmpty { return announced.removeFirst() }
    return await withCheckedContinuation { waiters.append($0) }
  }

  func completeNext(_ response: HelperResponse) {
    pending.removeFirst().continuation.resume(returning: response)
  }

  func failNext(_ error: any Error = URLError(.timedOut)) {
    pending.removeFirst().continuation.resume(throwing: error)
  }

  func pendingCount() -> Int { pending.count + announced.count }
}

private actor HelperStatusSequence {
  private var responses: [HelperResponse]

  init(_ responses: [HelperResponse]) {
    self.responses = responses
  }

  func next() -> HelperResponse {
    responses.removeFirst()
  }
}

private actor FailingThenStoppedStatus {
  private var attempt = 0

  func send(_: HelperRequest, _: Int) throws -> HelperResponse {
    attempt += 1
    if attempt == 1 { throw URLError(.timedOut) }
    return HelperResponse(success: true, coreRunning: false, message: "observed stopped")
  }
}

private final class SaveFailureController {
  var attempts = 0
  var failOnAttempts: Set<Int>

  init(failOnAttempts: Set<Int>) {
    self.failOnAttempts = failOnAttempts
  }

  func save(_: ProfileLibrary) throws {
    attempts += 1
    if failOnAttempts.contains(attempts) {
      throw CocoaError(.fileWriteNoPermission)
    }
  }
}

private actor ControlledValidator {
  private var continuation: CheckedContinuation<HelperResponse, any Error>?
  private var waiter: CheckedContinuation<CoreProfile, Never>?
  private var announced: CoreProfile?

  func validate(_ profile: CoreProfile) async throws -> HelperResponse {
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: profile)
    } else {
      announced = profile
    }
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func nextProfile() async -> CoreProfile {
    if let announced {
      self.announced = nil
      return announced
    }
    return await withCheckedContinuation { waiter = $0 }
  }

  func complete() {
    continuation?.resume(
      returning: HelperResponse(success: true, coreRunning: false, message: "valid")
    )
    continuation = nil
  }

  func requestWasMade() -> Bool { announced != nil || continuation != nil }
}

private actor QueuedValidator {
  private struct Pending {
    let profile: CoreProfile
    let continuation: CheckedContinuation<HelperResponse, any Error>
  }

  private var announced: [CoreProfile] = []
  private var pending: [Pending] = []

  func validate(_ profile: CoreProfile) async throws -> HelperResponse {
    announced.append(profile)
    return try await withCheckedThrowingContinuation { continuation in
      pending.append(Pending(profile: profile, continuation: continuation))
    }
  }

  func nextProfile() async -> CoreProfile {
    if !announced.isEmpty { return announced.removeFirst() }
    while announced.isEmpty { await Task.yield() }
    return announced.removeFirst()
  }

  func complete(_ profile: CoreProfile) {
    guard let index = pending.firstIndex(where: { $0.profile == profile }) else {
      preconditionFailure("No pending validation for the requested profile")
    }
    pending.remove(at: index).continuation.resume(
      returning: HelperResponse(success: true, coreRunning: false, message: "valid")
    )
  }

  func completeNext() {
    pending.removeFirst().continuation.resume(
      returning: HelperResponse(success: true, coreRunning: false, message: "valid")
    )
  }
}

private func hardeningConnection(_ host: String) -> ManagedConnection {
  ManagedConnection(
    outbound: .shadowsocks(
      ShadowsocksProfile(
        server: host,
        port: 443,
        method: "aes-256-gcm",
        password: "test-password",
        displayName: host
      )
    )
  )
}

private func hardeningPayload(_ host: String) -> CoreProfile {
  .compatibility(VPNProfile(connections: [hardeningConnection(host)]))
}

private func hardeningServer(_ payload: CoreProfile?) -> String? {
  guard case .compatibility(let profile)? = payload,
    case .shadowsocks(let connection)? = profile.connections.first?.outbound
  else { return nil }
  return connection.server
}

private func hardeningApplicationBundle(_ name: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-" + name + "-" + UUID().uuidString, isDirectory: true)
  let bundle = root.appendingPathComponent(name + ".app", isDirectory: true)
  let executable = bundle.appendingPathComponent("Contents/MacOS/" + name)
  try FileManager.default.createDirectory(
    at: executable.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("#!/bin/sh\n".utf8).write(to: executable)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: executable.path
  )
  let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>\(name)</string>
      <key>CFBundleIdentifier</key><string>test.sbm.\(name.lowercased())</string>
      <key>CFBundleDisplayName</key><string>\(name)</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
    """
  try Data(plist.utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
  return bundle
}

private func hardeningResponse(
  coreRunning: Bool,
  revision: Int,
  activeProfileID: UUID? = nil,
  message: String = "status"
) throws -> HelperResponse {
  let response = HelperResponse(
    success: true,
    coreRunning: coreRunning,
    activeProfileID: activeProfileID,
    message: message
  )
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
  )
  object["helperRevision"] = revision
  return try JSONDecoder().decode(
    HelperResponse.self,
    from: JSONSerialization.data(withJSONObject: object)
  )
}

@MainActor
private func hardeningModel(
  library: ProfileLibrary,
  manager: SubscriptionManager = SubscriptionManager { _, _ in
    SubscriptionFetchResult(profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  },
  lifecycleSender: @escaping @Sendable (HelperRequest, Int) async throws -> HelperResponse = {
    _, _ in
    HelperResponse(success: true, coreRunning: false, message: "status")
  },
  runtimeSender: @escaping @Sendable (HelperRequest) async throws -> HelperResponse = { request in
    HelperResponse(
      success: true,
      coreRunning: request.action == .start,
      mode: request.mode ?? .rule,
      selectedNode: request.node ?? .auto,
      activeProfileID: request.profileID,
      message: "runtime"
    )
  },
  validator: @escaping @Sendable (CoreProfile) async throws -> HelperResponse = { _ in
    HelperResponse(success: true, coreRunning: false, message: "valid")
  },
  saver: @escaping (ProfileLibrary) throws -> Void = { _ in },
  runtimeStateReader: @escaping @Sendable () async throws -> HelperResponse = {
    HelperResponse(success: true, coreRunning: false, message: "observed")
  },
  latencySender: @escaping @Sendable (ProxyNodeID) async throws -> HelperResponse = { node in
    HelperResponse(
      success: true,
      coreRunning: true,
      delays: [NodeDelay(node: node, milliseconds: 20)],
      message: "latency"
    )
  }
) -> AppModel {
  let model = AppModel(
    helperService: ReadyHelperService(),
    subscriptionManager: manager,
    helperLifecycleSender: lifecycleSender,
    runtimeSender: runtimeSender,
    profileValidator: validator,
    profileLibraryLoader: { library },
    profileLibrarySaver: saver,
    runtimeStateReader: runtimeStateReader,
    latencySender: latencySender,
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  return model
}

@Test @MainActor func manualRefreshAttemptsEveryRemoteSourceExactlyOnce() async {
  let fetcher = ControlledSubscriptionFetcher()
  let urls = (1...3).map { "https://source\($0).example.test/list" }
  let profiles = [
    ManagedProfile(
      name: "A",
      sources: urls.prefix(2).map {
        ManagedSource(name: $0, value: $0, payload: hardeningPayload("old.example.test"))
      },
      payload: hardeningPayload("old.example.test")
    ),
    ManagedProfile(
      name: "B",
      sources: [
        ManagedSource(name: "B", value: urls[2], payload: hardeningPayload("old.example.test"))
      ],
      payload: hardeningPayload("old.example.test")
    ),
  ]
  let model = hardeningModel(
    library: ProfileLibrary(profiles: profiles, selectedProfileID: profiles[0].id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  var attempted: [String] = []
  for _ in urls {
    let requested = await fetcher.nextRequest()
    attempted.append(requested)
    await fetcher.complete(
      requested,
      with: SubscriptionFetchResult(
        profile: hardeningPayload("fresh.example.test"), skippedTransports: [:]
      )
    )
    #expect(urls.contains(requested))
  }
  while model.isRefreshing { await Task.yield() }
  #expect(Set(attempted) == Set(urls))
  #expect(attempted.count == urls.count)
  #expect(model.subscriptionStatus.contains("3 updated"))
}

@Test @MainActor func refreshCompletionCannotRecreateDeletedSourceOrProfile() async {
  let fetcher = ControlledSubscriptionFetcher()
  let profileID = UUID()
  let sourceID = UUID()
  let url = "https://source.example.test/list"
  let source = ManagedSource(
    id: sourceID,
    name: "Remote",
    value: url,
    payload: hardeningPayload("old.example.test")
  )
  let profile = ManagedProfile(
    id: profileID,
    name: "A",
    sources: [source],
    payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  #expect(await fetcher.nextRequest() == url)
  model.deleteSelectedSource()
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  while model.isRefreshing { await Task.yield() }
  #expect(model.profiles.first?.sources.isEmpty == true)

  let model2 = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )
  model2.refreshExternalState()
  #expect(await fetcher.nextRequest() == url)
  model2.deleteSelectedProfile()
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  while model2.isRefreshing { await Task.yield() }
  #expect(model2.profiles.isEmpty)
}

@Test @MainActor func repeatedManualRefreshCoalescesToOneSweep() async {
  let fetcher = ControlledSubscriptionFetcher()
  let url = "https://source.example.test/list"
  let profile = ManagedProfile(
    name: "A",
    sources: [
      ManagedSource(name: "Remote", value: url, payload: hardeningPayload("old.example.test"))
    ],
    payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  model.refreshExternalState()
  #expect(await fetcher.nextRequest() == url)
  #expect(await fetcher.requestCount() == 1)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  while model.isRefreshing { await Task.yield() }
  #expect(await fetcher.requestCount() == 0)
}

@Test @MainActor func failedRefreshCannotEraseNewerUnrelatedProfileEdit() async {
  let fetcher = ControlledSubscriptionFetcher()
  let url = "https://source.example.test/list"
  let profileA = ManagedProfile(
    name: "A",
    sources: [
      ManagedSource(name: "Remote", value: url, payload: hardeningPayload("old.example.test"))
    ],
    payload: hardeningPayload("old.example.test")
  )
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileA.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  #expect(await fetcher.nextRequest() == url)
  model.profiles[1].name = "B edited while A refreshed"
  await fetcher.fail(url)
  while model.isRefreshing { await Task.yield() }
  #expect(model.profiles[1].name == "B edited while A refreshed")
}

@Test @MainActor func newerRuntimeChoiceSupersedesRefreshApplyWithoutHanging() async {
  let fetcher = ControlledSubscriptionFetcher()
  let runtime = ControlledHelperResponses()
  let url = "https://source.example.test/list"
  let source = ManagedSource(
    name: "Remote", value: url, payload: hardeningPayload("old.example.test")
  )
  let profile = ManagedProfile(
    name: "A", sources: [source], payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    lifecycleSender: { _, _ in
      HelperResponse(
        success: true, coreRunning: true, activeProfileID: profile.id, message: "status")
    },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.refreshExternalState()
  #expect(await fetcher.nextRequest() == url)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  #expect(await runtime.nextRequest().action == .start)
  model.setRoutingMode(.global)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: true, activeProfileID: profile.id, message: "old")
  )
  let current = await runtime.nextRequest()
  #expect(current.action == .start)
  #expect(current.mode == .global)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      mode: .global,
      activeProfileID: profile.id,
      message: "current"
    )
  )
  while model.isRefreshing || model.runtimeApplyStatus == .applying { await Task.yield() }
  #expect(model.routingMode == .global)
  guard case .compatibility(let refreshed)? = model.profiles[0].payload else {
    Issue.record("Expected a refreshed compatibility profile")
    return
  }
  guard case .shadowsocks(let outbound)? = refreshed.connections.first?.outbound else {
    Issue.record("Expected the refreshed Shadowsocks connection")
    return
  }
  #expect(outbound.server == "fresh.example.test")
}

@Test @MainActor func routingValidationCannotOverwriteNewerPayload() async throws {
  let validator = ControlledValidator()
  let profileID = UUID()
  let profile = ManagedProfile(
    id: profileID,
    name: "A",
    payload: hardeningPayload("a.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    validator: { profile in try await validator.validate(profile) }
  )
  let policyURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-policy-\(UUID().uuidString).json")
  try Data(#"{"route":{"rules":[{"domain":["example.com"],"outbound":"direct"}]}}"#.utf8)
    .write(to: policyURL)
  defer { try? FileManager.default.removeItem(at: policyURL) }

  model.importRoutingPolicy(from: policyURL)
  _ = await validator.nextProfile()
  model.profiles[0].payload = hardeningPayload("b.example.test")
  await validator.complete()
  while model.isSyncing { await Task.yield() }
  #expect(model.profiles[0].payload == hardeningPayload("b.example.test"))
  #expect(model.lastError?.contains("changed while") == true)
}

@Test @MainActor func websiteMutationStaysBoundToSourceProfileAfterSelectionChange() async {
  let validator = QueuedValidator()
  let profileA = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id),
    validator: { profile in try await validator.validate(profile) }
  )

  model.websiteRoutingInput = "a.example"
  model.addWebsiteRoutingRule()
  let validatedA = await validator.nextProfile()
  model.selectProfile(profileB.id)
  model.websiteRoutingInput = "b.example"
  model.addWebsiteRoutingRule()
  let validatedB = await validator.nextProfile()

  await validator.complete(validatedA)
  await validator.complete(validatedB)
  while model.profiles[1].payload?.websiteRoutingRules.count != 1 { await Task.yield() }

  #expect(model.profiles[0].payload?.websiteRoutingRules.map(\.domain) == ["a.example"])
  #expect(model.profiles[1].payload?.websiteRoutingRules.map(\.domain) == ["b.example"])
  #expect(model.selectedProfileID == profileB.id)
}

@Test @MainActor func applicationMutationStaysBoundToSourceProfileAfterSelectionChange() async {
  let validator = QueuedValidator()
  let rule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let payloadA = CoreProfile.compatibility(
    VPNProfile(
      connections: [hardeningConnection("a.example.test")],
      applicationRoutingRules: [rule]
    )
  )
  let payloadB = CoreProfile.compatibility(
    VPNProfile(
      connections: [hardeningConnection("b.example.test")],
      applicationRoutingRules: [rule]
    )
  )
  let profileA = ManagedProfile(name: "A", payload: payloadA)
  let profileB = ManagedProfile(name: "B", payload: payloadB)
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id),
    validator: { profile in try await validator.validate(profile) }
  )

  model.setApplicationRoutingTarget(rule.id, target: .direct)
  let validatedA = await validator.nextProfile()
  model.selectProfile(profileB.id)
  model.setApplicationRoutingTarget(rule.id, target: .direct)
  let validatedB = await validator.nextProfile()

  await validator.complete(validatedA)
  await validator.complete(validatedB)
  while model.profiles[1].payload?.applicationRoutingRules.first?.target != .direct {
    await Task.yield()
  }

  #expect(model.profiles[0].payload?.applicationRoutingRules.first?.target == .direct)
  #expect(model.profiles[1].payload?.applicationRoutingRules.first?.target == .direct)
  #expect(model.selectedProfileID == profileB.id)
}

@Test @MainActor func sameProfileWebsiteActionsAreQueuedAndBothPersist() async {
  let validator = QueuedValidator()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    validator: { profile in try await validator.validate(profile) }
  )

  model.websiteRoutingInput = "first.example"
  model.addWebsiteRoutingRule()
  let first = await validator.nextProfile()
  model.websiteRoutingInput = "second.example"
  model.addWebsiteRoutingRule()

  await validator.complete(first)
  let second = await validator.nextProfile()
  await validator.complete(second)
  while model.websiteRoutingRules.count != 2 { await Task.yield() }

  #expect(model.websiteRoutingRules.map(\.domain) == ["first.example", "second.example"])
  #expect(model.websiteRoutingStatus.state == .saved)
  #expect(model.websiteRoutingInput.isEmpty)
}

@Test @MainActor func websiteAddClearsDraftWhenNewerWebsiteMutationSupersedesItsStatus() async {
  let validator = QueuedValidator()
  let existingRule = WebsiteRoutingRule(domain: "existing.example", target: .selectedProxy)
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("a.example.test")],
        websiteRoutingRules: [existingRule]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    validator: { profile in try await validator.validate(profile) }
  )

  model.websiteRoutingInput = "new.example"
  model.addWebsiteRoutingRule()
  let addCandidate = await validator.nextProfile()

  model.setWebsiteRoutingTarget(existingRule.id, target: .direct)
  await validator.complete(addCandidate)

  let targetCandidate = await validator.nextProfile()
  await validator.complete(targetCandidate)
  while model.websiteRoutingRules.count != 2
    || model.websiteRoutingRules.first(where: { $0.id == existingRule.id })?.target != .direct
  {
    await Task.yield()
  }

  #expect(model.websiteRoutingInput.isEmpty)
  #expect(model.websiteRoutingRules.map(\.domain) == ["existing.example", "new.example"])
}

@Test @MainActor func sameProfileWebsiteAndApplicationActionsAreQueued() async {
  let validator = QueuedValidator()
  let application = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("a.example.test")],
        applicationRoutingRules: [application]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    validator: { profile in try await validator.validate(profile) }
  )

  model.websiteRoutingInput = "site.example"
  model.addWebsiteRoutingRule()
  let website = await validator.nextProfile()
  model.setApplicationRoutingTarget(application.id, target: .direct)

  await validator.complete(website)
  let app = await validator.nextProfile()
  await validator.complete(app)
  while model.applicationRoutingRules.first?.target != .direct { await Task.yield() }

  #expect(model.websiteRoutingRules.map(\.domain) == ["site.example"])
  #expect(model.applicationRoutingRules.first?.target == .direct)
}

@Test @MainActor func newerSameProfileRoutingStatePreventsOlderRuntimeRollback() async {
  let validator = QueuedValidator()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) },
    validator: { profile in try await validator.validate(profile) }
  )
  model.coreRunning = true

  model.websiteRoutingInput = "first.example"
  model.addWebsiteRoutingRule()
  let first = await validator.nextProfile()
  await validator.complete(first)
  #expect(await runtime.nextRequest().action == .start)

  model.websiteRoutingInput = "second.example"
  model.addWebsiteRoutingRule()
  let second = await validator.nextProfile()
  await validator.complete(second)

  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "old candidate failed"
    )
  )
  #expect(await runtime.nextRequest().action == .start)
  #expect(model.websiteRoutingRules.map(\.domain) == ["first.example", "second.example"])
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: true, activeProfileID: profile.id, message: "latest")
  )
  while model.runtimeApplyStatus == .applying { await Task.yield() }
  #expect(model.websiteRoutingRules.count == 2)
}

@Test @MainActor func routingImportRemainsBoundToSourceProfileAfterSelectionChange() async throws {
  let validator = QueuedValidator()
  let profileA = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id),
    validator: { profile in try await validator.validate(profile) }
  )
  let policyURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-routing-bound-" + UUID().uuidString + ".json")
  try Data(
    #"{"route":{"rules":[{"domain_suffix":[".example"],"action":"route","outbound":"direct"}]}}"#
      .utf8
  ).write(to: policyURL)
  defer { try? FileManager.default.removeItem(at: policyURL) }

  model.importRoutingPolicy(from: policyURL)
  let validatedA = await validator.nextProfile()
  model.selectProfile(profileB.id)
  await validator.complete(validatedA)
  while model.isSyncing { await Task.yield() }

  let importedPolicy: RoutingPolicy?
  let untouchedPolicy: RoutingPolicy?
  if case .compatibility(let profile)? = model.profiles[0].payload {
    importedPolicy = profile.routingPolicy
  } else {
    importedPolicy = nil
  }
  if case .compatibility(let profile)? = model.profiles[1].payload {
    untouchedPolicy = profile.routingPolicy
  } else {
    untouchedPolicy = nil
  }
  #expect(importedPolicy != nil)
  #expect(untouchedPolicy == nil)
  #expect(model.selectedProfileID == profileB.id)
}

@Test @MainActor func routingImportDoesNotLeakSyncStateIfSourceProfileDisappearsBeforeQueueing()
  async throws
{
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  )
  let policyURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBM-routing-deleted-" + UUID().uuidString + ".json")
  try Data(
    #"{"route":{"rules":[{"domain_suffix":[".example"],"action":"route","outbound":"direct"}]}}"#
      .utf8
  ).write(to: policyURL)
  defer { try? FileManager.default.removeItem(at: policyURL) }

  model.importRoutingPolicy(from: policyURL)
  #expect(model.isSyncing)
  model.deleteSelectedProfile()

  for _ in 0..<64 where model.isSyncing {
    await Task.yield()
  }

  #expect(model.profiles.isEmpty)
  #expect(!model.isSyncing)
}

@Test @MainActor func refreshUsesOnlyCurrentProfilesOwnBeforeAfterSnapshots() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let validator = QueuedValidator()
  let runtime = ControlledHelperResponses()
  let urlA = "https://refresh-a.example.test/list"
  let urlB = "https://refresh-b.example.test/list"
  let oldA = hardeningPayload("old-source-a.example.test")
  let oldB = hardeningPayload("old-source-b.example.test")
  let profileA = ManagedProfile(
    name: "A",
    sources: [ManagedSource(name: "A", value: urlA, payload: oldA)],
    payload: hardeningPayload("old-a.example.test")
  )
  let profileB = ManagedProfile(
    name: "B",
    sources: [ManagedSource(name: "B", value: urlB, payload: oldB)],
    payload: hardeningPayload("old-b.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(
      profiles: [profileA, profileB], selectedProfileID: profileA.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    runtimeSender: { request in try await runtime.send(request) },
    validator: { profile in try await validator.validate(profile) }
  )

  model.refreshExternalState()
  #expect(await fetcher.nextRequest() == urlA)
  await fetcher.complete(
    urlA,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:]
    )
  )
  let validatedA = await validator.nextProfile()
  await validator.complete(validatedA)

  #expect(await fetcher.nextRequest() == urlB)
  model.selectProfile(profileB.id)
  model.coreRunning = true
  await fetcher.complete(
    urlB,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-b.example.test"), skippedTransports: [:]
    )
  )
  let validatedB = await validator.nextProfile()
  await validator.complete(validatedB)

  let automaticRequest = await runtime.nextRequest()
  #expect(automaticRequest.profileID == profileA.id)
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileA.id, message: "automatic")
  )
  let request = await runtime.nextRequest()
  #expect(request.profileID == profileB.id)
  guard case .compatibility = request.profile else {
    Issue.record("Expected a compatibility profile in the refresh activation")
    return
  }
  #expect(hardeningServer(request.profile) == "fresh-b.example.test")
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profileB.id, message: "active")
  )
  while model.isRefreshing || model.runtimeApplyStatus == .applying { await Task.yield() }
  #expect(hardeningServer(model.profiles[0].payload) == "fresh-a.example.test")
  #expect(hardeningServer(model.profiles[1].payload) == "fresh-b.example.test")
}

@Test @MainActor func websiteAddPreservesInvalidDraftAndClearsAfterSuccess() async {
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  )

  model.websiteRoutingInput = "bad..example"
  model.addWebsiteRoutingRule()
  #expect(model.websiteRoutingInput == "bad..example")
  #expect(model.websiteRoutingStatus.state == .failed)
  #expect(model.websiteRoutingStatus.message?.contains("valid hostname") == true)

  model.websiteRoutingInput = "valid.example"
  model.addWebsiteRoutingRule()
  while model.websiteRoutingRules.isEmpty { await Task.yield() }
  #expect(model.websiteRoutingInput.isEmpty)
  #expect(model.websiteRoutingStatus.state == .saved)
}

@Test @MainActor func applicationChangePreservesRuleIdentityAndRejectsExactDuplicate() async throws
{
  let firstBundle = try hardeningApplicationBundle("First")
  let replacementBundle = try hardeningApplicationBundle("Replacement")
  let duplicateBundle = try hardeningApplicationBundle("Duplicate")
  defer {
    try? FileManager.default.removeItem(at: firstBundle.deletingLastPathComponent())
    try? FileManager.default.removeItem(at: replacementBundle.deletingLastPathComponent())
    try? FileManager.default.removeItem(at: duplicateBundle.deletingLastPathComponent())
  }
  let rule = ApplicationRoutingRule(
    displayName: "First",
    bundlePath: firstBundle.path,
    executablePath: firstBundle.appendingPathComponent("Contents/MacOS/First").path,
    target: .reject
  )
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("a.example.test")],
        applicationRoutingRules: [rule]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  )

  let replacementExecutable =
    replacementBundle
    .appendingPathComponent("Contents/MacOS/Replacement")
  #expect(
    try ApplicationBundleResolver.resolve(replacementBundle).executableURL == replacementExecutable
  )
  model.replaceApplicationRoutingRule(rule.id, from: replacementBundle)
  for _ in 0..<1_000 {
    if model.applicationRoutingRules.first?.executablePath == replacementExecutable.path {
      break
    }
    await Task.yield()
  }
  #expect(model.applicationRoutingRules.first?.executablePath == replacementExecutable.path)
  #expect(model.applicationRoutingRules.first?.id == rule.id)
  #expect(model.applicationRoutingRules.first?.target == .reject)

  let duplicateRule = ApplicationRoutingRule(
    displayName: "Duplicate",
    bundlePath: duplicateBundle.path,
    executablePath: duplicateBundle.appendingPathComponent("Contents/MacOS/Duplicate").path,
    target: .direct
  )
  guard case .compatibility(let current)? = model.profiles.first?.payload else {
    Issue.record("Expected a compatibility profile")
    return
  }
  model.profiles[0].payload = .compatibility(
    VPNProfile(
      connections: current.connections,
      applicationRoutingRules: [
        model.applicationRoutingRules[0], duplicateRule,
      ]
    )
  )
  model.replaceApplicationRoutingRule(rule.id, from: duplicateBundle)
  for _ in 0..<1_000 {
    if model.applicationRoutingStatus.state != .applying { break }
    await Task.yield()
  }
  #expect(model.applicationRoutingStatus.state == .failed)
  #expect(model.lastError?.contains("already has a routing rule") == true)
  #expect(model.applicationRoutingRules.first?.id == rule.id)
  #expect(model.applicationRoutingRules.first?.target == .reject)
}

@Test @MainActor func failedDeleteDoesNotRestoreOverNewerWebsiteMutation() async {
  let runtime = ControlledHelperResponses()
  let oldRule = WebsiteRoutingRule(domain: "old.example", target: .selectedProxy)
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("a.example.test")],
        websiteRoutingRules: [oldRule]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.removeWebsiteRoutingRule(oldRule.id)
  #expect(await runtime.nextRequest().action == .start)
  model.websiteRoutingInput = "new.example"
  model.addWebsiteRoutingRule()

  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "delete candidate failed"
    )
  )
  #expect(await runtime.nextRequest().action == .start)
  #expect(model.websiteRoutingRules.map(\.domain) == ["new.example"])
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "new active"
    )
  )
}

@Test @MainActor func stoppedStatusRestoresPersistedNodeForSelectedProfile() async {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let node = ProxyNodeID(rawValue: "node-persisted")
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(id: node, outbound: hardeningConnection("a.example.test").outbound)
      ])
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  _ = await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      mode: .rule,
      selectedNode: node,
      activeProfileID: profile.id,
      message: "stopped with persisted node"
    )
  )
  while model.helperStatus != "stopped with persisted node" { await Task.yield() }
  #expect(model.selectedNodeID == node)

  model.setCoreEnabled(true)
  let request = await runtime.nextRequest()
  #expect(request.action == .start)
  #expect(request.node == node)
}

@Test @MainActor func stoppedStatusDoesNotRestoreNodeMissingFromCurrentProfile() async {
  let status = ControlledHelperResponses()
  let persistedNode = ProxyNodeID(rawValue: "node-removed")
  let currentNode = ProxyNodeID(rawValue: "node-current")
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(
          id: currentNode,
          outbound: hardeningConnection("current.example.test").outbound
        )
      ])
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { request, _ in try await status.send(request) }
  )

  model.refresh()
  _ = await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: false,
      mode: .rule,
      selectedNode: persistedNode,
      activeProfileID: profile.id,
      message: "stopped with stale node"
    )
  )
  while model.helperStatus != "stopped with stale node" { await Task.yield() }

  #expect(model.selectedNodeID == .auto)
}

@Test @MainActor func staleStatusCannotRewriteNewerDesiredModeOrNode() async {
  let status = ControlledHelperResponses()
  let node = ProxyNodeID(rawValue: "node-current")
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(id: node, outbound: hardeningConnection("a.example.test").outbound)
      ])
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { request, _ in try await status.send(request) }
  )
  model.refresh()
  _ = await status.nextRequest()
  model.setRoutingMode(.global)
  model.setSelectedNode(node)
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      mode: .rule,
      selectedNode: .auto,
      activeProfileID: profile.id,
      message: "old status"
    )
  )
  while model.isBusy { await Task.yield() }
  #expect(model.routingMode == .global)
  #expect(model.selectedNodeID == node)
}

@Test @MainActor func disconnectBeforeQuitRequiresProvenStoppedCoreAndCanRetry() async {
  let responses = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await responses.send(request) }
  )
  model.coreRunning = true

  let first = Task { await model.disconnectBeforeQuit() }
  #expect(await responses.nextRequest().action == .shutdown)
  await responses.completeNext(
    HelperResponse(success: false, coreRunning: true, message: "stop failed")
  )
  #expect(await first.value == false)
  #expect(model.connectionPresentation == .failed(previousRuntimePreserved: true))

  let retry = Task { await model.disconnectBeforeQuit() }
  #expect(await responses.nextRequest().action == .shutdown)
  await responses.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  #expect(await retry.value)
}

@Test @MainActor func disconnectBeforeQuitRejectsRunningCoreAndIPCFailure() async {
  let responses = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await responses.send(request) }
  )
  model.coreRunning = true

  let stillRunning = Task { await model.disconnectBeforeQuit() }
  #expect(await responses.nextRequest().action == .shutdown)
  await responses.completeNext(
    HelperResponse(success: true, coreRunning: true, message: "still running")
  )
  #expect(await stillRunning.value == false)

  let timeout = Task { await model.disconnectBeforeQuit() }
  #expect(await responses.nextRequest().action == .shutdown)
  await responses.failNext()
  #expect(await timeout.value == false)
}

@Test @MainActor func alreadyDisconnectedQuitNeedsNoHelperRequest() async {
  let responses = ControlledHelperResponses()
  let model = hardeningModel(
    library: .empty,
    runtimeSender: { request in try await responses.send(request) }
  )
  model.coreRunning = false
  #expect(await model.disconnectBeforeQuit())
  #expect(await responses.pendingCount() == 0)
}

@Test @MainActor func recentErrorsAreBoundedDeduplicatedClearableAndRedacted() {
  let sensitiveURL = "https://private.example.test/subscription/secret"
  let source = ManagedSource(name: "Remote", value: sensitiveURL)
  let profile = ManagedProfile(
    name: "A", sources: [source], payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
  )

  model.lastError = "Failed to fetch \(sensitiveURL)"
  model.lastError = "Failed to fetch \(sensitiveURL)"
  #expect(model.recentErrors.count == 1)
  #expect(model.recentErrors[0].repeatCount == 2)
  #expect(!model.recentErrors[0].message.contains(sensitiveURL))

  for index in 0..<55 { model.lastError = "Synthetic failure \(index)" }
  #expect(model.recentErrors.count == 50)
  let snapshot = model.supportSnapshot
  #expect(!snapshot.text.contains(sensitiveURL))
  #expect(!snapshot.jsonText().contains(sensitiveURL))
  model.clearRecentErrors()
  #expect(model.recentErrors.isEmpty)
}

@Test @MainActor func latencyIsCancelledBeforeDisconnectBecomesNextRuntimeAction() async {
  let status = ControlledHelperResponses()
  let latency = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let node = ProxyNodeID(rawValue: "node-latency")
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(id: node, outbound: hardeningConnection("a.example.test").outbound)
      ])
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) },
    latencySender: { node in try await latency.send(HelperRequest(action: .testLatency, node: node))
    }
  )
  model.refresh()
  _ = await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "running"
    )
  )
  while model.helperStatus != "running" { await Task.yield() }

  model.testLatency()
  #expect(await latency.nextRequest().action == .testLatency)
  model.setCoreEnabled(false)
  #expect(await runtime.nextRequest().action == .stop)
  await latency.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      delays: [NodeDelay(node: node, milliseconds: 10)],
      message: "stale latency"
    )
  )
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  while model.runtimeApplyStatus == .applying { await Task.yield() }
  #expect(model.connectionPresentation == .disconnected)
  #expect(!model.latencyTestInProgress)
}

@Test @MainActor func connectionPresentationOrdersConnectThenImmediateDisconnect() async {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  #expect(await runtime.nextRequest().action == .start)
  #expect(model.connectionPresentation == .connecting)
  model.setCoreEnabled(true)
  #expect(await runtime.pendingCount() == 1)

  model.setCoreEnabled(false)
  #expect(model.connectionPresentation == .disconnecting)
  await runtime.completeNext(
    HelperResponse(
      success: true, coreRunning: true, activeProfileID: profile.id, message: "started")
  )
  #expect(await runtime.nextRequest().action == .stop)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  while model.runtimeApplyStatus == .applying { await Task.yield() }
  #expect(model.connectionPresentation == .disconnected)
}

@Test @MainActor func staleWebsiteApplyCannotRestoreAnOlderRule() async throws {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true
  model.websiteRoutingInput = "stepik.org"
  model.addWebsiteRoutingRule()
  #expect(await runtime.nextRequest().action == .start)
  let ruleID = try #require(model.websiteRoutingRules.first?.id)

  model.setWebsiteRoutingTarget(ruleID, target: .direct)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "old apply failed"
    )
  )
  #expect(await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "new apply active"
    )
  )
  while model.runtimeApplyStatus == .applying { await Task.yield() }
  #expect(model.websiteRoutingRules.first?.target == .direct)
}

@Test @MainActor func previousHelperRevisionIsRejectedAndCurrentRevisionIsAccepted() async throws {
  let status = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { request, _ in try await status.send(request) }
  )

  model.refresh()
  _ = await status.nextRequest()
  await status.completeNext(
    try hardeningResponse(
      coreRunning: false,
      revision: HelperConstants.helperRevision - 1
    )
  )
  while model.helperStatus != "Helper update required" { await Task.yield() }
  #expect(!model.helperReachable)
  #expect(model.helperStatus == "Helper update required")

  let currentStatus = ControlledHelperResponses()
  let currentModel = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { request, _ in try await currentStatus.send(request) }
  )
  currentModel.refresh()
  _ = await currentStatus.nextRequest()
  await currentStatus.completeNext(
    try hardeningResponse(coreRunning: false, revision: HelperConstants.helperRevision)
  )
  while !currentModel.helperReachable { await Task.yield() }
  #expect(currentModel.helperRevision == HelperConstants.helperRevision)

  let runtime = ControlledHelperResponses()
  let staleModel = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  staleModel.helperRevision = HelperConstants.helperRevision - 1
  staleModel.setCoreEnabled(true)
  #expect(await runtime.pendingCount() == 0)
  #expect(staleModel.lastError?.contains("repair") == true)
}

@Test @MainActor func disconnectRemainsAuthoritativeAcrossModeNodeWebsiteAndApplicationEdits()
  async throws
{
  let runtime = ControlledHelperResponses()
  let node = ProxyNodeID(rawValue: "node-a")
  let application = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [
          ManagedConnection(id: node, outbound: hardeningConnection("a.example.test").outbound)
        ],
        applicationRoutingRules: [application]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.setCoreEnabled(false)
  #expect(await runtime.nextRequest().action == .stop)
  model.setRoutingMode(.global)
  model.setSelectedNode(node)
  model.websiteRoutingInput = "stepik.org"
  model.addWebsiteRoutingRule()
  while model.websiteRoutingRules.isEmpty { await Task.yield() }
  model.setApplicationRoutingTarget(application.id, target: .direct)
  while model.applicationRoutingRules.first?.target != .direct {
    await Task.yield()
  }
  #expect(await runtime.pendingCount() == 1)

  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  while model.runtimeApplyStatus == .applying { await Task.yield() }
  #expect(model.coreIsKnownStopped)
  #expect(model.websiteRoutingRules.first?.domain == "stepik.org")
  #expect(model.applicationRoutingRules.first?.target == .direct)
  #expect(model.routingMode == .global)
  #expect(await runtime.pendingCount() == 0)

  model.setRoutingMode(.direct)
  model.setSelectedNode(.auto)
  #expect(model.routingMode == .direct)
  #expect(model.selectedNodeID == .auto)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func explicitDisconnectSuppressesRefreshAndRepairAutoConnectUntilExplicitConnect()
  async throws
{
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  _ = await status.nextRequest()
  await status.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "already running"
    )
  )
  while !model.coreRunning { await Task.yield() }

  model.setCoreEnabled(false)
  #expect(await runtime.nextRequest().action == .stop)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  while !model.coreIsKnownStopped { await Task.yield() }

  model.refresh()
  _ = await status.nextRequest()
  await status.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "still stopped")
  )
  while model.helperStatus != "still stopped" { await Task.yield() }
  #expect(await runtime.pendingCount() == 0)

  model.repairHelper()
  _ = await status.nextRequest()
  await status.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "repaired")
  )
  while model.helperSetupInProgress { await Task.yield() }
  #expect(await runtime.pendingCount() == 0)

  model.setCoreEnabled(true)
  #expect(await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "explicitly connected"
    )
  )
}

@Test @MainActor func disconnectInFlightAllowsProfileSelectionWithoutStartingIt() async {
  let runtime = ControlledHelperResponses()
  let profileA = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let profileB = ManagedProfile(name: "B", payload: hardeningPayload("b.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profileA, profileB], selectedProfileID: profileA.id),
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.setCoreEnabled(false)
  #expect(await runtime.nextRequest().action == .stop)
  model.selectProfile(profileB.id)
  #expect(model.selectedProfileID == profileB.id)
  #expect(await runtime.pendingCount() == 1)

  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  while model.runtimeApplyStatus == .applying { await Task.yield() }
  #expect(model.coreIsKnownStopped)
  #expect(model.selectedProfileID == profileB.id)
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func eligibleStartupAutoConnectOccursOnlyOnce() async {
  let status = ControlledHelperResponses()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { request, _ in try await status.send(request) },
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.refresh()
  _ = await status.nextRequest()
  await status.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "eligible")
  )
  #expect(await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: false,
      activeProfileID: nil,
      message: "start failed"
    )
  )
  while model.runtimeApplyStatus == .applying { await Task.yield() }

  model.refresh()
  _ = await status.nextRequest()
  await status.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "still eligible")
  )
  while model.isStatusRefreshInProgress { await Task.yield() }
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func shutdownPendingSupersessionCompletesFalseAndRetryWorks() async {
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { request in try await runtime.send(request) }
  )

  model.setCoreEnabled(true)
  #expect(await runtime.nextRequest().action == .start)
  let shutdown = Task { await model.disconnectBeforeQuit() }
  while model.connectionPresentation != .disconnecting { await Task.yield() }
  model.setCoreEnabled(true)
  #expect(await shutdown.value == false)

  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "stale start"
    )
  )
  #expect(await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "current start"
    )
  )
  while model.runtimeApplyStatus == .applying { await Task.yield() }

  let retry = Task { await model.disconnectBeforeQuit() }
  #expect(await runtime.nextRequest().action == .shutdown)
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "shutdown")
  )
  #expect(await retry.value)
}

@Test @MainActor func helperFailureMakesCoreUnknownAndQuitRequiresProvenStop() async {
  let status = FailingThenStoppedStatus()
  let runtime = ControlledHelperResponses()
  let profile = ManagedProfile(name: "A", payload: hardeningPayload("a.example.test"))
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { request, timeout in try await status.send(request, timeout) },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.refresh()
  while model.helperReachable { await Task.yield() }
  while model.isStatusRefreshInProgress { await Task.yield() }
  #expect(model.observedCoreState == .unknown)
  #expect(model.connectionPresentation == .unknown)
  #expect(!model.supportSnapshot.statusText.contains("Core: stopped"))

  let quit = Task { await model.disconnectBeforeQuit() }
  #expect(await quit.value == false)
  #expect(await runtime.pendingCount() == 0)

  model.helperReachable = true
  model.refresh()
  while !model.coreIsKnownStopped { await Task.yield() }
  #expect(await model.disconnectBeforeQuit())
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func refreshSkipsDeletedChangedAndNewSourcesBeforeFetch() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let urlA = "https://a.example.test/list"
  let urlB = "https://b.example.test/list"
  let sourceA = ManagedSource(
    name: "A", value: urlA, payload: hardeningPayload("old-a.example.test")
  )
  let sourceB = ManagedSource(
    name: "B", value: urlB, payload: hardeningPayload("old-b.example.test")
  )
  let profile = ManagedProfile(
    name: "A",
    sources: [sourceA, sourceB],
    payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) }
  )

  model.refreshExternalState()
  #expect(await fetcher.nextRequest() == urlA)
  model.profiles[0].sources.removeAll(where: { $0.id == sourceB.id })
  model.profiles[0].sources.append(
    ManagedSource(
      name: "New",
      value: "https://new.example.test/list",
      payload: hardeningPayload("new.example.test")
    )
  )
  await fetcher.complete(
    urlA,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:])
  )
  while model.isRefreshing { await Task.yield() }
  #expect(await fetcher.requestCount() == 0)

  let fetcher2 = ControlledSubscriptionFetcher()
  let model2 = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher2.fetch(value, headers) }
  )
  model2.refreshExternalState()
  #expect(await fetcher2.nextRequest() == urlA)
  let bIndex = try #require(model2.profiles[0].sources.firstIndex(where: { $0.id == sourceB.id }))
  model2.profiles[0].sources[bIndex].value = "https://changed.example.test/list"
  model2.profiles[0].sources[bIndex].headers = SubscriptionHeaders(
    userAgent: "Changed/Test",
    appVersion: "9.9",
    deviceOS: "ChangedOS",
    hardwareID: "changed-hwid"
  )
  model2.profiles[0].sources[bIndex].excludeRegex = "changed"
  await fetcher2.complete(
    urlA,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:])
  )
  while model2.isRefreshing { await Task.yield() }
  #expect(await fetcher2.requestCount() == 0)
}

@Test @MainActor func refreshApplyFailureKeepsNewerSameProfileWebsiteEdit() async throws {
  let fetcher = ControlledSubscriptionFetcher()
  let runtime = ControlledHelperResponses()
  let urlA = "https://a.example.test/list"
  let urlB = "https://b.example.test/list"
  let application = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let initialPayload = CoreProfile.compatibility(
    VPNProfile(
      connections: [hardeningConnection("old.example.test")],
      applicationRoutingRules: [application]
    )
  )
  let profile = ManagedProfile(
    name: "A",
    sources: [
      ManagedSource(name: "A", value: urlA, payload: hardeningPayload("old-a.example.test")),
      ManagedSource(name: "B", value: urlB, payload: hardeningPayload("old-b.example.test")),
    ],
    payload: initialPayload
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    lifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        message: "running"
      )
    },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.refreshExternalState()
  #expect(await fetcher.nextRequest() == urlA)
  await fetcher.complete(
    urlA,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-a.example.test"), skippedTransports: [:])
  )
  #expect(await fetcher.nextRequest() == urlB)

  model.websiteRoutingInput = "stepik.org"
  model.addWebsiteRoutingRule()
  #expect(await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "website active"
    )
  )
  while model.runtimeApplyStatus == .applying { await Task.yield() }

  model.setApplicationRoutingTarget(application.id, target: .direct)
  #expect(await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "application active"
    )
  )
  while model.runtimeApplyStatus == .applying { await Task.yield() }

  await fetcher.complete(
    urlB,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh-b.example.test"), skippedTransports: [:])
  )
  #expect(await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: false,
      coreRunning: true,
      activeProfileID: profile.id,
      message: "candidate failed; previous runtime preserved"
    )
  )
  while model.isRefreshing || model.runtimeApplyStatus == .applying { await Task.yield() }
  #expect(model.websiteRoutingRules.map(\.domain) == ["stepik.org"])
  #expect(model.applicationRoutingRules.first?.target == .direct)
  #expect(model.subscriptionStatus.contains("Sources saved; apply failed"))
}

@Test @MainActor func rollbackPersistenceFailureIsVisibleAndKeepsDurableCommittedState() async {
  let saver = SaveFailureController(failOnAttempts: [2])
  let rule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let profile = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("a.example.test")],
        applicationRoutingRules: [rule]
      )
    )
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    runtimeSender: { _ in
      HelperResponse(
        success: false,
        coreRunning: true,
        activeProfileID: profile.id,
        message: "apply failed"
      )
    },
    saver: { try saver.save($0) }
  )
  model.coreRunning = true
  model.setApplicationRoutingTarget(rule.id, target: .direct)
  while model.runtimeApplyStatus != .failed { await Task.yield() }

  #expect(saver.attempts == 2)
  #expect(model.applicationRoutingRules.first?.target == .direct)
  #expect(model.lastError?.contains("Rollback could not be saved") == true)
  #expect(model.recentErrors.last?.message.contains("Rollback could not be saved") == true)
}

@Test @MainActor func addProfileSaveFailureLeavesNoPhantomSelection() {
  let saver = SaveFailureController(failOnAttempts: [1])
  let model = hardeningModel(library: .empty, saver: { try saver.save($0) })
  model.addProfile()
  #expect(model.profiles.isEmpty)
  #expect(model.selectedProfileID == nil)
  #expect(model.lastError != nil)
}

@Test @MainActor func explicitDisconnectCancelsOlderRefreshBeforeValidationOrApply() async {
  let fetcher = ControlledSubscriptionFetcher()
  let validator = ControlledValidator()
  let runtime = ControlledHelperResponses()
  let url = "https://source.example.test/list"
  let profile = ManagedProfile(
    name: "A",
    sources: [
      ManagedSource(name: "Remote", value: url, payload: hardeningPayload("old.example.test"))
    ],
    payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    lifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        message: "running"
      )
    },
    runtimeSender: { request in try await runtime.send(request) },
    validator: { profile in try await validator.validate(profile) }
  )
  model.coreRunning = true

  model.refreshExternalState()
  #expect(await fetcher.nextRequest() == url)
  model.setCoreEnabled(false)
  #expect(await runtime.nextRequest().action == .stop)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  await runtime.completeNext(
    HelperResponse(success: true, coreRunning: false, message: "stopped")
  )
  while model.isRefreshing || model.runtimeApplyStatus == .applying { await Task.yield() }
  #expect(!(await validator.requestWasMade()))
  #expect(await runtime.pendingCount() == 0)
}

@Test @MainActor func connectedRefreshKeepsKnownGoodRuntimeWhenActivationIsDeferred() async {
  let fetcher = ControlledSubscriptionFetcher()
  let runtime = ControlledHelperResponses()
  let url = "https://source.example.test/list"
  let profile = ManagedProfile(
    name: "A",
    sources: [
      ManagedSource(name: "Remote", value: url, payload: hardeningPayload("old.example.test"))
    ],
    payload: hardeningPayload("old.example.test")
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    manager: SubscriptionManager { value, headers in try await fetcher.fetch(value, headers) },
    lifecycleSender: { _, _ in
      HelperResponse(
        success: true,
        coreRunning: true,
        activeProfileID: profile.id,
        message: "running"
      )
    },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.refreshExternalState()
  #expect(await fetcher.nextRequest() == url)
  await fetcher.complete(
    url,
    with: SubscriptionFetchResult(
      profile: hardeningPayload("fresh.example.test"), skippedTransports: [:])
  )
  #expect(await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profile.id,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  while model.runtimeApplyStatus != .reconnectRequired { await Task.yield() }

  #expect(model.coreRunning)
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")
  #expect(model.subscriptionStatus != DeferredRuntimeApplyPresentation.changesReadyToApply)
  #expect(hardeningServer(model.profiles.first?.payload) == "fresh.example.test")
}

@Test @MainActor func relaunchStatusRestoresDeferredRuntimeFromHelperMarker() async {
  let profile = ManagedProfile(
    name: "A",
    payload: hardeningPayload("active.example.test")
  )
  let deferredResponse = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: profile.id,
    runtimeOutcome: .reconnectRequired,
    message: HelperRuntimeOutcome.reconnectRequired.userMessage!
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { _, _ in deferredResponse },
    runtimeStateReader: { deferredResponse }
  )

  model.refresh()
  while model.runtimeApplyStatus != .reconnectRequired { await Task.yield() }

  #expect(model.coreRunning)
  #expect(model.selectedProfileID == profile.id)
  #expect(model.deferredRuntimeApplyPresentation?.headline == "Changes ready to apply")
  #expect(model.subscriptionStatus != DeferredRuntimeApplyPresentation.changesReadyToApply)
}

@Test @MainActor func relaunchAfterSuccessfulReconnectDoesNotRestoreStalePendingState() async {
  let profile = ManagedProfile(
    name: "A",
    payload: hardeningPayload("active.example.test")
  )
  let appliedResponse = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: profile.id,
    message: "active"
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { _, _ in appliedResponse },
    runtimeStateReader: { appliedResponse }
  )

  model.refresh()
  while model.isStatusRefreshInProgress { await Task.yield() }

  #expect(model.runtimeApplyStatus == .active)
  #expect(model.deferredRuntimeApplyPresentation == nil)
}

@Test @MainActor func authoritativeAppliedObservationClearsDeferredRuntimeState() async {
  let profile = ManagedProfile(
    name: "A",
    payload: hardeningPayload("active.example.test")
  )
  let deferredResponse = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: profile.id,
    runtimeOutcome: .reconnectRequired,
    message: HelperRuntimeOutcome.reconnectRequired.userMessage!
  )
  let appliedResponse = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: profile.id,
    message: "applied"
  )
  let statuses = HelperStatusSequence([deferredResponse, appliedResponse])
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profile.id),
    lifecycleSender: { _, _ in await statuses.next() }
  )

  model.refresh()
  while model.runtimeApplyStatus != .reconnectRequired { await Task.yield() }
  model.refresh()
  while model.isStatusRefreshInProgress { await Task.yield() }

  #expect(model.runtimeApplyStatus == .active)
  #expect(model.deferredRuntimeApplyPresentation == nil)
  #expect(model.coreRunning)
}

@Test @MainActor
func authoritativeStatusAfterDeferredRoutingMutationDoesNotResurrectPendingPresentation() async {
  let profileID = UUID()
  let rule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    target: .selectedProxy
  )
  let profile = ManagedProfile(
    id: profileID,
    name: "Applications",
    payload: .compatibility(
      VPNProfile(
        connections: [hardeningConnection("active.example.test")],
        applicationRoutingRules: [rule]
      )
    )
  )
  let runtime = ControlledHelperResponses()
  let applied = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: profileID,
    runtimeOutcome: .applied,
    message: "active"
  )
  let model = hardeningModel(
    library: ProfileLibrary(profiles: [profile], selectedProfileID: profileID),
    lifecycleSender: { _, _ in applied },
    runtimeSender: { request in try await runtime.send(request) }
  )
  model.coreRunning = true

  model.setApplicationRoutingTarget(rule.id, target: .direct)
  #expect(await runtime.nextRequest().action == .start)
  await runtime.completeNext(
    HelperResponse(
      success: true,
      coreRunning: true,
      activeProfileID: profileID,
      runtimeOutcome: .reconnectRequired,
      message: HelperRuntimeOutcome.reconnectRequired.userMessage!
    )
  )
  while model.runtimeApplyStatus != .reconnectRequired { await Task.yield() }
  #expect(model.applicationRoutingStatus.state == .reconnectRequired)

  model.websiteRoutingInput = "bad..example"
  model.addWebsiteRoutingRule()
  #expect(model.websiteRoutingStatus.state == .failed)
  #expect(model.websiteRoutingStatus.message?.contains("valid hostname") == true)

  model.refresh()
  while model.isStatusRefreshInProgress { await Task.yield() }

  #expect(model.runtimeApplyStatus == .active)
  #expect(model.deferredRuntimeApplyPresentation == nil)
  #expect(model.applicationRoutingStatus.state == .saved)
  #expect(model.applicationRoutingStatus.message == nil)
  #expect(model.websiteRoutingStatus.state == .failed)
  #expect(model.websiteRoutingStatus.message?.contains("valid hostname") == true)
  #expect(model.subscriptionStatus != DeferredRuntimeApplyPresentation.changesReadyToApply)
}
