import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

@MainActor
private func waitForInspectorCondition(
  timeout: Duration = .seconds(2),
  _ condition: @MainActor () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return await condition()
}

@MainActor
private final class RegisteredInspectorHelper: HelperServiceManaging {
  var registrationState: HelperRegistrationState = .enabled
  var legacyRegistrationState: HelperRegistrationState = .notRegistered

  func register() throws {}
  func unregister() async throws {}
  func unregisterLegacy() async throws {}
  func openSystemSettings() {}
}

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
    ).decision == .direct
  )
  #expect(
    RoutingInspector.inspect(
      route: route,
      context: RoutingInspectionContext(ipAddress: "203.0.113.8"),
      outboundDecisions: decisions,
    ).decision == .vpn
  )
  #expect(
    RoutingInspector.inspect(
      route: route,
      context: RoutingInspectionContext(ipAddress: "fc00::1"),
      outboundDecisions: decisions,
    ).decision == .direct
  )
}

@Test func routingInspectorNormalizesUnicodeDomainsLikeWebsiteRouting() throws {
  let unicodeDomain = "bücher.example"
  let savedDomain = try WebsiteDomainNormalizer.normalize(unicodeDomain)
  #expect(savedDomain == "xn--bcher-kva.example")
  let savedRule = WebsiteRoutingRule(domain: savedDomain, target: .direct)
  let route: [String: Any] = [
    "rules": [["domain": [savedRule.domain], "action": "route", "outbound": "direct"]],
    "final": "proxy-selector",
  ]

  for input in [unicodeDomain, savedDomain] {
    let context = try RoutingInspector.parseInput(
      input,
      mode: .rule,
      inboundTag: nil
    )
    #expect(context.domain == savedDomain)
    let result = RoutingInspector.inspect(
      route: route,
      context: context,
      outboundDecisions: outboundDecisions,
    )
    #expect(result.decision == .direct)
  }
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

  func complete(
    profileID: UUID,
    selectedNode: ProxyNodeID = .auto,
    activeProfileID: UUID? = nil,
    runtimeOutcome: HelperRuntimeOutcome = .applied
  ) {
    continuation?.resume(
      returning: HelperResponse(
        success: true,
        coreRunning: true,
        selectedNode: selectedNode,
        activeProfileID: activeProfileID ?? profileID,
        runtimeOutcome: runtimeOutcome,
        message: "active"
      ))
    continuation = nil
  }
}

private actor InspectorServiceSpy {
  private var requests = 0
  private var profileValidations = 0

  func send(_: HelperRequest) -> HelperResponse {
    requests += 1
    return HelperResponse(success: true, coreRunning: false, message: "unexpected request")
  }

  func validateProfile() -> HelperResponse {
    profileValidations += 1
    return HelperResponse(success: true, coreRunning: false, message: "unexpected validation")
  }

  func counts() -> (requests: Int, profileValidations: Int) {
    (requests, profileValidations)
  }
}

@MainActor
private final class InspectorSaveSpy {
  private(set) var count = 0

  func record() { count += 1 }
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
  )

  #expect(defaultResult.decision == .direct)
  #expect(defaultResult.ruleIndex == 8)
  #expect(applicationResult.decision == .vpn)
  #expect(applicationResult.ruleIndex == 3)
}

@Test func applicationTargetsOverrideGlobalDirectAndPrivateModeRules() throws {
  let node = ProxyNodeID(rawValue: "node-fixed")
  let executablePaths = [
    ApplicationRoutingTarget.direct: "/Applications/Direct.app/Contents/MacOS/Direct",
    .selectedProxy: "/Applications/Selected.app/Contents/MacOS/Selected",
    .node(node): "/Applications/Fixed.app/Contents/MacOS/Fixed",
    .reject: "/Applications/Reject.app/Contents/MacOS/Reject",
  ]
  let cases: [(ApplicationRoutingTarget, RoutingMode, RoutingInspectionResult.Decision)] = [
    (.direct, .global, .direct),
    (.selectedProxy, .direct, .vpn),
    (.node(node), .direct, .vpn),
    (.reject, .direct, .reject),
  ]

  for (target, mode, expected) in cases {
    let executablePath = try #require(executablePaths[target])
    let profile = CoreProfile.compatibility(
      VPNProfile(
        connections: [
          ManagedConnection(
            id: node,
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
        applicationRoutingRules: [
          ApplicationRoutingRule(
            displayName: "Selected application",
            bundlePath: URL(fileURLWithPath: executablePath).deletingLastPathComponent()
              .deletingLastPathComponent().deletingLastPathComponent().path,
            executablePath: executablePath,
            target: target
          )
        ]
      )
    )
    let composed = try ComposedRoutingInspection.make(profile: profile, selectedNode: node)
    let result = RoutingInspector.inspect(
      route: composed.route,
      context: RoutingInspectionContext(
        domain: "private.example.test",
        ipAddress: "192.168.1.20",
        mode: mode,
        applicationPath: executablePath
      ),
      outboundDecisions: composed.outboundDecisions,
    )
    #expect(result.decision == expected)
    #expect(result.ruleIndex == 3)
  }
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
  )

  #expect(result.decision == .reject)
  #expect(composed.presentation(for: result) == "REJECT\nMatched: Transmission")
  #expect(
    composed.details(for: result, contextLabel: "Transmission")
      == "Traffic from: Transmission\nRule: 4")
}

@Test func routingInspectorViewUsesPromptAndUncompressedExplainControl() throws {
  let source = try String(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Sources/SBM/SettingsView.swift"),
    encoding: .utf8
  )
  #expect(!source.contains(#"TextField("gosuslugi.ru", text:"#))
  #expect(source.contains(#"prompt: Text("Enter a domain or IP address")"#))
  #expect(RoutingInspectorState.idleOutput.isEmpty)
  #expect(!source.contains("Enter a domain or IP address to explain traffic routing."))
  #expect(source.contains(#"Button("Explain")"#))
  #expect(source.contains(".frame(minWidth: 180, maxWidth: .infinity)"))
  #expect(source.contains(".frame(width: routingInspectorActionButtonWidth)"))
  #expect(source.contains(#"Text("Proxy").tag(ApplicationRoutingTarget.selectedProxy)"#))
  #expect(source.contains(#"prompt: Text("(?i)lte|russia")"#))
  #expect(source.contains(#"settingsRow("Exclude regex")"#))
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
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.setCoreEnabled(true)
  #expect(await waitForInspectorCondition { await runtime.count() > 0 })
  let saveCount = saves

  model.routingInspectorInput = "google.com"
  model.inspectRouting()

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
    userDefaults: IsolatedTestUserDefaults(),
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
    userDefaults: IsolatedTestUserDefaults(),
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

@Test @MainActor func remoteRuleSetExplainIsImmediateAndIndependentOfHelperState() async throws {
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
  let service = InspectorServiceSpy()
  let saves = InspectorSaveSpy()
  let model = AppModel(
    helperService: RegisteredInspectorHelper(),
    runtimeSender: { request in await runtime.send(request) },
    helperRequestSender: { request in await service.send(request) },
    profileValidator: { _ in await service.validateProfile() },
    profileLibraryLoader: {
      ProfileLibrary(
        profiles: [ManagedProfile(id: profileID, name: "Inspector", payload: profile)],
        selectedProfileID: profileID
      )
    },
    profileLibrarySaver: { _ in saves.record() },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )

  model.routingInspectorInput = "198.51.100.42"
  model.inspectRouting()
  #expect(model.routingInspectorState.snapshot != nil)
  #expect(model.routingInspectorOutput.contains("Depends on remote rule-set membership"))
  #expect(model.routingInspectorDetails.contains("remote rule-set membership is unknown locally"))
  #expect(model.routingInspectorDetails.contains("Possible route:"))
  #expect(await runtime.count() == 0)
  #expect(await service.counts().requests == 0)
  #expect(await service.counts().profileValidations == 0)
  #expect(saves.count == 0)

  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.setCoreEnabled(true)
  #expect(await waitForInspectorCondition { await runtime.count() > 0 })
  await runtime.complete(profileID: profileID, selectedNode: nodeID)
  #expect(
    await waitForInspectorCondition { model.coreRunning && model.runtimeApplyStatus == .active })
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision

  let runtimeRequestsBeforeExplain = await runtime.count()
  let serviceCountsBeforeExplain = await service.counts()
  let savesBeforeExplain = saves.count
  for (input, revision, applyStatus) in [
    ("203.0.113.42", HelperConstants.helperRevision, RuntimeApplyStatus.active),
    ("198.51.100.43", HelperConstants.helperRevision - 1, RuntimeApplyStatus.active),
    ("192.0.2.1", HelperConstants.helperRevision, RuntimeApplyStatus.reconnectRequired),
  ] {
    model.helperRevision = revision
    model.runtimeApplyStatus = applyStatus
    model.routingInspectorInput = input
    model.inspectRouting()
    #expect(model.routingInspectorState.snapshot != nil)
    #expect(model.routingInspectorOutput.contains("Depends on remote rule-set membership"))
    #expect(model.routingInspectorDetails.contains("remote rule-set membership is unknown locally"))
    #expect(model.routingInspectorDetails.contains("Possible route:"))
  }

  try await Task.sleep(for: .milliseconds(20))
  #expect(await runtime.count() == runtimeRequestsBeforeExplain)
  #expect(await service.counts().requests == serviceCountsBeforeExplain.requests)
  #expect(
    await service.counts().profileValidations == serviceCountsBeforeExplain.profileValidations)
  #expect(saves.count == savesBeforeExplain)
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
  let regexResult = inspect(rules: [regexRule], domain: "api.test.example")
  #expect(regexResult.decision == .indeterminate)
  #expect(regexResult.uncertaintyReason?.contains("active routing core") == true)

  let adversarialRule: [String: Any] = [
    "domain_regex": ["^(a+)+$"],
    "action": "route",
    "outbound": "direct",
  ]
  let started = ContinuousClock.now
  let adversarial = inspect(
    rules: [adversarialRule], domain: String(repeating: "a", count: 100) + "b"
  )
  #expect(adversarial.decision == .indeterminate)
  #expect(started.duration(to: .now) < .seconds(1))
}

@Test func routingInspectorPreservesImportedLiteralDomainAndPathSemantics() throws {
  let leadingDot: [[String: Any]] = [
    [
      "domain_suffix": [".example.test"], "action": "route", "outbound": "direct",
    ]
  ]
  #expect(inspect(rules: leadingDot, domain: "example.test").decision == .vpn)
  #expect(inspect(rules: leadingDot, domain: "www.example.test").decision == .direct)

  let noLeadingDot: [[String: Any]] = [
    [
      "domain_suffix": ["example.test"], "action": "route", "outbound": "direct",
    ]
  ]
  #expect(inspect(rules: noLeadingDot, domain: "example.test").decision == .direct)
  #expect(inspect(rules: noLeadingDot, domain: "www.example.test").decision == .direct)

  let uppercaseSuffix: [[String: Any]] = [
    [
      "domain_suffix": ["Example.Test"], "action": "route", "outbound": "direct",
    ]
  ]
  #expect(inspect(rules: uppercaseSuffix, domain: "example.test").decision == .vpn)

  let exactDomain: [[String: Any]] = [
    ["domain": ["example.test"], "action": "route", "outbound": "direct"]
  ]
  let uppercaseDomain: [[String: Any]] = [
    ["domain": ["Example.Test"], "action": "route", "outbound": "direct"]
  ]
  let dottedDomain: [[String: Any]] = [
    ["domain": [".example.test"], "action": "route", "outbound": "direct"]
  ]
  #expect(inspect(rules: exactDomain, domain: "example.test").decision == .direct)
  #expect(inspect(rules: uppercaseDomain, domain: "example.test").decision == .vpn)
  #expect(inspect(rules: dottedDomain, domain: "example.test").decision == .vpn)

  let managedWebsite = ManagedRoutingPlanComposer.routeRules(
    for: VPNProfile(
      connections: [],
      websiteRoutingRules: [WebsiteRoutingRule(domain: "example.test", target: .direct)]
    ),
    ipv6Enabled: true
  )
  let managedWebsiteRule = try #require(managedWebsite.last)
  #expect(inspect(rules: [managedWebsiteRule], domain: "example.test").decision == .direct)
  #expect(inspect(rules: [managedWebsiteRule], domain: "www.example.test").decision == .direct)

  func processPathResult(_ importedPath: String) -> RoutingInspectionResult {
    RoutingInspector.inspect(
      route: [
        "rules": [["process_path": [importedPath], "action": "route", "outbound": "direct"]],
        "final": "proxy-selector",
      ],
      context: RoutingInspectionContext(applicationPath: "/A/X"),
      outboundDecisions: outboundDecisions,
    )
  }
  #expect(processPathResult("/A/../A/X").decision == .vpn)
  #expect(processPathResult("/A/X").decision == .direct)
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
  #expect(inspect(rules: [logical], domain: "internal.example.ru").decision == .indeterminate)
  #expect(inspect(rules: [logical], domain: "public.example.ru").decision == .indeterminate)

  let inverted: [String: Any] = [
    "domain_suffix": [".ru"],
    "invert": true,
    "action": "route",
    "outbound": "direct",
  ]
  #expect(inspect(rules: [inverted], domain: "example.com").decision == .direct)
  #expect(inspect(rules: [inverted], domain: "example.ru").decision == .vpn)

  let processPathRegex: [String: Any] = [
    "process_path_regex": ["^/Applications/.*"],
    "action": "route",
    "outbound": "direct",
  ]
  let unsupportedRegex = RoutingInspector.inspect(
    route: ["rules": [processPathRegex], "final": "proxy-selector"],
    context: RoutingInspectionContext(applicationPath: "/Applications/Test.app/Test"),
    outboundDecisions: outboundDecisions,
  )
  #expect(unsupportedRegex.decision == .indeterminate)
  #expect(unsupportedRegex.uncertaintyReason?.contains("not supported") == true)

}

@Test func routingInspectorKeepsRemoteRuleSetMembershipUnknownLocally() {
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
      inboundTag: "tun-in"
    ).presentation(for: processResult).contains("Decision: INDETERMINATE")
  )

  let remoteRule: [String: Any] = [
    "rule_set": ["remote-geosite"],
    "action": "route",
    "outbound": "direct",
  ]
  let remoteResult = inspect(rules: [remoteRule], domain: "example.com")
  #expect(remoteResult.decision == .indeterminate)
  #expect(
    remoteResult.uncertaintyReason?.contains("remote rule-set membership is unknown locally")
      == true)
  #expect(remoteResult.uncertaintyReason?.contains("remote-geosite") == true)
  #expect(remoteResult.fallback?.decision == .vpn)
  #expect(remoteResult.alternatives.contains { $0.decision == .direct })
  #expect(remoteResult.alternatives.contains { $0.decision == .vpn })

  let remoteWithNonmatchingDomain = inspect(
    rules: [
      [
        "domain": ["outer.test"],
        "rule_set": ["remote-geosite"],
        "action": "route",
        "outbound": "direct",
      ]
    ],
    domain: "inner.test"
  )
  #expect(remoteWithNonmatchingDomain.decision == .indeterminate)

  let remoteWithNonmatchingIP = RoutingInspector.inspect(
    route: [
      "rules": [
        [
          "ip_cidr": ["203.0.113.0/24"],
          "rule_set": ["remote-geosite"],
          "action": "route",
          "outbound": "direct",
        ]
      ],
      "final": "proxy-selector",
    ],
    context: RoutingInspectionContext(ipAddress: "198.51.100.42"),
    outboundDecisions: outboundDecisions
  )
  #expect(remoteWithNonmatchingIP.decision == .indeterminate)

  let sourceCIDRRule: [String: Any] = [
    "rule_set": ["remote-geosite"],
    "rule_set_ip_cidr_match_source": true,
    "action": "route",
    "outbound": "direct",
  ]
  let sourceCIDRResult = inspect(rules: [sourceCIDRRule], domain: "example.com")
  #expect(sourceCIDRResult.decision == .indeterminate)
  #expect(sourceCIDRResult.uncertaintyReason?.contains("source address metadata") == true)

  let modeMismatch = RoutingInspector.inspect(
    route: [
      "rules": [
        [
          "clash_mode": [RoutingMode.global.rawValue],
          "rule_set": ["remote-geosite"],
          "action": "route",
          "outbound": "direct",
        ]
      ],
      "final": "proxy-selector",
    ],
    context: RoutingInspectionContext(domain: "inner.test", mode: .rule),
    outboundDecisions: outboundDecisions
  )
  #expect(modeMismatch.decision == .vpn)

  let rejectResult = RoutingInspector.inspect(
    route: [
      "rules": [["rule_set": ["remote-geosite"], "action": "reject"]],
      "final": "proxy-selector",
    ],
    context: RoutingInspectionContext(domain: "example.com"),
    outboundDecisions: outboundDecisions
  )
  #expect(rejectResult.decision == .indeterminate)

  let unresolvedIP = inspect(
    rules: [["ip_cidr": ["203.0.113.0/24"], "action": "route", "outbound": "direct"]],
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
  )
  let ipv6 = RoutingInspector.inspect(
    route: route,
    context: RoutingInspectionContext(ipAddress: "2001:db8::8"),
    outboundDecisions: decisions,
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
  )

  #expect(result.decision == .indeterminate)
  #expect(Set(result.alternatives.map(\.outboundTag)) == Set(["vpn-a", "vpn-b"]))
  #expect(result.alternatives.count == 2)
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
  )

  #expect(result.analysisLimited)
  #expect(result.decision == .indeterminate)
  #expect(result.alternatives.isEmpty)
}
