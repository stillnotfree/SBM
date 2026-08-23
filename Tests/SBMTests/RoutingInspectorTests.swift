import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

@Test func privateIPRuleWithoutResolvedAddressShowsConditionalAlternatives() {
  let result = RoutingInspector.inspect(
    route: [
      "rules": [
        ["ip_is_private": true, "action": "route", "outbound": "direct"],
        ["domain_suffix": ["example.com"], "action": "route", "outbound": "proxy"],
      ],
      "final": "direct",
    ],
    context: RoutingInspectionContext(domain: "www.example.com"),
    outboundDecisions: ["direct": .direct, "proxy": .vpn],
    selectorOutbound: "proxy"
  )
  #expect(result.decision == .indeterminate)
  #expect(result.uncertaintyReason?.contains("unresolved IP conditions") == true)
  #expect(result.fallback == nil)
  #expect(result.alternatives.count == 2)
  #expect(
    result.alternatives.contains { $0.decision == .direct && $0.condition == "Private address" }
  )
  #expect(result.alternatives.contains { $0.decision == .vpn && $0.condition == "Public address" })
}

@Test func privateIPRuleEvaluatesConcreteIPv4AndIPv6Addresses() {
  let route: [String: Any] = [
    "rules": [["ip_is_private": true, "action": "route", "outbound": "direct"]],
    "final": "proxy",
  ]
  let decisions: [String: RoutingInspectionResult.Decision] = [
    "direct": .direct, "proxy": .vpn,
  ]
  #expect(
    RoutingInspector.inspect(
      route: route,
      context: RoutingInspectionContext(ipAddress: "10.0.0.1"),
      outboundDecisions: decisions,
      selectorOutbound: "proxy"
    ).decision == .direct
  )
  #expect(
    RoutingInspector.inspect(
      route: route,
      context: RoutingInspectionContext(ipAddress: "203.0.113.8"),
      outboundDecisions: decisions,
      selectorOutbound: "proxy"
    ).decision == .vpn
  )
  #expect(
    RoutingInspector.inspect(
      route: route,
      context: RoutingInspectionContext(ipAddress: "fc00::1"),
      outboundDecisions: decisions,
      selectorOutbound: "proxy"
    ).decision == .direct
  )
}

private let outboundDecisions: [String: RoutingInspectionResult.Decision] = [
  "direct": .direct,
  "proxy-selector": .vpn,
  "block": .reject,
]

private func inspect(
  rules: [[String: Any]],
  final: String = "proxy-selector",
  domain: String? = nil,
  ipAddress: String? = nil
) -> RoutingInspectionResult {
  RoutingInspector.inspect(
    route: ["rules": rules, "final": final],
    context: RoutingInspectionContext(domain: domain, ipAddress: ipAddress),
    outboundDecisions: outboundDecisions,
    selectorOutbound: "proxy-selector"
  )
}

private actor InspectorRuntimeSpy {
  private var requests: [HelperRequest] = []
  private var continuation: CheckedContinuation<HelperResponse, Never>?

  func send(_ request: HelperRequest) async -> HelperResponse {
    requests.append(request)
    return await withCheckedContinuation { continuation = $0 }
  }

  func count() -> Int { requests.count }

  func complete(profileID: UUID, selectedNode: ProxyNodeID = .auto) {
    continuation?.resume(
      returning: HelperResponse(
        success: true,
        coreRunning: true,
        selectedNode: selectedNode,
        activeProfileID: profileID,
        message: "active"
      ))
    continuation = nil
  }
}

private actor InspectorRuleSetMatcherSpy {
  private var requests: [([String], String)] = []
  private var failuresRemaining: Int

  init(failuresBeforeSuccess: Int = 0) {
    failuresRemaining = failuresBeforeSuccess
  }

  func match(tags: [String], destination: String) throws -> [String: Bool] {
    requests.append((tags, destination))
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw InspectorRuleSetMatcherFailure.transient
    }
    return Dictionary(uniqueKeysWithValues: tags.map { ($0, false) })
  }

  func count() -> Int { requests.count }
}

private actor BlockingInspectorRuleSetMatcher {
  private var continuation: CheckedContinuation<[String: Bool], Never>?

  func match(tags: [String], destination: String) async -> [String: Bool] {
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func isWaiting() -> Bool { continuation != nil }

  func complete() {
    continuation?.resume(returning: [:])
    continuation = nil
  }
}

private enum InspectorRuleSetMatcherFailure: Error {
  case transient
}

private actor FailingRuleSetMatcher {
  private var requests = 0

  func match(tags _: [String], destination _: String) throws -> [String: Bool] {
    requests += 1
    throw RoutingInspectionFailure.activeRuleSetDataUnavailable(
      "cache metadata missing\nsecret details are omitted"
    )
  }

  func count() -> Int { requests }
}

@Test func routingInspectorExplainsRussianExampleWithoutNetworkAccess() throws {
  let data = try Data(
    contentsOf: URL(fileURLWithPath: "Examples/routing-ru-direct.json")
  )
  let policy = try RoutingPolicyParser.parse(data)
  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "node-test"),
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.10",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password",
              displayName: "Test"
            )
          )
        )
      ],
      routingPolicy: policy
    )
  )
  let composed = try ComposedRoutingInspection.make(profile: profile)
  let built = try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "synthetic-secret")
    .makeConfiguration(profile: profile, mode: .rule, selectedNode: .auto)
  let builtRoot = try #require(
    JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let builtRoute = try #require(builtRoot["route"] as? [String: Any])
  #expect(
    try JSONSerialization.data(withJSONObject: composed.route, options: [.sortedKeys])
      == JSONSerialization.data(withJSONObject: builtRoute, options: [.sortedKeys])
  )

  let russian = RoutingInspector.inspect(
    route: composed.route,
    context: RoutingInspectionContext(
      domain: "2ip.ru",
      ipAddress: "93.184.216.34",
      mode: .rule,
      inboundTag: composed.inboundTag
    ),
    outboundDecisions: composed.outboundDecisions,
    selectorOutbound: composed.selectorOutbound
  )
  let special = RoutingInspector.inspect(
    route: composed.route,
    context: RoutingInspectionContext(
      domain: "www.google.ru",
      ipAddress: "93.184.216.34",
      mode: .rule,
      inboundTag: composed.inboundTag
    ),
    outboundDecisions: composed.outboundDecisions,
    selectorOutbound: composed.selectorOutbound
  )
  let unresolved = RoutingInspector.inspect(
    route: composed.route,
    context: RoutingInspectionContext(
      domain: "google.com",
      ipAddress: "93.184.216.34",
      mode: .rule,
      inboundTag: composed.inboundTag
    ),
    outboundDecisions: composed.outboundDecisions,
    selectorOutbound: composed.selectorOutbound
  )

  #expect(russian.decision == .direct)
  #expect(special.decision == .vpn)
  #expect(unresolved.decision == .indeterminate)
  #expect(unresolved.uncertaintyReason?.contains("geosite-category-ru") == true)
  #expect(unresolved.ruleIndex == 8)
  #expect(unresolved.fallback?.decision == .vpn)
  #expect(unresolved.fallback?.matchedRule == "Final route")
}

@Test func defaultAndApplicationContextsResolveScreenshotScenario() throws {
  let applicationPath = "/Applications/Browser.app/Contents/MacOS/Browser"
  let policy = try RoutingPolicyParser.parse(
    Data(contentsOf: URL(fileURLWithPath: "Examples/routing-ru-direct.json"))
  )
  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "node-test"),
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.10",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password",
              displayName: "Test"
            ))
        )
      ],
      routingPolicy: policy,
      applicationRoutingRules: [
        ApplicationRoutingRule(
          displayName: "Browser",
          bundlePath: "/Applications/Browser.app",
          executablePath: applicationPath,
          target: .selectedProxy
        )
      ]
    )
  )
  let composed = try ComposedRoutingInspection.make(profile: profile)

  let defaultResult = RoutingInspector.inspect(
    route: composed.route,
    context: RoutingInspectionContext(
      domain: "gosuslugi.ru",
      ipAddress: "93.184.216.34",
      mode: .rule,
      inboundTag: composed.inboundTag,
      defaultApplicationPaths: [applicationPath]
    ),
    outboundDecisions: composed.outboundDecisions,
    selectorOutbound: composed.selectorOutbound
  )
  let applicationResult = RoutingInspector.inspect(
    route: composed.route,
    context: RoutingInspectionContext(
      domain: "gosuslugi.ru",
      ipAddress: "93.184.216.34",
      mode: .rule,
      inboundTag: composed.inboundTag,
      applicationPath: applicationPath
    ),
    outboundDecisions: composed.outboundDecisions,
    selectorOutbound: composed.selectorOutbound
  )

  #expect(defaultResult.decision == .direct)
  #expect(defaultResult.ruleIndex == 8)
  #expect(applicationResult.decision == .vpn)
  #expect(applicationResult.ruleIndex == 6)
}

@Test func defaultTrafficSkipsApplicationRuleAndUsesDeterministicFinal() throws {
  let applicationPath = "/Applications/Direct.app/Contents/MacOS/Direct"
  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "node-test"),
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.10",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password",
              displayName: "Test"
            ))
        )
      ],
      applicationRoutingRules: [
        ApplicationRoutingRule(
          displayName: "Direct",
          bundlePath: "/Applications/Direct.app",
          executablePath: applicationPath,
          target: .direct
        )
      ]
    )
  )
  let composed = try ComposedRoutingInspection.make(profile: profile)

  let defaultGoogle = RoutingInspector.inspect(
    route: composed.route,
    context: RoutingInspectionContext(
      domain: "google.com",
      ipAddress: "93.184.216.34",
      mode: .rule,
      inboundTag: composed.inboundTag,
      defaultApplicationPaths: [applicationPath]
    ),
    outboundDecisions: composed.outboundDecisions,
    selectorOutbound: composed.selectorOutbound
  )
  let directApplication = RoutingInspector.inspect(
    route: composed.route,
    context: RoutingInspectionContext(
      domain: "google.com",
      ipAddress: "93.184.216.34",
      mode: .rule,
      inboundTag: composed.inboundTag,
      applicationPath: applicationPath
    ),
    outboundDecisions: composed.outboundDecisions,
    selectorOutbound: composed.selectorOutbound
  )

  #expect(defaultGoogle.decision == .vpn)
  #expect(directApplication.decision == .direct)
}

@Test func routingInspectorExplainsApplicationRejectCompactly() throws {
  let applicationPath = "/Applications/Transmission.app/Contents/MacOS/Transmission"
  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "node-test"),
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.10",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password",
              displayName: "Test"
            ))
        )
      ],
      applicationRoutingRules: [
        ApplicationRoutingRule(
          displayName: "Transmission",
          bundlePath: "/Applications/Transmission.app",
          executablePath: applicationPath,
          target: .reject
        )
      ]
    )
  )
  let composed = try ComposedRoutingInspection.make(profile: profile)
  let result = RoutingInspector.inspect(
    route: composed.route,
    context: RoutingInspectionContext(
      domain: "example.com",
      ipAddress: "93.184.216.34",
      mode: .rule,
      inboundTag: composed.inboundTag,
      applicationPath: applicationPath
    ),
    outboundDecisions: composed.outboundDecisions,
    selectorOutbound: composed.selectorOutbound
  )

  #expect(result.decision == .reject)
  #expect(composed.presentation(for: result) == "REJECT\nMatched: Transmission")
  #expect(
    composed.details(for: result, contextLabel: "Transmission")
      == "Traffic from: Transmission\nRule: 7")
}

@Test func routingInspectorViewUsesPromptAndUncompressedExplainControl() throws {
  let source = try String(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Sources/SBM/SettingsView.swift"),
    encoding: .utf8
  )
  #expect(!source.contains(#"TextField("gosuslugi.ru", text:"#))
  #expect(source.contains(#"prompt: Text("gosuslugi.ru")"#))
  #expect(source.contains(#"Button("Explain")"#))
  #expect(source.contains(".frame(minWidth: 180, maxWidth: .infinity)"))
  #expect(source.contains(".frame(width: routingInspectorActionButtonWidth)"))
  #expect(source.contains(#"Text("Proxy").tag(ApplicationRoutingTarget.selectedProxy)"#))
  #expect(source.contains(#"prompt: Text("(?i)lte|russia")"#))
  #expect(source.contains(#"settingsRow("Exclude regex (optional)")"#))
}

@Test @MainActor func explainDoesNotMutatePersistenceGenerationOrRuntime() async {
  let profileID = UUID()
  let profile = CoreProfile.compatibility(
    VPNProfile(connections: [
      ManagedConnection(
        id: ProxyNodeID(rawValue: "node-test"),
        outbound: .shadowsocks(
          ShadowsocksProfile(
            server: "198.51.100.10",
            port: 443,
            method: "aes-128-gcm",
            password: "synthetic-test-password",
            displayName: "Test"
          ))
      )
    ]))
  let library = ProfileLibrary(
    profiles: [ManagedProfile(id: profileID, name: "Inspector", payload: profile)],
    selectedProfileID: profileID
  )
  let runtime = InspectorRuntimeSpy()
  var saves = 0
  let model = AppModel(
    runtimeSender: { request in await runtime.send(request) },
    profileLibraryLoader: { library },
    profileLibrarySaver: { _ in saves += 1 },
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.setCoreEnabled(true)
  for _ in 0..<100 where await runtime.count() == 0 { await Task.yield() }
  let generation = model.desiredRuntimeGeneration
  let saveCount = saves

  model.routingInspectorInput = "google.com"
  model.inspectRouting()

  #expect(model.desiredRuntimeGeneration == generation)
  #expect(await runtime.count() == 1)
  #expect(saves == saveCount)
  #expect(
    model.routingInspectorOutput
      == "IPv6: REJECT\nIPv4 + Private address: DIRECT\nIPv4 + Public address: PROXY · Auto"
  )
  #expect(model.routingInspectorDetails.contains("Traffic from: Default traffic"))
  await runtime.complete(profileID: profileID)
}

@Test @MainActor func changingInspectorInputOrApplicationInvalidatesCompletedResult() {
  let profileID = UUID()
  let executablePath = "/Applications/Browser.app/Contents/MacOS/Browser"
  let rule = ApplicationRoutingRule(
    displayName: "Browser",
    bundlePath: "/Applications/Browser.app",
    executablePath: executablePath,
    target: .selectedProxy
  )
  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "node-test"),
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.10",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password"
            )
          )
        )
      ],
      applicationRoutingRules: [rule]
    )
  )
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [ManagedProfile(id: profileID, name: "Inspector", payload: profile)],
        selectedProfileID: profileID
      )
    },
    profileLibrarySaver: { _ in },
    performStartup: false
  )

  model.routingInspectorInput = "example.com"
  model.inspectRouting()
  #expect(model.routingInspectorState.snapshot != nil)
  #expect(model.routingInspectorOutput != RoutingInspectorState.idleOutput)

  model.routingInspectorInput = "changed.example"
  #expect(model.routingInspectorState == .idle)
  #expect(model.routingInspectorOutput == RoutingInspectorState.idleOutput)
  #expect(model.routingInspectorDetails.isEmpty)

  model.routingInspectorInput = "example.com"
  model.inspectRouting()
  model.routingInspectorApplicationID = rule.id
  #expect(model.routingInspectorState == .idle)
  #expect(model.routingInspectorOutput == RoutingInspectorState.idleOutput)
}

@Test @MainActor func changingInspectorProfileNodeOrModeInvalidatesCompletedResult() {
  let profileAID = UUID()
  let profileBID = UUID()
  let profileA = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "node-a"),
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.10",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password"
            )
          )
        )
      ]
    )
  )
  let profileB = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: ProxyNodeID(rawValue: "node-b"),
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.11",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password"
            )
          )
        )
      ]
    )
  )
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [
          ManagedProfile(id: profileAID, name: "A", payload: profileA),
          ManagedProfile(id: profileBID, name: "B", payload: profileB),
        ],
        selectedProfileID: profileAID
      )
    },
    profileLibrarySaver: { _ in },
    performStartup: false
  )

  model.routingInspectorInput = "example.com"
  model.inspectRouting()
  #expect(model.routingInspectorState.snapshot != nil)

  model.selectedNodeID = ProxyNodeID(rawValue: "node-a")
  #expect(model.routingInspectorState == .idle)
  model.inspectRouting()
  model.routingMode = .direct
  #expect(model.routingInspectorState == .idle)
  model.inspectRouting()
  model.selectProfile(profileBID)
  #expect(model.routingInspectorState == .idle)
}

@Test @MainActor func obsoleteActiveRuleSetLookupCannotLeaveCheckingStateOrOverwriteNewInput()
  async throws
{
  let profileID = UUID()
  let nodeID = ProxyNodeID(rawValue: "node-germany")
  let policy = try RoutingPolicyParser.parse(
    Data(contentsOf: URL(fileURLWithPath: "Examples/routing-ru-direct.json"))
  )
  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: nodeID,
          displayName: "Germany",
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.20",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password"
            )
          )
        )
      ],
      routingPolicy: policy
    )
  )
  let runtime = InspectorRuntimeSpy()
  let matcher = BlockingInspectorRuleSetMatcher()
  let model = AppModel(
    runtimeSender: { request in await runtime.send(request) },
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [ManagedProfile(id: profileID, name: "Inspector", payload: profile)],
        selectedProfileID: profileID
      )
    },
    profileLibrarySaver: { _ in },
    routingRuleSetMatcher: { tags, destination in
      await matcher.match(tags: tags, destination: destination)
    },
    routingRuleSetRetryDelay: .zero,
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.setCoreEnabled(true)
  for _ in 0..<100 where await runtime.count() == 0 { await Task.yield() }
  await runtime.complete(profileID: profileID, selectedNode: nodeID)
  for _ in 0..<100 where !model.coreRunning { await Task.yield() }

  model.routingInspectorInput = "google.com"
  model.inspectRouting()
  for _ in 0..<100 where !(await matcher.isWaiting()) { await Task.yield() }
  #expect(model.routingInspectorOutput == "Checking active rule sets…")

  model.routingInspectorInput = "new.example"
  #expect(model.routingInspectorState == .idle)
  #expect(model.routingInspectorOutput == RoutingInspectorState.idleOutput)
  await matcher.complete()
  for _ in 0..<100 { await Task.yield() }
  #expect(model.routingInspectorOutput == RoutingInspectorState.idleOutput)
  #expect(!model.routingInspectorOutput.contains("Checking active rule sets"))
}

@Test @MainActor func activeRuleSetInspectionRetriesWithConcreteSelectedNode() async throws {
  let profileID = UUID()
  let nodeID = ProxyNodeID(rawValue: "node-germany")
  let policy = try RoutingPolicyParser.parse(
    Data(contentsOf: URL(fileURLWithPath: "Examples/routing-ru-direct.json"))
  )
  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: nodeID,
          displayName: "Germany",
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.20",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password",
              displayName: "Legacy"
            ))
        )
      ],
      routingPolicy: policy
    )
  )
  let runtime = InspectorRuntimeSpy()
  let matcher = InspectorRuleSetMatcherSpy(failuresBeforeSuccess: 2)
  let model = AppModel(
    runtimeSender: { request in await runtime.send(request) },
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [ManagedProfile(id: profileID, name: "Inspector", payload: profile)],
        selectedProfileID: profileID
      )
    },
    profileLibrarySaver: { _ in },
    routingRuleSetMatcher: { tags, destination in
      try await matcher.match(tags: tags, destination: destination)
    },
    routingRuleSetRetryDelay: .zero,
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.setCoreEnabled(true)
  for _ in 0..<100 where await runtime.count() == 0 { await Task.yield() }
  await runtime.complete(profileID: profileID, selectedNode: nodeID)
  for _ in 0..<100 where !model.coreRunning { await Task.yield() }

  model.routingInspectorInput = "google.com"
  model.inspectRouting()
  for _ in 0..<100 where model.routingInspectorOutput == "Checking active rule sets…" {
    await Task.yield()
  }

  #expect(await matcher.count() == 3)
  #expect(model.selectedNodeID == .auto)
  #expect(
    model.routingInspectorOutput
      == "IPv6: REJECT\nIPv4 + Private address: DIRECT\nIPv4 + Public address: PROXY · Auto"
  )
}

@Test @MainActor func activeRuleSetFailureIsTypedAndBounded() async throws {
  let profileID = UUID()
  let nodeID = ProxyNodeID(rawValue: "node-germany")
  let policy = try RoutingPolicyParser.parse(
    Data(contentsOf: URL(fileURLWithPath: "Examples/routing-ru-direct.json"))
  )
  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: nodeID,
          displayName: "Germany",
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.20",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password"
            ))
        )
      ],
      routingPolicy: policy
    )
  )
  let runtime = InspectorRuntimeSpy()
  let matcher = FailingRuleSetMatcher()
  let model = AppModel(
    runtimeSender: { request in await runtime.send(request) },
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [ManagedProfile(id: profileID, name: "Inspector", payload: profile)],
        selectedProfileID: profileID
      )
    },
    profileLibrarySaver: { _ in },
    routingRuleSetMatcher: { tags, destination in
      try await matcher.match(tags: tags, destination: destination)
    },
    routingRuleSetRetryDelay: .zero,
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.setCoreEnabled(true)
  for _ in 0..<100 where await runtime.count() == 0 { await Task.yield() }
  await runtime.complete(profileID: profileID, selectedNode: nodeID)
  for _ in 0..<100 where !model.coreRunning { await Task.yield() }

  model.routingInspectorInput = "google.com"
  model.inspectRouting()
  for _ in 0..<100
  where !model.routingInspectorDetails.contains("Active rule-set data is unavailable") {
    await Task.yield()
  }

  #expect(await matcher.count() == 5)
  #expect(model.routingInspectorOutput == "Active rule-set data is unavailable.")
  #expect(
    model.routingInspectorDetails
      == "Active rule-set data is unavailable: cache metadata missing secret details are omitted"
  )
}

@Test func routingInspectorHandlesFinalRejectCIDRAndPrecedence() {
  #expect(inspect(rules: [], domain: "unmatched.example.com").decision == .vpn)
  #expect(
    inspect(
      rules: [["domain": ["blocked.example"], "action": "reject"]],
      domain: "blocked.example"
    ).decision == .reject
  )
  #expect(
    inspect(
      rules: [
        ["ip_cidr": ["203.0.113.0/24"], "action": "route", "outbound": "direct"]
      ],
      ipAddress: "203.0.113.42"
    ).decision == .direct
  )
  #expect(
    inspect(
      rules: [
        ["domain_keyword": ["example"], "action": "route", "outbound": "direct"],
        ["domain_suffix": [".com"], "action": "route", "outbound": "proxy-selector"],
      ],
      domain: "api.example.com"
    ).decision == .direct
  )
}

@Test func routingInspectorUsesSingBoxDestinationAddressORGroup() {
  let mixedDestinationRule: [String: Any] = [
    "domain_suffix": [".com"],
    "ip_cidr": ["203.0.113.0/24"],
    "action": "route",
    "outbound": "direct",
  ]
  #expect(inspect(rules: [mixedDestinationRule], domain: "google.com").decision == .direct)
  #expect(inspect(rules: [mixedDestinationRule], ipAddress: "203.0.113.9").decision == .direct)

  let regexRule: [String: Any] = [
    "domain_regex": [#"^api\.[a-z]+\.example$"#],
    "action": "route",
    "outbound": "direct",
  ]
  #expect(inspect(rules: [regexRule], domain: "api.test.example").decision == .direct)
}

@Test func routingInspectorHandlesLogicalAndInvertRules() {
  let logical: [String: Any] = [
    "type": "logical",
    "mode": "and",
    "rules": [
      ["domain_suffix": [".ru"]],
      ["domain_keyword": ["internal"]],
    ],
    "action": "route",
    "outbound": "direct",
  ]
  #expect(inspect(rules: [logical], domain: "internal.example.ru").decision == .direct)
  #expect(inspect(rules: [logical], domain: "public.example.ru").decision == .vpn)

  let inverted: [String: Any] = [
    "domain_suffix": [".ru"],
    "invert": true,
    "action": "route",
    "outbound": "direct",
  ]
  #expect(inspect(rules: [inverted], domain: "example.com").decision == .direct)
  #expect(inspect(rules: [inverted], domain: "example.ru").decision == .vpn)
}

@Test func routingInspectorStopsAtRuntimeDependentOrRemoteRuleSet() {
  let processRule: [String: Any] = [
    "domain_suffix": [".com"],
    "process_path": ["/Applications/Example.app/Contents/MacOS/Example"],
    "action": "route",
    "outbound": "direct",
  ]
  let processResult = inspect(rules: [processRule], domain: "example.com")
  #expect(processResult.decision == .indeterminate)
  #expect(processResult.uncertaintyReason?.contains("select an application") == true)
  #expect(processResult.fallback?.decision == .vpn)
  #expect(
    !ComposedRoutingInspection(
      route: [:],
      outboundDecisions: outboundDecisions,
      vpnServerNames: [:],
      selectorOutbound: "proxy-selector",
      inboundTag: "tun-in"
    ).presentation(for: processResult).contains("Decision: INDETERMINATE"))

  let remoteResult = inspect(
    rules: [
      [
        "rule_set": ["remote-geosite"],
        "action": "route",
        "outbound": "direct",
      ]
    ],
    domain: "example.com"
  )
  #expect(remoteResult.decision == .indeterminate)
  #expect(remoteResult.uncertaintyReason?.contains("remote-geosite") == true)
  #expect(remoteResult.fallback?.decision == .vpn)

  let remoteRoute: [String: Any] = [
    "rules": [
      [
        "rule_set": ["remote-geosite"],
        "action": "route",
        "outbound": "direct",
      ]
    ],
    "final": "proxy-selector",
  ]
  let remoteMatch = RoutingInspector.inspect(
    route: remoteRoute,
    context: RoutingInspectionContext(domain: "example.com"),
    outboundDecisions: outboundDecisions,
    selectorOutbound: "proxy-selector",
    ruleSetMatches: ["remote-geosite": true]
  )
  let remoteNonMatch = RoutingInspector.inspect(
    route: remoteRoute,
    context: RoutingInspectionContext(domain: "example.com"),
    outboundDecisions: outboundDecisions,
    selectorOutbound: "proxy-selector",
    ruleSetMatches: ["remote-geosite": false]
  )
  #expect(remoteMatch.decision == .direct)
  #expect(remoteNonMatch.decision == .vpn)

  let unresolvedIP = inspect(
    rules: [
      ["ip_cidr": ["203.0.113.0/24"], "action": "route", "outbound": "direct"]
    ],
    domain: "example.com"
  )
  #expect(unresolvedIP.decision == .indeterminate)
  #expect(unresolvedIP.uncertaintyReason?.contains("unresolved IP conditions") == true)
  #expect(unresolvedIP.fallback == nil)
  #expect(unresolvedIP.alternatives.count == 2)
}

@Test func routingInspectorDoesNotLetUnrelatedRuntimeRuleHideLaterMatch() {
  let result = inspect(
    rules: [
      [
        "domain_suffix": [".net"],
        "process_path": ["/Applications/Unknown.app/Contents/MacOS/Unknown"],
        "action": "route",
        "outbound": "direct",
      ],
      ["domain_suffix": [".ru"], "action": "route", "outbound": "direct"],
    ],
    domain: "2ip.ru"
  )
  #expect(result.decision == .direct)
}

@Test func routingInspectorPresentationExplainsVPNServerAndTechnicalTag() throws {
  let germanyID = ProxyNodeID(rawValue: "node-germany")
  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          id: germanyID,
          displayName: "Germany",
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "198.51.100.20",
              port: 443,
              method: "aes-128-gcm",
              password: "synthetic-test-password",
              displayName: "Legacy"
            )
          )
        )
      ]
    )
  )
  let composed = try ComposedRoutingInspection.make(profile: profile, selectedNode: germanyID)
  let result = RoutingInspector.inspect(
    route: composed.route,
    context: RoutingInspectionContext(
      domain: "unmatched.example.com",
      ipAddress: "93.184.216.34",
      mode: .rule,
      inboundTag: composed.inboundTag
    ),
    outboundDecisions: composed.outboundDecisions,
    selectorOutbound: composed.selectorOutbound
  )
  let presentation = composed.presentation(for: result)

  #expect(presentation == "PROXY · Germany\nMatched: Final route")
  let details = composed.details(for: result, contextLabel: "Default traffic")
  #expect(details.contains("Traffic from: Default traffic"))
  #expect(details.contains("Outbound: proxy-selector"))
}

@Test func routingInspectorSymbolicallySplitsIPv6OffHostname() throws {
  let result = RoutingInspector.inspect(
    route: [
      "rules": [
        ["ip_version": 6, "action": "reject"],
        ["ip_version": 4, "action": "route", "outbound": "direct"],
      ],
      "final": "proxy",
    ],
    context: RoutingInspectionContext(domain: "example.com"),
    outboundDecisions: ["direct": .direct, "proxy": .vpn],
    selectorOutbound: "proxy"
  )

  #expect(result.decision == .indeterminate)
  let alternatives = try #require(
    result.alternatives.count == 2 ? result.alternatives : nil
  )
  #expect(alternatives[0].condition == "IPv6")
  #expect(alternatives[0].decision == .reject)
  #expect(alternatives[1].condition == "IPv4")
  #expect(alternatives[1].decision == .direct)
  #expect(
    !ComposedRoutingInspection(
      route: [:],
      outboundDecisions: [:],
      vpnServerNames: [:],
      selectorOutbound: "proxy",
      inboundTag: "tun-in"
    ).presentation(for: result).contains("Depends on resolved IP")
  )
}

@Test func routingInspectorLiteralIPUsesOnlyItsKnownFamily() {
  let route: [String: Any] = [
    "rules": [
      ["ip_version": 6, "action": "reject"],
      ["ip_version": 4, "action": "route", "outbound": "direct"],
    ],
    "final": "proxy",
  ]
  let decisions: [String: RoutingInspectionResult.Decision] = [
    "direct": .direct, "proxy": .vpn,
  ]

  let ipv4 = RoutingInspector.inspect(
    route: route,
    context: RoutingInspectionContext(ipAddress: "203.0.113.8"),
    outboundDecisions: decisions,
    selectorOutbound: "proxy"
  )
  let ipv6 = RoutingInspector.inspect(
    route: route,
    context: RoutingInspectionContext(ipAddress: "2001:db8::8"),
    outboundDecisions: decisions,
    selectorOutbound: "proxy"
  )

  #expect(ipv4.decision == .direct)
  #expect(ipv4.ruleIndex == 1)
  #expect(ipv6.decision == .reject)
  #expect(ipv6.ruleIndex == 0)
  #expect(ipv4.alternatives.isEmpty)
  #expect(ipv6.alternatives.isEmpty)
}

@Test func routingInspectorKeepsMultipleUnresolvedIPPredicatesUseful() {
  let result = RoutingInspector.inspect(
    route: [
      "rules": [
        ["ip_cidr": ["203.0.113.0/24"], "action": "route", "outbound": "direct"],
        ["ip_is_private": true, "action": "reject"],
      ],
      "final": "proxy",
    ],
    context: RoutingInspectionContext(domain: "example.com"),
    outboundDecisions: ["direct": .direct, "proxy": .vpn],
    selectorOutbound: "proxy"
  )

  #expect(result.decision == .indeterminate)
  #expect(result.alternatives.map(\.decision) == [.direct, .reject, .vpn])
  #expect(result.uncertaintyReason?.contains("unresolved IP conditions") == true)
}

@Test func routingInspectorCollapsesConvergentSymbolicPaths() {
  let result = RoutingInspector.inspect(
    route: [
      "rules": [["ip_is_private": true, "action": "route", "outbound": "direct"]],
      "final": "direct",
    ],
    context: RoutingInspectionContext(domain: "example.com"),
    outboundDecisions: ["direct": .direct],
    selectorOutbound: "direct"
  )

  #expect(result.decision == .direct)
  #expect(result.alternatives.isEmpty)
  #expect(result.collapsedPathCount == 2)
}

@Test func routingInspectorCollapsesConvergentGenericUnknownPaths() {
  let result = inspect(
    rules: [
      [
        "process_path": ["/Applications/Example.app/Contents/MacOS/Example"],
        "action": "route",
        "outbound": "direct",
      ]
    ],
    final: "direct",
    domain: "example.com"
  )

  #expect(result.decision == .direct)
  #expect(result.alternatives.isEmpty)
  #expect(result.collapsedPathCount == 2)
}

@Test func routingInspectorKeepsDistinctVPNOutboundTagsAsAlternatives() {
  let result = RoutingInspector.inspect(
    route: [
      "rules": [
        ["ip_version": 6, "action": "route", "outbound": "vpn-a"],
        ["ip_version": 4, "action": "route", "outbound": "vpn-b"],
      ],
      "final": "vpn-a",
    ],
    context: RoutingInspectionContext(domain: "example.com"),
    outboundDecisions: ["vpn-a": .vpn, "vpn-b": .vpn],
    selectorOutbound: "vpn-a"
  )

  #expect(result.decision == .indeterminate)
  #expect(Set(result.alternatives.map(\.outboundTag)) == Set(["vpn-a", "vpn-b"]))
  #expect(result.alternatives.count == 2)
}

@Test func routingInspectorPrunesNestedCIDRAndNegativeSetContradictions() {
  let nested = inspect(
    rules: [
      [
        "type": "logical",
        "mode": "and",
        "rules": [
          ["ip_cidr": ["10.1.0.0/16"]],
          ["ip_cidr": ["10.0.0.0/8"]],
        ],
        "action": "route",
        "outbound": "direct",
      ]
    ],
    final: "proxy-selector",
    domain: "example.com"
  )
  #expect(nested.decision == .indeterminate)
  #expect(nested.alternatives.contains { $0.decision == .direct })

  let impossible = inspect(
    rules: [
      [
        "type": "logical",
        "mode": "and",
        "rules": [
          [
            "ip_cidr": ["10.0.0.0/8", "192.168.0.0/16"],
            "invert": true,
          ],
          ["ip_cidr": ["10.0.0.0/8"]],
        ],
        "action": "route",
        "outbound": "direct",
      ]
    ],
    final: "proxy-selector",
    domain: "example.com"
  )
  #expect(impossible.decision == .vpn)
  #expect(impossible.alternatives.isEmpty)
}

@Test func routingInspectorDerivesPrivateCIDRAndRejectsPublicContradiction() {
  let impliedPrivate = inspect(
    rules: [
      [
        "type": "logical",
        "mode": "and",
        "rules": [
          ["ip_cidr": ["10.0.0.0/8"]],
          ["ip_is_private": true],
        ],
        "action": "route",
        "outbound": "direct",
      ]
    ],
    final: "proxy-selector",
    domain: "example.com"
  )
  #expect(impliedPrivate.decision == .indeterminate)
  #expect(impliedPrivate.alternatives.contains { $0.decision == .direct })

  let contradictoryPublic = inspect(
    rules: [
      [
        "type": "logical",
        "mode": "and",
        "rules": [
          ["ip_cidr": ["10.0.0.0/8"]],
          ["ip_is_private": false],
        ],
        "action": "route",
        "outbound": "direct",
      ]
    ],
    final: "proxy-selector",
    domain: "example.com"
  )
  #expect(contradictoryPublic.decision == .vpn)
  #expect(contradictoryPublic.alternatives.isEmpty)
}

@Test func routingInspectorPrunesContradictoryFamilyConstraints() {
  let result = RoutingInspector.inspect(
    route: [
      "rules": [
        [
          "type": "logical",
          "mode": "and",
          "rules": [
            ["ip_version": 4],
            ["ip_version": 6],
          ],
          "action": "route",
          "outbound": "direct",
        ]
      ],
      "final": "proxy",
    ],
    context: RoutingInspectionContext(domain: "example.com"),
    outboundDecisions: ["direct": .direct, "proxy": .vpn],
    selectorOutbound: "proxy"
  )

  #expect(result.decision == .vpn)
  #expect(result.alternatives.isEmpty)
}

@Test func routingInspectorStopsAtBoundedSymbolicComplexity() {
  let rules: [[String: Any]] = (0..<40).map { index in
    [
      "ip_cidr": ["203.0.\(index).0/24"],
      "action": "route",
      "outbound": "direct",
    ]
  }
  let result = RoutingInspector.inspect(
    route: ["rules": rules, "final": "direct"],
    context: RoutingInspectionContext(domain: "example.com"),
    outboundDecisions: ["direct": .direct],
    selectorOutbound: "direct"
  )

  #expect(result.analysisLimited)
  #expect(result.decision == .indeterminate)
  #expect(result.alternatives.isEmpty)
}
