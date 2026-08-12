import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

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

private enum InspectorRuleSetMatcherFailure: Error {
  case transient
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
  #expect(unresolved.ruleIndex == 7)
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
      mode: .rule,
      inboundTag: composed.inboundTag,
      applicationPath: applicationPath
    ),
    outboundDecisions: composed.outboundDecisions,
    selectorOutbound: composed.selectorOutbound
  )

  #expect(defaultResult.decision == .direct)
  #expect(defaultResult.ruleIndex == 7)
  #expect(applicationResult.decision == .vpn)
  #expect(applicationResult.ruleIndex == 5)
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
      == "Traffic from: Transmission\nRule: 6")
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
  #expect(source.contains(".fixedSize()"))
  #expect(source.contains(".fixedSize(horizontal: true, vertical: false)"))
  #expect(!source.contains(".frame(minWidth: 220, idealWidth: 260, maxWidth: 320)"))
  #expect(source.contains(#"Text("Proxy").tag(ApplicationRoutingTarget.selectedProxy)"#))
  #expect(source.contains(#"prompt: Text("(?i)lte|russia")"#))
  #expect(source.contains(#"LabeledContent("Exclude regex (optional)")"#))
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
  #expect(model.routingInspectorOutput == "PROXY · Auto\nMatched: Final route")
  #expect(model.routingInspectorDetails.contains("Traffic from: Default traffic"))
  await runtime.complete(profileID: profileID)
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
  #expect(model.selectedNodeID == nodeID)
  #expect(model.routingInspectorOutput == "PROXY · Germany\nMatched: Final route")
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
  #expect(unresolvedIP.uncertaintyReason?.contains("resolved destination IP") == true)
  #expect(unresolvedIP.fallback?.decision == .vpn)
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
