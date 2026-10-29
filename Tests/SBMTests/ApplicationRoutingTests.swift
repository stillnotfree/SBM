import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

@MainActor
private func waitForApplicationRoutingCondition(
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

@Test func transmissionDirectVPNAndRejectCandidatesPassExactPinnedCore() throws {
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let core = project.appendingPathComponent(".vendor/sing-box")
  let actualCoreDigest = try TestProcessSupport.run(
    executableURL: URL(fileURLWithPath: "/usr/bin/shasum"),
    arguments: ["-a", "256", core.path]
  )
  #expect(actualCoreDigest.status == 0)
  #expect(actualCoreDigest.output.hasPrefix(CoreBuildInfo.signedSHA256))
  let coreVersion = try TestProcessSupport.run(executableURL: core, arguments: ["version"])
  #expect(coreVersion.status == 0)
  #expect(coreVersion.output.hasPrefix("sing-box version \(CoreBuildInfo.version)\n"))
  #expect(coreVersion.output.contains("Revision: \(CoreBuildInfo.revision)\n"))
  #expect(coreVersion.output.contains("Environment: \(CoreBuildInfo.goVersion) darwin/arm64\n"))
  #expect(coreVersion.output.contains("Tags: \(CoreBuildInfo.buildTags)\n"))
  #expect(coreVersion.output.contains("CGO: \(CoreBuildInfo.cgo)\n"))
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMTransmissionRouting-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  for target in [ApplicationRoutingTarget.direct, .selectedProxy, .reject] {
    let profile = VPNProfile(
      connections: [testApplicationConnection(id: ProxyNodeID(rawValue: "node-transmission"))],
      routingPolicy: RoutingPolicy(
        configuration: Data(
          #"{"route":{"rules":[{"domain_suffix":[".import.example.test"],"action":"route","outbound":"direct"}]}}"#
            .utf8
        )
      ),
      applicationRoutingRules: [
        ApplicationRoutingRule(
          displayName: "Transmission",
          bundlePath: "/Applications/Transmission.app",
          executablePath: "/Applications/Transmission.app/Contents/MacOS/Transmission",
          target: target
        )
      ],
      websiteRoutingRules: [
        WebsiteRoutingRule(domain: "site.example.test", target: .direct)
      ]
    )
    let built = try ConfigBuilder(
      cachePath: temporary.appendingPathComponent("cache.db").path,
      apiSecret: "transmission-test-secret"
    ).makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
    let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
    let route = try #require(root["route"] as? [String: Any])
    let rules = try #require(route["rules"] as? [[String: Any]])
    let processRule = try #require(
      rules.first {
        ($0["process_path"] as? [String])
          == ["/Applications/Transmission.app/Contents/MacOS/Transmission"]
      }
    )
    let filename: String
    switch target {
    case .direct:
      filename = "direct"
      #expect(processRule["action"] as? String == "route")
      #expect(processRule["outbound"] as? String == "direct")
    case .selectedProxy:
      filename = "vpn"
      #expect(processRule["action"] as? String == "route")
      #expect(processRule["outbound"] as? String == "proxy-selector")
    case .reject:
      filename = "reject"
      #expect(processRule["action"] as? String == "reject")
      #expect(processRule["outbound"] == nil)
    case .node:
      Issue.record("Unexpected fixed-node target in this regression")
      filename = "unexpected"
    }

    let dns = try #require(root["dns"] as? [String: Any])
    let dnsRules = try #require(dns["rules"] as? [[String: Any]])
    let appDNS = dnsRules.first {
      ($0["process_path"] as? [String])
        == ["/Applications/Transmission.app/Contents/MacOS/Transmission"]
    }
    if target == .direct {
      #expect(appDNS?["action"] as? String == "route")
      #expect(appDNS?["server"] as? String == "dns-local")
      let directModeIndex = try #require(
        dnsRules.firstIndex { $0["clash_mode"] as? String == RoutingMode.direct.rawValue }
      )
      let appDNSIndex = try #require(
        dnsRules.firstIndex {
          $0["process_path"] as? [String]
            == ["/Applications/Transmission.app/Contents/MacOS/Transmission"]
        }
      )
      let websiteDirectIndex = try #require(
        dnsRules.firstIndex { $0["domain"] as? [String] == ["site.example.test"] }
      )
      let importedDirectIndex = try #require(
        dnsRules.firstIndex {
          $0["domain_suffix"] as? [String] == [".import.example.test"]
        }
      )
      let remoteIndex = try #require(
        dnsRules.firstIndex { $0["server"] as? String == "dns-remote" })
      #expect(directModeIndex < appDNSIndex)
      #expect(appDNSIndex < websiteDirectIndex)
      #expect(websiteDirectIndex < importedDirectIndex)
      #expect(importedDirectIndex < remoteIndex)
    } else {
      #expect(appDNS == nil)
    }

    let configURL = temporary.appendingPathComponent("\(filename).json")
    try built.data.write(to: configURL)
    let result = try TestProcessSupport.run(
      executableURL: core,
      arguments: ["check", "-c", configURL.path]
    )
    #expect(result.status == 0, Comment(rawValue: result.output))
  }
}

@Test func applicationRejectUsesNativeActionAtManagedPrecedence() throws {
  let executablePath = "/Applications/Transmission.app/Contents/MacOS/Transmission"
  let profile = VPNProfile(
    connections: [testApplicationConnection(id: ProxyNodeID(rawValue: "node-reject"))],
    routingPolicy: RoutingPolicy(
      configuration: Data(
        #"{"route":{"rules":[{"domain_suffix":["example.test"],"action":"route","outbound":"direct"}]}}"#
          .utf8
      )
    ),
    applicationRoutingRules: [
      ApplicationRoutingRule(
        displayName: "Transmission",
        bundlePath: "/Applications/Transmission.app",
        executablePath: executablePath,
        target: .reject
      )
    ]
  )
  let built = try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
    .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let route = try #require(root["route"] as? [String: Any])
  let rules = try #require(route["rules"] as? [[String: Any]])
  let privateIndex = try #require(rules.firstIndex { $0["ip_is_private"] as? Bool == true })
  let rejectIndex = try #require(
    rules.firstIndex { ($0["process_path"] as? [String]) == [executablePath] })
  let importedIndex = try #require(
    rules.firstIndex { ($0["domain_suffix"] as? [String]) == ["example.test"] })

  #expect(rejectIndex < privateIndex)
  #expect(rejectIndex < importedIndex)
  #expect(rules[rejectIndex]["action"] as? String == "reject")
  #expect(rules[rejectIndex]["outbound"] == nil)
}

@Test func applicationRejectTargetRoundTripsThroughPersistenceEncoding() throws {
  let rule = ApplicationRoutingRule(
    displayName: "Transmission",
    bundlePath: "/Applications/Transmission.app",
    executablePath: "/Applications/Transmission.app/Contents/MacOS/Transmission",
    target: .reject
  )
  #expect(
    try JSONDecoder().decode(ApplicationRoutingRule.self, from: JSONEncoder().encode(rule)) == rule)
}

@Test func applicationRulesUseExactPathsTargetsAndManagedPrecedence() throws {
  let node = ProxyNodeID(rawValue: "node-fixed")
  let connection = testApplicationConnection(id: node)
  let imported = RoutingPolicy(
    configuration: Data(
      #"{"route":{"rules":[{"domain_suffix":["example.test"],"action":"route","outbound":"direct"}]}}"#
        .utf8
    )
  )
  let rules = [
    ApplicationRoutingRule(
      displayName: "Direct App",
      bundlePath: "/Applications/Direct App.APP",
      executablePath: "/Applications/Direct App.APP/Contents/MacOS/Direct App",
      target: .direct
    ),
    ApplicationRoutingRule(
      displayName: "Current App",
      bundlePath: "/Applications/Current.app",
      executablePath: "/Applications/Current.app/Contents/MacOS/Current",
      target: .selectedProxy
    ),
    ApplicationRoutingRule(
      displayName: "Fixed App",
      bundlePath: "/Applications/Fixed.app",
      executablePath: "/Applications/Fixed.app/Contents/MacOS/Fixed",
      target: .node(node)
    ),
  ]
  let profile = VPNProfile(
    connections: [connection],
    routingPolicy: imported,
    applicationRoutingRules: rules
  )
  let built = try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
    .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let route = try #require(root["route"] as? [String: Any])
  let composed = try #require(route["rules"] as? [[String: Any]])

  let privateIndex = try #require(composed.firstIndex { $0["ip_is_private"] as? Bool == true })
  let directIndex = try #require(
    composed.firstIndex {
      ($0["process_path"] as? [String])
        == ["/Applications/Direct App.APP/Contents/MacOS/Direct App"]
    })
  let importedIndex = try #require(
    composed.firstIndex { ($0["domain_suffix"] as? [String]) == ["example.test"] })
  let directModeIndex = try #require(
    composed.firstIndex { ($0["clash_mode"] as? String) == RoutingMode.direct.rawValue })
  let globalModeIndex = try #require(
    composed.firstIndex { ($0["clash_mode"] as? String) == RoutingMode.global.rawValue })
  #expect(directIndex < directModeIndex)
  #expect(directIndex < globalModeIndex)
  #expect(directIndex < privateIndex)
  #expect(directIndex < importedIndex)
  #expect(composed[directIndex]["outbound"] as? String == "direct")
  #expect(
    composed.first {
      ($0["process_path"] as? [String])
        == ["/Applications/Current.app/Contents/MacOS/Current"]
    }?["outbound"] as? String == "proxy-selector"
  )
  #expect(
    composed.first {
      ($0["process_path"] as? [String])
        == ["/Applications/Fixed.app/Contents/MacOS/Fixed"]
    }?["outbound"] as? String == node.rawValue
  )
}

@Test func missingFixedApplicationNodeIsInactiveAndInvalidPathFailsClosed() throws {
  let profile = VPNProfile(
    connections: [testApplicationConnection(id: ProxyNodeID(rawValue: "node-present"))],
    applicationRoutingRules: [
      ApplicationRoutingRule(
        displayName: "Missing",
        bundlePath: "/Applications/Missing.app",
        executablePath: "/Applications/Missing.app/Contents/MacOS/Missing",
        target: .node(ProxyNodeID(rawValue: "node-gone"))
      )
    ]
  )
  let built = try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
    .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let route = try #require(root["route"] as? [String: Any])
  let composed = try #require(route["rules"] as? [[String: Any]])
  #expect(!composed.contains { $0["process_path"] != nil })
  let dns = try #require(root["dns"] as? [String: Any])
  let dnsRules = try #require(dns["rules"] as? [[String: Any]])
  #expect(!dnsRules.contains { $0["process_path"] != nil })

  let invalid = VPNProfile(
    connections: profile.connections,
    applicationRoutingRules: [
      ApplicationRoutingRule(
        displayName: "Escape",
        bundlePath: "/Applications/Escape.app",
        executablePath: "/usr/bin/escape",
        target: .direct
      )
    ]
  )
  #expect(throws: CoreFailure.self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .compatibility(invalid), mode: .rule, selectedNode: .auto)
  }
}

@Test func applicationPathsRoundTripUnicodeSpacesAndRejectDuplicates() throws {
  let executablePath = "/Applications/Пример App.app/Contents/MacOS/Пример App"
  let rule = ApplicationRoutingRule(
    displayName: "Пример App",
    bundlePath: "/Applications/Пример App.app",
    executablePath: executablePath,
    target: .direct
  )
  let profile = VPNProfile(
    connections: [testApplicationConnection(id: ProxyNodeID(rawValue: "node-present"))],
    applicationRoutingRules: [rule]
  )
  let built = try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
    .makeConfiguration(profile: .compatibility(profile), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let route = try #require(root["route"] as? [String: Any])
  let rules = try #require(route["rules"] as? [[String: Any]])
  #expect(rules.contains { ($0["process_path"] as? [String]) == [executablePath] })

  let duplicate = VPNProfile(
    connections: profile.connections,
    applicationRoutingRules: [
      rule,
      ApplicationRoutingRule(
        displayName: "Duplicate",
        bundlePath: rule.bundlePath,
        executablePath: rule.executablePath,
        target: .selectedProxy
      ),
    ]
  )
  #expect(throws: CoreFailure.self) {
    try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
      .makeConfiguration(profile: .compatibility(duplicate), mode: .rule, selectedNode: .auto)
  }
}

@Test func sharedRoutingCompositionIsModeAndSelectionIndependent() throws {
  let executablePath = "/Applications/Browser.app/Contents/MacOS/Browser"
  let node = ProxyNodeID(rawValue: "node-present")
  let profile = VPNProfile(
    connections: [testApplicationConnection(id: node)],
    routingPolicy: RoutingPolicy(
      configuration: Data(
        #"{"route":{"rules":[{"domain_suffix":[".import.example.test"],"action":"route","outbound":"direct"}]}}"#
          .utf8
      )
    ),
    applicationRoutingRules: [
      ApplicationRoutingRule(
        displayName: "Browser",
        bundlePath: "/Applications/Browser.app",
        executablePath: executablePath,
        target: .direct
      )
    ],
    websiteRoutingRules: [
      WebsiteRoutingRule(domain: "site.example.test", target: .direct)
    ]
  )
  var expectedRules: [[String: Any]]?

  for mode in RoutingMode.allCases {
    for selectedNode in [ProxyNodeID.auto, node] {
      let built = try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
        .makeConfiguration(
          profile: .compatibility(profile),
          mode: mode,
          selectedNode: selectedNode
        )
      let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
      let route = try #require(root["route"] as? [String: Any])
      let rules = try #require(route["rules"] as? [[String: Any]])
      let defaults = try #require(root["experimental"] as? [String: Any])
      let clashAPI = try #require(defaults["clash_api"] as? [String: Any])
      #expect(clashAPI["default_mode"] as? String == mode.rawValue)
      let directAppIndex = try #require(
        rules.firstIndex { $0["process_path"] as? [String] == [executablePath] }
      )
      let directModeIndex = try #require(
        rules.firstIndex { $0["clash_mode"] as? String == RoutingMode.direct.rawValue }
      )
      let globalModeIndex = try #require(
        rules.firstIndex { $0["clash_mode"] as? String == RoutingMode.global.rawValue }
      )
      let privateIndex = try #require(
        rules.firstIndex { $0["ip_is_private"] as? Bool == true }
      )
      let websiteIndex = try #require(
        rules.firstIndex { $0["domain"] as? [String] == ["site.example.test"] }
      )
      let importedIndex = try #require(
        rules.firstIndex { $0["domain_suffix"] as? [String] == [".import.example.test"] }
      )
      #expect(directAppIndex < directModeIndex)
      #expect(directAppIndex < globalModeIndex)
      #expect(directAppIndex < privateIndex)
      #expect(directAppIndex < websiteIndex)
      #expect(websiteIndex < importedIndex)

      let dns = try #require(root["dns"] as? [String: Any])
      let dnsRules = try #require(dns["rules"] as? [[String: Any]])
      #expect(dnsRules[0]["clash_mode"] as? String == RoutingMode.direct.rawValue)
      #expect(dnsRules[1]["process_path"] as? [String] == [executablePath])
      #expect(dnsRules[1]["action"] as? String == "route")
      #expect(dnsRules[1]["server"] as? String == "dns-local")
      #expect(dnsRules[2]["domain"] as? [String] == ["site.example.test"])
      #expect(dnsRules[2]["server"] as? String == "dns-local")
      #expect(dnsRules[3]["domain_suffix"] as? [String] == [".import.example.test"])
      #expect(dnsRules[3]["server"] as? String == "dns-local")
      #expect(dnsRules.last?["server"] as? String == "dns-remote")

      let inspection = try ComposedRoutingInspection.make(
        profile: .compatibility(profile),
        selectedNode: selectedNode
      )
      #expect(
        try JSONSerialization.data(withJSONObject: inspection.route, options: [.sortedKeys])
          == JSONSerialization.data(withJSONObject: route, options: [.sortedKeys])
      )
      if let expectedRules {
        #expect(
          try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
            == JSONSerialization.data(withJSONObject: expectedRules, options: [.sortedKeys])
        )
      } else {
        expectedRules = rules
      }
    }
  }
}

@Test @MainActor
func applicationBundleResolverUsesDeclaredMainExecutableAndRejectsInvalidBundle() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMApplicationResolver-\(UUID().uuidString)", isDirectory: true)
  let bundleURL = directory.appendingPathComponent("Declared.app", isDirectory: true)
  let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
  let executableURL = contentsURL.appendingPathComponent("MacOS/DeclaredMain", isDirectory: false)
  try FileManager.default.createDirectory(
    at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("#!/bin/sh\n".utf8).write(to: executableURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
  try Data(
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>DeclaredMain</string>
      <key>CFBundleIdentifier</key><string>test.sbm.declared</string>
      <key>CFBundleDisplayName</key><string>Declared Application</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
    """.utf8
  ).write(to: contentsURL.appendingPathComponent("Info.plist"))
  defer { try? FileManager.default.removeItem(at: directory) }

  let resolved = try ApplicationBundleResolver.resolve(bundleURL)
  #expect(resolved.bundleURL == bundleURL.standardizedFileURL)
  #expect(resolved.executableURL == executableURL.standardizedFileURL)
  #expect(resolved.displayName == "Declared Application")

  let profileID = UUID()
  let library = ProfileLibrary(
    profiles: [
      ManagedProfile(
        id: profileID,
        name: "Applications",
        payload: .compatibility(
          VPNProfile(
            connections: [testApplicationConnection(id: ProxyNodeID(rawValue: "node-app"))]
          ))
      )
    ],
    selectedProfileID: profileID
  )
  let model = AppModel(
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    profileLibraryLoader: { library },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.addApplicationRoutingRule(from: bundleURL, profileID: profileID)
  #expect(
    await waitForApplicationRoutingCondition {
      !model.applicationRoutingRules.isEmpty || model.lastError != nil
    }
  )
  #expect(model.applicationRoutingRules.count == 1)
  #expect(model.applicationRoutingRules.first?.displayName == "Declared Application")
  #expect(model.applicationRoutingRules.first?.target == .selectedProxy)

  let invalidURL = directory.appendingPathComponent("Invalid.app", isDirectory: true)
  try FileManager.default.createDirectory(at: invalidURL, withIntermediateDirectories: true)
  #expect(throws: ApplicationBundleResolutionFailure.self) {
    try ApplicationBundleResolver.resolve(invalidURL)
  }
  model.addApplicationRoutingRule(from: invalidURL, profileID: profileID)
  #expect(model.applicationRoutingRules.count == 1)
  #expect(model.lastError?.contains("main executable") == true)
}

@Test @MainActor func movedApplicationIsReportedUnresolvedWithoutNameGuessing() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMApplicationRule-\(UUID().uuidString)", isDirectory: true)
  let bundleURL = directory.appendingPathComponent("Exact.app", isDirectory: true)
  let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
  let executableURL = contentsURL.appendingPathComponent("MacOS/Exact", isDirectory: false)
  try FileManager.default.createDirectory(
    at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("#!/bin/sh\n".utf8).write(to: executableURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
  try Data(
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>Exact</string>
      <key>CFBundleIdentifier</key><string>test.sbm.exact</string>
      <key>CFBundleName</key><string>Exact</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
    """.utf8
  ).write(to: contentsURL.appendingPathComponent("Info.plist"))
  defer { try? FileManager.default.removeItem(at: directory) }

  let rule = ApplicationRoutingRule(
    displayName: "Exact",
    bundlePath: bundleURL.path,
    executablePath: executableURL.path,
    target: .direct
  )
  let profileID = UUID()
  let library = ProfileLibrary(
    profiles: [
      ManagedProfile(
        id: profileID,
        name: "Applications",
        payload: .compatibility(
          VPNProfile(
            connections: [testApplicationConnection(id: ProxyNodeID(rawValue: "node-app"))],
            applicationRoutingRules: [rule]
          ))
      )
    ],
    selectedProfileID: profileID
  )
  let model = AppModel(
    profileLibraryLoader: { library },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  #expect(model.applicationRoutingRuleIsResolved(rule))

  let movedURL = directory.appendingPathComponent("Moved.app")
  try FileManager.default.moveItem(at: bundleURL, to: movedURL)
  #expect(!model.applicationRoutingRuleIsResolved(rule))
}

@Test @MainActor
func applicationPickerMutationRemainsBoundToOriginatingProfileAfterSelectionChanges() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMApplicationOrigin-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bundleURL = directory.appendingPathComponent("Chosen.app", isDirectory: true)
  let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
  let executableURL = contentsURL.appendingPathComponent("MacOS/Chosen", isDirectory: false)
  try FileManager.default.createDirectory(
    at: executableURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("#!/bin/sh\n".utf8).write(to: executableURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
  try Data(
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>Chosen</string>
      <key>CFBundleIdentifier</key><string>test.sbm.chosen</string>
      <key>CFBundleDisplayName</key><string>Chosen Application</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
    """.utf8
  ).write(to: contentsURL.appendingPathComponent("Info.plist"))

  let profileA = ManagedProfile(
    name: "A",
    payload: .compatibility(
      VPNProfile(connections: [testApplicationConnection(id: ProxyNodeID(rawValue: "node-a"))])
    )
  )
  let profileB = ManagedProfile(
    name: "B",
    payload: .compatibility(
      VPNProfile(connections: [testApplicationConnection(id: ProxyNodeID(rawValue: "node-b"))])
    )
  )
  let library = ProfileLibrary(
    profiles: [profileA, profileB],
    selectedProfileID: profileA.id
  )
  let model = AppModel(
    profileValidator: { _ in
      HelperResponse(success: true, coreRunning: false, message: "valid")
    },
    profileLibraryLoader: { library },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision

  model.addApplicationRoutingRule(from: bundleURL, profileID: profileA.id)
  model.selectProfile(profileB.id)
  #expect(model.selectedProfileID == profileB.id)
  #expect(
    await waitForApplicationRoutingCondition {
      model.profiles.first(where: { $0.id == profileA.id })
        .flatMap { $0.payload?.applicationRoutingRules }?.count == 1
    }
  )

  let savedA = try #require(
    model.profiles.first(where: { $0.id == profileA.id })?.payload?.applicationRoutingRules
  )
  let savedB = try #require(
    model.profiles.first(where: { $0.id == profileB.id })?.payload?.applicationRoutingRules
  )
  #expect(savedA.count == 1)
  #expect(savedA.first?.displayName == "Chosen Application")
  #expect(savedB.isEmpty)
  #expect(model.selectedProfileID == profileB.id)
}

private func testApplicationConnection(id: ProxyNodeID) -> ManagedConnection {
  ManagedConnection(
    id: id,
    outbound: .shadowsocks(
      ShadowsocksProfile(
        server: "ss.example.test",
        port: 443,
        method: "aes-256-gcm",
        password: "test-password",
        displayName: "Test"
      ))
  )
}
