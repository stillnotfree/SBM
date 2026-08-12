import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

@Test func transmissionDirectVPNAndRejectCandidatesPassExactBundledCore() throws {
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let core = project.appendingPathComponent(".vendor/sing-box")
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMTransmissionRouting-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  for target in [ApplicationRoutingTarget.direct, .selectedProxy, .reject] {
    let profile = VPNProfile(
      connections: [testApplicationConnection(id: ProxyNodeID(rawValue: "node-transmission"))],
      applicationRoutingRules: [
        ApplicationRoutingRule(
          displayName: "Transmission",
          bundlePath: "/Applications/Transmission.app",
          executablePath: "/Applications/Transmission.app/Contents/MacOS/Transmission",
          target: target
        )
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

    let configURL = temporary.appendingPathComponent("\(filename).json")
    try built.data.write(to: configURL)
    let process = Process()
    let output = Pipe()
    process.executableURL = core
    process.arguments = ["check", "-c", configURL.path]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let message =
      String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, Comment(rawValue: message))
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

  #expect(privateIndex < rejectIndex)
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
  #expect(privateIndex < directIndex)
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

@Test func nativeApplicationRulesPrecedeImportedRoutingAndUseNativeTargets() throws {
  let source = Data(
    """
    {
      "outbounds": [
        {"type":"socks","tag":"office","server":"203.0.113.20","server_port":1080}
      ],
      "route": {
        "rules": [
          {"domain_suffix":["example.test"],"action":"route","outbound":"office"}
        ]
      }
    }
    """.utf8
  )
  let parsed = try NativeProfileParser.parse(source)
  #expect(parsed.nodes.map(\.kind) == [.automatic, .native])
  let native = NativeProfile(
    configuration: parsed.configuration,
    selectorTag: parsed.selectorTag,
    nodes: parsed.nodes,
    applicationRoutingRules: [
      ApplicationRoutingRule(
        displayName: "Current",
        bundlePath: "/Applications/Current.app",
        executablePath: "/Applications/Current.app/Contents/MacOS/Current",
        target: .selectedProxy
      ),
      ApplicationRoutingRule(
        displayName: "Office",
        bundlePath: "/Applications/Office.app",
        executablePath: "/Applications/Office.app/Contents/MacOS/Office",
        target: .node(ProxyNodeID(rawValue: "office"))
      ),
      ApplicationRoutingRule(
        displayName: "Not a fixed server",
        bundlePath: "/Applications/Auto.app",
        executablePath: "/Applications/Auto.app/Contents/MacOS/Auto",
        target: .node(ProxyNodeID(rawValue: "sbm-auto"))
      ),
    ]
  )
  let built = try ConfigBuilder(cachePath: "/tmp/cache", apiSecret: "secret")
    .makeConfiguration(profile: .native(native), mode: .rule, selectedNode: .auto)
  let root = try #require(JSONSerialization.jsonObject(with: built.data) as? [String: Any])
  let route = try #require(root["route"] as? [String: Any])
  let rules = try #require(route["rules"] as? [[String: Any]])
  let inspected = try ComposedRoutingInspection.make(profile: .native(native))
  #expect(
    try JSONSerialization.data(withJSONObject: inspected.route, options: [.sortedKeys])
      == JSONSerialization.data(withJSONObject: route, options: [.sortedKeys])
  )
  let privateIndex = try #require(rules.firstIndex { $0["ip_is_private"] as? Bool == true })
  let currentIndex = try #require(
    rules.firstIndex {
      ($0["process_path"] as? [String])
        == ["/Applications/Current.app/Contents/MacOS/Current"]
    })
  let importedIndex = try #require(
    rules.firstIndex { ($0["domain_suffix"] as? [String]) == ["example.test"] })
  #expect(privateIndex < currentIndex)
  #expect(currentIndex < importedIndex)
  #expect(rules[currentIndex]["outbound"] as? String == built.selectorTag)
  #expect(
    rules.first {
      ($0["process_path"] as? [String])
        == ["/Applications/Office.app/Contents/MacOS/Office"]
    }?["outbound"] as? String == "office"
  )
  #expect(
    !rules.contains {
      ($0["process_path"] as? [String]) == ["/Applications/Auto.app/Contents/MacOS/Auto"]
    }
  )
}

@Test func applicationRuleSchemaMigrationPreservesManagedIDsAndOldNativeProfilesDecode() throws {
  let stableID = ProxyNodeID(rawValue: "node-v2-preserved")
  let profileID = UUID()
  let library = ProfileLibrary(
    profiles: [
      ManagedProfile(
        id: profileID,
        name: "Version 2",
        payload: .compatibility(
          VPNProfile(connections: [testApplicationConnection(id: stableID)]))
      )
    ],
    selectedProfileID: profileID
  )
  var root = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as? [String: Any])
  root["schemaVersion"] = 2
  let decoded = try JSONDecoder().decode(
    ProfileLibrary.self,
    from: JSONSerialization.data(withJSONObject: root)
  )
  #expect(decoded.requiresMigration)
  guard case .compatibility(let decodedProfile) = try #require(decoded.profiles[0].payload) else {
    Issue.record("Expected a compatibility profile")
    return
  }
  #expect(decodedProfile.connections.map(\.id) == [stableID])
  #expect(decodedProfile.applicationRoutingRules.isEmpty)

  let native = NativeProfile(
    configuration: Data(#"{"outbounds":[]}"#.utf8),
    selectorTag: "proxy",
    nodes: []
  )
  var nativeRoot = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(native)) as? [String: Any])
  nativeRoot.removeValue(forKey: "applicationRoutingRules")
  let oldNative = try JSONDecoder().decode(
    NativeProfile.self,
    from: JSONSerialization.data(withJSONObject: nativeRoot)
  )
  #expect(oldNative.applicationRoutingRules.isEmpty)
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
    performStartup: false
  )
  model.helperEnabled = true
  model.helperReachable = true
  model.helperVersion = HelperConstants.helperVersion
  model.helperRevision = HelperConstants.helperRevision
  model.addApplicationRoutingRule(from: bundleURL)
  for _ in 0..<100 where model.applicationRoutingRules.isEmpty && model.lastError == nil {
    try await Task.sleep(for: .milliseconds(1))
  }
  #expect(model.applicationRoutingRules.count == 1)
  #expect(model.applicationRoutingRules.first?.displayName == "Declared Application")
  #expect(model.applicationRoutingRules.first?.target == .selectedProxy)

  let invalidURL = directory.appendingPathComponent("Invalid.app", isDirectory: true)
  try FileManager.default.createDirectory(at: invalidURL, withIntermediateDirectories: true)
  #expect(throws: ApplicationBundleResolutionFailure.self) {
    try ApplicationBundleResolver.resolve(invalidURL)
  }
  model.addApplicationRoutingRule(from: invalidURL)
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
    performStartup: false
  )
  #expect(model.applicationRoutingRuleIsResolved(rule))

  let movedURL = directory.appendingPathComponent("Moved.app")
  try FileManager.default.moveItem(at: bundleURL, to: movedURL)
  #expect(!model.applicationRoutingRuleIsResolved(rule))
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
