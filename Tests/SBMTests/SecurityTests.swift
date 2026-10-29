import CryptoKit
import Foundation
import SBMShared
import Testing

@testable import SBM
@testable import SBMHelper

private struct ReleasedV9RequestShape: Decodable {
  let protocolVersion: Int
  let profile: ReleasedV9CoreProfile?
}

private struct ReleasedV9CoreProfile: Decodable {
  let compatibility: ReleasedV9ProfileWrapper
}

private struct ReleasedV9ProfileWrapper: Decodable {
  let value: ReleasedV9Profile

  private enum CodingKeys: String, CodingKey {
    case value = "_0"
  }
}

private struct ReleasedV9Profile: Decodable {
  let connections: [ReleasedV9Connection]
}

private struct ReleasedV9Connection: Decodable {
  let outbound: ReleasedV9Outbound
}

private enum ReleasedV9Outbound: Decodable {
  private enum CodingKeys: String, CodingKey {
    case kind, vless
  }

  private enum Kind: String, Decodable {
    case vless
  }

  case vless(ReleasedV9VLESS)

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .vless:
      self = .vless(try container.decode(ReleasedV9VLESS.self, forKey: .vless))
    }
  }
}

private struct ReleasedV9VLESS: Decodable {
  let displayName: String
}

@Test func currentIPCShapeRequiresTheNewProtocolBoundary() throws {
  #expect(HelperConstants.protocolVersion == 14)

  let profile = CoreProfile.compatibility(
    VPNProfile(
      connections: [
        ManagedConnection(
          displayName: "Current authoritative name",
          outbound: .vless(
            VLESSProfile(
              server: "203.0.113.10",
              port: 443,
              uuid: "5efab93b-90d0-4904-93d6-44b4f0b00000",
              serverName: "example.test",
              fingerprint: "chrome",
              publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
              shortID: ""
            )
          )
        )
      ]
    )
  )
  let request = HelperRequest(action: .start, profile: profile)
  let encoded = try JSONEncoder().encode(request)
  let object = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
  )
  #expect(object["ruleSetTags"] == nil)
  #expect(object["routingDestination"] == nil)
  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(
      HelperRequest.self,
      from: Data(#"{"protocolVersion":14,"action":"matchRuleSets"}"#.utf8)
    )
  }
  let profileObject = try #require(object["profile"] as? [String: Any])
  #expect(Set(profileObject.keys) == ["compatibility"])
  let compatibility = try #require(profileObject["compatibility"] as? [String: Any])
  #expect(Set(compatibility.keys) == ["_0"])
  let profilePayload = try #require(compatibility["_0"] as? [String: Any])
  #expect(
    Set(profilePayload.keys)
      == Set([
        "connections", "nodeGroups", "applicationRoutingRules", "websiteRoutingRules",
        "autoExcludedNodeIDs",
      ])
  )
  let connections = try #require(profilePayload["connections"] as? [[String: Any]])
  let connection = try #require(connections.first)
  let outbound = try #require(connection["outbound"] as? [String: Any])
  let vless = try #require(outbound["vless"] as? [String: Any])
  #expect(vless["displayName"] == nil)

  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(ReleasedV9RequestShape.self, from: encoded)
  }
}

@Test func autoObservationWireFieldsAreOptionalAndRoundTrip() throws {
  #expect(HelperConstants.protocolVersion == 14)

  let missingRequest = try JSONDecoder().decode(
    HelperRequest.self,
    from: Data(#"{"protocolVersion":14,"action":"status"}"#.utf8)
  )
  #expect(missingRequest.observeAutoNode == nil)
  #expect(missingRequest.recoverDesiredRuntime == nil)
  #expect(missingRequest.dnsSettings == nil)
  #expect((missingRequest.dnsSettings ?? .defaults) == .defaults)
  #expect((missingRequest.observeAutoNode ?? false) == false)
  #expect((missingRequest.recoverDesiredRuntime ?? false) == false)

  let deniedRequest = HelperRequest(action: .status, recoverDesiredRuntime: false)
  let deniedData = try JSONEncoder().encode(deniedRequest)
  let deniedObject = try #require(
    JSONSerialization.jsonObject(with: deniedData) as? [String: Any]
  )
  #expect(deniedObject["recoverDesiredRuntime"] as? Bool == false)
  #expect(
    try JSONDecoder().decode(HelperRequest.self, from: deniedData).recoverDesiredRuntime == false
  )

  let dnsSettings = ManagedDNSSettings(
    direct: .google,
    proxy: .customDoH("https://dns.example.test/query")
  )
  let requested = HelperRequest(
    action: .status,
    observeAutoNode: true,
    recoverDesiredRuntime: true,
    dnsSettings: dnsSettings
  )
  let decodedRequest = try JSONDecoder().decode(
    HelperRequest.self,
    from: JSONEncoder().encode(requested)
  )
  #expect(decodedRequest.observeAutoNode == true)
  #expect(decodedRequest.recoverDesiredRuntime == true)
  #expect(decodedRequest.dnsSettings == dnsSettings)

  let node = ProxyNodeID(rawValue: "active-child")
  let response = HelperResponse(
    success: true,
    coreRunning: true,
    effectiveAutoNode: node,
    message: "status"
  )
  let encodedResponse = try JSONEncoder().encode(response)
  var responseObject = try #require(
    JSONSerialization.jsonObject(with: encodedResponse) as? [String: Any]
  )
  #expect(responseObject["ruleSetMatches"] == nil)
  let decodedResponse = try JSONDecoder().decode(HelperResponse.self, from: encodedResponse)
  #expect(decodedResponse.effectiveAutoNode == node)

  responseObject.removeValue(forKey: "effectiveAutoNode")
  let missingResponse = try JSONDecoder().decode(
    HelperResponse.self,
    from: JSONSerialization.data(withJSONObject: responseObject)
  )
  #expect(missingResponse.effectiveAutoNode == nil)
}

@Test func helperAutoObservationUsesOnlyTheExistingBoundedActiveProfilePath() throws {
  let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  let repositoryRoot = testDirectory.deletingLastPathComponent().deletingLastPathComponent()
  let managerURL = repositoryRoot.appendingPathComponent("Sources/SBMHelper/CoreManager.swift")
  let serverURL = repositoryRoot.appendingPathComponent("Sources/SBMHelper/main.swift")
  let managerSource = try String(contentsOf: managerURL, encoding: .utf8)
  let serverSource = try String(contentsOf: serverURL, encoding: .utf8)
  let statusStart = try #require(managerSource.range(of: "  func status("))
  let statusEnd = try #require(
    managerSource.range(
      of: "  func reconcileDesiredRuntime(recoveryAuthorized: Bool)",
      range: statusStart.upperBound..<managerSource.endIndex
    )
  )
  let statusSource = String(managerSource[statusStart.lowerBound..<statusEnd.lowerBound])

  #expect(statusSource.contains("if observeAutoNode, coreRunning, state.selectedNode == .auto"))
  #expect(statusSource.contains("case .compatibility(let activeProfile)? = state.profile"))
  #expect(statusSource.components(separatedBy: "path: \"/proxies/auto\"").count - 1 == 1)
  #expect(statusSource.contains("timeoutSeconds: 0.25"))
  #expect(statusSource.contains("totalPhaseTimeout: true"))
  #expect(statusSource.contains("object[\"now\"] as? String"))
  #expect(statusSource.contains("activeProfile.connections.contains"))
  #expect(statusSource.contains("activeProfile.autoExcludedNodeIDs.contains"))
  #expect(managerSource.contains("timeoutSeconds: TimeInterval = 2"))
  #expect(managerSource.contains("totalPhaseTimeout: Bool = false"))
  #expect(
    managerSource.contains("? ProcessInfo.processInfo.systemUptime + timeoutSeconds"))
  #expect(!managerSource.contains("sendDeadline"))
  #expect(!managerSource.contains("receiveDeadline"))
  #expect(managerSource.contains("seconds: deadline - ProcessInfo.processInfo.systemUptime"))
  #expect(serverSource.contains("observeAutoNode: request.observeAutoNode ?? false"))
}

@Test func helperRecoveryAuthorizationIsCheckedBeforeReconciliationEffects() throws {
  let appModel = try projectSource("Sources/SBM/AppModel.swift")
  let refresh = try sourceSection(
    appModel,
    from: "  func refresh(observeAutoNode: Bool = false)",
    to: "  func refreshExternalState()"
  )
  let statusTask = try #require(refresh.range(of: "statusRefreshTask = Task {"))
  let appAuthorization = try #require(
    refresh.range(of: "let authorizeDesiredRuntimeRecovery =")
  )
  let sender = try #require(refresh.range(of: "try await helperLifecycleSender("))
  #expect(statusTask.lowerBound < appAuthorization.lowerBound)
  #expect(appAuthorization.lowerBound < sender.lowerBound)

  let helper = try projectSource("Sources/SBMHelper/main.swift")
  let handle = try sourceSection(
    helper,
    from: "private func handle(",
    to: "private func authenticatePeer("
  )
  let protocolCheck = try #require(handle.range(of: "guard request.protocolVersion =="))
  let actionDispatch = try #require(handle.range(of: "switch request.action"))
  #expect(protocolCheck.lowerBound < actionDispatch.lowerBound)
  let statusCase = try sourceSection(handle, from: "case .status:", to: "case .start:")
  #expect(
    statusCase.contains(
      "recoveryAuthorized: request.recoverDesiredRuntime ?? false"
    )
  )

  let manager = try projectSource("Sources/SBMHelper/CoreManager.swift")
  let reconciliation = try sourceSection(
    manager,
    from: "  func reconcileDesiredRuntime(recoveryAuthorized: Bool)",
    to: "  func start("
  )
  let authorization = try #require(
    reconciliation.range(of: "guard recoveryAuthorized else { return nil }")
  )
  let prepare = try #require(reconciliation.range(of: "try prepareFilesystem()"))
  let configurationProbe = try #require(
    reconciliation.range(of: "pathExistsWithoutFollowingSymlinks(configURL)")
  )
  let policy = try #require(reconciliation.range(of: "DesiredRuntimeRecoveryPolicy.decision("))
  #expect(authorization.lowerBound < prepare.lowerBound)
  #expect(authorization.lowerBound < configurationProbe.lowerBound)
  #expect(authorization.lowerBound < policy.lowerBound)

  let recoveryPolicy = try sourceSection(
    manager,
    from: "enum DesiredRuntimeRecoveryPolicy {",
    to: "enum CoreActivationDisposition"
  )
  let noPermission = try #require(
    recoveryPolicy.range(of: "guard recoveryAuthorized else { return .noAction }")
  )
  let desiredState = try #require(recoveryPolicy.range(of: "guard desiredRunning else"))
  #expect(noPermission.lowerBound < desiredState.lowerBound)
}

@Test func coldOffReplacementBindsManifestToCurrentSignedCandidateAndRechecksAfterUnregister()
  throws
{
  let helperClient = try projectSource("Sources/SBM/HelperClient.swift")
  let candidate = try sourceSection(
    helperClient,
    from: "  static func currentCandidateSnapshot(",
    to: "private static func candidateFileIdentities("
  )
  #expect(candidate.contains("CurrentReleaseManifest.verify("))
  #expect(candidate.contains("payload.appCDHash"))
  #expect(candidate.contains("payload.helperCDHash"))
  #expect(candidate.contains("staticCodeIdentity(at: paths[0], isBundle: true)"))
  #expect(candidate.contains("staticCodeIdentity(at: paths[3])"))
  #expect(candidate.contains("runningCodeIdentity()"))
  #expect(candidate.contains("payload.appVersion"))
  #expect(candidate.contains("payload.appBuild"))
  #expect(candidate.contains("payload.helperRevision == HelperConstants.helperRevision"))
  #expect(candidate.contains("payload.ipcProtocolVersion == HelperConstants.protocolVersion"))
  #expect(candidate.contains("payload.coreSHA256 == CoreBuildInfo.signedSHA256"))

  let lifecycle = try projectSource("Sources/SBM/HelperLifecycle.swift")
  let replace = try sourceSection(
    lifecycle,
    from: "  static func replace(",
    to: "  static func upgradeLegacy1115("
  )
  let candidateCheckBeforeUnregister = try #require(
    replace.range(of: "try HelperClient.validateHeldColdOffClaim(")
  )
  let unregister = try #require(replace.range(of: "try await service.unregister()"))
  let candidateRecheck = try #require(
    replace.range(
      of: "try HelperClient.validateHeldColdOffClaim(",
      range: candidateCheckBeforeUnregister.upperBound..<replace.endIndex
    )
  )
  let release = try #require(replace.range(of: "coldOffClaim.release()"))
  let register = try #require(replace.range(of: "try service.register()"))
  let attemptSnapshot = try #require(
    replace.range(of: "_ = try HelperClient.currentCandidateSnapshot(")
  )
  #expect(candidateCheckBeforeUnregister.lowerBound < unregister.lowerBound)
  #expect(unregister.lowerBound < candidateRecheck.lowerBound)
  #expect(candidateRecheck.lowerBound < release.lowerBound)
  #expect(attemptSnapshot.lowerBound < register.lowerBound)
  #expect(release.lowerBound < register.lowerBound)

  let appModel = try projectSource("Sources/SBM/AppModel.swift")
  let repair = try sourceSection(
    appModel,
    from: "  func repairHelper()",
    to: "  private func retainCurrentColdOffClaim("
  )
  #expect(repair.contains("candidateBundleURL: applicationBundleURL"))
  let retainClaim = try sourceSection(
    appModel,
    from: "  private func retainCurrentColdOffClaim(",
    to: "  func setLaunchAtLoginEnabled("
  )
  #expect(retainClaim.contains("claim.requireOFFMarker()"))
  #expect(retainClaim.contains("ColdOffProof.acquireClaim()"))
  #expect(!retainClaim.contains("HelperClient.validateHeldColdOffClaim"))
  #expect(!retainClaim.contains("HelperClient.acquireColdOffClaim"))
}

@Test func helperLatencyHistoryUsesSingBoxValuesInStateOrder() throws {
  let nodes = [
    ProxyNodeDescriptor(id: .auto, name: "Auto", kind: .automatic),
    ProxyNodeDescriptor(id: ProxyNodeID(rawValue: "second"), name: "Second"),
    ProxyNodeDescriptor(id: ProxyNodeID(rawValue: "empty"), name: "Empty"),
    ProxyNodeDescriptor(id: ProxyNodeID(rawValue: "missing"), name: "Missing"),
  ]
  let json =
    #"{"proxies":{"second":{"history":[{"delay":82}]},"auto":{"history":[{"delay":37}]},"empty":{"history":[]},"missing":{"history":[{"delay":"bad"}]},"ignored":{"history":[{"delay":999}]}}}"#

  let delays = try parseLatencyHistory(Data(json.utf8), nodes: nodes)

  #expect(delays.map(\.node) == nodes.map(\.id))
  #expect(delays.map(\.milliseconds) == [37, 82, nil, nil])
}

@Test func helperLatencyRejectsAutoAndMalformedProxyResponses() {
  #expect(throws: CoreFailure.self) {
    try CoreManager().testLatency(node: .auto)
  }
  #expect(throws: CoreFailure.self) {
    try parseLatencyHistory(Data(#"{"unexpected":{}}"#.utf8), nodes: [])
  }
}

@Test func latencyCleanupRemovesBlockingBulkAndUsesBoundedSingleSender() throws {
  let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  let repositoryRoot = testDirectory.deletingLastPathComponent().deletingLastPathComponent()
  let helperSource = try String(
    contentsOf: repositoryRoot.appendingPathComponent("Sources/SBMHelper/CoreManager.swift"),
    encoding: .utf8
  )
  let appSource = try String(
    contentsOf: repositoryRoot.appendingPathComponent("Sources/SBM/AppEnvironment.swift"),
    encoding: .utf8
  )

  #expect(!helperSource.contains("DelayResults"))
  #expect(!helperSource.contains("concurrentPerform"))
  #expect(helperSource.contains("waitForResponse: false"))
  #expect(helperSource.contains("path: \"/proxies\""))
  #expect(helperSource.contains(#"inet_addr("127.0.0.1")"#))
  #expect(helperSource.contains(#"Authorization: Bearer \(state.apiSecret)"#))
  let latencyStart = try #require(helperSource.range(of: "func testLatency(node"))
  let validationStart = try #require(
    helperSource.range(
      of: "func validate(profile:", range: latencyStart.upperBound..<helperSource.endIndex)
  )
  let latencySource = helperSource[latencyStart.lowerBound..<validationStart.lowerBound]
  #expect(latencySource.contains("target: state.latencyTestURL"))
  #expect(latencySource.contains("path: \"/proxies\""))
  #expect(latencySource.contains("runtimeOutcome: DeferredRuntimeMarkerPolicy.outcome("))
  #expect(latencySource.contains("marker: state.deferredRuntimeApplyPending"))
  #expect(!appSource.contains("latencyCycleSender"))
  #expect(!appSource.contains("LatencyRequestPolicy"))
  #expect(appSource.contains("receiveTimeoutSeconds: 2"))
}

@Test func profileLibraryPersistsDisabledIPv6Preference() throws {
  let library = ProfileLibrary(
    profiles: [ManagedProfile(name: "IPv6")],
    selectedProfileID: nil,
    ipv6Enabled: false
  )
  let decoded = try JSONDecoder().decode(
    ProfileLibrary.self,
    from: JSONEncoder().encode(library)
  )
  #expect(decoded == library)
  #expect(!decoded.ipv6Enabled)
}

@Test func persistentHelperStateDefaultsRecoveryAndDeferredMarkersForOlderStores() throws {
  let data = Data(
    """
    {
      "profile": {
        "compatibility": {
          "_0": {
            "connections": [
              {
                "id": "legacy-node",
                "displayName": "Legacy node",
                "outbound": {
                  "kind": "shadowsocks",
                  "shadowsocks": {
                    "server": "198.51.100.10",
                    "port": 443,
                    "method": "aes-256-gcm",
                    "password": "fixture-password"
                  }
                }
              }
            ],
            "nodeGroups": [],
            "applicationRoutingRules": [],
            "websiteRoutingRules": []
          }
        }
      },
      "activeProfileID": "11111111-1111-4111-8111-111111111111",
      "mode": "Rule",
      "selectedNode": "auto",
      "selectorTag": "proxy-selector",
      "nodes": [
        { "id": "auto", "name": "Auto", "kind": "automatic" },
        { "id": "legacy-node", "name": "Legacy node", "kind": "shadowsocks" }
      ],
      "desiredRunning": true,
      "automaticRecoveryAttempted": false,
      "deferredRuntimeApplyPending": false,
      "localSOCKSEnabled": false,
      "localSOCKSPort": 1082,
      "latencyTestURL": "https://www.gstatic.com/generate_204",
      "apiSecret": "test-secret"
    }
    """.utf8
  )
  let state = try JSONDecoder().decode(PersistentState.self, from: data)
  #expect(state.desiredRunning)
  #expect(!state.automaticRecoveryAttempted)
  #expect(!state.deferredRuntimeApplyPending)
  #expect(!state.ipv6Enabled)
  #expect(!state.activeIPv6PolicyKnown)
  #expect(state.activeIPv6Enabled == nil)
  #expect(state.activeIPv6Policy == nil)
  #expect(state.dnsSettings == .defaults)

  var unrelated = state
  unrelated.mode = .direct
  unrelated.dnsSettings = ManagedDNSSettings(direct: .yandex, proxy: .adguard)
  let roundTripped = try JSONDecoder().decode(
    PersistentState.self,
    from: JSONEncoder().encode(unrelated)
  )
  #expect(roundTripped.mode == .direct)
  #expect(!roundTripped.ipv6Enabled)
  #expect(!roundTripped.activeIPv6PolicyKnown)
  #expect(roundTripped.activeIPv6Enabled == nil)
  #expect(roundTripped.dnsSettings == unrelated.dnsSettings)

  let knownCurrentState = try JSONDecoder().decode(
    PersistentState.self,
    from: Data(
      """
      {
        "ipv6Enabled": false,
        "apiSecret": "current-fixture"
      }
      """.utf8
    )
  )
  #expect(!knownCurrentState.ipv6Enabled)
  #expect(!knownCurrentState.activeIPv6PolicyKnown)
  #expect(knownCurrentState.activeIPv6Policy == nil)
}

@Test func persistentStatePreservesCurrentSelectionAndFallsBackForCorruptMapping() throws {
  let node = ProxyNodeID(rawValue: "node-vless")
  let connection = ManagedConnection(
    id: node,
    displayName: "Reality",
    outbound: .vless(
      VLESSProfile(
        server: "203.0.113.1", port: 443,
        uuid: "5efab93b-90d0-4904-93d6-44b4f0b00001", serverName: "a.example.com",
        fingerprint: "chrome", publicKey: "Z9rM8XAd3bkfAcRjXymiE_nAe-E6okm35RfIq_iMBBU",
        shortID: ""
      )
    )
  )
  let profile = CoreProfile.compatibility(VPNProfile(connections: [connection]))
  let state: [String: Any] = [
    "profile": try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)),
    "selectedNode": node.rawValue,
    "nodes": [["id": node.rawValue, "name": "Reality"]],
    "apiSecret": "test-secret",
  ]
  let preserved = try JSONDecoder().decode(
    PersistentState.self, from: JSONSerialization.data(withJSONObject: state))
  #expect(preserved.selectedNode == node)
  #expect(preserved.nodes.first?.kind == .vless)

  var corrupt = state
  corrupt["selectedNode"] = "node-missing"
  let recovered = try JSONDecoder().decode(
    PersistentState.self, from: JSONSerialization.data(withJSONObject: corrupt))
  #expect(recovered.selectedNode == .auto)
}

@Test func persistentStateDuplicateManagedIDsFailClosedWithoutTrapping() throws {
  let outbound = ManagedOutbound.shadowsocks(
    ShadowsocksProfile(
      server: "ss.example.com",
      port: 443,
      method: "aes-128-gcm",
      password: "password",
      displayName: "Shadowsocks"
    ))
  let duplicateID = ProxyNodeID(rawValue: "node-duplicate")
  let profile = CoreProfile.compatibility(
    VPNProfile(connections: [
      ManagedConnection(id: duplicateID, outbound: outbound),
      ManagedConnection(id: duplicateID, outbound: outbound),
    ]))
  let state: [String: Any] = [
    "profile": try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)),
    "selectedNode": duplicateID.rawValue,
    "nodes": [["id": duplicateID.rawValue, "name": "Duplicate"]],
    "apiSecret": "test-secret",
  ]

  let decoded = try JSONDecoder().decode(
    PersistentState.self,
    from: JSONSerialization.data(withJSONObject: state)
  )
  #expect(decoded.selectedNode == .auto)
}

@Test func desiredRuntimeRecoveryAllowsOnlyOneAutomaticAttempt() {
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      recoveryAuthorized: true,
      desiredRunning: false,
      coreRunning: true,
      profileAvailable: true,
      configurationAvailable: true,
      recoveryAlreadyAttempted: false
    ) == .stop
  )
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      recoveryAuthorized: true,
      desiredRunning: true,
      coreRunning: true,
      profileAvailable: true,
      configurationAvailable: true,
      recoveryAlreadyAttempted: false
    ) == .noAction
  )
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      recoveryAuthorized: true,
      desiredRunning: true,
      coreRunning: false,
      profileAvailable: true,
      configurationAvailable: true,
      recoveryAlreadyAttempted: false
    ) == .attemptRecovery
  )
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      recoveryAuthorized: true,
      desiredRunning: true,
      coreRunning: false,
      profileAvailable: true,
      configurationAvailable: true,
      recoveryAlreadyAttempted: true
    ) == .disableDesiredState
  )
  #expect(
    DesiredRuntimeRecoveryPolicy.decision(
      recoveryAuthorized: true,
      desiredRunning: true,
      coreRunning: false,
      profileAvailable: false,
      configurationAvailable: true,
      recoveryAlreadyAttempted: false
    ) == .disableDesiredState
  )
}

@Test func helperResponseDefaultsMissingRecoverySignalForOlderHelpers() throws {
  let response = HelperResponse(success: true, coreRunning: false, message: "ready")
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
  object.removeValue(forKey: "automaticRecoveryExhausted")
  let legacy = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder().decode(HelperResponse.self, from: legacy)
  #expect(!decoded.automaticRecoveryExhausted)
  #expect(decoded.runtimeOutcome == .applied)
}

@Test func helperResponseRoundTripsReconnectRequiredOutcome() throws {
  let response = HelperResponse(
    success: true,
    coreRunning: true,
    activeProfileID: UUID(uuidString: "00000000-0000-0000-0000-000000000044"),
    runtimeOutcome: .reconnectRequired,
    message: HelperRuntimeOutcome.reconnectRequired.userMessage!
  )

  let decoded = try JSONDecoder().decode(
    HelperResponse.self,
    from: JSONEncoder().encode(response)
  )
  #expect(decoded.runtimeOutcome == .reconnectRequired)
  #expect(decoded.message == "Changes ready to apply")
}

@Test func restoredCoreMetadataUsesPostRenameFileIdentity() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMCoreRollbackMetadataTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let backup = directory.appendingPathComponent("sing-box.backup")
  let candidate = directory.appendingPathComponent("sing-box.rollback")
  let restored = directory.appendingPathComponent("sing-box")
  let contents = Data("previous reviewed core".utf8)
  try contents.write(to: backup)
  try FileManager.default.copyItem(at: backup, to: candidate)
  let backupIdentity = try #require(CoreFileIdentity.read(backup))
  let candidateIdentity = try #require(CoreFileIdentity.read(candidate))
  #expect(backupIdentity.inode != candidateIdentity.inode)

  try FileManager.default.moveItem(at: candidate, to: restored)
  let restoredIdentity = try #require(CoreFileIdentity.read(restored))
  let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
  let metadata = CoreMetadata(
    digest: digest,
    identity: restoredIdentity,
    version: "sing-box version previous-reviewed"
  )

  #expect(metadata.matches(restoredIdentity))
  #expect(!metadata.matches(backupIdentity))
  #expect(
    try JSONDecoder().decode(CoreMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
}

@Test func profileLibraryRequiresPositiveLatencyIntervalWithoutSmallUpperCap() throws {
  let library = ProfileLibrary(
    profiles: [],
    selectedProfileID: nil,
    latencyIntervalMinutes: 100_000
  )
  #expect(library.latencyIntervalMinutes == 100_000)
}

@Test func generatedSubscriptionHWIDUsesCanonicalUUIDFormat() {
  let hardwareID = SubscriptionHeaders.makeHardwareID()
  #expect(UUID(uuidString: hardwareID) != nil)
  #expect(hardwareID.count == 36)
  #expect(hardwareID == hardwareID.uppercased())
}

@Test func resettingRequestPresetPreservesHWID() {
  let original = SubscriptionHeaders(
    userAgent: "Custom/1.0",
    appVersion: nil,
    deviceOS: "CustomOS",
    deviceOSVersion: "CustomVersion",
    deviceModel: "CustomModel",
    hardwareID: "stable-device-id"
  )

  let reset = original.resettingRequestPreset()

  #expect(reset.userAgent == SubscriptionHeaders.defaultUserAgent)
  #expect(reset.appVersion == nil)
  #expect(reset.deviceOS == SubscriptionHeaders.defaultDeviceOS)
  #expect(reset.deviceOSVersion == SubscriptionHeaders.defaultDeviceOSVersion)
  #expect(reset.deviceModel == SubscriptionHeaders.defaultDeviceModel)
  #expect(reset.hardwareID == "stable-device-id")
}

@Test func newSourcesUseShadowrocketPresetWithoutMigratingStoredHeaders() throws {
  let fresh = ManagedSource()
  #expect(
    fresh.headers.userAgent
      == "Shadowrocket/3445 CFNetwork/3860.700.2 Darwin/25.6.0 iPhone17,1"
  )
  #expect(fresh.headers.appVersion == nil)
  #expect(fresh.headers.deviceOS == "iOS")
  #expect(fresh.headers.deviceOSVersion == "26.7")
  #expect(fresh.headers.deviceModel == "iPhone")
  #expect(UUID(uuidString: fresh.headers.hardwareID) != nil)
  #expect(fresh.headers.hardwareID.count == 36)
  #expect(fresh.headers.hardwareID == fresh.headers.hardwareID.uppercased())

  let stored = ManagedSource(
    name: "Existing",
    headers: SubscriptionHeaders(
      userAgent: "Custom Existing Client/7.0",
      appVersion: nil,
      deviceOS: "CustomOS",
      deviceOSVersion: nil,
      deviceModel: nil,
      hardwareID: "existing-hwid"
    )
  )
  let restored = try JSONDecoder().decode(
    ManagedSource.self,
    from: JSONEncoder().encode(stored)
  )
  #expect(restored.headers.userAgent == "Custom Existing Client/7.0")
  #expect(restored.headers.appVersion == nil)
  #expect(restored.headers.deviceOS == "CustomOS")
  #expect(restored.headers.deviceOSVersion == nil)
  #expect(restored.headers.deviceModel == nil)
  #expect(restored.headers.hardwareID == "existing-hwid")
}

@Test func profileStorePreservesMalformedLibraryAndReportsFailure() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMInvalidStoreTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let malformed = Data(#"{"schemaVersion":11,"profiles":null}"#.utf8)
  FileManager.default.createFile(
    atPath: url.path,
    contents: malformed,
    attributes: [.posixPermissions: 0o600]
  )

  #expect(throws: ProfileStoreFailure.self) {
    try ProfileStore.loadProfileLibrary(from: url, preserveInvalidCopy: true)
  }
  #expect(try Data(contentsOf: url) == malformed)
  let preserved = try FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: nil
  ).filter { $0.lastPathComponent.hasPrefix("profiles.invalid-") }
  #expect(preserved.count == 1)
  #expect(try Data(contentsOf: preserved[0]) == malformed)
}

@Test func profileStoreImportsValidatedRecoveryWithoutLosingDestination() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMRecoveryImportTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }

  let destination = directory.appendingPathComponent("profiles.json")
  let source = directory.appendingPathComponent("recovered.json")
  let original = Data("{broken".utf8)
  FileManager.default.createFile(
    atPath: destination.path,
    contents: original,
    attributes: [.posixPermissions: 0o600]
  )
  let recovered = ProfileLibrary(
    profiles: [ManagedProfile(name: "Recovered")],
    selectedProfileID: nil
  )
  FileManager.default.createFile(
    atPath: source.path,
    contents: try JSONEncoder().encode(recovered),
    attributes: [.posixPermissions: 0o600]
  )

  let imported = try ProfileStore.importProfileLibrary(from: source, to: destination)
  #expect(imported == recovered)
  #expect(
    try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: destination)) == recovered)
}

@Test func profileStoreRejectsMalformedRecoveryBeforeReplacingDestination() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMInvalidRecoveryTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }

  let destination = directory.appendingPathComponent("profiles.json")
  let source = directory.appendingPathComponent("recovered.json")
  let original = try JSONEncoder().encode(ProfileLibrary.empty)
  FileManager.default.createFile(
    atPath: destination.path,
    contents: original,
    attributes: [.posixPermissions: 0o600]
  )
  FileManager.default.createFile(
    atPath: source.path,
    contents: Data("{broken".utf8),
    attributes: [.posixPermissions: 0o600]
  )

  #expect(throws: ProfileStoreFailure.self) {
    try ProfileStore.importProfileLibrary(from: source, to: destination)
  }
  #expect(try Data(contentsOf: destination) == original)
}

@Test func profileStoreRejectsSymlinkedRecoveryBeforeReplacingDestination() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMSymlinkRecoveryTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }

  let destination = directory.appendingPathComponent("profiles.json")
  let target = directory.appendingPathComponent("recovered-target.json")
  let source = directory.appendingPathComponent("recovered-link.json")
  let original = try JSONEncoder().encode(ProfileLibrary.empty)
  FileManager.default.createFile(
    atPath: destination.path,
    contents: original,
    attributes: [.posixPermissions: 0o600]
  )
  FileManager.default.createFile(
    atPath: target.path,
    contents: try JSONEncoder().encode(ProfileLibrary.empty),
    attributes: [.posixPermissions: 0o600]
  )
  try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)

  #expect(throws: ProfileStoreFailure.self) {
    try ProfileStore.importProfileLibrary(from: source, to: destination)
  }
  #expect(try Data(contentsOf: destination) == original)
}

@Test func profileStoreResetPreservesOriginalBeforeStartingEmpty() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMRecoveryResetTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }

  let destination = directory.appendingPathComponent("profiles.json")
  let original = Data(#"{"schemaVersion":11,"profiles":null}"#.utf8)
  FileManager.default.createFile(
    atPath: destination.path,
    contents: original,
    attributes: [.posixPermissions: 0o600]
  )

  let reset = try ProfileStore.resetProfileLibrary(at: destination)
  #expect(reset == .empty)
  #expect(
    try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: destination)) == .empty
  )
  let preserved = try FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: nil
  ).filter { $0.lastPathComponent.hasPrefix("profiles.invalid-") }
  #expect(preserved.count == 1)
  #expect(try Data(contentsOf: preserved[0]) == original)
}

@Test func diagnosticRedactionRemovesKnownAndPatternSecrets() throws {
  let sourceURL = "https://user:subscription-token@example.com/private"
  let profile = try SubscriptionClient.parsePayload(
    "hysteria2://proxy-password@vpn.example.com:443/?sni=vpn.example.com#Hysteria2"
  )
  let profiles = [
    ManagedProfile(
      name: "Private",
      sources: [
        ManagedSource(
          name: "Provider",
          value: sourceURL,
          headers: SubscriptionHeaders(hardwareID: "private-hwid-value"),
          payload: profile
        )
      ],
      payload: profile
    )
  ]
  let report = SecretRedactor.redact(
    "URL \(sourceURL) HWID private-hwid-value password proxy-password Authorization: Bearer auth-token",
    secrets: DiagnosticSecrets.collect(from: profiles)
  )

  for secret in [
    sourceURL, "subscription-token", "private-hwid-value", "proxy-password", "auth-token",
  ] {
    #expect(!report.contains(secret))
  }
}

@Test func pinnedCoreMatchesGeneratedBuildInformation() throws {
  let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let core = project.appendingPathComponent(".vendor/sing-box")
  let lock = try String(contentsOf: project.appendingPathComponent("Core.lock"), encoding: .utf8)
  func recipeValue(_ name: String) throws -> String {
    let lines = lock.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("\(name) :=") }
    let line = try #require(lines.count == 1 ? lines.first : nil)
    return try #require(line.split(separator: ":=", maxSplits: 1).last)
      .trimmingCharacters(in: .whitespaces)
  }
  #expect(try recipeValue("CORE_VERSION") == CoreBuildInfo.version)
  #expect(try recipeValue("CORE_REVISION") == CoreBuildInfo.revision)
  #expect(try recipeValue("CORE_GO_DIRECTIVE") == "1.25.5")
  #expect(try recipeValue("CORE_GO_DIRECTIVE") != recipeValue("CORE_GO_VERSION"))
  #expect(try recipeValue("CORE_GO_VERSION") == String(CoreBuildInfo.goVersion.dropFirst(2)))
  #expect(try recipeValue("CORE_BUILD_TAGS") == CoreBuildInfo.buildTags)
  #expect(try recipeValue("CORE_CGO_ENABLED") == (CoreBuildInfo.cgo == "enabled" ? "1" : "0"))
  #expect(try recipeValue("CORE_LDFLAGS") == CoreBuildInfo.linkerFlags)
  let coreAttributes = try FileManager.default.attributesOfItem(atPath: core.path)
  let coreSize = try #require((coreAttributes[.size] as? NSNumber)?.int64Value)
  #expect(coreSize == CoreBuildInfo.signedSize)
  let packagedCore = project.appending(path: "dist/SBM.app/Contents/Resources/sing-box")
  if FileManager.default.fileExists(atPath: packagedCore.path) {
    let packagedAttributes = try FileManager.default.attributesOfItem(atPath: packagedCore.path)
    let packagedSize = try #require((packagedAttributes[.size] as? NSNumber)?.int64Value)
    #expect(packagedSize == CoreBuildInfo.signedSize)
  }

  let digest = SHA256.hash(data: try Data(contentsOf: core))
    .map { String(format: "%02x", $0) }.joined()
  #expect(digest == CoreBuildInfo.signedSHA256)

  let result = try TestProcessSupport.run(
    executableURL: core,
    arguments: ["version"]
  )
  #expect(result.status == 0)
  #expect(result.output.hasPrefix("sing-box version \(CoreBuildInfo.version)\n"))
  #expect(result.output.contains("Revision: \(CoreBuildInfo.revision)\n"))
  #expect(result.output.contains("Environment: \(CoreBuildInfo.goVersion) darwin/arm64\n"))
  #expect(result.output.contains("Tags: \(CoreBuildInfo.buildTags)\n"))
  #expect(result.output.contains("CGO: \(CoreBuildInfo.cgo)\n"))
}

@Test func bundledCoreCaptureCopiesAnExactSizeRegularFile() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMCoreCaptureTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("source")
  let destination = directory.appendingPathComponent("candidate")
  let contents = Data("signed-core-fixture".utf8)
  try contents.write(to: source)

  try CoreManager.captureBundledCore(
    from: source,
    to: destination,
    expectedSize: Int64(contents.count)
  )

  #expect(try Data(contentsOf: destination) == contents)
}

@Test(arguments: [Int64(3), Int64(5)])
func bundledCoreCaptureRejectsDeclaredSizeMismatch(expectedSize: Int64) throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMCoreCaptureTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("source")
  let destination = directory.appendingPathComponent("candidate")
  try Data("1234".utf8).write(to: source)

  #expect(throws: CoreFailure.self) {
    try CoreManager.captureBundledCore(from: source, to: destination, expectedSize: expectedSize)
  }
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func bundledCoreCaptureRejectsSymlinkSource() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMCoreCaptureTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appendingPathComponent("target")
  let source = directory.appendingPathComponent("source")
  let destination = directory.appendingPathComponent("candidate")
  try Data("signed-core-fixture".utf8).write(to: target)
  try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)

  #expect(throws: CoreFailure.self) {
    try CoreManager.captureBundledCore(
      from: source,
      to: destination,
      expectedSize: Int64("signed-core-fixture".utf8.count)
    )
  }
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func bundledCoreCaptureDoesNotReplaceAnExistingDestination() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMCoreCaptureTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("source")
  let destination = directory.appendingPathComponent("candidate")
  let existing = Data("existing".utf8)
  try Data("signed-core-fixture".utf8).write(to: source)
  try existing.write(to: destination)

  #expect(throws: CoreFailure.self) {
    try CoreManager.captureBundledCore(
      from: source,
      to: destination,
      expectedSize: Int64("signed-core-fixture".utf8.count)
    )
  }
  #expect(try Data(contentsOf: destination) == existing)
}

@Test func bundledCoreInstallationUsesBoundedDescriptorCaptureBeforeTrustChecks() throws {
  let core = try projectSource("Sources/SBMHelper/CoreManager.swift")
  let installation = try sourceSection(
    core,
    from: "private func installBundledCoreIfNeeded()",
    to: "private func restoreBackupCore("
  )
  #expect(!installation.contains("sha256(of: bundledCoreURL)"))
  #expect(!installation.contains("copyItem(at: bundledCoreURL"))
  #expect(!installation.contains("isExecutableFile(atPath: bundledCoreURL.path)"))
  let capture = try #require(installation.range(of: "try Self.captureBundledCore("))
  let secure = try #require(installation.range(of: "try secureExecutable(candidate)"))
  let digest = try #require(installation.range(of: "sha256(of: candidate)"))
  let version = try #require(installation.range(of: "readCoreVersion(at: candidate)"))
  #expect(capture.lowerBound < secure.lowerBound)
  #expect(secure.lowerBound < digest.lowerBound)
  #expect(digest.lowerBound < version.lowerBound)

  let captureImplementation = try sourceSection(
    core,
    from: "static func captureBundledCore(",
    to: "private func restoreBackupCore("
  )
  for required in [
    "O_RDONLY | O_NOFOLLOW | O_NONBLOCK", "Darwin.fstat(sourceDescriptor, &sourceInfo)",
    "sourceInfo.st_mode & S_IFMT == S_IFREG", "sourceInfo.st_size == expectedSize",
    "O_CREAT | O_EXCL | O_NOFOLLOW", "mode_t(0o600)", "copied < expectedSize",
    "size_t(readLimit)", "Darwin.write", "guard readCount > 0", "extraByte",
  ] {
    #expect(captureImplementation.contains(required))
  }
  let makefile = try projectSource("Makefile")
  #expect(makefile.contains("signed_size=\"$$(stat -f %z"))
  #expect(makefile.contains("public static let signedSize: Int64"))
}

@Test func profileStoreWritesCredentialsWithUserOnlyPermissions() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMStoreTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: directory.path
  )
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  let library = ProfileLibrary(
    profiles: [
      ManagedProfile(
        name: "Private",
        sources: [
          ManagedSource(
            name: "Private subscription",
            value: "https://user:secret@example.com/subscription",
            headers: SubscriptionHeaders(
              userAgent: "Custom Client/1.0",
              deviceOS: "macOS",
              hardwareID: "private-hwid"
            )
          )
        ]
      )
    ],
    selectedProfileID: nil
  )

  try ProfileStore.saveProfileLibrary(library, to: url)
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  let decoded = try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: url))
  #expect(decoded == library)
}

@Test func strictJSONDuplicateValidatorRejectsNestedAndEscapedDuplicateKeys() {
  for text in [
    #"{"outer":{"key":1,"key":2}}"#,
    #"{"a":1,"\u0061":2}"#,
  ] {
    #expect(throws: StrictJSONValidationError.self) {
      try StrictJSONDuplicateValidator.validate(
        Data(text.utf8),
        maximumBytes: 128,
        maximumDepth: 8,
        maximumStringBytes: 64
      )
    }
  }
  #expect(throws: StrictJSONValidationError.self) {
    try StrictJSONDuplicateValidator.validate(
      Data(#"{"outer":[1,]}"#.utf8),
      maximumBytes: 128,
      maximumDepth: 8,
      maximumStringBytes: 64
    )
  }
}

@Test func strictJSONDuplicateValidatorEnforcesRawDepthAndDecodedStringBounds() throws {
  try StrictJSONDuplicateValidator.validate(
    Data("null".utf8), maximumBytes: 4, maximumDepth: 0, maximumStringBytes: 0)
  #expect(throws: StrictJSONValidationError.oversized) {
    try StrictJSONDuplicateValidator.validate(
      Data("null".utf8), maximumBytes: 3, maximumDepth: 0, maximumStringBytes: 0)
  }

  try StrictJSONDuplicateValidator.validate(
    Data("[[0]]".utf8), maximumBytes: 5, maximumDepth: 2, maximumStringBytes: 0)
  #expect(throws: StrictJSONValidationError.invalidJSON) {
    try StrictJSONDuplicateValidator.validate(
      Data("[[0]]".utf8), maximumBytes: 5, maximumDepth: 1, maximumStringBytes: 0)
  }

  try StrictJSONDuplicateValidator.validate(
    Data(#""abc""#.utf8), maximumBytes: 5, maximumDepth: 0, maximumStringBytes: 3)
  #expect(throws: StrictJSONValidationError.oversized) {
    try StrictJSONDuplicateValidator.validate(
      Data(#""abc""#.utf8), maximumBytes: 5, maximumDepth: 0, maximumStringBytes: 2)
  }
}

@Test func strictJSONDuplicateValidatorAcceptsCurrentHelperAndRoutingShapes() throws {
  let request = try JSONEncoder().encode(HelperRequest(action: .status))
  try StrictJSONDuplicateValidator.validate(
    request,
    maximumBytes: 2 * 1_048_576,
    maximumDepth: 32,
    maximumStringBytes: 2 * 1_048_576
  )
  let policy = Data(
    #"{"route":{"rules":[{"domain_suffix":["example.test"],"action":"route","outbound":"direct"}]}}"#
      .utf8
  )
  try StrictJSONDuplicateValidator.validate(
    policy,
    maximumBytes: RoutingPolicyParser.maximumPolicySize,
    maximumDepth: 64,
    maximumStringBytes: RoutingPolicyParser.maximumPolicySize
  )
}

private func projectSource(_ path: String) throws -> String {
  try String(
    contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: path),
    encoding: .utf8
  )
}

private func sourceSection(
  _ source: String,
  from startMarker: String,
  to endMarker: String
) throws -> String {
  let start = try #require(source.range(of: startMarker))
  let end = try #require(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
  return String(source[start.lowerBound..<end.lowerBound])
}

@Test func preRCJSONBoundariesRejectDuplicatesBeforeDecoding() throws {
  let helper = try projectSource("Sources/SBMHelper/main.swift")
  let request = try sourceSection(
    helper,
    from: "private func decodeRequest(_ frame: Data)",
    to: "private func prepareColdOffLifetime()"
  )
  #expect(request.range(of: "StrictJSONDuplicateValidator.validate") != nil)
  let requestValidation = try #require(request.range(of: "StrictJSONDuplicateValidator.validate"))
  let requestDecode = try #require(request.range(of: "JSONDecoder().decode(HelperRequest.self"))
  #expect(requestValidation.lowerBound < requestDecode.lowerBound)

  let client = try projectSource("Sources/SBM/HelperClient.swift")
  #expect(client.range(of: "StrictJSONDuplicateValidator.validate") != nil)
  let responseValidation = try #require(client.range(of: "StrictJSONDuplicateValidator.validate"))
  let responseDecode = try #require(client.range(of: "JSONDecoder().decode(HelperResponse.self"))
  #expect(responseValidation.lowerBound < responseDecode.lowerBound)
  let routing = try projectSource("Sources/SBM/SubscriptionClient.swift")
  let parser = try sourceSection(
    routing,
    from: "static func parse(_ data: Data) throws -> RoutingPolicy",
    to: "\n  }\n}"
  )
  let policyValidation = try #require(parser.range(of: "StrictJSONDuplicateValidator.validate"))
  let policyParse = try #require(parser.range(of: "JSONSerialization.jsonObject"))
  #expect(policyValidation.lowerBound < policyParse.lowerBound)
  #expect(
    try projectSource("Sources/SBMHelper/ConfigBuilder.swift")
      .contains("StrictJSONDuplicateValidator.validate"))
}

@Test func preRCHelperShutdownAndInfoPlistAdmissionStayBounded() throws {
  let helper = try projectSource("Sources/SBMHelper/main.swift")
  let shutdown = try sourceSection(
    helper,
    from: "case .shutdown:",
    to: "\n      }\n    } catch HelperFailure.unauthorizedPeer"
  )
  let normalizedShutdown =
    shutdown
    .split(whereSeparator: \.isWhitespace)
    .joined(separator: " ")
  let shutdownStopArm = try #require(
    normalizedShutdown.range(of: "response = manager.legacy1115Retired ? try manager.stop()")
  )
  let unresolvedShutdownResponse = try #require(
    normalizedShutdown.range(
      of:
        ": manager.inertLegacyUpgradeResponse( success: false, message: \"Legacy helper retirement is unresolved; shutdown cannot report OFF.\""
    )
  )
  let terminalMark = try #require(normalizedShutdown.range(of: "terminalDisposition = .exiting"))
  #expect(terminalMark.lowerBound < shutdownStopArm.lowerBound)
  #expect(shutdownStopArm.upperBound < unresolvedShutdownResponse.lowerBound)
  #expect(!shutdown.contains("if !response.coreRunning"))

  let handle = try sourceSection(
    helper,
    from: "private func handle(",
    to: "private func authenticatePeer("
  )
  let catchPath = try #require(handle.range(of: "} catch HelperFailure.unauthorizedPeer"))
  let truthfulError = try #require(handle.range(of: "let current = manager.status()"))
  let terminalReturn = try #require(
    handle.range(of: "\n    return terminalDisposition == .exiting\n  }")
  )
  #expect(catchPath.lowerBound < truthfulError.lowerBound)
  #expect(truthfulError.lowerBound < terminalReturn.lowerBound)
  #expect(handle.contains("message: error.localizedDescription"))

  let trust = try projectSource("Sources/SBMHelper/HelperTrust.swift")
  let reader = try sourceSection(
    trust,
    from: "private static func boundedInfoPlistData(at path: String)",
    to: "static func currentReleaseFieldsMatch("
  )
  for required in [
    "open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)",
    "fstat(descriptor, &info)",
    "S_IFREG",
    "maximumBytes = 256 * 1_024",
    "maximumBytes + 1 - data.count",
    "Darwin.read",
    "close(descriptor)",
  ] {
    #expect(reader.contains(required))
  }
  #expect(!reader.contains("Data(contentsOf:"))
  #expect(trust.contains("boundedInfoPlistData(at: appInfoURL.path)"))
}

@Test func coreConfigurationCandidatesHaveCleanupBeforeSecureFileAdmission() throws {
  let core = try projectSource("Sources/SBMHelper/CoreManager.swift")
  for (start, end) in [
    ("private func validateConfiguration(", "private func backupActiveConfiguration("),
    ("private func writeValidatedConfiguration(", "private func restoreBackupConfiguration("),
  ] {
    let section = try sourceSection(core, from: start, to: end)
    let cleanup = try #require(
      section.range(of: "defer { try? fileManager.removeItem(at: candidate) }")
    )
    let secure = try #require(section.range(of: "try secureFile(candidate)"))
    #expect(cleanup.lowerBound < secure.lowerBound)
  }
}
