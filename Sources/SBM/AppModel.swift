import AppKit
import Foundation
import Observation
import SBMShared
import ServiceManagement

struct ResolvedApplicationBundle: Equatable {
  let displayName: String
  let bundleURL: URL
  let executableURL: URL
}

enum ApplicationBundleResolver {
  static func resolve(_ url: URL, fileManager: FileManager = .default) throws
    -> ResolvedApplicationBundle
  {
    let bundleURL = url.standardizedFileURL
    guard bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
      let bundle = Bundle(url: bundleURL),
      let executableURL = bundle.executableURL?.standardizedFileURL,
      fileManager.isExecutableFile(atPath: executableURL.path)
    else { throw ApplicationBundleResolutionFailure.missingMainExecutable }
    let bundlePrefix = bundleURL.path.hasSuffix("/") ? bundleURL.path : bundleURL.path + "/"
    guard executableURL.path.hasPrefix(bundlePrefix) else {
      throw ApplicationBundleResolutionFailure.mainExecutableOutsideBundle
    }
    let displayName =
      (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? bundleURL.deletingPathExtension().lastPathComponent
    guard !displayName.isEmpty else {
      throw ApplicationBundleResolutionFailure.missingDisplayName
    }
    return ResolvedApplicationBundle(
      displayName: displayName,
      bundleURL: bundleURL,
      executableURL: executableURL
    )
  }
}

enum ApplicationBundleResolutionFailure: LocalizedError {
  case missingMainExecutable
  case mainExecutableOutsideBundle
  case missingDisplayName

  var errorDescription: String? {
    switch self {
    case .missingMainExecutable:
      "The selected .app does not declare an accessible main executable."
    case .mainExecutableOutsideBundle:
      "The selected application's main executable is outside its .app bundle."
    case .missingDisplayName:
      "The selected application has no usable display name."
    }
  }
}

enum RoutingPolicyDocument {
  static func makeTemporaryCopy(
    _ configuration: Data,
    fileManager: FileManager = .default
  ) throws -> URL {
    guard !configuration.isEmpty,
      configuration.count <= RoutingPolicyParser.maximumPolicySize,
      let object = try? JSONSerialization.jsonObject(with: configuration)
    else { throw SubscriptionFailure.invalidRoutingPolicy }
    let formatted = try JSONSerialization.data(
      withJSONObject: object,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "SBM-Routing-\(UUID().uuidString)", isDirectory: true)
    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let destination = directory.appendingPathComponent("current-routing.json")
      guard
        fileManager.createFile(
          atPath: destination.path,
          contents: formatted,
          attributes: [.posixPermissions: 0o600]
        )
      else { throw CocoaError(.fileWriteUnknown) }
      return destination
    } catch {
      try? fileManager.removeItem(at: directory)
      throw error
    }
  }
}

struct ProxyNode: Identifiable, Hashable {
  let id: ProxyNodeID
  let name: String
  let symbol: String
  let groupID: String?
  let groupName: String?
  let groupOrder: Int?
  let nodeOrder: Int?
  var delay: Int?
}

struct ProxyNodeSection: Identifiable {
  let id: String
  let name: String
  let order: Int
  let nodes: [ProxyNode]
}

enum ProxyNodeMenuPresentation {
  static func latencyLabel(delay: Int?, testCompleted: Bool) -> String {
    if let delay { return "\(delay) ms" }
    return testCompleted ? "timeout" : ""
  }
}

enum ProxyNodeSectionBuilder {
  static func make(from nodes: [ProxyNode]) -> [ProxyNodeSection] {
    let proxyNodes = nodes.filter { $0.id != .auto }
    let grouped = Dictionary(grouping: proxyNodes) { $0.groupID ?? "ungrouped" }
    return grouped.map { id, values in
      let first = values.first
      let sorted = values.enumerated().sorted { leftEntry, rightEntry in
        let left = leftEntry.element
        let right = rightEntry.element
        switch (left.delay, right.delay) {
        case (.some(let leftDelay), .some(let rightDelay)) where leftDelay != rightDelay:
          return leftDelay < rightDelay
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        default:
          return (left.nodeOrder ?? leftEntry.offset)
            < (right.nodeOrder ?? rightEntry.offset)
        }
      }.map(\.element)
      return ProxyNodeSection(
        id: id,
        name: first?.groupName ?? "Servers",
        order: first?.groupOrder ?? Int.max,
        nodes: sorted
      )
    }.sorted { left, right in
      if left.order != right.order { return left.order < right.order }
      return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
  }
}

enum SubscriptionStatusLevel: Equatable {
  case neutral
  case success
  case warning
}

enum AutomaticConnectionPolicy {
  static func shouldConnect(
    didAttemptAutomaticConnection: Bool,
    automaticRecoveryExhausted: Bool,
    helperReady: Bool,
    profileAvailable: Bool,
    coreRunningForSelectedProfile: Bool
  ) -> Bool {
    !didAttemptAutomaticConnection
      && !automaticRecoveryExhausted
      && helperReady
      && profileAvailable
      && !coreRunningForSelectedProfile
  }
}

@MainActor
@Observable
final class AppModel {
  var routingMode: RoutingMode = .rule
  var selectedNodeID: ProxyNodeID = .auto
  var helperStatus = "Checking…"
  var helperEnabled = false
  var helperReachable = false
  var helperRequiresApproval = false
  private(set) var helperApprovalPending = false
  private(set) var helperApprovalPolling = false
  var coreRunning = false
  var helperVersion: String?
  var helperRevision: Int?
  var coreVersion: String?
  var launchAtLoginEnabled = false
  private var busyOperationCount = 0
  var isBusy: Bool { busyOperationCount > 0 }
  var helperSetupInProgress = false
  var lastError: String?
  var updateStatus = "Not checked"
  var availableUpdateVersion: String?
  var isCheckingForUpdates = false
  var isDownloadingUpdate = false
  var updateDownloadProgress: Double?

  var profiles: [ManagedProfile] = []
  var selectedProfileID: UUID?
  var profileName = ""
  var selectedSourceID: UUID?
  var sourceName = ""
  var sourceExcludeRegex = ""
  var routingInspectorInput = ""
  var routingInspectorApplicationID: UUID?
  var routingInspectorOutput = "Enter a domain or IP address to explain traffic routing."
  var routingInspectorDetails = ""
  var subscriptionURL = ""
  var subscriptionUserAgent = SubscriptionHeaders.defaultUserAgent
  var subscriptionAppVersion = SubscriptionHeaders.defaultAppVersion
  var subscriptionDeviceOS = SubscriptionHeaders.defaultDeviceOS
  var subscriptionHWID = SubscriptionHeaders.makeHardwareID()
  var subscriptionStatus = "No subscription synced"
  var subscriptionStatusLevel: SubscriptionStatusLevel = .neutral
  var runtimeApplyStatus: RuntimeApplyStatus = .saved
  var isSyncing = false
  var profileAvailable = false
  var localSOCKSEnabled = false
  var localSOCKSPort: UInt16 = 1082
  var latencyIntervalMinutes = 10
  var latencyTestURL = LatencyTargetPolicy.defaultURL
  var latencyTestURLDraft = LatencyTargetPolicy.defaultURL
  private var subscriptionRefreshTask: Task<Void, Never>?
  private var latencyRefreshTask: Task<Void, Never>?
  private var profileStoreLoadError: String?
  private var helperRepairTask: Task<Void, Never>?
  private var helperApprovalPollTask: Task<Void, Never>?
  private var helperApprovalSettingsPresented = false
  private var refreshGeneration = 0
  private var applicationRoutingEditGeneration = 0
  private var routingInspectionGeneration = 0
  private var runtimeFailurePreservedPrevious = false
  private var refreshInProgress = false
  private var lastLatencyTestAt: Date?
  var latencyTestCompleted = false
  var latencyTestInProgress = false
  private var didAttemptAutomaticConnection = false
  private var automaticRecoveryExhausted = false
  private var helperActiveProfileID: UUID?
  private var availableUpdate: AppUpdate?

  var nodes: [ProxyNode] = [
    ProxyNode(
      id: .auto,
      name: "Auto",
      symbol: "wand.and.stars",
      groupID: nil,
      groupName: nil,
      groupOrder: nil,
      nodeOrder: nil,
      delay: nil
    )
  ]

  var automaticNode: ProxyNode? {
    nodes.first(where: { $0.id == .auto })
  }

  var nodeSections: [ProxyNodeSection] {
    ProxyNodeSectionBuilder.make(from: nodes)
  }

  var profileRecoveryRequired: Bool {
    profileStoreLoadError != nil
  }

  var profileRecoveryMessage: String {
    profileStoreLoadError ?? "Profile library is available."
  }

  private let helperService: any HelperServiceManaging
  private let helperLifecycleSender: @Sendable (HelperRequest, Int) async throws -> HelperResponse
  private let helperApprovalDefaults: UserDefaults
  private let helperApprovalPollDuration: Duration
  private let helperApprovalPollInterval: Duration
  private let applicationBundleURL: URL
  private let subscriptionManager: SubscriptionManager
  private let runtimeApplyCoordinator: RuntimeApplyCoordinator<HelperRequest, HelperResponse>
  private let profileValidator: @Sendable (CoreProfile) async throws -> HelperResponse
  private let profileLibrarySaver: (ProfileLibrary) throws -> Void
  private let routingRuleSetMatcher: @Sendable ([String], String) async throws -> [String: Bool]
  private let routingRuleSetRetryDelay: Duration
  private let runtimeStateReader: @Sendable () async throws -> HelperResponse
  private let loginItemService = SMAppService.mainApp

  private func setSubscriptionStatus(
    _ value: String,
    level: SubscriptionStatusLevel = .neutral
  ) {
    subscriptionStatus = value
    subscriptionStatusLevel = level
  }

  init(
    helperService: any HelperServiceManaging = SystemHelperService(),
    subscriptionManager: SubscriptionManager = SubscriptionManager(),
    helperLifecycleSender:
      @escaping @Sendable (
        HelperRequest, Int
      ) async throws -> HelperResponse = { request, timeout in
        try await Task.detached {
          try HelperClient.send(request, receiveTimeoutSeconds: timeout)
        }.value
      },
    helperApprovalDefaults: UserDefaults = .standard,
    helperApprovalPollDuration: Duration = .seconds(60),
    helperApprovalPollInterval: Duration = .milliseconds(500),
    applicationBundleURL: URL = Bundle.main.bundleURL,
    runtimeSender: @escaping @Sendable (HelperRequest) async throws -> HelperResponse = {
      request in
      try await Task.detached {
        try HelperClient.send(
          request,
          receiveTimeoutSeconds: HelperClient.runtimeMutationReceiveTimeoutSeconds
        )
      }.value
    },
    profileValidator: @escaping @Sendable (CoreProfile) async throws -> HelperResponse = {
      profile in
      try await Task.detached {
        try HelperClient.send(HelperRequest(action: .validateProfile, profile: profile))
      }.value
    },
    profileLibraryLoader: () throws -> ProfileLibrary? = {
      try ProfileStore.loadProfileLibrary()
    },
    profileLibrarySaver: @escaping (ProfileLibrary) throws -> Void = {
      try ProfileStore.saveProfileLibrary($0)
    },
    routingRuleSetMatcher:
      @escaping @Sendable ([String], String) async throws -> [String: Bool] = { tags, destination in
        let response = try await Task.detached {
          try HelperClient.send(
            HelperRequest(
              action: .matchRuleSets,
              ruleSetTags: tags,
              routingDestination: destination
            )
          )
        }.value
        guard response.success else {
          throw AppModelFailure.profileActivationFailed(response.message)
        }
        return Dictionary(
          uniqueKeysWithValues: response.ruleSetMatches.map { ($0.tag, $0.matches) })
      },
    routingRuleSetRetryDelay: Duration = .milliseconds(250),
    runtimeStateReader: @escaping @Sendable () async throws -> HelperResponse = {
      try await Task.detached {
        try HelperClient.send(HelperRequest(action: .status))
      }.value
    },
    performStartup: Bool = true
  ) {
    self.helperService = helperService
    self.helperLifecycleSender = helperLifecycleSender
    self.helperApprovalDefaults = helperApprovalDefaults
    self.helperApprovalPollDuration = helperApprovalPollDuration
    self.helperApprovalPollInterval = helperApprovalPollInterval
    self.applicationBundleURL = applicationBundleURL
    self.subscriptionManager = subscriptionManager
    runtimeApplyCoordinator = RuntimeApplyCoordinator(sender: runtimeSender)
    self.profileValidator = profileValidator
    self.profileLibrarySaver = profileLibrarySaver
    self.routingRuleSetMatcher = routingRuleSetMatcher
    self.routingRuleSetRetryDelay = routingRuleSetRetryDelay
    self.runtimeStateReader = runtimeStateReader
    let stored: ProfileLibrary
    do {
      stored = try profileLibraryLoader() ?? .empty
    } catch {
      stored = .empty
      profileStoreLoadError = error.localizedDescription
    }
    profiles = stored.profiles
    selectedProfileID = stored.selectedProfileID
    localSOCKSEnabled = stored.localSOCKSEnabled
    localSOCKSPort = stored.localSOCKSPort
    latencyIntervalMinutes = stored.latencyIntervalMinutes
    latencyTestURL = stored.latencyTestURL
    latencyTestURLDraft = stored.latencyTestURL
    helperApprovalPending = helperApprovalDefaults.bool(
      forKey: HelperApprovalPersistence.pendingKey
    )
    if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
      selectedProfileID = profiles.first?.id
    }
    loadSelectedProfileEditor()
    updateNodes()
    if let profileStoreLoadError {
      lastError = profileStoreLoadError
    }
    guard performStartup else { return }
    guard isInstalledInApplications else {
      helperStatus = "Move the app to Applications"
      lastError =
        "Move SBM.app to the Applications folder, eject the DMG, then open the installed copy."
      return
    }
    enableLaunchAtLoginIfNeeded()
    refreshRegistrationStatus()
    bootstrapHelper()
    if !profiles.isEmpty {
      profileAvailable = selectedProfile?.payload != nil
      startSubscriptionRefreshLoop()
    }
    checkForUpdates(userInitiated: false)
  }

  var selectedProfileName: String {
    selectedProfile?.name ?? (coreRunning ? "Active configuration" : "None")
  }

  func importRecoveredProfileLibrary(from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let stored = try ProfileStore.importProfileLibrary(from: url)
      profileStoreLoadError = nil
      applyProfileLibrary(stored)
      lastError = nil
      setSubscriptionStatus("Profile library recovered", level: .success)
    } catch {
      lastError = "Profile recovery failed: \(error.localizedDescription)"
    }
  }

  func resetCorruptProfileLibrary() {
    guard !coreRunning else {
      lastError = "Disconnect the VPN before starting with an empty profile library."
      return
    }
    do {
      let stored = try ProfileStore.resetProfileLibrary()
      profileStoreLoadError = nil
      applyProfileLibrary(stored)
      lastError = nil
      setSubscriptionStatus("Started with an empty profile library", level: .warning)
    } catch {
      lastError = "Profile recovery failed: \(error.localizedDescription)"
    }
  }

  func revealPreservedProfileLibrary() {
    do {
      guard let url = try ProfileStore.latestPreservedProfileURL() else {
        lastError = "No preserved profile-library copy was found."
        return
      }
      NSWorkspace.shared.activateFileViewerSelecting([url])
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func openCurrentRoutingPolicy() {
    guard case .compatibility(let profile) = selectedProfile?.payload,
      let policy = profile.routingPolicy
    else {
      lastError = "The selected profile has no routing policy."
      return
    }
    do {
      let url = try RoutingPolicyDocument.makeTemporaryCopy(policy.configuration)
      guard NSWorkspace.shared.open(url) else {
        lastError = "macOS could not open the routing JSON in its default application."
        return
      }
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  var routingPolicyStatus: String {
    guard case .compatibility(let profile) = selectedProfile?.payload else {
      return "Available for Reality + Hysteria2 subscriptions"
    }
    switch runtimeApplyStatus {
    case .applying:
      return "Routing policy applying"
    case .failed:
      return runtimeFailurePreservedPrevious
        ? "Apply failed — previous routing remains active"
        : "Apply failed — active routing is unknown"
    case .active where coreRunning && helperActiveProfileID == selectedProfileID:
      return profile.routingPolicy == nil ? "No routing policy" : "Routing policy active"
    case .saved, .active:
      return profile.routingPolicy == nil ? "No routing policy" : "Routing policy saved, not active"
    }
  }

  var routingPolicyStatusLevel: SubscriptionStatusLevel {
    switch runtimeApplyStatus {
    case .active where coreRunning && helperActiveProfileID == selectedProfileID:
      return hasRoutingPolicy ? .success : .neutral
    case .failed:
      return .warning
    case .saved where hasRoutingPolicy:
      return .warning
    case .applying, .saved, .active:
      return .neutral
    }
  }

  var desiredRuntimeGeneration: UInt64 { runtimeApplyCoordinator.currentGeneration }

  var canManageRoutingPolicy: Bool {
    guard case .compatibility = selectedProfile?.payload else { return false }
    return true
  }

  var canManageSources: Bool {
    guard let payload = selectedProfile?.payload else { return selectedProfile != nil }
    guard case .compatibility = payload else { return false }
    return true
  }

  var selectedProfileSources: [ManagedSource] {
    selectedProfile?.sources ?? []
  }

  var hasRoutingPolicy: Bool {
    guard case .compatibility(let profile) = selectedProfile?.payload else { return false }
    return profile.routingPolicy != nil
  }

  var applicationRoutingRules: [ApplicationRoutingRule] {
    selectedProfile?.payload?.applicationRoutingRules ?? []
  }

  var routingInspectorApplicationLabel: String {
    guard let routingInspectorApplicationID,
      let rule = applicationRoutingRules.first(where: { $0.id == routingInspectorApplicationID })
    else { return "Default traffic" }
    return rule.displayName
  }

  var fixedApplicationRoutingNodes: [ProxyNode] {
    let fixedIDs = Set(
      (selectedProfile?.payload?.nodes ?? [])
        .filter { $0.kind != .automatic }
        .map(\.id)
    )
    return nodes.filter { fixedIDs.contains($0.id) }
  }

  func applicationRoutingRuleIsResolved(_ rule: ApplicationRoutingRule) -> Bool {
    let bundleURL = URL(fileURLWithPath: rule.bundlePath).standardizedFileURL
    let executableURL = URL(fileURLWithPath: rule.executablePath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: bundleURL.path),
      FileManager.default.isExecutableFile(atPath: executableURL.path),
      Bundle(url: bundleURL)?.executableURL?.standardizedFileURL == executableURL
    else { return false }
    if case .node(let node) = rule.target {
      return fixedApplicationRoutingNodes.contains(where: { $0.id == node })
    }
    return true
  }

  func addApplicationRoutingRule(from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    let resolved: ResolvedApplicationBundle
    do {
      resolved = try ApplicationBundleResolver.resolve(url)
    } catch {
      lastError = error.localizedDescription
      return
    }
    guard
      !applicationRoutingRules.contains(where: {
        URL(fileURLWithPath: $0.executablePath).standardizedFileURL == resolved.executableURL
      })
    else {
      lastError = "This application already has a routing rule."
      return
    }
    var rules = applicationRoutingRules
    rules.append(
      ApplicationRoutingRule(
        displayName: resolved.displayName,
        bundlePath: resolved.bundleURL.path,
        executablePath: resolved.executableURL.path,
        target: .selectedProxy
      )
    )
    saveApplicationRoutingRules(rules, status: "Application rule saved")
  }

  func removeApplicationRoutingRule(_ id: UUID) {
    saveApplicationRoutingRules(
      applicationRoutingRules.filter { $0.id != id },
      status: "Application rule removed"
    )
  }

  func setApplicationRoutingTarget(_ id: UUID, target: ApplicationRoutingTarget) {
    let rules = applicationRoutingRules.map { rule in
      guard rule.id == id else { return rule }
      return ApplicationRoutingRule(
        id: rule.id,
        displayName: rule.displayName,
        bundlePath: rule.bundlePath,
        executablePath: rule.executablePath,
        target: target
      )
    }
    saveApplicationRoutingRules(rules, status: "Application rule updated")
  }

  func inspectRouting() {
    routingInspectionGeneration &+= 1
    let inspectionGeneration = routingInspectionGeneration
    do {
      guard let payload = selectedProfile?.payload else {
        throw RoutingInspectionFailure.unavailable
      }
      let composed = try ComposedRoutingInspection.make(
        profile: payload,
        selectedNode: selectedNodeID
      )
      let selectedApplication = routingInspectorApplicationID.flatMap { id in
        applicationRoutingRules.first(where: { $0.id == id })
      }
      if routingInspectorApplicationID != nil, selectedApplication == nil {
        routingInspectorApplicationID = nil
      }
      let context = try RoutingInspector.parseInput(
        routingInspectorInput,
        mode: routingMode,
        inboundTag: composed.inboundTag,
        applicationPath: selectedApplication?.executablePath,
        defaultApplicationPaths: selectedApplication == nil
          ? Set(applicationRoutingRules.map(\.executablePath)) : []
      )
      let result = RoutingInspector.inspect(
        route: composed.route,
        context: context,
        outboundDecisions: composed.outboundDecisions,
        selectorOutbound: composed.selectorOutbound
      )
      let contextLabel = selectedApplication?.displayName ?? "Default traffic"
      routingInspectorOutput = composed.presentation(for: result)
      routingInspectorDetails = composed.details(for: result, contextLabel: contextLabel)
      let ruleSetTags = RoutingInspector.referencedRuleSetTags(in: composed.route)
      guard result.decision == .indeterminate, !ruleSetTags.isEmpty else { return }
      guard ruleSetTags.count <= 8, coreRunning,
        helperActiveProfileID == selectedProfileID
      else {
        routingInspectorOutput = "Connect this profile to inspect its active rule-set cache."
        return
      }
      let capturedProfileID = selectedProfileID
      let capturedApplicationID = routingInspectorApplicationID
      let capturedSelectedNodeID = selectedNodeID
      let destination = routingInspectorInput.trimmingCharacters(in: .whitespacesAndNewlines)
      routingInspectorOutput = "Checking active rule sets…"
      Task {
        do {
          let matches = try await matchActiveRuleSets(ruleSetTags, destination: destination)
          guard inspectionGeneration == routingInspectionGeneration,
            capturedProfileID == selectedProfileID,
            capturedApplicationID == routingInspectorApplicationID,
            capturedSelectedNodeID == selectedNodeID,
            destination == routingInspectorInput.trimmingCharacters(in: .whitespacesAndNewlines)
          else { return }
          let exact = RoutingInspector.inspect(
            route: composed.route,
            context: context,
            outboundDecisions: composed.outboundDecisions,
            selectorOutbound: composed.selectorOutbound,
            ruleSetMatches: matches
          )
          routingInspectorOutput = composed.presentation(for: exact)
          routingInspectorDetails = composed.details(for: exact, contextLabel: contextLabel)
        } catch {
          guard inspectionGeneration == routingInspectionGeneration,
            capturedProfileID == selectedProfileID,
            capturedApplicationID == routingInspectorApplicationID,
            capturedSelectedNodeID == selectedNodeID,
            destination == routingInspectorInput.trimmingCharacters(in: .whitespacesAndNewlines)
          else { return }
          routingInspectorOutput = "Active rule-set data is unavailable."
          routingInspectorDetails = error.localizedDescription
        }
      }
    } catch {
      routingInspectorOutput = error.localizedDescription
      routingInspectorDetails = ""
    }
  }

  private func matchActiveRuleSets(_ tags: [String], destination: String) async throws
    -> [String: Bool]
  {
    for attempt in 0..<5 {
      do {
        return try await routingRuleSetMatcher(tags, destination)
      } catch {
        guard attempt < 4 else { throw error }
        try await Task.sleep(for: routingRuleSetRetryDelay)
      }
    }
    throw CancellationError()
  }

  var supportSnapshot: SupportSnapshot {
    let appVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
    let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
    let profileKind: SupportSnapshot.ProfileKind
    switch selectedProfile?.payload {
    case .compatibility: profileKind = .compatibilitySubscription
    case .native: profileKind = .nativeJSON
    case nil: profileKind = .none
    }
    let delays = Dictionary(
      nodes.map { ($0.id, $0.delay) },
      uniquingKeysWith: { _, latest in latest }
    )
    let descriptors = selectedProfile?.payload?.nodes ?? []
    let observations = descriptors.compactMap { descriptor -> SupportSnapshot.NodeObservation? in
      guard descriptor.kind != .automatic else { return nil }
      return SupportSnapshot.NodeObservation(
        kind: descriptor.kind,
        delayMilliseconds: delays[descriptor.id] ?? nil
      )
    }
    let supportHelperState: SupportSnapshot.HelperState
    if helperSetupInProgress {
      supportHelperState = .setupInProgress
    } else if helperReachable {
      supportHelperState = .reachable
    } else if helperEnabled {
      supportHelperState = .unreachable
    } else {
      supportHelperState = .notEnabled
    }
    return SupportSnapshot(
      capturedAt: Date(),
      appVersion: appVersion,
      appBuild: appBuild,
      macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      helperReachable: helperReachable,
      helperVersion: helperVersion,
      helperRevision: helperRevision,
      helperState: supportHelperState,
      coreRunning: coreRunning,
      coreVersion: coreVersion,
      routingMode: routingMode,
      profileKind: profileKind,
      profileUpdatedAt: selectedProfile?.updatedAt,
      profileLibraryAvailable: profileStoreLoadError == nil,
      sourceCount: selectedProfile?.sources.count ?? 0,
      localSOCKSEnabled: localSOCKSEnabled,
      localSOCKSPort: localSOCKSPort,
      selectedProtocolKind: descriptors.first(where: { $0.id == selectedNodeID })?.kind,
      nodes: observations,
      lastError: lastError,
      redactionSecrets: DiagnosticSecrets.collect(from: profiles)
    )
  }

  var diagnosticReport: String { supportSnapshot.text }

  func applicationDidBecomeActive() {
    guard helperApprovalPending else {
      refresh()
      return
    }
    helperApprovalSettingsPresented = false
    continueHelperApprovalFlow()
  }

  func refresh() {
    guard !helperApprovalPending else {
      continueHelperApprovalFlow()
      return
    }
    refreshRegistrationStatus()
    guard helperEnabled else {
      coreRunning = false
      return
    }
    guard !helperSetupInProgress, !refreshInProgress else { return }

    refreshGeneration += 1
    let generation = refreshGeneration
    refreshInProgress = true
    Task {
      defer {
        if refreshGeneration == generation {
          refreshInProgress = false
        }
      }
      do {
        let response = try await helperLifecycleSender(
          HelperRequest(action: .status),
          5
        )
        guard refreshGeneration == generation, !helperSetupInProgress else { return }
        guard response.helperRevision == HelperConstants.helperRevision else {
          helperStatus = "Helper update required"
          helperReachable = false
          lastError = AppModelFailure.helperRevisionMismatch.localizedDescription
          return
        }
        apply(response)
        helperReachable = true
        lastError = response.success ? nil : response.message
        connectAutomaticallyIfNeeded()
      } catch {
        guard refreshGeneration == generation, !helperSetupInProgress else { return }
        helperStatus = "Helper unavailable"
        helperReachable = false
        coreRunning = false
        lastError = error.localizedDescription
      }
    }
  }

  func checkForUpdates(userInitiated: Bool = true) {
    guard !isCheckingForUpdates else { return }
    if !userInitiated,
      let previous = UserDefaults.standard.object(
        forKey: "LastUpdateCheck"
      ) as? Date,
      Date().timeIntervalSince(previous) < 24 * 60 * 60
    {
      return
    }
    isCheckingForUpdates = true
    if userInitiated { updateStatus = "Checking…" }
    Task {
      defer { isCheckingForUpdates = false }
      do {
        let update = try await UpdateService.latest(
          currentVersion: applicationVersion
        )
        UserDefaults.standard.set(Date(), forKey: "LastUpdateCheck")
        availableUpdate = update
        availableUpdateVersion = update?.version
        updateStatus =
          update.map { "Version \($0.version) is available" }
          ?? "SBM is up to date"
      } catch {
        if userInitiated {
          updateStatus = "Update check failed"
          lastError = error.localizedDescription
        }
      }
    }
  }

  func downloadAndOpenUpdate() {
    guard let update = availableUpdate else {
      checkForUpdates()
      return
    }
    guard !isDownloadingUpdate else { return }
    isDownloadingUpdate = true
    updateDownloadProgress = 0
    updateStatus = "Downloading \(update.version)…"
    Task {
      defer {
        isDownloadingUpdate = false
        updateDownloadProgress = nil
      }
      do {
        let image = try await UpdateService.download(update) { [weak self] fraction in
          Task { @MainActor [weak self] in
            guard self?.isDownloadingUpdate == true else { return }
            self?.updateDownloadProgress = fraction
            self?.updateStatus =
              "Downloading \(update.version)… \(Int((fraction * 100).rounded()))%"
          }
        }
        guard NSWorkspace.shared.open(image) else {
          throw UpdateFailure.downloadFailed
        }
        updateStatus = "Verified DMG opened"
        lastError = nil
      } catch {
        updateStatus = "Update failed"
        lastError = error.localizedDescription
      }
    }
  }

  func enableHelper() {
    guard isInstalledInApplications else {
      lastError =
        "Move SBM.app to the Applications folder, eject the DMG, then open the installed copy."
      return
    }
    if helperRequiresApproval {
      beginHelperApprovalFlow(openSystemSettings: true)
      return
    }
    guard helperRepairTask == nil else {
      helperStatus = "Helper setup already in progress…"
      return
    }
    invalidateRefresh()
    beginBusyOperation()
    helperSetupInProgress = true
    helperStatus = "Enabling background helper…"
    lastError = nil
    helperRepairTask = Task {
      defer {
        endBusyOperation()
        helperSetupInProgress = false
        helperRepairTask = nil
      }
      do {
        let response = try await enableCurrentHelper()
        apply(response)
        helperReachable = true
        helperStatus = "Helper enabled"
        completeHelperApprovalFlow()
        connectAutomaticallyIfNeeded()
      } catch HelperLifecycleFailure.approvalRequired,
        HelperLifecycleFailure.registrationDidNotFinish
      {
        beginHelperApprovalFlow(openSystemSettings: true)
      } catch {
        completeHelperApprovalFlow()
        helperReachable = false
        lastError = "Background helper setup failed: \(error.localizedDescription)"
        refreshRegistrationStatus()
      }
    }
  }

  func repairHelper() {
    guard helperRepairTask == nil else {
      helperStatus = "Helper update already in progress…"
      return
    }
    invalidateRefresh()
    beginBusyOperation()
    helperSetupInProgress = true
    helperReachable = false
    didAttemptAutomaticConnection = false
    helperStatus = "Repairing helper…"
    lastError = nil

    helperRepairTask = Task {
      defer {
        endBusyOperation()
        helperSetupInProgress = false
        helperRepairTask = nil
      }
      do {
        if helperEnabled {
          if let current = try? await helperLifecycleSender(
            HelperRequest(action: .status),
            5
          ),
            current.helperVersion == HelperConstants.helperVersion,
            current.helperRevision == HelperConstants.helperRevision
          {
            apply(current)
            helperReachable = true
            helperStatus = "Helper ready"
            lastError = current.success ? nil : current.message
            completeHelperApprovalFlow()
            connectAutomaticallyIfNeeded()
            return
          }
          helperStatus = "Stopping previous helper…"
          _ = try? await helperLifecycleSender(
            HelperRequest(action: .stop),
            5
          )
        }
        helperStatus = "Replacing background helper…"
        let response = try await HelperLifecycle.replace(
          service: helperService,
          waiting: { [weak self] in
            self?.helperStatus = "Waiting for macOS to replace helper…"
          }
        ) {
          try await self.helperLifecycleSender(
            HelperRequest(action: .status),
            5
          )
        }
        apply(response)
        helperReachable = true
        helperStatus = "Helper updated"
        completeHelperApprovalFlow()
        connectAutomaticallyIfNeeded()
      } catch HelperLifecycleFailure.approvalRequired,
        HelperLifecycleFailure.registrationDidNotFinish
      {
        beginHelperApprovalFlow(openSystemSettings: true)
      } catch is CancellationError {
        refreshRegistrationStatus()
      } catch {
        completeHelperApprovalFlow()
        helperReachable = false
        lastError = "Background helper repair failed: \(error.localizedDescription)"
        refreshRegistrationStatus()
      }
    }
  }

  func openBackgroundItems() {
    helperService.openSystemSettings()
  }

  func setCoreEnabled(_ enabled: Bool) {
    guard helperEnabled else {
      lastError = "Enable the background helper before connecting."
      return
    }
    guard helperReachable else {
      lastError = "Update or repair the background helper before connecting."
      return
    }
    let request: HelperRequest
    if enabled, let payload = selectedProfile?.payload {
      didAttemptAutomaticConnection = true
      request = makeStartRequest(profile: payload, profileID: selectedProfileID)
    } else {
      request = HelperRequest(action: .stop)
    }
    submitRuntimeApply(request)
  }

  func disconnectBeforeQuit() async -> Bool {
    subscriptionRefreshTask?.cancel()
    helperRepairTask?.cancel()
    helperApprovalPollTask?.cancel()

    let result = await withCheckedContinuation { continuation in
      submitRuntimeApply(HelperRequest(action: .shutdown)) { result in
        continuation.resume(returning: result)
      }
    }
    switch result {
    case .success(let response) where response.success && !response.coreRunning:
      lastError = nil
    case .success(let response):
      lastError =
        "Unable to disconnect before quitting: "
        + AppModelFailure.coreStopFailed(response.message).localizedDescription
    case .failure(let error):
      lastError = "Unable to disconnect before quitting: \(error.localizedDescription)"
    }
    return true
  }

  func setRoutingMode(_ mode: RoutingMode) {
    routingMode = mode
    if runtimeApplyCoordinator.isApplying {
      applyCurrentDesiredRuntimeIfNeeded()
    } else {
      submitRuntimeApply(HelperRequest(action: .setMode, mode: mode))
    }
  }

  func setSelectedNode(_ node: ProxyNodeID) {
    selectedNodeID = node
    if runtimeApplyCoordinator.isApplying {
      applyCurrentDesiredRuntimeIfNeeded()
    } else {
      submitRuntimeApply(HelperRequest(action: .setNode, node: node))
    }
  }

  func testLatency() {
    guard coreRunning else {
      lastError = "Connect the VPN before testing latency."
      return
    }
    guard !latencyTestInProgress else { return }
    lastLatencyTestAt = Date()
    latencyTestInProgress = true
    beginBusyOperation()
    Task {
      defer {
        latencyTestInProgress = false
        endBusyOperation()
        scheduleNextLatencyRefresh()
      }
      do {
        let response = try await Task.detached {
          try HelperClient.send(.testLatency)
        }.value
        apply(response)
        for delay in response.delays {
          if let index = nodes.firstIndex(where: { $0.id == delay.node }) {
            nodes[index].delay = delay.milliseconds
          }
        }
        let measured = response.delays.compactMap(\.milliseconds)
        if let autoIndex = nodes.firstIndex(where: { $0.id == .auto }),
          nodes[autoIndex].delay == nil
        {
          nodes[autoIndex].delay = measured.min()
        }
        latencyTestCompleted = response.success
        lastError = response.success ? nil : response.message
      } catch {
        helperReachable = false
        lastError = error.localizedDescription
      }
    }
  }

  func refreshLatencyIfNeeded() {
    guard coreRunning else {
      latencyRefreshTask?.cancel()
      latencyRefreshTask = nil
      return
    }
    guard !isBusy, !latencyTestInProgress else {
      scheduleLatencyRefresh(after: 60)
      return
    }
    if !LatencyRefreshSchedule.isDue(
      lastTestAt: lastLatencyTestAt,
      now: Date(),
      intervalMinutes: latencyIntervalMinutes
    ) {
      scheduleNextLatencyRefresh()
      return
    }
    testLatency()
  }

  func setLatencyIntervalMinutes(_ value: Int) {
    latencyIntervalMinutes = max(value, 1)
    try? persistProfileLibrary()
    scheduleNextLatencyRefresh()
  }

  @discardableResult
  func applyLatencyTestURL() -> Bool {
    do {
      let normalized = try LatencyTargetSettings.apply(draft: latencyTestURLDraft) { target in
        try persistProfileLibrary(latencyTestURL: target)
      }
      latencyTestURL = normalized
      latencyTestURLDraft = normalized
      lastError = nil
      if helperEnabled, helperReachable {
        send(HelperRequest(action: .setLatencyTarget, latencyTestURL: normalized))
      }
      return true
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }

  func resetLatencyTestURL() {
    latencyTestURLDraft = LatencyTargetPolicy.defaultURL
    applyLatencyTestURL()
  }

  func saveAndSyncSubscription() {
    syncSelectedSource()
    startSubscriptionRefreshLoop()
  }

  func saveProfileName() {
    guard let selectedProfileID,
      let index = profiles.firstIndex(where: { $0.id == selectedProfileID })
    else { return }
    let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      lastError = "Profile name cannot be empty."
      return
    }
    profiles[index].name = name
    profileName = name
    do {
      try persistProfileLibrary()
      setSubscriptionStatus("Profile name saved", level: .success)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func addSource() {
    guard canManageSources, let selectedProfileID,
      let profileIndex = profiles.firstIndex(where: { $0.id == selectedProfileID })
    else { return }
    let source = ManagedSource(name: "Subscription \(profiles[profileIndex].sources.count + 1)")
    profiles[profileIndex].sources.append(source)
    selectedSourceID = source.id
    loadSelectedSourceEditor()
    setSubscriptionStatus("Enter a subscription URL or connection link")
    do {
      try persistProfileLibrary()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func deleteSelectedSource() {
    guard let selectedProfileID, let selectedSourceID,
      let profileIndex = profiles.firstIndex(where: { $0.id == selectedProfileID }),
      let sourceIndex = profiles[profileIndex].sources.firstIndex(where: {
        $0.id == selectedSourceID
      })
    else { return }

    let previous = profiles
    profiles[profileIndex].sources.remove(at: sourceIndex)
    do {
      try rebuildCompatibilityPayload(at: profileIndex)
      self.selectedSourceID = profiles[profileIndex].sources.first?.id
      loadSelectedSourceEditor()
      try persistProfileLibrary()
      updateNodes()
      profileAvailable = profiles[profileIndex].payload != nil
      setSubscriptionStatus(
        profileAvailable ? "Source removed" : "No sources synced",
        level: profileAvailable ? .success : .neutral
      )
      lastError = nil
      if self.selectedProfileID == selectedProfileID {
        applyCurrentDesiredRuntimeIfNeeded()
      }
    } catch {
      profiles = previous
      loadSelectedProfileEditor()
      updateNodes()
      lastError = error.localizedDescription
    }
  }

  func selectSource(_ id: UUID) {
    guard selectedProfileSources.contains(where: { $0.id == id }) else { return }
    selectedSourceID = id
    loadSelectedSourceEditor()
  }

  func resetSubscriptionRequestPreset() {
    let reset = SubscriptionHeaders(
      userAgent: subscriptionUserAgent,
      appVersion: subscriptionAppVersion.isEmpty ? nil : subscriptionAppVersion,
      deviceOS: subscriptionDeviceOS,
      hardwareID: subscriptionHWID
    ).resettingRequestPreset()
    subscriptionUserAgent = reset.userAgent
    subscriptionAppVersion = reset.appVersion ?? ""
    subscriptionDeviceOS = reset.deviceOS
    subscriptionHWID = reset.hardwareID
  }

  func regenerateSubscriptionHWID() {
    guard let selectedProfileID, let selectedSourceID,
      let profileIndex = profiles.firstIndex(where: { $0.id == selectedProfileID }),
      let sourceIndex = profiles[profileIndex].sources.firstIndex(where: {
        $0.id == selectedSourceID
      })
    else { return }
    let previous = profiles[profileIndex].sources[sourceIndex].headers.hardwareID
    let replacement = SubscriptionHeaders.makeHardwareID()
    profiles[profileIndex].sources[sourceIndex].headers.hardwareID = replacement
    subscriptionHWID = replacement
    do {
      try persistProfileLibrary()
      lastError = nil
    } catch {
      profiles[profileIndex].sources[sourceIndex].headers.hardwareID = previous
      subscriptionHWID = previous
      lastError = error.localizedDescription
    }
  }

  @discardableResult
  func applyLocalSOCKSSettings() -> Bool {
    guard (1024...65535).contains(Int(localSOCKSPort)), localSOCKSPort != 19090 else {
      lastError = "Choose a local SOCKS5 port from 1024 to 65535, except 19090."
      return false
    }
    do {
      try persistProfileLibrary()
    } catch {
      lastError = error.localizedDescription
      return false
    }
    guard coreRunning || runtimeApplyCoordinator.isApplying else {
      lastError = nil
      return true
    }
    applyCurrentDesiredRuntimeIfNeeded()
    return true
  }

  func importNativeProfile(from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    let name = url.deletingPathExtension().lastPathComponent
    let result = Result { try Data(contentsOf: url, options: [.mappedIfSafe]) }
    isSyncing = true
    Task {
      defer { isSyncing = false }
      do {
        let native = try NativeProfileParser.parse(result.get())
        let payload = CoreProfile.native(native)
        try await validateProfile(payload)
        let imported = ManagedProfile(
          name: name,
          payload: payload,
          updatedAt: Date()
        )
        profiles.append(imported)
        selectedProfileID = imported.id
        loadSelectedProfileEditor()
        updateNodes()
        profileAvailable = true
        setSubscriptionStatus("Imported JSON profile", level: .success)
        try persistProfileLibrary()
        lastError = nil
        applyCurrentDesiredRuntimeIfNeeded()
      } catch {
        lastError = error.localizedDescription
        setSubscriptionStatus("Import failed", level: .warning)
      }
    }
  }

  func importRoutingPolicy(from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    guard let selectedProfileID,
      let initialIndex = profiles.firstIndex(where: { $0.id == selectedProfileID }),
      case .compatibility(let current) = profiles[initialIndex].payload
    else {
      lastError = "Sync a Reality + Hysteria2 subscription before importing routing."
      return
    }
    let result = Result { try Data(contentsOf: url, options: [.mappedIfSafe]) }
    isSyncing = true
    Task {
      defer { isSyncing = false }
      do {
        let policy = try RoutingPolicyParser.parse(result.get())
        let updated = CoreProfile.compatibility(
          VPNProfile(
            connections: current.connections,
            routingPolicy: policy,
            nodeGroups: current.nodeGroups ?? [],
            applicationRoutingRules: current.applicationRoutingRules
          )
        )
        try await validateProfile(updated)
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else {
          return
        }
        let previous = profiles
        profiles[index].payload = updated
        do {
          try persistProfileLibrary()
        } catch {
          profiles = previous
          try? persistProfileLibrary()
          throw error
        }
        let shouldApply = coreRunning || runtimeApplyCoordinator.isApplying
        if shouldApply {
          setSubscriptionStatus("Routing policy applying", level: .neutral)
          applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
              self.setSubscriptionStatus("Routing policy active", level: .success)
            case .failure(let error):
              self.profiles = previous
              try? self.persistProfileLibrary()
              self.updateNodes()
              self.setSubscriptionStatus("Routing policy apply failed", level: .warning)
              self.lastError = error.localizedDescription
            }
          }
        } else {
          runtimeApplyCoordinator.markSaved()
          runtimeApplyStatus = .saved
          setSubscriptionStatus("Routing policy saved", level: .success)
        }
        lastError = nil
      } catch {
        setSubscriptionStatus("Routing import failed", level: .warning)
        lastError = error.localizedDescription
      }
    }
  }

  func clearRoutingPolicy() {
    guard let selectedProfileID,
      let index = profiles.firstIndex(where: { $0.id == selectedProfileID }),
      case .compatibility(let current) = profiles[index].payload,
      current.routingPolicy != nil
    else { return }
    let updated = CoreProfile.compatibility(
      VPNProfile(
        connections: current.connections,
        nodeGroups: current.nodeGroups ?? [],
        applicationRoutingRules: current.applicationRoutingRules
      )
    )
    let previous = profiles
    profiles[index].payload = updated
    do {
      try persistProfileLibrary()
    } catch {
      profiles = previous
      lastError = error.localizedDescription
      return
    }
    let shouldApply = coreRunning || runtimeApplyCoordinator.isApplying
    if shouldApply {
      setSubscriptionStatus("Routing policy removal applying", level: .neutral)
      applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
        guard let self else { return }
        switch result {
        case .success:
          self.setSubscriptionStatus("Routing policy removed and active", level: .success)
        case .failure(let error):
          self.profiles = previous
          try? self.persistProfileLibrary()
          self.updateNodes()
          self.setSubscriptionStatus("Routing policy removal failed", level: .warning)
          self.lastError = error.localizedDescription
        }
      }
    } else {
      runtimeApplyCoordinator.markSaved()
      runtimeApplyStatus = .saved
      setSubscriptionStatus("Routing policy removed and saved", level: .success)
    }
    lastError = nil
  }

  func addProfile() {
    let profile = ManagedProfile(
      name: "New Profile",
      sources: [ManagedSource()]
    )
    profiles.append(profile)
    selectedProfileID = profile.id
    loadSelectedProfileEditor()
    updateNodes()
    profileAvailable = false
    setSubscriptionStatus("Enter a subscription URL or connection link")
    try? persistProfileLibrary()
  }

  func deleteSelectedProfile() {
    guard let selectedProfileID,
      let index = profiles.firstIndex(where: { $0.id == selectedProfileID })
    else { return }
    let previousProfiles = profiles
    let previousSelection = selectedProfileID
    profiles.remove(at: index)
    self.selectedProfileID = profiles.first?.id
    loadSelectedProfileEditor()
    updateNodes()
    profileAvailable = selectedProfile?.payload != nil
    setSubscriptionStatus(
      profileAvailable ? "Ready" : "No subscription synced",
      level: profileAvailable ? .success : .neutral
    )
    do {
      try persistProfileLibrary()
    } catch {
      profiles = previousProfiles
      self.selectedProfileID = previousSelection
      loadSelectedProfileEditor()
      updateNodes()
      lastError = error.localizedDescription
      return
    }
    guard coreRunning || runtimeApplyCoordinator.isApplying else {
      runtimeApplyCoordinator.markSaved()
      runtimeApplyStatus = .saved
      return
    }
    applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
      guard let self, case .failure(let error) = result else { return }
      self.profiles = previousProfiles
      self.selectedProfileID = previousSelection
      self.loadSelectedProfileEditor()
      self.updateNodes()
      try? self.persistProfileLibrary()
      self.lastError = error.localizedDescription
    }
  }

  func selectProfile(_ id: UUID) {
    guard id != selectedProfileID, profiles.contains(where: { $0.id == id }) else { return }
    let previousSelection = selectedProfileID
    selectedProfileID = id
    loadSelectedProfileEditor()
    updateNodes()
    profileAvailable = selectedProfile?.payload != nil
    setSubscriptionStatus(
      profileAvailable ? "Ready" : "Not synced",
      level: profileAvailable ? .success : .neutral
    )
    do {
      try persistProfileLibrary()
    } catch {
      selectedProfileID = previousSelection
      loadSelectedProfileEditor()
      updateNodes()
      lastError = error.localizedDescription
      return
    }

    if coreRunning || runtimeApplyCoordinator.isApplying {
      applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
        guard let self, case .failure(let error) = result else { return }
        self.selectedProfileID = previousSelection
        self.loadSelectedProfileEditor()
        self.updateNodes()
        try? self.persistProfileLibrary()
        self.lastError = error.localizedDescription
      }
    } else if selectedProfile?.payload == nil,
      selectedProfile?.sources.contains(where: { !$0.value.isEmpty }) == true
    {
      syncSelectedSource()
    }
  }

  private var selectedProfile: ManagedProfile? {
    guard let selectedProfileID else { return nil }
    return profiles.first(where: { $0.id == selectedProfileID })
  }

  private func syncSelectedSource() {
    let value = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let headers = SubscriptionHeaders(
      userAgent: subscriptionUserAgent.trimmingCharacters(in: .whitespacesAndNewlines),
      appVersion: {
        let value = subscriptionAppVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
      }(),
      deviceOS: subscriptionDeviceOS.trimmingCharacters(in: .whitespacesAndNewlines),
      hardwareID: subscriptionHWID.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    guard let targetProfileID = selectedProfileID,
      let targetSourceID = selectedSourceID,
      let profileIndex = profiles.firstIndex(where: { $0.id == targetProfileID }),
      let sourceIndex = profiles[profileIndex].sources.firstIndex(where: {
        $0.id == targetSourceID
      })
    else {
      lastError = "Add a subscription source first."
      return
    }
    if case .native = profiles[profileIndex].payload {
      lastError = SubscriptionFailure.nativeProfileCannotBeMerged.localizedDescription
      return
    }
    do {
      try SubscriptionClient.validate(headers: headers)
      let effectiveName = try SubscriptionClient.validateDisplayName(
        name.isEmpty ? "Subscription" : name
      )
      let excludeRegex = try SourceNameFilter.normalized(sourceExcludeRegex)
      profiles[profileIndex].sources[sourceIndex].name = effectiveName
      profiles[profileIndex].sources[sourceIndex].value = value
      profiles[profileIndex].sources[sourceIndex].headers = headers
      profiles[profileIndex].sources[sourceIndex].excludeRegex = excludeRegex
      try persistProfileLibrary()
    } catch {
      lastError = error.localizedDescription
      return
    }
    guard !value.isEmpty else {
      setSubscriptionStatus(
        profiles[profileIndex].payload == nil ? "Enter a source" : "Saved",
        level: profiles[profileIndex].payload == nil ? .neutral : .success
      )
      return
    }
    isSyncing = true
    setSubscriptionStatus("Syncing…")
    let sourceToSync = profiles[profileIndex].sources[sourceIndex]
    Task {
      defer { isSyncing = false }
      let previousProfiles = profiles
      do {
        let result = try await subscriptionManager.synchronize(sourceToSync)
        let fetched = ManagedConnectionReconciler.reconcile(
          existing: profiles.first(where: { $0.id == targetProfileID })?
            .sources.first(where: { $0.id == targetSourceID })?.payload,
          fetched: result.profile
        )
        guard case .compatibility = fetched else {
          throw SubscriptionFailure.nativeProfileCannotBeMerged
        }
        guard
          let currentProfileIndex = profiles.firstIndex(where: {
            $0.id == targetProfileID
          }),
          let currentSourceIndex = profiles[currentProfileIndex].sources.firstIndex(where: {
            $0.id == targetSourceID
          })
        else { return }
        let oldEffective = profiles[currentProfileIndex].payload
        profiles[currentProfileIndex].sources[currentSourceIndex].payload = fetched
        profiles[currentProfileIndex].sources[currentSourceIndex].updatedAt = Date()
        try rebuildCompatibilityPayload(at: currentProfileIndex)
        guard let effective = profiles[currentProfileIndex].payload else {
          throw SubscriptionFailure.missingProtocols
        }
        try await validateProfile(effective)
        profiles[currentProfileIndex].updatedAt = Date()
        try persistProfileLibrary()
        if self.selectedProfileID == targetProfileID,
          coreRunning || runtimeApplyCoordinator.isApplying,
          ManagedConnectionReconciler.requiresActivation(previous: oldEffective, next: effective)
        {
          setSubscriptionStatus("Sources updated; applying", level: .neutral)
          applyCurrentDesiredRuntimeIfNeeded { [weak self] applyResult in
            guard let self else { return }
            switch applyResult {
            case .success:
              if let warning = result.warningDescription {
                self.setSubscriptionStatus(warning, level: .warning)
              } else {
                self.setSubscriptionStatus("Sources updated and active", level: .success)
              }
            case .failure(let error):
              self.profiles = previousProfiles
              try? self.persistProfileLibrary()
              self.loadSelectedProfileEditor()
              self.updateNodes()
              self.profileAvailable = self.selectedProfile?.payload != nil
              self.setSubscriptionStatus("Source apply failed", level: .warning)
              self.lastError = error.localizedDescription
            }
          }
        } else if case .compatibility(let profile) = effective {
          if let warning = result.warningDescription {
            setSubscriptionStatus(warning, level: .warning)
          } else {
            setSubscriptionStatus(profileSummary(profile) + " ready", level: .success)
          }
        }
        profileAvailable = true
        updateNodes()
        if runtimeApplyStatus != .failed {
          lastError = nil
        }
        connectAutomaticallyIfNeeded()
      } catch {
        profiles = previousProfiles
        try? persistProfileLibrary()
        loadSelectedProfileEditor()
        updateNodes()
        profileAvailable = selectedProfile?.payload != nil
        setSubscriptionStatus(
          profileAvailable ? "Using cached sources; sync failed" : "Sync failed",
          level: .warning
        )
        lastError = error.localizedDescription
      }
    }
  }

  private func startSubscriptionRefreshLoop() {
    subscriptionRefreshTask?.cancel()
    subscriptionRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(6 * 60 * 60))
        guard !Task.isCancelled else { return }
        self?.refreshAllProfiles()
      }
    }
  }

  private func scheduleNextLatencyRefresh() {
    latencyRefreshTask?.cancel()
    guard coreRunning else {
      latencyRefreshTask = nil
      return
    }
    scheduleLatencyRefresh(
      after: LatencyRefreshSchedule.nextDelay(
        lastTestAt: lastLatencyTestAt,
        now: Date(),
        intervalMinutes: latencyIntervalMinutes
      )
    )
  }

  private func scheduleLatencyRefresh(after seconds: TimeInterval) {
    latencyRefreshTask?.cancel()
    latencyRefreshTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.refreshLatencyIfNeeded()
    }
  }

  private func validateProfile(_ profile: CoreProfile) async throws {
    guard currentHelperIsReady else {
      throw AppModelFailure.helperRequiredForValidation
    }
    let response = try await profileValidator(profile)
    guard response.helperRevision == HelperConstants.helperRevision else {
      throw AppModelFailure.helperRevisionMismatch
    }
    guard response.success else {
      throw AppModelFailure.profileValidationFailed(response.message)
    }
  }

  private func refreshAllProfiles() {
    guard !isSyncing, currentHelperIsReady else { return }
    let hasRemoteSources = profiles.contains { profile in
      profile.sources.contains { SubscriptionClient.isRemoteSource($0.value) }
    }
    guard hasRemoteSources else { return }
    isSyncing = true
    Task {
      defer { isSyncing = false }
      var selectedFailure: Error?
      var selectedWarnings: [String] = []
      let previousProfiles = profiles
      var selectedProfileChanged = false
      do {
        for profileIndex in profiles.indices {
          if case .native = profiles[profileIndex].payload { continue }
          var refreshedAnySource = false
          for sourceIndex in profiles[profileIndex].sources.indices {
            let source = profiles[profileIndex].sources[sourceIndex]
            guard SubscriptionClient.isRemoteSource(source.value) else { continue }
            do {
              let result = try await subscriptionManager.synchronize(source)
              let fetched = ManagedConnectionReconciler.reconcile(
                existing: profiles[profileIndex].sources[sourceIndex].payload,
                fetched: result.profile
              )
              guard case .compatibility = fetched else {
                throw SubscriptionFailure.nativeProfileCannotBeMerged
              }
              profiles[profileIndex].sources[sourceIndex].payload = fetched
              profiles[profileIndex].sources[sourceIndex].updatedAt = Date()
              refreshedAnySource = true
              if profiles[profileIndex].id == selectedProfileID,
                let warning = result.warningDescription
              {
                selectedWarnings.append(warning)
              }
            } catch {
              if profiles[profileIndex].id == selectedProfileID {
                selectedFailure = error
              }
            }
          }
          guard refreshedAnySource else { continue }
          let oldPayload = profiles[profileIndex].payload
          try rebuildCompatibilityPayload(at: profileIndex)
          guard let payload = profiles[profileIndex].payload else { continue }
          try await validateProfile(payload)
          profiles[profileIndex].updatedAt = Date()
          if profiles[profileIndex].id == selectedProfileID,
            ManagedConnectionReconciler.requiresActivation(previous: oldPayload, next: payload)
          {
            selectedProfileChanged = true
          }
        }
        try persistProfileLibrary()
        let applyingSelectedProfile =
          selectedProfileChanged && (coreRunning || runtimeApplyCoordinator.isApplying)
        if applyingSelectedProfile {
          setSubscriptionStatus("Sources refreshed; applying", level: .neutral)
          applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
              if let selectedFailure {
                self.setSubscriptionStatus(
                  "Some sources could not be refreshed",
                  level: .warning
                )
                self.lastError = selectedFailure.localizedDescription
              } else if !selectedWarnings.isEmpty {
                self.setSubscriptionStatus(
                  Array(Set(selectedWarnings)).sorted().joined(separator: "; "),
                  level: .warning
                )
                self.lastError = nil
              } else {
                self.setSubscriptionStatus("Sources refreshed and active", level: .success)
                self.lastError = nil
              }
            case .failure(let error):
              self.profiles = previousProfiles
              try? self.persistProfileLibrary()
              self.loadSelectedProfileEditor()
              self.updateNodes()
              self.setSubscriptionStatus("Source refresh apply failed", level: .warning)
              self.lastError = error.localizedDescription
            }
          }
        }
        updateNodes()
        if !applyingSelectedProfile, let selectedFailure {
          setSubscriptionStatus("Some sources could not be refreshed", level: .warning)
          lastError = selectedFailure.localizedDescription
        } else if !applyingSelectedProfile, !selectedWarnings.isEmpty {
          setSubscriptionStatus(
            Array(Set(selectedWarnings)).sorted().joined(separator: "; "),
            level: .warning
          )
          lastError = nil
        } else if !applyingSelectedProfile {
          setSubscriptionStatus("Sources refreshed", level: .success)
          lastError = nil
        }
        connectAutomaticallyIfNeeded()
      } catch {
        profiles = previousProfiles
        try? persistProfileLibrary()
        loadSelectedProfileEditor()
        updateNodes()
        lastError = error.localizedDescription
      }
    }
  }

  private func loadSelectedProfileEditor() {
    profileName = selectedProfile?.name ?? ""
    if selectedProfile?.sources.contains(where: { $0.id == selectedSourceID }) != true {
      selectedSourceID = selectedProfile?.sources.first?.id
    }
    loadSelectedSourceEditor()
  }

  private func applyProfileLibrary(_ stored: ProfileLibrary) {
    subscriptionRefreshTask?.cancel()
    profiles = stored.profiles
    selectedProfileID = stored.selectedProfileID
    localSOCKSEnabled = stored.localSOCKSEnabled
    localSOCKSPort = stored.localSOCKSPort
    latencyIntervalMinutes = stored.latencyIntervalMinutes
    latencyTestURL = stored.latencyTestURL
    latencyTestURLDraft = stored.latencyTestURL
    if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
      selectedProfileID = profiles.first?.id
    }
    selectedSourceID = nil
    loadSelectedProfileEditor()
    updateNodes()
    profileAvailable = selectedProfile?.payload != nil
    scheduleNextLatencyRefresh()
    if !profiles.isEmpty {
      startSubscriptionRefreshLoop()
    }
    applyCurrentDesiredRuntimeIfNeeded()
  }

  private func loadSelectedSourceEditor() {
    guard let selectedSourceID,
      let source = selectedProfile?.sources.first(where: { $0.id == selectedSourceID })
    else {
      sourceName = ""
      sourceExcludeRegex = ""
      subscriptionURL = ""
      subscriptionUserAgent = SubscriptionHeaders.defaultUserAgent
      subscriptionAppVersion = SubscriptionHeaders.defaultAppVersion
      subscriptionDeviceOS = SubscriptionHeaders.defaultDeviceOS
      subscriptionHWID = SubscriptionHeaders.makeHardwareID()
      return
    }
    sourceName = source.name
    sourceExcludeRegex = source.excludeRegex ?? ""
    subscriptionURL = source.value
    subscriptionUserAgent = source.headers.userAgent
    subscriptionAppVersion = source.headers.appVersion ?? ""
    subscriptionDeviceOS = source.headers.deviceOS
    subscriptionHWID = source.headers.hardwareID
  }

  private func persistProfileLibrary(latencyTestURL: String? = nil) throws {
    if let profileStoreLoadError {
      throw AppModelFailure.profileLibraryUnavailable(profileStoreLoadError)
    }
    try profileLibrarySaver(
      ProfileLibrary(
        profiles: profiles,
        selectedProfileID: selectedProfileID,
        localSOCKSEnabled: localSOCKSEnabled,
        localSOCKSPort: localSOCKSPort,
        latencyIntervalMinutes: latencyIntervalMinutes,
        latencyTestURL: latencyTestURL ?? self.latencyTestURL
      )
    )
  }

  private func makeStartRequest(
    profile: CoreProfile,
    profileID: UUID?
  ) -> HelperRequest {
    HelperRequest(
      action: .start,
      profile: profile,
      profileID: profileID,
      mode: routingMode,
      node: selectedNodeID,
      localSOCKSEnabled: localSOCKSEnabled,
      localSOCKSPort: localSOCKSPort,
      latencyTestURL: latencyTestURL
    )
  }

  private func rebuildCompatibilityPayload(at profileIndex: Int) throws {
    let previousPayload = profiles[profileIndex].payload
    let policy: RoutingPolicy?
    let applicationRoutingRules: [ApplicationRoutingRule]
    if case .compatibility(let current) = previousPayload {
      policy = current.routingPolicy
      applicationRoutingRules = current.applicationRoutingRules
    } else {
      policy = nil
      applicationRoutingRules = []
    }
    guard profiles[profileIndex].sources.contains(where: { $0.payload != nil }) else {
      profiles[profileIndex].payload = nil
      profiles[profileIndex].updatedAt = nil
      return
    }
    let merged = try ProfileAggregator.merge(
      sources: profiles[profileIndex].sources,
      routingPolicy: policy,
      applicationRoutingRules: applicationRoutingRules
    )
    profiles[profileIndex].payload = ManagedConnectionReconciler.reconcile(
      existing: previousPayload,
      fetched: merged
    )
  }

  private func saveApplicationRoutingRules(
    _ rules: [ApplicationRoutingRule],
    status: String
  ) {
    guard rules.count <= 32, let selectedProfileID,
      let index = profiles.firstIndex(where: { $0.id == selectedProfileID }),
      let payload = profiles[index].payload
    else {
      lastError = "The selected profile cannot store application rules."
      return
    }
    let updated: CoreProfile
    switch payload {
    case .compatibility(let profile):
      updated = .compatibility(
        VPNProfile(
          connections: profile.connections,
          routingPolicy: profile.routingPolicy,
          nodeGroups: profile.nodeGroups ?? [],
          applicationRoutingRules: rules
        )
      )
    case .native(let profile):
      updated = .native(
        NativeProfile(
          configuration: profile.configuration,
          selectorTag: profile.selectorTag,
          nodes: profile.nodes,
          applicationRoutingRules: rules
        )
      )
    }
    applicationRoutingEditGeneration &+= 1
    let editGeneration = applicationRoutingEditGeneration
    Task {
      do {
        try await validateProfile(updated)
        guard editGeneration == applicationRoutingEditGeneration else { return }
        guard let currentIndex = profiles.firstIndex(where: { $0.id == selectedProfileID }) else {
          return
        }
        guard profiles[currentIndex].payload == payload else {
          lastError = "The profile changed while the application rule was validated. Try again."
          return
        }
        profiles[currentIndex].payload = updated
        try persistProfileLibrary()
        updateNodes()
        setSubscriptionStatus(status, level: .success)
        lastError = nil
        applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
          guard let self, editGeneration == self.applicationRoutingEditGeneration,
            case .failure(let error) = result
          else { return }
          if let rollbackIndex = self.profiles.firstIndex(where: { $0.id == selectedProfileID }),
            self.profiles[rollbackIndex].payload == updated
          {
            self.profiles[rollbackIndex].payload = payload
            try? self.persistProfileLibrary()
            self.updateNodes()
          }
          self.setSubscriptionStatus(
            self.runtimeFailurePreservedPrevious
              ? "Apply failed — previous routing remains active"
              : "Application rule apply failed",
            level: .warning
          )
          self.lastError = error.localizedDescription
        }
      } catch {
        guard editGeneration == applicationRoutingEditGeneration else { return }
        lastError = error.localizedDescription
      }
    }
  }

  private func updateNodes() {
    lastLatencyTestAt = nil
    latencyTestCompleted = false
    let descriptors =
      selectedProfile?.payload?.nodes ?? [
        ProxyNodeDescriptor(id: .auto, name: "Auto", kind: .automatic)
      ]
    nodes = descriptors.map { descriptor in
      let metadata = groupMetadata(for: descriptor.id)
      return ProxyNode(
        id: descriptor.id,
        name: descriptor.name,
        symbol: symbol(for: descriptor.kind),
        groupID: metadata?.id,
        groupName: metadata?.name,
        groupOrder: metadata?.groupOrder,
        nodeOrder: metadata?.nodeOrder,
        delay: nil
      )
    }
    if !nodes.contains(where: { $0.id == selectedNodeID }) {
      selectedNodeID = nodes.first?.id ?? .auto
    }
  }

  private func send(_ request: HelperRequest) {
    guard helperEnabled, helperReachable else {
      lastError = "The background helper is not ready."
      return
    }
    beginBusyOperation()
    Task {
      defer { endBusyOperation() }
      do {
        let response = try await Task.detached {
          try HelperClient.send(request)
        }.value
        apply(response)
        lastError = response.success ? nil : response.message
      } catch {
        lastError = error.localizedDescription
      }
    }
  }

  private func submitRuntimeApply(
    _ request: HelperRequest,
    onCurrentResult: (@MainActor (Result<HelperResponse, any Error>) -> Void)? = nil
  ) {
    guard helperEnabled, helperReachable else {
      runtimeApplyStatus = .failed
      runtimeFailurePreservedPrevious = false
      let failure = AppModelFailure.helperNotReady
      lastError = failure.localizedDescription
      onCurrentResult?(.failure(failure))
      return
    }
    runtimeApplyStatus = .applying
    runtimeFailurePreservedPrevious = false
    let previouslyActiveProfileID = helperActiveProfileID
    let previouslyRunning = coreRunning
    let knownGoodProfileID = previouslyActiveProfileID ?? request.profileID
    runtimeApplyCoordinator.submit(request) { [weak self] outcome in
      guard let self else { return }
      switch outcome.result {
      case .success(let response):
        self.apply(response, preserveDesiredRuntime: !outcome.isCurrent)
        guard outcome.isCurrent else { return }
        if response.success {
          self.runtimeApplyStatus = response.coreRunning ? .active : .saved
          self.runtimeFailurePreservedPrevious = false
          self.lastError = nil
          onCurrentResult?(.success(response))
        } else {
          self.runtimeApplyStatus = .failed
          self.runtimeFailurePreservedPrevious =
            previouslyRunning && response.coreRunning
            && response.activeProfileID == knownGoodProfileID
          let failure = AppModelFailure.profileActivationFailed(response.message)
          self.lastError = failure.localizedDescription
          onCurrentResult?(.failure(failure))
        }
      case .failure(let error):
        guard outcome.isCurrent else { return }
        self.runtimeApplyStatus = .failed
        self.runtimeFailurePreservedPrevious = false
        self.lastError = error.localizedDescription
        Task {
          do {
            let observed = try await self.runtimeStateReader()
            guard outcome.generation == self.runtimeApplyCoordinator.currentGeneration else {
              return
            }
            self.apply(observed)
            self.helperReachable = true
            self.runtimeApplyStatus = .failed
            self.runtimeFailurePreservedPrevious =
              previouslyRunning && observed.coreRunning
              && observed.activeProfileID == knownGoodProfileID
          } catch {
            guard outcome.generation == self.runtimeApplyCoordinator.currentGeneration else {
              return
            }
            self.helperReachable = false
          }
          onCurrentResult?(.failure(error))
        }
      }
    }
  }

  private func applyCurrentDesiredRuntimeIfNeeded(
    onCurrentResult: (@MainActor (Result<HelperResponse, any Error>) -> Void)? = nil
  ) {
    runtimeApplyCoordinator.markSaved()
    runtimeApplyStatus = .saved
    guard coreRunning || runtimeApplyCoordinator.isApplying else { return }
    guard let payload = selectedProfile?.payload else {
      submitRuntimeApply(HelperRequest(action: .stop), onCurrentResult: onCurrentResult)
      return
    }
    submitRuntimeApply(
      makeStartRequest(profile: payload, profileID: selectedProfileID),
      onCurrentResult: onCurrentResult
    )
  }

  private func apply(
    _ response: HelperResponse,
    preserveDesiredRuntime: Bool = false
  ) {
    let shouldPrimeLatency = response.coreRunning && !coreRunning
    helperStatus = response.message
    helperVersion = response.helperVersion
    helperRevision = response.helperRevision
    coreRunning = response.coreRunning
    coreVersion = response.coreVersion
    automaticRecoveryExhausted = response.automaticRecoveryExhausted
    if !preserveDesiredRuntime, !runtimeApplyCoordinator.isApplying {
      runtimeApplyStatus = response.coreRunning ? .active : .saved
    }
    if !preserveDesiredRuntime {
      routingMode = response.mode
    }
    helperActiveProfileID = response.activeProfileID
    let responseMatchesSelection =
      response.coreRunning && response.activeProfileID == selectedProfileID
    if responseMatchesSelection, !preserveDesiredRuntime {
      selectedNodeID = response.selectedNode
    }
    if responseMatchesSelection, !response.nodes.isEmpty {
      let delays = Dictionary(
        uniqueKeysWithValues: nodes.compactMap { node in
          node.delay.map { (node.id, $0) }
        })
      nodes = response.nodes.map { descriptor in
        let metadata = groupMetadata(for: descriptor.id)
        return ProxyNode(
          id: descriptor.id,
          name: descriptor.name,
          symbol: symbol(for: descriptor.kind),
          groupID: metadata?.id,
          groupName: metadata?.name,
          groupOrder: metadata?.groupOrder,
          nodeOrder: metadata?.nodeOrder,
          delay: delays[descriptor.id]
        )
      }
    } else {
      updateNodes()
    }
    if shouldPrimeLatency {
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(250))
        self?.refreshLatencyIfNeeded()
      }
    } else if response.coreRunning {
      scheduleNextLatencyRefresh()
    } else {
      latencyRefreshTask?.cancel()
      latencyRefreshTask = nil
    }
  }

  private func symbol(for kind: ProxyNodeKind) -> String {
    switch kind {
    case .automatic: "wand.and.stars"
    case .vless: "shield.lefthalf.filled"
    case .hysteria2: "bolt.horizontal.fill"
    case .shadowsocks: "lock.shield"
    case .native, .unknown: "network"
    }
  }

  private func groupMetadata(for nodeID: ProxyNodeID) -> (
    id: String, name: String, groupOrder: Int, nodeOrder: Int
  )? {
    guard case .compatibility(let profile) = selectedProfile?.payload else { return nil }
    for (groupOrder, group) in (profile.nodeGroups ?? []).enumerated() {
      if let nodeOrder = group.nodes.firstIndex(of: nodeID) {
        return (group.id, group.name, groupOrder, nodeOrder)
      }
    }
    return nil
  }

  private func enableCurrentHelper() async throws -> HelperResponse {
    try await HelperLifecycle.enable(service: helperService) {
      try await self.helperLifecycleSender(
        HelperRequest(action: .status),
        5
      )
    }
  }

  private func refreshRegistrationStatus() {
    switch helperService.registrationState {
    case .enabled:
      helperEnabled = true
      helperRequiresApproval = false
      helperStatus = "Helper enabled"
    case .requiresApproval:
      helperEnabled = false
      helperReachable = false
      helperRequiresApproval = true
      helperStatus = "Approval required"
    case .notRegistered:
      helperEnabled = false
      helperReachable = false
      helperRequiresApproval = false
      helperStatus = "Helper not enabled"
    case .notFound:
      helperEnabled = false
      helperReachable = false
      helperRequiresApproval = false
      helperStatus = "Helper missing"
    case .unknown:
      helperEnabled = false
      helperReachable = false
      helperRequiresApproval = false
      helperStatus = "Unknown helper state"
    }
  }

  private func bootstrapHelper() {
    if helperApprovalPending {
      continueHelperApprovalFlow()
      return
    }
    switch helperService.registrationState {
    case .enabled:
      refresh()
    case .notRegistered, .notFound:
      enableHelper()
    case .requiresApproval, .unknown:
      break
    }
  }

  private func invalidateRefresh() {
    refreshGeneration += 1
    refreshInProgress = false
  }

  private func beginHelperApprovalFlow(openSystemSettings: Bool) {
    helperApprovalPending = true
    helperApprovalDefaults.set(true, forKey: HelperApprovalPersistence.pendingKey)
    helperEnabled = false
    helperReachable = false
    helperRequiresApproval = true
    helperStatus = "Waiting for approval in System Settings…"
    lastError = nil
    if openSystemSettings, !helperApprovalSettingsPresented {
      helperService.openSystemSettings()
      helperApprovalSettingsPresented = true
    }
    startHelperApprovalPolling()
  }

  private func completeHelperApprovalFlow() {
    helperApprovalPending = false
    helperApprovalDefaults.removeObject(forKey: HelperApprovalPersistence.pendingKey)
    helperApprovalPollTask?.cancel()
    helperApprovalPollTask = nil
    helperApprovalPolling = false
    helperApprovalSettingsPresented = false
  }

  private func continueHelperApprovalFlow() {
    guard helperApprovalPending else {
      refresh()
      return
    }
    guard helperRepairTask == nil else { return }

    switch helperService.registrationState {
    case .requiresApproval:
      beginHelperApprovalFlow(openSystemSettings: false)
    case .enabled:
      helperEnabled = true
      helperRequiresApproval = false
      repairHelper()
    case .notRegistered, .notFound:
      helperEnabled = false
      helperRequiresApproval = false
      enableHelper()
    case .unknown:
      helperEnabled = false
      helperReachable = false
      helperRequiresApproval = false
      helperStatus = "Waiting for macOS to update helper approval…"
      startHelperApprovalPolling()
    }
  }

  private func startHelperApprovalPolling() {
    guard helperApprovalPending, helperApprovalPollTask == nil else { return }
    helperApprovalPolling = true
    helperApprovalPollTask = Task { [weak self] in
      guard let self else { return }
      defer {
        helperApprovalPolling = false
        helperApprovalPollTask = nil
      }

      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: helperApprovalPollDuration)
      while helperApprovalPending, clock.now < deadline {
        do {
          try await Task.sleep(for: helperApprovalPollInterval)
        } catch {
          return
        }
        guard helperApprovalPending else { return }
        switch helperService.registrationState {
        case .requiresApproval, .unknown:
          continue
        case .enabled, .notRegistered, .notFound:
          if helperRepairTask != nil { continue }
          continueHelperApprovalFlow()
          return
        }
      }
      helperApprovalSettingsPresented = false
    }
  }

  private func enableLaunchAtLoginIfNeeded() {
    launchAtLoginEnabled = loginItemService.status == .enabled
    guard loginItemService.status == .notRegistered else { return }
    do {
      try loginItemService.register()
      launchAtLoginEnabled = loginItemService.status == .enabled
    } catch {
      lastError = "Unable to enable launch at login: \(error.localizedDescription)"
    }
  }

  private func connectAutomaticallyIfNeeded() {
    guard let payload = selectedProfile?.payload else { return }
    guard
      AutomaticConnectionPolicy.shouldConnect(
        didAttemptAutomaticConnection: didAttemptAutomaticConnection,
        automaticRecoveryExhausted: automaticRecoveryExhausted,
        helperReady: currentHelperIsReady,
        profileAvailable: true,
        coreRunningForSelectedProfile: coreRunning && helperActiveProfileID == selectedProfileID
      )
    else { return }
    didAttemptAutomaticConnection = true
    let request = makeStartRequest(profile: payload, profileID: selectedProfileID)
    submitRuntimeApply(request) { [weak self] result in
      if case .failure(let error) = result {
        self?.lastError = "Automatic connection failed: \(error.localizedDescription)"
      }
    }
  }

  private var isInstalledInApplications: Bool {
    applicationBundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/")
  }

  private var currentHelperIsReady: Bool {
    helperEnabled
      && helperReachable
      && helperVersion == HelperConstants.helperVersion
      && helperRevision == HelperConstants.helperRevision
  }

  private var applicationVersion: String {
    Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "0.0.0"
  }

  private func beginBusyOperation() {
    busyOperationCount += 1
  }

  private func endBusyOperation() {
    busyOperationCount = max(0, busyOperationCount - 1)
  }

  private func profileSummary(_ profile: VPNProfile) -> String {
    let count = profile.connections.count
    return "\(count) server\(count == 1 ? "" : "s")"
  }
}

private enum AppModelFailure: LocalizedError {
  case profileActivationFailed(String)
  case profileValidationFailed(String)
  case helperRequiredForValidation
  case helperRevisionMismatch
  case helperNotReady
  case coreStopFailed(String)
  case profileLibraryUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .profileActivationFailed(let message):
      "The subscription was downloaded but could not be activated: \(message)"
    case .profileValidationFailed(let message):
      "The profile was rejected before activation: \(message)"
    case .helperRequiredForValidation:
      "Enable the background helper before importing a profile."
    case .helperRevisionMismatch:
      "macOS is still running an older background helper. Approve the updated item in System Settings, then repair it again."
    case .helperNotReady:
      "The background helper is not ready."
    case .coreStopFailed(let message):
      "The VPN core did not stop: \(message)"
    case .profileLibraryUnavailable(let message): message
    }
  }
}
