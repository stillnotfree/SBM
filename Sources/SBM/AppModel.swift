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
      let ordered = values.enumerated().sorted { leftEntry, rightEntry in
        (leftEntry.element.nodeOrder ?? leftEntry.offset)
          < (rightEntry.element.nodeOrder ?? rightEntry.offset)
      }.map(\.element)
      return ProxyNodeSection(
        id: id,
        name: first?.groupName ?? "Servers",
        order: first?.groupOrder ?? Int.max,
        nodes: ordered
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

enum RoutingMutationState: Equatable, Sendable {
  case saved
  case applying
  case failed
  case reconnectRequired
}

struct RoutingMutationPresentation: Equatable, Sendable {
  let state: RoutingMutationState
  let message: String?

  static let saved = RoutingMutationPresentation(state: .saved, message: nil)
  static let reconnectRequired = RoutingMutationPresentation(
    state: .reconnectRequired,
    message: nil
  )
}

enum SettingsSectionIssue: Equatable, Sendable {
  case validation(String)
  case persistence(String)
  case runtimeSynchronization(String)

  var message: String {
    switch self {
    case .validation(let message), .persistence(let message),
      .runtimeSynchronization(let message):
      message
    }
  }

  var canRetrySynchronization: Bool {
    if case .runtimeSynchronization = self { return true }
    return false
  }
}

enum ConnectionPresentation: Equatable {
  case disconnected
  case unknown
  case connecting
  case connected
  case disconnecting
  case failed(previousRuntimePreserved: Bool)

  var title: String {
    switch self {
    case .disconnected: "VPN Disconnected"
    case .unknown: "VPN state unknown"
    case .connecting: "Connecting…"
    case .connected: "VPN Connected"
    case .disconnecting: "Disconnecting…"
    case .failed(let preserved):
      preserved ? "Connection change failed — previous VPN active" : "Connection failed"
    }
  }

  var systemImage: String {
    switch self {
    case .connected, .failed(previousRuntimePreserved: true): "lock.shield.fill"
    case .connecting, .disconnecting: "arrow.trianglehead.2.clockwise.rotate.90"
    case .unknown: "exclamationmark.shield"
    case .disconnected, .failed(previousRuntimePreserved: false): "lock.shield"
    }
  }

  var nextEnabledState: Bool? {
    switch self {
    case .disconnected, .failed(previousRuntimePreserved: false): true
    case .unknown: false
    case .connecting, .connected, .failed(previousRuntimePreserved: true): false
    case .disconnecting: nil
    }
  }
}

enum DeferredRuntimeApplyAction: Equatable, Sendable {
  case reconnect

  var title: String {
    "Reconnect to Apply"
  }
}

enum DeferredRuntimeApplyPhase: Equatable, Sendable {
  case idle
  case pending
  case reconnecting
  case failed
}

struct DeferredRuntimeApplyPresentation: Equatable, Sendable {
  let headline: String
  let action: DeferredRuntimeApplyAction
  let phase: DeferredRuntimeApplyPhase

  static let changesReadyToApply = "Changes ready to apply"
}

enum ObservedCoreState: String, Codable, Equatable, Sendable {
  case running
  case stopped
  case unknown
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
  private enum RoutingMutationKind: Hashable, Sendable {
    case website
    case application
    case policy

    var routingName: String {
      switch self {
      case .website: "Website rule"
      case .application: "Application rule"
      case .policy: "Routing policy"
      }
    }
  }

  private struct RoutingMutationIdentity: Hashable, Sendable {
    let profileID: UUID
    let revision: UInt64
  }

  private struct RoutingMutationStatus: Equatable, Sendable {
    let identity: RoutingMutationIdentity?
    let presentation: RoutingMutationPresentation
  }

  private struct RefreshActivationSnapshot {
    let before: ManagedProfile
    var after: ManagedProfile
  }

  private enum RoutingMutationFailure: LocalizedError {
    case profileChanged(String)
    case ruleMissing(String)

    var errorDescription: String? {
      switch self {
      case .profileChanged(let message), .ruleMissing(let message): message
      }
    }
  }

  private struct SourceFetchBasis: Equatable {
    let value: String
    let headers: SubscriptionHeaders
    let excludeRegex: String?
  }

  struct RecentError: Identifiable, Equatable {
    let id: UUID
    var occurredAt: Date
    let message: String
    var repeatCount: Int
  }

  private enum HelperResponsePolicy {
    case observation(runtimeCurrent: Bool, adoptDesiredRuntime: Bool)
    case currentMutation
    case staleMutation
  }
  var routingMode: RoutingMode = .rule
  var selectedNodeID: ProxyNodeID = .auto
  var helperStatus = "Checking…"
  var helperEnabled = false
  var helperReachable = false
  var helperRequiresApproval = false
  private(set) var helperApprovalPending = false
  private(set) var helperApprovalPolling = false
  var observedCoreState: ObservedCoreState = .unknown
  var coreRunning: Bool {
    get { observedCoreState == .running }
    set { observedCoreState = newValue ? .running : .stopped }
  }
  var helperProtocolVersion: Int? = HelperConstants.protocolVersion
  var helperVersion: String?
  var helperRevision: Int?
  var coreVersion: String?
  var launchAtLoginEnabled = false
  private var busyOperationCount = 0
  var isBusy: Bool { busyOperationCount > 0 }
  var helperSetupInProgress = false
  var lastError: String? {
    didSet {
      if let lastError, !lastError.isEmpty { recordRecentError(lastError) }
    }
  }
  private(set) var recentErrors: [RecentError] = []
  var updateStatus = "Not checked"
  var availableUpdateVersion: String?
  var isCheckingForUpdates = false
  var isDownloadingUpdate = false
  var updateDownloadProgress: Double?

  var profiles: [ManagedProfile] = []
  var selectedProfileID: UUID?
  var profileName = ""
  private(set) var profileNameError: String?
  var selectedSourceID: UUID?
  var sourceName = ""
  var sourceExcludeRegex = ""
  var routingInspectorInput = ""
  var routingInspectorApplicationID: UUID?
  var routingInspectorOutput = "Enter a domain or IP address to explain traffic routing."
  var routingInspectorDetails = ""
  var websiteRoutingInput = ""
  var websiteRoutingTarget: WebsiteRoutingTarget = .selectedProxy
  var websiteRoutingEditingRuleID: UUID?
  var subscriptionURL = ""
  var subscriptionUserAgent = SubscriptionHeaders.defaultUserAgent
  var subscriptionAppVersion = SubscriptionHeaders.defaultAppVersion
  var subscriptionDeviceOS = SubscriptionHeaders.defaultDeviceOS
  var subscriptionHWID = SubscriptionHeaders.makeHardwareID()
  var subscriptionStatus = "No subscription synced"
  var subscriptionStatusLevel: SubscriptionStatusLevel = .neutral
  private(set) var sourceEditorError: String?
  private(set) var latencySettingsIssue: SettingsSectionIssue?
  private(set) var localSOCKSIssue: SettingsSectionIssue?
  var latencySettingsError: String? { latencySettingsIssue?.message }
  var localSOCKSError: String? { localSOCKSIssue?.message }
  var canRetryLatencySynchronization: Bool {
    latencySettingsIssue?.canRetrySynchronization == true
  }
  var canRetryLocalSOCKSSynchronization: Bool {
    localSOCKSIssue?.canRetrySynchronization == true
  }
  var runtimeApplyStatus: RuntimeApplyStatus = .saved
  private var syncingOperationCount = 0
  var isSyncing: Bool { syncingOperationCount > 0 }
  var profileAvailable = false
  var localSOCKSEnabled = false
  var localSOCKSPort: UInt16 = 1082
  var localSOCKSEnabledDraft = false
  var localSOCKSPortDraft: UInt16 = 1082
  private(set) var localSOCKSApplyInProgress = false
  var latencyIntervalMinutes = 10
  var latencyIntervalMinutesDraft = 10
  var latencyTestURL = LatencyTargetPolicy.defaultURL
  var latencyTestURLDraft = LatencyTargetPolicy.defaultURL
  private(set) var latencyApplyInProgress = false
  private var subscriptionRefreshTask: Task<Void, Never>?
  private var profileRefreshTask: Task<Void, Never>?
  private var refreshRequestedByUser = false
  private var latencyRefreshTask: Task<Void, Never>?
  private var latencyOperationTask: Task<Void, Never>?
  private var latencyOperationGeneration = 0
  private var profileStoreLoadError: String?
  private var helperRepairTask: Task<Void, Never>?
  private var helperApprovalPollTask: Task<Void, Never>?
  private var helperApprovalSettingsPresented = false
  private var refreshGeneration = 0
  private var routingMutationRevisions: [UUID: UInt64] = [:]
  private var routingMutationQueues: [UUID: Task<Void, Never>] = [:]
  private var routingMutationQueueTokens: [UUID: UUID] = [:]
  private var routingMutationStatuses: [UUID: [RoutingMutationKind: RoutingMutationStatus]] = [:]
  private var routingInspectionGeneration = 0
  private var runtimeFailurePreservedPrevious = false
  private var runtimeFailureProfileID: UUID?
  private var deferredRuntimeApplyPending = false
  private(set) var deferredRuntimeApplyPhase: DeferredRuntimeApplyPhase = .idle
  private(set) var deferredRuntimeApplyError: String?
  /// `nil` means startup has not yet adopted a helper observation or received
  /// explicit user intent. Explicit Disconnect is always stored as `false`.
  private var desiredCoreRunning: Bool?
  private var refreshInProgress = false
  var isStatusRefreshInProgress: Bool { refreshInProgress }
  var isRefreshing: Bool { refreshRequestedByUser && profileRefreshTask != nil }
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
  private let helperRequestSender: @Sendable (HelperRequest) async throws -> HelperResponse
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
  private let latencySender: @Sendable (ProxyNodeID) async throws -> HelperResponse
  private let loginItemService = SMAppService.mainApp

  private func setSubscriptionStatus(
    _ value: String,
    level: SubscriptionStatusLevel = .neutral
  ) {
    subscriptionStatus = value
    subscriptionStatusLevel = level
  }

  private func boundedSettingsError(
    _ prefix: String,
    error: any Error,
    additionalSecrets: [String] = []
  ) -> String {
    let secrets = DiagnosticSecrets.collect(from: profiles) + additionalSecrets
    let detail = SafeDiagnosticError.sanitize(
      error.localizedDescription,
      secrets: secrets
    )
    guard detail != "Error details redacted.", !detail.isEmpty else { return prefix }
    return "\(prefix): \(detail)"
  }

  private func setSettingsError(
    _ prefix: String,
    error: any Error,
    additionalSecrets: [String] = []
  ) -> String {
    let message = boundedSettingsError(
      prefix,
      error: error,
      additionalSecrets: additionalSecrets
    )
    lastError = message
    return message
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
    helperRequestSender: @escaping @Sendable (HelperRequest) async throws -> HelperResponse = {
      request in
      try await Task.detached {
        try HelperClient.send(request)
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
        guard response.protocolVersion == HelperConstants.protocolVersion,
          response.helperVersion == HelperConstants.helperVersion,
          response.helperRevision == HelperConstants.helperRevision
        else {
          throw AppModelFailure.helperRevisionMismatch
        }
        guard response.success else {
          throw RoutingInspectionFailure.activeRuleSetDataUnavailable(response.message)
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
    latencySender: @escaping @Sendable (ProxyNodeID) async throws -> HelperResponse = { node in
      try await Task.detached {
        try HelperClient.send(
          HelperRequest(action: .testLatency, node: node),
          receiveTimeoutSeconds: 10
        )
      }.value
    },
    performStartup: Bool = true
  ) {
    self.helperService = helperService
    self.helperLifecycleSender = helperLifecycleSender
    self.helperRequestSender = helperRequestSender
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
    self.latencySender = latencySender
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
    localSOCKSEnabledDraft = stored.localSOCKSEnabled
    localSOCKSPortDraft = stored.localSOCKSPort
    latencyIntervalMinutes = stored.latencyIntervalMinutes
    latencyIntervalMinutesDraft = stored.latencyIntervalMinutes
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
    case .failed
    where runtimeFailureProfileID == nil || runtimeFailureProfileID == selectedProfileID:
      return runtimeFailurePreservedPrevious
        ? "Apply failed — previous routing remains active"
        : "Apply failed — active routing is unknown"
    case .failed:
      return profile.routingPolicy == nil
        ? "No routing policy" : "Routing policy saved, not active"
    case .active where coreRunning && helperActiveProfileID == selectedProfileID:
      return profile.routingPolicy == nil ? "No routing policy" : "Routing policy active"
    case .reconnectRequired:
      return profile.routingPolicy == nil
        ? "No routing policy"
        : "Routing policy saved"
    case .saved, .active:
      return profile.routingPolicy == nil ? "No routing policy" : "Routing policy saved, not active"
    }
  }

  var routingPolicyStatusLevel: SubscriptionStatusLevel {
    switch runtimeApplyStatus {
    case .active where coreRunning && helperActiveProfileID == selectedProfileID:
      return hasRoutingPolicy ? .success : .neutral
    case .failed
    where runtimeFailureProfileID == nil || runtimeFailureProfileID == selectedProfileID:
      return .warning
    case .failed:
      return .neutral
    case .saved where hasRoutingPolicy:
      return .warning
    case .reconnectRequired:
      return .warning
    case .applying, .saved, .active:
      return .neutral
    }
  }

  var desiredRuntimeGeneration: UInt64 { runtimeApplyCoordinator.currentGeneration }

  var connectionPresentation: ConnectionPresentation {
    if runtimeApplyStatus == .applying {
      return (desiredCoreRunning ?? coreRunning) ? .connecting : .disconnecting
    }
    if runtimeApplyStatus == .failed {
      guard observedCoreState != .unknown else { return .unknown }
      return .failed(previousRuntimePreserved: runtimeFailurePreservedPrevious)
    }
    switch observedCoreState {
    case .running: return .connected
    case .stopped: return .disconnected
    case .unknown: return .unknown
    }
  }

  var deferredRuntimeApplyPresentation: DeferredRuntimeApplyPresentation? {
    guard deferredRuntimeApplyPending,
      runtimeApplyStatus != .applying || deferredRuntimeApplyPhase == .reconnecting,
      observedCoreState != .unknown
    else { return nil }
    let isReconnecting = deferredRuntimeApplyPhase == .reconnecting
    return DeferredRuntimeApplyPresentation(
      headline: isReconnecting
        ? "Reconnecting…" : DeferredRuntimeApplyPresentation.changesReadyToApply,
      action: .reconnect,
      phase: isReconnecting ? .reconnecting : deferredRuntimeApplyPhase
    )
  }

  func applyDeferredRuntimeChange() {
    reconnectToApply()
  }

  var profileNameSaveEnabled: Bool {
    guard selectedProfileID != nil else { return false }
    let candidate = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (try? SubscriptionClient.validateDisplayName(candidate)) != nil else { return false }
    return candidate != selectedProfile?.name
  }

  var sourceDraftIsValid: Bool {
    guard selectedSourceID != nil,
      (try? SubscriptionClient.validateSourceValue(subscriptionURL)) != nil
    else { return false }
    let candidateName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedName = candidateName.isEmpty ? "Subscription" : candidateName
    guard (try? SubscriptionClient.validateDisplayName(normalizedName)) != nil else {
      return false
    }
    let headers = SubscriptionHeaders(
      userAgent: subscriptionUserAgent.trimmingCharacters(in: .whitespacesAndNewlines),
      appVersion: subscriptionAppVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil : subscriptionAppVersion.trimmingCharacters(in: .whitespacesAndNewlines),
      deviceOS: subscriptionDeviceOS.trimmingCharacters(in: .whitespacesAndNewlines),
      hardwareID: subscriptionHWID.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    guard (try? SubscriptionClient.validate(headers: headers)) != nil else { return false }
    do {
      _ = try SourceNameFilter.normalized(sourceExcludeRegex)
      return true
    } catch {
      return false
    }
  }

  var latencySettingsDirty: Bool {
    latencyIntervalMinutesDraft != latencyIntervalMinutes
      || latencyTestURLDraft != latencyTestURL
  }

  var latencySettingsValid: Bool {
    latencyIntervalMinutesDraft > 0
      && (try? LatencyTargetPolicy.normalized(latencyTestURLDraft)) != nil
  }

  var localSOCKSSettingsDirty: Bool {
    localSOCKSEnabledDraft != localSOCKSEnabled || localSOCKSPortDraft != localSOCKSPort
  }

  var localSOCKSSettingsValid: Bool {
    (1024...65535).contains(Int(localSOCKSPortDraft)) && localSOCKSPortDraft != 19090
  }

  var coreIsKnownStopped: Bool { observedCoreState == .stopped }

  private var shouldApplyDesiredRuntime: Bool {
    deferredRuntimeApplyPhase != .reconnecting
      && desiredCoreRunning != false
      && (coreRunning || runtimeApplyCoordinator.isApplying)
  }

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

  var websiteRoutingRules: [WebsiteRoutingRule] {
    selectedProfile?.payload?.websiteRoutingRules ?? []
  }

  var websiteRoutingControlsEnabled: Bool {
    selectedProfile?.payload != nil && !helperSetupInProgress
  }

  var websiteRoutingStatus: RoutingMutationPresentation {
    routingMutationPresentation(for: .website, profileID: selectedProfileID)
  }

  var applicationRoutingStatus: RoutingMutationPresentation {
    routingMutationPresentation(for: .application, profileID: selectedProfileID)
  }

  var routingPolicyMutationStatus: RoutingMutationPresentation {
    routingMutationPresentation(for: .policy, profileID: selectedProfileID)
  }

  var websiteRoutingActionTitle: String {
    websiteRoutingEditingRuleID == nil ? "Add" : "Save"
  }

  func beginWebsiteRoutingEdit(_ id: UUID) {
    guard let rule = websiteRoutingRules.first(where: { $0.id == id }) else { return }
    websiteRoutingEditingRuleID = id
    websiteRoutingInput = rule.domain
    websiteRoutingTarget = rule.target
  }

  func cancelWebsiteRoutingEdit() {
    websiteRoutingEditingRuleID = nil
    websiteRoutingInput = ""
  }

  func addWebsiteRoutingRule() {
    let profileID = selectedProfileID
    let input = websiteRoutingInput
    let target = websiteRoutingTarget
    let editingRuleID = websiteRoutingEditingRuleID
    do {
      let domain = try WebsiteDomainNormalizer.normalize(websiteRoutingInput)
      enqueueRoutingMutation(
        profileID: profileID,
        kind: .website,
        successMessage: editingRuleID == nil ? "Website rule saved" : "Website rule updated",
        operation: { payload in
          let currentRules = payload.websiteRoutingRules
          if let editingRuleID {
            guard currentRules.contains(where: { $0.id == editingRuleID }) else {
              throw RoutingMutationFailure.ruleMissing(
                "The website rule changed before it could be updated."
              )
            }
            guard
              !currentRules.contains(where: {
                $0.id != editingRuleID && $0.domain == domain
              })
            else {
              throw WebsiteRoutingFailure.duplicateDomain
            }
            let rules = currentRules.map { rule in
              rule.id == editingRuleID
                ? WebsiteRoutingRule(id: rule.id, domain: domain, target: target)
                : rule
            }
            return self.replacingWebsiteRoutingRules(rules, in: payload)
          }
          guard currentRules.count < 128 else { throw WebsiteRoutingFailure.tooManyRules }
          guard !currentRules.contains(where: { $0.domain == domain }) else {
            throw WebsiteRoutingFailure.duplicateDomain
          }
          return self.replacingWebsiteRoutingRules(
            currentRules + [WebsiteRoutingRule(domain: domain, target: target)],
            in: payload
          )
        },
        onSuccess: { [weak self] in
          guard let self,
            self.selectedProfileID == profileID,
            self.websiteRoutingInput == input,
            self.websiteRoutingEditingRuleID == editingRuleID
          else { return }
          self.websiteRoutingInput = ""
          self.websiteRoutingEditingRuleID = nil
        }
      )
    } catch {
      presentRoutingMutationFailure(
        error,
        kind: .website,
        profileID: profileID
      )
    }
  }

  func removeWebsiteRoutingRule(_ id: UUID) {
    enqueueRoutingMutation(
      profileID: selectedProfileID,
      kind: .website,
      successMessage: "Website rule removed",
      operation: { payload in
        guard payload.websiteRoutingRules.contains(where: { $0.id == id }) else {
          throw RoutingMutationFailure.ruleMissing(
            "The website rule changed before it could be removed."
          )
        }
        return self.replacingWebsiteRoutingRules(
          payload.websiteRoutingRules.filter { $0.id != id },
          in: payload
        )
      }
    )
  }

  func setWebsiteRoutingTarget(_ id: UUID, target: WebsiteRoutingTarget) {
    enqueueRoutingMutation(
      profileID: selectedProfileID,
      kind: .website,
      successMessage: "Website rule updated",
      operation: { payload in
        guard payload.websiteRoutingRules.contains(where: { $0.id == id }) else {
          throw RoutingMutationFailure.ruleMissing(
            "The website rule changed before its route could be updated."
          )
        }
        let rules = payload.websiteRoutingRules.map { rule in
          rule.id == id
            ? WebsiteRoutingRule(id: rule.id, domain: rule.domain, target: target) : rule
        }
        return self.replacingWebsiteRoutingRules(rules, in: payload)
      }
    )
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
      presentRoutingMutationFailure(
        error,
        kind: .application,
        profileID: selectedProfileID
      )
      return
    }
    enqueueApplicationRoutingMutation(
      profileID: selectedProfileID,
      successMessage: "Application rule saved"
    ) { payload in
      guard payload.applicationRoutingRules.count < 32 else {
        throw RoutingMutationFailure.ruleMissing(
          "A profile may contain at most 32 application rules."
        )
      }
      guard
        !payload.applicationRoutingRules.contains(where: {
          URL(fileURLWithPath: $0.executablePath).standardizedFileURL == resolved.executableURL
        })
      else {
        throw RoutingMutationFailure.ruleMissing(
          "This application already has a routing rule."
        )
      }
      let rules =
        payload.applicationRoutingRules + [
          ApplicationRoutingRule(
            displayName: resolved.displayName,
            bundlePath: resolved.bundleURL.path,
            executablePath: resolved.executableURL.path,
            target: .selectedProxy
          )
        ]
      return self.replacingApplicationRoutingRules(rules, in: payload)
    }
  }

  func replaceApplicationRoutingRule(_ id: UUID, from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    let resolved: ResolvedApplicationBundle
    do {
      resolved = try ApplicationBundleResolver.resolve(url)
    } catch {
      presentRoutingMutationFailure(
        error,
        kind: .application,
        profileID: selectedProfileID
      )
      return
    }
    enqueueApplicationRoutingMutation(
      profileID: selectedProfileID,
      successMessage: "Application rule updated"
    ) { payload in
      guard let current = payload.applicationRoutingRules.first(where: { $0.id == id })
      else {
        throw RoutingMutationFailure.ruleMissing(
          "The application rule changed before it could be updated."
        )
      }
      guard
        !payload.applicationRoutingRules.contains(where: {
          $0.id != id
            && URL(fileURLWithPath: $0.executablePath).standardizedFileURL == resolved.executableURL
        })
      else {
        throw RoutingMutationFailure.ruleMissing(
          "This application already has a routing rule."
        )
      }
      let rules = payload.applicationRoutingRules.map { rule in
        guard rule.id == id else { return rule }
        return ApplicationRoutingRule(
          id: rule.id,
          displayName: resolved.displayName,
          bundlePath: resolved.bundleURL.path,
          executablePath: resolved.executableURL.path,
          target: current.target
        )
      }
      return self.replacingApplicationRoutingRules(rules, in: payload)
    }
  }

  func removeApplicationRoutingRule(_ id: UUID) {
    enqueueApplicationRoutingMutation(
      profileID: selectedProfileID,
      successMessage: "Application rule removed"
    ) { payload in
      guard payload.applicationRoutingRules.contains(where: { $0.id == id }) else {
        throw RoutingMutationFailure.ruleMissing(
          "The application rule changed before it could be removed."
        )
      }
      return self.replacingApplicationRoutingRules(
        payload.applicationRoutingRules.filter { $0.id != id },
        in: payload
      )
    }
  }

  func setApplicationRoutingTarget(_ id: UUID, target: ApplicationRoutingTarget) {
    enqueueApplicationRoutingMutation(
      profileID: selectedProfileID,
      successMessage: "Application rule updated"
    ) { payload in
      guard payload.applicationRoutingRules.contains(where: { $0.id == id }) else {
        throw RoutingMutationFailure.ruleMissing(
          "The application rule changed before its route could be updated."
        )
      }
      let rules = payload.applicationRoutingRules.map { rule in
        guard rule.id == id else { return rule }
        return ApplicationRoutingRule(
          id: rule.id,
          displayName: rule.displayName,
          bundlePath: rule.bundlePath,
          executablePath: rule.executablePath,
          target: target
        )
      }
      return self.replacingApplicationRoutingRules(rules, in: payload)
    }
  }

  // Routing actions enqueue transformations rather than prebuilt rule arrays.
  // Each queued action is rebased on the profile state immediately before it.

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
      guard ruleSetTags.count <= 8, currentHelperIsReady, coreRunning,
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
      coreState: observedCoreState,
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
      recentErrors: recentErrors.map { entry in
        entry.repeatCount == 1
          ? entry.message : "\(entry.message) (repeated \(entry.repeatCount) times)"
      },
      redactionSecrets: DiagnosticSecrets.collect(from: profiles)
    )
  }

  var diagnosticReport: String { supportSnapshot.text }

  func clearRecentErrors() {
    recentErrors.removeAll(keepingCapacity: true)
  }

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
      observedCoreState = .unknown
      return
    }
    guard !helperSetupInProgress, !refreshInProgress else { return }

    refreshGeneration += 1
    let generation = refreshGeneration
    let runtimeGeneration = runtimeApplyCoordinator.currentGeneration
    let errorBasis = lastError
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
        guard response.protocolVersion == HelperConstants.protocolVersion,
          response.helperVersion == HelperConstants.helperVersion,
          response.helperRevision == HelperConstants.helperRevision
        else {
          helperStatus = "Helper update required"
          helperReachable = false
          observedCoreState = .unknown
          lastError = AppModelFailure.helperRevisionMismatch.localizedDescription
          return
        }
        let runtimeCurrent = runtimeGeneration == runtimeApplyCoordinator.currentGeneration
        apply(
          response,
          policy: .observation(
            runtimeCurrent: runtimeCurrent,
            adoptDesiredRuntime: runtimeCurrent && runtimeGeneration == 0
          )
        )
        helperReachable = true
        if lastError == errorBasis {
          lastError = response.success ? nil : response.message
        }
        connectAutomaticallyIfNeeded()
      } catch {
        guard refreshGeneration == generation, !helperSetupInProgress else { return }
        helperStatus = "Helper unavailable"
        helperReachable = false
        if runtimeGeneration == runtimeApplyCoordinator.currentGeneration {
          observedCoreState = .unknown
        }
        if lastError == errorBasis { lastError = error.localizedDescription }
      }
    }
  }

  func refreshExternalState() {
    refresh()
    refreshAllProfiles(userInitiated: true)
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
        apply(
          response,
          policy: .observation(
            runtimeCurrent: true,
            adoptDesiredRuntime: runtimeApplyCoordinator.currentGeneration == 0
          )
        )
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
        observedCoreState = .unknown
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
    observedCoreState = .unknown
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
            current.protocolVersion == HelperConstants.protocolVersion,
            current.helperVersion == HelperConstants.helperVersion,
            current.helperRevision == HelperConstants.helperRevision
          {
            apply(
              current,
              policy: .observation(
                runtimeCurrent: true,
                adoptDesiredRuntime: runtimeApplyCoordinator.currentGeneration == 0
              )
            )
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
        apply(
          response,
          policy: .observation(
            runtimeCurrent: true,
            adoptDesiredRuntime: runtimeApplyCoordinator.currentGeneration == 0
          )
        )
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
        observedCoreState = .unknown
        lastError = "Background helper repair failed: \(error.localizedDescription)"
        refreshRegistrationStatus()
      }
    }
  }

  func openBackgroundItems() {
    helperService.openSystemSettings()
  }

  func setCoreEnabled(_ enabled: Bool) {
    guard deferredRuntimeApplyPhase != .reconnecting else { return }
    guard desiredCoreRunning != enabled || !runtimeApplyCoordinator.isApplying else { return }
    desiredCoreRunning = enabled
    didAttemptAutomaticConnection = true
    if !enabled {
      profileRefreshTask?.cancel()
      cancelLatencyOperation()
    }
    guard helperEnabled else {
      lastError = "Enable the background helper before connecting."
      return
    }
    guard currentHelperIsReady else {
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

  func reconnectToApply() {
    guard deferredRuntimeApplyPending,
      deferredRuntimeApplyPhase != .reconnecting,
      observedCoreState != .unknown
    else { return }
    guard currentHelperIsReady else {
      deferredRuntimeApplyPhase = .failed
      deferredRuntimeApplyError = setSettingsError(
        "Reconnect to Apply is unavailable",
        error: AppModelFailure.helperNotReady
      )
      return
    }

    deferredRuntimeApplyPhase = .reconnecting
    deferredRuntimeApplyError = nil
    didAttemptAutomaticConnection = true
    let wasRunning = observedCoreState == .running
    desiredCoreRunning = wasRunning || desiredCoreRunning == true
    if wasRunning {
      desiredCoreRunning = false
      submitRuntimeApply(
        HelperRequest(action: .stop),
        onCurrentResult: { [weak self] result in
          guard let self else { return }
          switch result {
          case .success(let response) where response.success && !response.coreRunning:
            self.desiredCoreRunning = true
            self.startLatestDeferredRuntime()
          case .success(let response):
            self.finishDeferredRuntimeReconnectFailure(
              "Reconnect to Apply could not confirm that the VPN stopped: \(response.message)"
            )
          case .failure(let error):
            self.finishDeferredRuntimeReconnectFailure(
              "Reconnect to Apply could not stop the VPN",
              error: error
            )
          }
        },
        onSuperseded: { [weak self] in
          self?.finishDeferredRuntimeReconnectFailure(
            "Reconnect to Apply was superseded by another runtime change."
          )
        }
      )
    } else {
      desiredCoreRunning = true
      startLatestDeferredRuntime()
    }
  }

  private func startLatestDeferredRuntime() {
    guard deferredRuntimeApplyPhase == .reconnecting else { return }
    guard let payload = selectedProfile?.payload else {
      finishDeferredRuntimeReconnectFailure(
        "Reconnect to Apply could not start because the selected profile is unavailable."
      )
      return
    }
    submitRuntimeApply(
      makeStartRequest(profile: payload, profileID: selectedProfileID),
      onCurrentResult: { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let response)
        where response.success && response.coreRunning
          && response.runtimeOutcome == .applied:
          self.confirmDeferredRuntimeReconnect()
        case .success(let response):
          self.finishDeferredRuntimeReconnectFailure(
            "Reconnect to Apply could not activate the saved configuration: \(response.message)"
          )
        case .failure(let error):
          self.finishDeferredRuntimeReconnectFailure(
            "Reconnect to Apply failed; the VPN remains disconnected",
            error: error
          )
        }
      },
      onSuperseded: { [weak self] in
        self?.finishDeferredRuntimeReconnectFailure(
          "Reconnect to Apply was superseded by another runtime change."
        )
      },
      visibleProfileID: selectedProfileID
    )
  }

  private func confirmDeferredRuntimeReconnect() {
    let generation = runtimeApplyCoordinator.currentGeneration
    Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await runtimeStateReader()
        guard generation == self.runtimeApplyCoordinator.currentGeneration else { return }
        guard response.protocolVersion == HelperConstants.protocolVersion,
          response.helperVersion == HelperConstants.helperVersion,
          response.helperRevision == HelperConstants.helperRevision
        else {
          self.finishDeferredRuntimeReconnectFailure(
            "Reconnect to Apply completed, but helper status is from an older helper."
          )
          return
        }
        self.apply(response, policy: .observation(runtimeCurrent: true, adoptDesiredRuntime: false))
        guard response.success,
          response.coreRunning,
          response.runtimeOutcome == .applied,
          response.activeProfileID == self.selectedProfileID
        else {
          self.finishDeferredRuntimeReconnectFailure(
            "Reconnect to Apply completed, but authoritative helper status did not confirm the saved configuration."
          )
          return
        }
        self.deferredRuntimeApplyPending = false
        self.deferredRuntimeApplyPhase = .idle
        self.deferredRuntimeApplyError = nil
        self.clearDeferredRuntimePendingPresentations()
        self.desiredCoreRunning = true
        self.runtimeApplyStatus = .active
        self.runtimeFailurePreservedPrevious = false
        self.runtimeFailureProfileID = nil
        self.lastError = nil
      } catch {
        self.finishDeferredRuntimeReconnectFailure(
          "Reconnect to Apply completed, but authoritative helper status could not be read",
          error: error
        )
      }
    }
  }

  private func finishDeferredRuntimeReconnectFailure(
    _ prefix: String,
    error: (any Error)? = nil
  ) {
    deferredRuntimeApplyPhase = .failed
    let message: String
    if let error {
      message = boundedSettingsError(prefix, error: error)
      lastError = message
    } else {
      message = prefix
      lastError = message
    }
    deferredRuntimeApplyError = message
    deferredRuntimeApplyPending = true
    runtimeApplyStatus = .reconnectRequired
    desiredCoreRunning = observedCoreState == .running ? true : false
  }

  func disconnectBeforeQuit() async -> Bool {
    if coreIsKnownStopped {
      subscriptionRefreshTask?.cancel()
      helperRepairTask?.cancel()
      helperApprovalPollTask?.cancel()
      return true
    }
    desiredCoreRunning = false
    didAttemptAutomaticConnection = true
    profileRefreshTask?.cancel()
    cancelLatencyOperation()

    let result = await withCheckedContinuation { continuation in
      submitRuntimeApply(
        HelperRequest(action: .shutdown),
        onCurrentResult: { continuation.resume(returning: $0) },
        onSuperseded: {
          continuation.resume(
            returning: .failure(AppModelFailure.runtimeMutationSuperseded)
          )
        }
      )
    }
    switch result {
    case .success(let response) where response.success && !response.coreRunning:
      lastError = nil
      subscriptionRefreshTask?.cancel()
      helperRepairTask?.cancel()
      helperApprovalPollTask?.cancel()
      return true
    case .success(let response):
      lastError =
        "Unable to disconnect before quitting: "
        + AppModelFailure.coreStopFailed(response.message).localizedDescription
      return false
    case .failure(let error):
      lastError = "Unable to disconnect before quitting: \(error.localizedDescription)"
      return false
    }
  }

  func setRoutingMode(_ mode: RoutingMode) {
    routingMode = mode
    guard deferredRuntimeApplyPhase != .reconnecting else { return }
    guard desiredCoreRunning != false else {
      if !runtimeApplyCoordinator.isApplying {
        runtimeApplyCoordinator.markSaved()
        runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
      }
      return
    }
    if runtimeApplyCoordinator.isApplying {
      applyCurrentDesiredRuntimeIfNeeded()
    } else {
      submitRuntimeApply(HelperRequest(action: .setMode, mode: mode))
    }
  }

  func setSelectedNode(_ node: ProxyNodeID) {
    selectedNodeID = node
    guard deferredRuntimeApplyPhase != .reconnecting else { return }
    guard desiredCoreRunning != false else {
      if !runtimeApplyCoordinator.isApplying {
        runtimeApplyCoordinator.markSaved()
        runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
      }
      return
    }
    if coreRunning, helperActiveProfileID != selectedProfileID {
      deferredRuntimeApplyPending = true
      deferredRuntimeApplyPhase = .pending
      deferredRuntimeApplyError = nil
      if !runtimeApplyCoordinator.isApplying {
        runtimeApplyCoordinator.markSaved()
        runtimeApplyStatus = .reconnectRequired
      }
      return
    }
    if runtimeApplyCoordinator.isApplying {
      applyCurrentDesiredRuntimeIfNeeded()
    } else {
      submitRuntimeApply(HelperRequest(action: .setNode, node: node))
    }
  }

  func testLatency() {
    guard currentHelperIsReady else {
      lastError = "Update or repair the background helper before testing latency."
      return
    }
    guard coreRunning else {
      lastError = "Connect the VPN before testing latency."
      return
    }
    guard helperActiveProfileID == selectedProfileID else {
      lastError = "Disconnect and reconnect before testing latency for the selected profile."
      return
    }
    guard latencyOperationTask == nil else { return }
    lastLatencyTestAt = Date()
    latencyTestInProgress = true
    latencyOperationGeneration &+= 1
    let generation = latencyOperationGeneration
    let profileID = selectedProfileID
    let activeProfileID = helperActiveProfileID
    let runtimeGeneration = runtimeApplyCoordinator.currentGeneration
    let requestedNodes = nodes.map(\.id)
    latencyOperationTask = Task {
      defer {
        if generation == latencyOperationGeneration {
          latencyTestInProgress = false
          latencyOperationTask = nil
          scheduleNextLatencyRefresh()
        }
      }
      do {
        var completed = true
        var measured: [Int] = []
        for node in requestedNodes {
          try Task.checkCancellation()
          let response = try await latencySender(node)
          try Task.checkCancellation()
          guard generation == latencyOperationGeneration,
            selectedProfileID == profileID,
            helperActiveProfileID == activeProfileID,
            runtimeApplyCoordinator.currentGeneration == runtimeGeneration
          else { return }
          guard response.protocolVersion == HelperConstants.protocolVersion,
            response.helperVersion == HelperConstants.helperVersion,
            response.helperRevision == HelperConstants.helperRevision
          else {
            throw AppModelFailure.helperRevisionMismatch
          }
          apply(
            response,
            policy: .observation(runtimeCurrent: true, adoptDesiredRuntime: false)
          )
          for delay in response.delays where delay.node == node {
            if let index = nodes.firstIndex(where: { $0.id == delay.node }) {
              nodes[index].delay = delay.milliseconds
            }
            if let milliseconds = delay.milliseconds {
              measured.append(milliseconds)
            }
          }
          completed = completed && response.success
        }
        if let autoIndex = nodes.firstIndex(where: { $0.id == .auto }),
          nodes[autoIndex].delay == nil
        {
          nodes[autoIndex].delay = measured.min()
        }
        latencyTestCompleted = completed
        if completed { lastError = nil }
      } catch is CancellationError {
        return
      } catch {
        guard generation == latencyOperationGeneration else { return }
        helperReachable = false
        observedCoreState = .unknown
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
    latencyIntervalMinutesDraft = value
  }

  @discardableResult
  func applyLatencyTestURL() -> Bool {
    applyLatencySettings()
  }

  @discardableResult
  func applyLatencySettings() -> Bool {
    guard latencySettingsValid else {
      let message = "Choose a positive interval and a valid HTTPS target."
      latencySettingsIssue = .validation(message)
      lastError = message
      return false
    }
    let normalized: String
    do {
      normalized = try LatencyTargetPolicy.normalized(latencyTestURLDraft)
      try persistProfileLibrary(
        latencyIntervalMinutes: latencyIntervalMinutesDraft,
        latencyTestURL: normalized
      )
    } catch {
      let message = setSettingsError(
        "Latency settings were not saved",
        error: error,
        additionalSecrets: [latencyTestURLDraft]
      )
      latencySettingsIssue = .persistence(message)
      return false
    }

    latencyIntervalMinutes = latencyIntervalMinutesDraft
    latencyTestURL = normalized
    latencyTestURLDraft = normalized
    latencyIntervalMinutesDraft = latencyIntervalMinutes
    latencySettingsIssue = nil
    lastError = nil
    scheduleNextLatencyRefresh()
    if currentHelperIsReady {
      synchronizeLatencyTarget(normalized)
    } else {
      let message = "Saved locally; background helper synchronization is pending."
      latencySettingsIssue = .runtimeSynchronization(message)
      lastError = message
    }
    return true
  }

  func retryLatencySynchronization() {
    guard canRetryLatencySynchronization else { return }
    guard currentHelperIsReady else {
      let message = "Background helper is not ready; retry after it is enabled."
      latencySettingsIssue = .runtimeSynchronization(message)
      lastError = message
      return
    }
    synchronizeLatencyTarget(latencyTestURL)
  }

  func resetLatencySettings() {
    latencyIntervalMinutesDraft = 10
    latencyTestURLDraft = LatencyTargetPolicy.defaultURL
  }

  func resetLatencyTestURL() {
    latencyTestURLDraft = LatencyTargetPolicy.defaultURL
  }

  @discardableResult
  func applyLocalSOCKSSettings() -> Bool {
    guard localSOCKSSettingsValid else {
      let message = "Choose a local SOCKS5 port from 1024 to 65535, except 19090."
      localSOCKSIssue = .validation(message)
      lastError = message
      return false
    }
    do {
      try persistProfileLibrary(
        localSOCKSEnabled: localSOCKSEnabledDraft,
        localSOCKSPort: localSOCKSPortDraft
      )
    } catch {
      let message = setSettingsError(
        "Local SOCKS5 settings were not saved",
        error: error
      )
      localSOCKSIssue = .persistence(message)
      return false
    }
    localSOCKSEnabled = localSOCKSEnabledDraft
    localSOCKSPort = localSOCKSPortDraft
    localSOCKSIssue = nil
    guard shouldApplyDesiredRuntime else {
      lastError = nil
      return true
    }
    localSOCKSApplyInProgress = true
    applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
      guard let self else { return }
      self.localSOCKSApplyInProgress = false
      if case .failure(let error) = result {
        let message = self.setSettingsError(
          "Local SOCKS5 runtime synchronization failed",
          error: error
        )
        self.localSOCKSIssue = .runtimeSynchronization(message)
      } else {
        self.localSOCKSIssue = nil
      }
    }
    return true
  }

  func retryLocalSOCKSSynchronization() {
    guard canRetryLocalSOCKSSynchronization else { return }
    localSOCKSApplyInProgress = true
    applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
      guard let self else { return }
      self.localSOCKSApplyInProgress = false
      if case .failure(let error) = result {
        let message = self.setSettingsError(
          "Local SOCKS5 runtime synchronization failed",
          error: error
        )
        self.localSOCKSIssue = .runtimeSynchronization(message)
      } else {
        self.localSOCKSIssue = nil
      }
    }
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
    guard let validatedName = try? SubscriptionClient.validateDisplayName(name) else {
      profileNameError = "Profile name is empty or invalid."
      lastError = profileNameError
      return
    }
    guard validatedName != profiles[index].name else { return }
    var candidateProfiles = profiles
    candidateProfiles[index].name = validatedName
    do {
      try persistProfileLibrary(profiles: candidateProfiles)
      profiles = candidateProfiles
      profileName = validatedName
      setSubscriptionStatus("Profile name saved", level: .success)
      profileNameError = nil
      lastError = nil
    } catch {
      profileNameError = setSettingsError("Profile name was not saved", error: error)
    }
  }

  func addSource() {
    guard canManageSources, let selectedProfileID,
      let profileIndex = profiles.firstIndex(where: { $0.id == selectedProfileID })
    else { return }
    let source = ManagedSource(name: "Subscription \(profiles[profileIndex].sources.count + 1)")
    let previousSelection = selectedSourceID
    profiles[profileIndex].sources.append(source)
    selectedSourceID = source.id
    loadSelectedSourceEditor()
    setSubscriptionStatus("Enter a subscription URL or connection link")
    do {
      try persistProfileLibrary()
      lastError = nil
    } catch {
      if let sourceIndex = profiles[profileIndex].sources.firstIndex(where: {
        $0.id == source.id
      }) {
        profiles[profileIndex].sources.remove(at: sourceIndex)
      }
      selectedSourceID = previousSelection
      loadSelectedSourceEditor()
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

  func importNativeProfile(from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    let name = url.deletingPathExtension().lastPathComponent
    let result = Result { try Data(contentsOf: url, options: [.mappedIfSafe]) }
    beginSyncingOperation()
    Task {
      defer { endSyncingOperation() }
      do {
        let native = try NativeProfileParser.parse(result.get())
        let payload = CoreProfile.native(native)
        try await validateProfile(payload)
        let imported = ManagedProfile(
          name: name,
          payload: payload,
          updatedAt: Date()
        )
        let previousSelection = selectedProfileID
        profiles.append(imported)
        selectedProfileID = imported.id
        loadSelectedProfileEditor()
        updateNodes()
        profileAvailable = true
        setSubscriptionStatus("Imported JSON profile", level: .success)
        do {
          try persistProfileLibrary()
        } catch {
          if let index = profiles.firstIndex(where: { $0.id == imported.id }) {
            profiles.remove(at: index)
          }
          if selectedProfileID == imported.id {
            selectedProfileID = previousSelection
          }
          loadSelectedProfileEditor()
          updateNodes()
          profileAvailable = selectedProfile?.payload != nil
          throw error
        }
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
      profiles[initialIndex].payload != nil
    else {
      lastError = "Sync a Reality + Hysteria2 subscription before importing routing."
      return
    }
    let result = Result { try Data(contentsOf: url, options: [.mappedIfSafe]) }
    beginSyncingOperation()
    Task {
      do {
        let policy = try RoutingPolicyParser.parse(result.get())
        enqueueRoutingMutation(
          profileID: selectedProfileID,
          kind: .policy,
          successMessage: "Routing policy saved",
          operation: { payload in
            guard case .compatibility(let current) = payload else {
              throw RoutingMutationFailure.profileChanged(
                "The profile changed while the routing policy was being prepared. Try again."
              )
            }
            return .compatibility(
              VPNProfile(
                connections: current.connections,
                routingPolicy: policy,
                nodeGroups: current.nodeGroups ?? [],
                applicationRoutingRules: current.applicationRoutingRules,
                websiteRoutingRules: current.websiteRoutingRules
              )
            )
          },
          onFinished: { [weak self] in self?.endSyncingOperation() }
        )
      } catch {
        endSyncingOperation()
        presentRoutingMutationFailure(error, kind: .policy, profileID: selectedProfileID)
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
        applicationRoutingRules: current.applicationRoutingRules,
        websiteRoutingRules: current.websiteRoutingRules
      )
    )
    let previousProfile = profiles[index]
    var committedProfile = previousProfile
    committedProfile.payload = updated
    profiles[index] = committedProfile
    do {
      try persistProfileLibrary()
    } catch {
      if profiles[index] == committedProfile { profiles[index] = previousProfile }
      lastError = error.localizedDescription
      return
    }
    if shouldApplyDesiredRuntime(for: selectedProfileID) {
      setSubscriptionStatus("Routing policy removal applying", level: .neutral)
      submitRuntimeApply(
        makeStartRequest(profile: updated, profileID: selectedProfileID),
        onCurrentResult: { [weak self] result in
          guard let self else { return }
          switch result {
          case .success(let response) where response.runtimeOutcome == .reconnectRequired:
            self.setSubscriptionStatus("Routing policy removed and saved", level: .success)
          case .success:
            self.setSubscriptionStatus("Routing policy removed and active", level: .success)
          case .failure(let error):
            self.rollbackProfileUpdate(
              profileID: selectedProfileID,
              committed: committedProfile,
              previous: previousProfile,
              originalError: error,
              visibleProfileID: selectedProfileID
            )
            if self.selectedProfileID == selectedProfileID { self.updateNodes() }
            self.setSubscriptionStatus("Routing policy removal failed", level: .warning)
          }
        },
        visibleProfileID: selectedProfileID
      )
    } else {
      runtimeApplyCoordinator.markSaved()
      if !runtimeApplyCoordinator.isApplying {
        runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
      }
      setSubscriptionStatus("Routing policy removed and saved", level: .success)
    }
    lastError = nil
  }

  func addProfile() {
    let previousProfiles = profiles
    let previousSelection = selectedProfileID
    let previousProfileAvailable = profileAvailable
    let previousStatus = subscriptionStatus
    let previousStatusLevel = subscriptionStatusLevel
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
    do {
      try persistProfileLibrary()
      lastError = nil
    } catch {
      profiles = previousProfiles
      selectedProfileID = previousSelection
      profileAvailable = previousProfileAvailable
      loadSelectedProfileEditor()
      updateNodes()
      setSubscriptionStatus(previousStatus, level: previousStatusLevel)
      lastError = error.localizedDescription
    }
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
    let committedProfiles = profiles
    let committedSelection = self.selectedProfileID
    guard shouldApplyDesiredRuntime else {
      runtimeApplyCoordinator.markSaved()
      runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
      return
    }
    applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
      guard let self, case .failure(let error) = result else { return }
      guard self.profiles == committedProfiles,
        self.selectedProfileID == committedSelection
      else {
        self.lastError = error.localizedDescription
        return
      }
      self.profiles = previousProfiles
      self.selectedProfileID = previousSelection
      self.loadSelectedProfileEditor()
      self.updateNodes()
      do {
        try self.persistProfileLibrary()
        self.lastError = error.localizedDescription
      } catch let persistenceError {
        self.profiles = committedProfiles
        self.selectedProfileID = committedSelection
        self.loadSelectedProfileEditor()
        self.updateNodes()
        self.lastError =
          "\(error.localizedDescription) Rollback could not be saved: "
          + persistenceError.localizedDescription
      }
    }
  }

  func selectProfile(_ id: UUID) {
    guard id != selectedProfileID, profiles.contains(where: { $0.id == id }) else { return }
    let previousSelection = selectedProfileID
    selectedProfileID = id
    websiteRoutingInput = ""
    websiteRoutingEditingRuleID = nil
    loadSelectedProfileEditor()
    updateNodes()
    profileAvailable = selectedProfile?.payload != nil
    setSubscriptionStatus(
      profileAvailable ? "Ready" : "Not synced",
      level: profileAvailable ? .success : .neutral
    )
    do {
      try persistProfileLibrary()
      lastError = nil
    } catch {
      selectedProfileID = previousSelection
      loadSelectedProfileEditor()
      updateNodes()
      lastError = error.localizedDescription
      return
    }

    if shouldApplyDesiredRuntime {
      applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
        guard let self, case .failure(let error) = result else { return }
        guard self.selectedProfileID == id else {
          self.lastError = error.localizedDescription
          return
        }
        self.selectedProfileID = previousSelection
        self.loadSelectedProfileEditor()
        self.updateNodes()
        do {
          try self.persistProfileLibrary()
          self.lastError = error.localizedDescription
        } catch let persistenceError {
          self.selectedProfileID = id
          self.loadSelectedProfileEditor()
          self.updateNodes()
          self.lastError =
            "\(error.localizedDescription) Rollback could not be saved: "
            + persistenceError.localizedDescription
        }
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
    sourceEditorError = nil
    let value: String
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
      sourceEditorError = "Add a subscription source first."
      lastError = sourceEditorError
      return
    }
    if case .native = profiles[profileIndex].payload {
      sourceEditorError = boundedSettingsError(
        "Save and Sync is unavailable",
        error: SubscriptionFailure.nativeProfileCannotBeMerged
      )
      lastError = sourceEditorError
      return
    }
    do {
      value = try SubscriptionClient.validateSourceValue(subscriptionURL)
      try SubscriptionClient.validate(headers: headers)
      let effectiveName = try SubscriptionClient.validateDisplayName(
        name.isEmpty ? "Subscription" : name
      )
      let excludeRegex = try SourceNameFilter.normalized(sourceExcludeRegex)
      var candidateProfiles = profiles
      candidateProfiles[profileIndex].sources[sourceIndex].name = effectiveName
      candidateProfiles[profileIndex].sources[sourceIndex].value = value
      candidateProfiles[profileIndex].sources[sourceIndex].headers = headers
      candidateProfiles[profileIndex].sources[sourceIndex].excludeRegex = excludeRegex
      try persistProfileLibrary(profiles: candidateProfiles)
      profiles = candidateProfiles
    } catch {
      sourceEditorError = setSettingsError(
        "Save and Sync did not save the source",
        error: error,
        additionalSecrets: [subscriptionURL, subscriptionHWID]
      )
      return
    }
    sourceEditorError = nil
    guard !value.isEmpty else {
      setSubscriptionStatus(
        profiles[profileIndex].payload == nil ? "Enter a source" : "Saved",
        level: profiles[profileIndex].payload == nil ? .neutral : .success
      )
      return
    }
    beginSyncingOperation()
    setSubscriptionStatus("Syncing…")
    let sourceToSync = profiles[profileIndex].sources[sourceIndex]
    Task {
      defer { endSyncingOperation() }
      do {
        let result = try await subscriptionManager.synchronize(sourceToSync)
        let fetched = ManagedConnectionReconciler.reconcile(
          existing: sourceToSync.payload,
          fetched: result.profile
        )
        guard case .compatibility = fetched else {
          throw SubscriptionFailure.nativeProfileCannotBeMerged
        }
        guard let currentProfile = profiles.first(where: { $0.id == targetProfileID }),
          let currentSourceIndex = currentProfile.sources.firstIndex(where: {
            $0.id == targetSourceID
          }),
          currentProfile.sources[currentSourceIndex] == sourceToSync
        else { throw AppModelFailure.staleProfileOperation }
        var updatedProfile = currentProfile
        updatedProfile.sources[currentSourceIndex].payload = fetched
        updatedProfile.sources[currentSourceIndex].updatedAt = Date()
        updatedProfile = try rebuiltCompatibilityProfile(updatedProfile)
        guard let effective = updatedProfile.payload else {
          throw SubscriptionFailure.missingProtocols
        }
        try await validateProfile(effective)
        guard try commitProfileUpdate(expected: currentProfile, updated: updatedProfile) else {
          throw AppModelFailure.staleProfileOperation
        }
        if self.selectedProfileID == targetProfileID,
          shouldApplyDesiredRuntime,
          ManagedConnectionReconciler.requiresActivation(
            previous: currentProfile.payload,
            next: effective
          )
        {
          setSubscriptionStatus("Sources updated; applying", level: .neutral)
          applyCurrentDesiredRuntimeIfNeeded { [weak self] applyResult in
            guard let self else { return }
            switch applyResult {
            case .success(let response) where response.runtimeOutcome == .reconnectRequired:
              if let warning = result.warningDescription {
                self.setSubscriptionStatus(warning, level: .warning)
              } else {
                self.setSubscriptionStatus("Sources updated and saved", level: .success)
              }
            case .success:
              if let warning = result.warningDescription {
                self.setSubscriptionStatus(warning, level: .warning)
              } else {
                self.setSubscriptionStatus("Sources updated and active", level: .success)
              }
            case .failure(let error):
              self.rollbackProfileUpdate(
                profileID: targetProfileID,
                committed: updatedProfile,
                previous: currentProfile,
                originalError: error
              )
              self.loadSelectedProfileEditor()
              self.updateNodes()
              self.profileAvailable = self.selectedProfile?.payload != nil
              self.setSubscriptionStatus("Source apply failed", level: .warning)
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
        loadSelectedProfileEditor()
        updateNodes()
        profileAvailable = selectedProfile?.payload != nil
        setSubscriptionStatus(
          profileAvailable ? "Using cached sources; sync failed" : "Sync failed",
          level: .warning
        )
        sourceEditorError = setSettingsError(
          "Save and Sync failed",
          error: error,
          additionalSecrets: [subscriptionURL, subscriptionHWID, value]
        )
      }
    }
  }

  private func rebuiltCompatibilityProfile(_ profile: ManagedProfile) throws -> ManagedProfile {
    var updated = profile
    let routingPolicy: RoutingPolicy?
    let applicationRules: [ApplicationRoutingRule]
    let websiteRules: [WebsiteRoutingRule]
    if case .compatibility(let current) = profile.payload {
      routingPolicy = current.routingPolicy
      applicationRules = current.applicationRoutingRules
      websiteRules = current.websiteRoutingRules
    } else {
      routingPolicy = nil
      applicationRules = []
      websiteRules = []
    }
    guard profile.sources.contains(where: { $0.payload != nil }) else {
      updated.payload = nil
      updated.updatedAt = nil
      return updated
    }
    let merged = try ProfileAggregator.merge(
      sources: profile.sources,
      routingPolicy: routingPolicy,
      applicationRoutingRules: applicationRules,
      websiteRoutingRules: websiteRules
    )
    updated.payload = ManagedConnectionReconciler.reconcile(
      existing: profile.payload,
      fetched: merged
    )
    updated.updatedAt = Date()
    return updated
  }

  @discardableResult
  private func commitProfileUpdate(
    expected: ManagedProfile,
    updated: ManagedProfile
  ) throws -> Bool {
    guard let index = profiles.firstIndex(where: { $0.id == expected.id }),
      profiles[index] == expected
    else { return false }
    profiles[index] = updated
    do {
      try persistProfileLibrary()
      return true
    } catch {
      if let rollbackIndex = profiles.firstIndex(where: { $0.id == expected.id }),
        profiles[rollbackIndex] == updated
      {
        profiles[rollbackIndex] = expected
      }
      throw error
    }
  }

  private func rollbackProfileUpdate(
    profileID: UUID,
    committed: ManagedProfile,
    previous: ManagedProfile,
    originalError: any Error,
    visibleProfileID: UUID? = nil
  ) {
    func present(_ message: String) {
      guard visibleProfileID == nil || selectedProfileID == visibleProfileID else { return }
      lastError = message
    }
    guard let index = profiles.firstIndex(where: { $0.id == profileID }),
      profiles[index] == committed
    else {
      present(originalError.localizedDescription)
      return
    }
    profiles[index] = previous
    do {
      try persistProfileLibrary()
      present(originalError.localizedDescription)
    } catch {
      // The committed version was already saved successfully. If saving the
      // corrective rollback fails, retain that proven durable version in
      // memory instead of presenting an unsaved rollback as successful.
      if let restoreIndex = profiles.firstIndex(where: { $0.id == profileID }),
        profiles[restoreIndex] == previous
      {
        profiles[restoreIndex] = committed
      }
      present(
        "\(originalError.localizedDescription) Rollback could not be saved: "
          + error.localizedDescription
      )
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
    guard response.protocolVersion == HelperConstants.protocolVersion,
      response.helperVersion == HelperConstants.helperVersion,
      response.helperRevision == HelperConstants.helperRevision
    else {
      throw AppModelFailure.helperRevisionMismatch
    }
    guard response.success else {
      throw AppModelFailure.profileValidationFailed(response.message)
    }
  }

  private func refreshAllProfiles(userInitiated: Bool = false) {
    if userInitiated { refreshRequestedByUser = true }
    guard currentHelperIsReady else {
      if userInitiated {
        refreshRequestedByUser = false
        setSubscriptionStatus("Refresh requires the background helper", level: .warning)
      }
      return
    }
    if profileRefreshTask != nil {
      if userInitiated {
        setSubscriptionStatus("Refresh already in progress", level: .neutral)
      }
      return
    }
    let sources = profiles.flatMap { profile in
      profile.sources.compactMap { source in
        SubscriptionClient.isRemoteSource(source.value) ? (profile.id, source) : nil
      }
    }
    guard !sources.isEmpty else {
      if userInitiated {
        refreshRequestedByUser = false
        setSubscriptionStatus("Refresh complete: no remote sources", level: .success)
      }
      return
    }

    beginSyncingOperation()
    let refreshBefore = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    profileRefreshTask = Task { [weak self] in
      guard let self else { return }
      defer {
        endSyncingOperation()
        profileRefreshTask = nil
        refreshRequestedByUser = false
      }
      var refreshed = 0
      var unchanged = 0
      var failed = 0
      var firstFailure: Error?
      var refreshSnapshots: [UUID: RefreshActivationSnapshot] = [:]

      for (profileID, sourceSnapshot) in sources {
        do {
          try Task.checkCancellation()
          guard let fetchProfile = profiles.first(where: { $0.id == profileID }),
            let fetchSource = fetchProfile.sources.first(where: { $0.id == sourceSnapshot.id }),
            sourceFetchBasis(fetchSource) == sourceFetchBasis(sourceSnapshot)
          else {
            continue
          }
          let result = try await subscriptionManager.synchronize(sourceSnapshot)
          try Task.checkCancellation()
          let fetched = ManagedConnectionReconciler.reconcile(
            existing: sourceSnapshot.payload,
            fetched: result.profile
          )
          guard case .compatibility = fetched else {
            throw SubscriptionFailure.nativeProfileCannotBeMerged
          }
          guard let currentProfile = profiles.first(where: { $0.id == profileID }),
            let sourceIndex = currentProfile.sources.firstIndex(where: {
              $0.id == sourceSnapshot.id
            }),
            currentProfile.sources[sourceIndex] == sourceSnapshot
          else { throw AppModelFailure.staleProfileOperation }

          var updatedProfile = currentProfile
          let sourceChanged = sourceSnapshot.payload != fetched
          updatedProfile.sources[sourceIndex].payload = fetched
          updatedProfile.sources[sourceIndex].updatedAt = Date()
          updatedProfile = try rebuiltCompatibilityProfile(updatedProfile)
          guard let payload = updatedProfile.payload else {
            throw SubscriptionFailure.missingProtocols
          }
          try Task.checkCancellation()
          try await validateProfile(payload)
          try Task.checkCancellation()
          guard try commitProfileUpdate(expected: currentProfile, updated: updatedProfile) else {
            throw AppModelFailure.staleProfileOperation
          }
          if sourceChanged { refreshed += 1 } else { unchanged += 1 }
          if let before = refreshBefore[profileID] {
            if var snapshot = refreshSnapshots[profileID] {
              snapshot.after = updatedProfile
              refreshSnapshots[profileID] = snapshot
            } else {
              refreshSnapshots[profileID] = RefreshActivationSnapshot(
                before: before,
                after: updatedProfile
              )
            }
          }
        } catch is CancellationError {
          return
        } catch {
          failed += 1
          firstFailure = firstFailure ?? error
        }
      }

      let selectedProfileAtCompletion = selectedProfileID
      let selectedSnapshot = selectedProfileAtCompletion.flatMap {
        refreshSnapshots[$0]
      }
      let selectedCurrentProfile = selectedProfileAtCompletion.flatMap { profileID in
        profiles.first(where: { $0.id == profileID })
      }
      let selectedChanged: Bool
      if let selectedSnapshot, let selectedCurrentProfile,
        selectedCurrentProfile == selectedSnapshot.after
      {
        selectedChanged = ManagedConnectionReconciler.requiresActivation(
          previous: selectedSnapshot.before.payload,
          next: selectedCurrentProfile.payload
        )
      } else {
        selectedChanged = false
      }
      guard !Task.isCancelled else { return }
      let applying =
        selectedChanged
        && selectedProfileAtCompletion.flatMap { shouldApplyDesiredRuntime(for: $0) } == true
      let summary =
        "Refresh complete: \(refreshed) updated, \(unchanged) unchanged, \(failed) failed"
      if applying {
        setSubscriptionStatus("Refreshing current profile…", level: .neutral)
        let result: Result<HelperResponse, any Error>? = await withCheckedContinuation {
          continuation in
          guard let profileID = selectedProfileAtCompletion,
            let payload = selectedCurrentProfile?.payload
          else {
            continuation.resume(returning: nil)
            return
          }
          submitRuntimeApply(
            makeStartRequest(profile: payload, profileID: profileID),
            onCurrentResult: { result in continuation.resume(returning: result) },
            onSuperseded: { continuation.resume(returning: nil) },
            visibleProfileID: profileID
          )
        }
        switch result {
        case .success(let response)? where response.runtimeOutcome == .reconnectRequired:
          setSubscriptionStatus(summary, level: failed == 0 ? .success : .warning)
          lastError = firstFailure?.localizedDescription
        case .success?:
          setSubscriptionStatus(summary, level: failed == 0 ? .success : .warning)
          lastError = firstFailure?.localizedDescription
        case .failure(let error)?:
          loadSelectedProfileEditor()
          updateNodes()
          setSubscriptionStatus(
            runtimeFailurePreservedPrevious
              ? "Sources saved; apply failed — previous VPN remains active"
              : "Sources saved; apply failed",
            level: .warning
          )
          lastError = error.localizedDescription
        case nil:
          setSubscriptionStatus(
            "\(summary); newer connection change is applying",
            level: failed == 0 ? .neutral : .warning
          )
          lastError = firstFailure?.localizedDescription
        }
      } else {
        setSubscriptionStatus(summary, level: failed == 0 ? .success : .warning)
        lastError = firstFailure?.localizedDescription
      }
      updateNodes()
      connectAutomaticallyIfNeeded()
    }
  }

  private func sourceFetchBasis(_ source: ManagedSource) -> SourceFetchBasis {
    SourceFetchBasis(
      value: source.value,
      headers: source.headers,
      excludeRegex: source.excludeRegex
    )
  }

  private func loadSelectedProfileEditor() {
    profileNameError = nil
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
    localSOCKSEnabledDraft = stored.localSOCKSEnabled
    localSOCKSPortDraft = stored.localSOCKSPort
    latencyIntervalMinutes = stored.latencyIntervalMinutes
    latencyIntervalMinutesDraft = stored.latencyIntervalMinutes
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
    sourceEditorError = nil
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

  private func persistProfileLibrary(
    profiles: [ManagedProfile]? = nil,
    localSOCKSEnabled: Bool? = nil,
    localSOCKSPort: UInt16? = nil,
    latencyIntervalMinutes: Int? = nil,
    latencyTestURL: String? = nil
  ) throws {
    if let profileStoreLoadError {
      throw AppModelFailure.profileLibraryUnavailable(profileStoreLoadError)
    }
    try profileLibrarySaver(
      ProfileLibrary(
        profiles: profiles ?? self.profiles,
        selectedProfileID: selectedProfileID,
        localSOCKSEnabled: localSOCKSEnabled ?? self.localSOCKSEnabled,
        localSOCKSPort: localSOCKSPort ?? self.localSOCKSPort,
        latencyIntervalMinutes: latencyIntervalMinutes ?? self.latencyIntervalMinutes,
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
    let websiteRoutingRules: [WebsiteRoutingRule]
    if case .compatibility(let current) = previousPayload {
      policy = current.routingPolicy
      applicationRoutingRules = current.applicationRoutingRules
      websiteRoutingRules = current.websiteRoutingRules
    } else {
      policy = nil
      applicationRoutingRules = []
      websiteRoutingRules = []
    }
    guard profiles[profileIndex].sources.contains(where: { $0.payload != nil }) else {
      profiles[profileIndex].payload = nil
      profiles[profileIndex].updatedAt = nil
      return
    }
    let merged = try ProfileAggregator.merge(
      sources: profiles[profileIndex].sources,
      routingPolicy: policy,
      applicationRoutingRules: applicationRoutingRules,
      websiteRoutingRules: websiteRoutingRules
    )
    profiles[profileIndex].payload = ManagedConnectionReconciler.reconcile(
      existing: previousPayload,
      fetched: merged
    )
  }

  private func enqueueApplicationRoutingMutation(
    profileID: UUID?,
    successMessage: String,
    operation: @escaping @MainActor (CoreProfile) throws -> CoreProfile
  ) {
    enqueueRoutingMutation(
      profileID: profileID,
      kind: .application,
      successMessage: successMessage,
      operation: operation
    )
  }

  private func enqueueRoutingMutation(
    profileID: UUID?,
    kind: RoutingMutationKind,
    successMessage: String,
    operation: @escaping @MainActor (CoreProfile) throws -> CoreProfile,
    onSuccess: (@MainActor () -> Void)? = nil,
    onFinished: (@MainActor () -> Void)? = nil
  ) {
    guard let profileID,
      let profile = profiles.first(where: { $0.id == profileID }),
      profile.payload != nil
    else {
      let error = RoutingMutationFailure.profileChanged(
        "The selected profile cannot store routing rules."
      )
      presentRoutingMutationFailure(error, kind: kind, profileID: profileID)
      onFinished?()
      return
    }

    let revision = (routingMutationRevisions[profileID] ?? 0) &+ 1
    routingMutationRevisions[profileID] = revision
    let identity = RoutingMutationIdentity(profileID: profileID, revision: revision)
    routingMutationStatuses[profileID, default: [:]][kind] = RoutingMutationStatus(
      identity: identity,
      presentation: RoutingMutationPresentation(
        state: .applying,
        message: "Routing change applying…"
      )
    )

    let predecessor = routingMutationQueues[profileID]
    let queueToken = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      if let predecessor { await predecessor.value }
      await self.performRoutingMutation(
        identity: identity,
        kind: kind,
        successMessage: successMessage,
        operation: operation,
        onSuccess: onSuccess,
        onFinished: onFinished
      )
      self.finishRoutingMutationQueue(profileID: profileID, token: queueToken)
    }
    routingMutationQueues[profileID] = task
    routingMutationQueueTokens[profileID] = queueToken
  }

  private func performRoutingMutation(
    identity: RoutingMutationIdentity,
    kind: RoutingMutationKind,
    successMessage: String,
    operation: @escaping @MainActor (CoreProfile) throws -> CoreProfile,
    onSuccess: (@MainActor () -> Void)?,
    onFinished: (@MainActor () -> Void)?
  ) async {
    defer { onFinished?() }
    do {
      guard let currentProfile = profiles.first(where: { $0.id == identity.profileID }),
        let basePayload = currentProfile.payload
      else {
        throw RoutingMutationFailure.profileChanged(
          "The profile was removed while the routing change was pending."
        )
      }
      let updated = try operation(basePayload)
      try await validateProfile(updated)
      guard let latestProfile = profiles.first(where: { $0.id == identity.profileID }),
        latestProfile.payload == basePayload
      else {
        throw RoutingMutationFailure.profileChanged(
          staleRoutingMutationMessage(for: kind)
        )
      }
      var committedProfile = latestProfile
      committedProfile.payload = updated
      committedProfile.updatedAt = Date()
      guard try commitProfileUpdate(expected: latestProfile, updated: committedProfile) else {
        throw RoutingMutationFailure.profileChanged(staleRoutingMutationMessage(for: kind))
      }
      if selectedProfileID == identity.profileID {
        updateNodes()
      }

      if shouldApplyDesiredRuntime(for: identity.profileID) {
        presentSubscriptionStatus(
          "\(successMessage.replacingOccurrences(of: "saved", with: "applying"))",
          level: .neutral,
          profileID: identity.profileID
        )
        submitRuntimeApply(
          makeStartRequest(profile: updated, profileID: identity.profileID),
          onCurrentResult: { [weak self] result in
            self?.completeRoutingMutation(
              identity: identity,
              kind: kind,
              successMessage: successMessage,
              committed: committedProfile,
              previous: latestProfile,
              result: result,
              onSuccess: onSuccess
            )
          },
          onSuperseded: { [weak self] in
            self?.completeSupersededRoutingMutation(
              identity: identity,
              kind: kind,
              onSuccess: onSuccess
            )
          },
          visibleProfileID: identity.profileID
        )
      } else {
        runtimeApplyCoordinator.markSaved()
        if !runtimeApplyCoordinator.isApplying {
          runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
        }
        completeSavedRoutingMutation(
          identity: identity,
          kind: kind,
          message: successMessage,
          onSuccess: onSuccess
        )
      }
    } catch {
      failRoutingMutation(identity: identity, kind: kind, error: error)
    }
  }

  private func completeRoutingMutation(
    identity: RoutingMutationIdentity,
    kind: RoutingMutationKind,
    successMessage: String,
    committed: ManagedProfile,
    previous: ManagedProfile,
    result: Result<HelperResponse, any Error>,
    onSuccess: (@MainActor () -> Void)?
  ) {
    guard isCurrentRoutingMutation(identity) else {
      completeSupersededRoutingMutation(
        identity: identity,
        kind: kind,
        onSuccess: onSuccess
      )
      return
    }
    switch result {
    case .success(let response) where response.runtimeOutcome == .reconnectRequired:
      completeDeferredRoutingMutation(
        identity: identity,
        kind: kind,
        savedMessage: successMessage,
        onSuccess: onSuccess
      )
    case .success:
      completeSavedRoutingMutation(
        identity: identity,
        kind: kind,
        message: "\(successMessage) and active",
        onSuccess: onSuccess
      )
    case .failure(let error):
      rollbackProfileUpdate(
        profileID: identity.profileID,
        committed: committed,
        previous: previous,
        originalError: error,
        visibleProfileID: identity.profileID
      )
      if selectedProfileID == identity.profileID { updateNodes() }
      let message =
        runtimeFailurePreservedPrevious
        ? "Apply failed — previous routing remains active" : "\(kind.routingName) apply failed"
      setRoutingMutationStatus(
        identity,
        kind: kind,
        presentation: RoutingMutationPresentation(state: .failed, message: message)
      )
      presentSubscriptionStatus(message, level: .warning, profileID: identity.profileID)
    }
  }

  private func completeDeferredRoutingMutation(
    identity: RoutingMutationIdentity,
    kind: RoutingMutationKind,
    savedMessage: String,
    onSuccess: (@MainActor () -> Void)?
  ) {
    guard isCurrentRoutingMutation(identity) else {
      completeSupersededRoutingMutation(
        identity: identity,
        kind: kind,
        onSuccess: onSuccess
      )
      return
    }
    setRoutingMutationStatus(
      identity,
      kind: kind,
      presentation: .reconnectRequired
    )
    presentSubscriptionStatus(savedMessage, level: .success, profileID: identity.profileID)
    if selectedProfileID == identity.profileID { lastError = nil }
    onSuccess?()
  }

  private func completeSavedRoutingMutation(
    identity: RoutingMutationIdentity,
    kind: RoutingMutationKind,
    message: String,
    onSuccess: (@MainActor () -> Void)?
  ) {
    guard isCurrentRoutingMutation(identity) else {
      completeSupersededRoutingMutation(
        identity: identity,
        kind: kind,
        onSuccess: onSuccess
      )
      return
    }
    setRoutingMutationStatus(
      identity,
      kind: kind,
      presentation: RoutingMutationPresentation(state: .saved, message: message)
    )
    presentSubscriptionStatus(message, level: .success, profileID: identity.profileID)
    if selectedProfileID == identity.profileID { lastError = nil }
    onSuccess?()
  }

  private func completeSupersededRoutingMutation(
    identity: RoutingMutationIdentity,
    kind: RoutingMutationKind,
    onSuccess: (@MainActor () -> Void)?
  ) {
    if routingMutationStatus(identity, kind: kind) != nil {
      setRoutingMutationStatus(
        identity,
        kind: kind,
        presentation: RoutingMutationPresentation(
          state: .saved,
          message: "Saved; a newer routing change is applying"
        )
      )
    }
    onSuccess?()
  }

  private func failRoutingMutation(
    identity: RoutingMutationIdentity,
    kind: RoutingMutationKind,
    error: any Error
  ) {
    let message = error.localizedDescription
    setRoutingMutationStatus(
      identity,
      kind: kind,
      presentation: RoutingMutationPresentation(state: .failed, message: message)
    )
    presentSubscriptionStatus(
      "\(kind.routingName) change failed", level: .warning, profileID: identity.profileID
    )
    if selectedProfileID == identity.profileID { lastError = message }
  }

  private func presentRoutingMutationFailure(
    _ error: any Error,
    kind: RoutingMutationKind,
    profileID: UUID?
  ) {
    let message = error.localizedDescription
    if let profileID {
      routingMutationStatuses[profileID, default: [:]][kind] = RoutingMutationStatus(
        identity: nil,
        presentation: RoutingMutationPresentation(state: .failed, message: message)
      )
      presentSubscriptionStatus(
        "\(kind.routingName) change failed", level: .warning, profileID: profileID
      )
    }
    if profileID == selectedProfileID || profileID == nil { lastError = message }
  }

  private func routingMutationPresentation(
    for kind: RoutingMutationKind,
    profileID: UUID?
  ) -> RoutingMutationPresentation {
    guard let profileID else { return .saved }
    return routingMutationStatuses[profileID]?[kind]?.presentation ?? .saved
  }

  private func routingMutationStatus(
    _ identity: RoutingMutationIdentity,
    kind: RoutingMutationKind
  ) -> RoutingMutationStatus? {
    guard let status = routingMutationStatuses[identity.profileID]?[kind],
      status.identity == identity
    else { return nil }
    return status
  }

  private func setRoutingMutationStatus(
    _ identity: RoutingMutationIdentity,
    kind: RoutingMutationKind,
    presentation: RoutingMutationPresentation
  ) {
    guard routingMutationStatuses[identity.profileID]?[kind]?.identity == identity else {
      return
    }
    routingMutationStatuses[identity.profileID]?[kind] = RoutingMutationStatus(
      identity: identity,
      presentation: presentation
    )
  }

  private func clearDeferredRuntimePendingPresentations() {
    for profileID in Array(routingMutationStatuses.keys) {
      for kind in [RoutingMutationKind.website, .application, .policy] {
        guard let status = routingMutationStatuses[profileID]?[kind],
          status.presentation.state == .reconnectRequired
        else { continue }
        routingMutationStatuses[profileID]?[kind] = RoutingMutationStatus(
          identity: status.identity,
          presentation: .saved
        )
      }
    }
  }

  private func isCurrentRoutingMutation(_ identity: RoutingMutationIdentity) -> Bool {
    routingMutationRevisions[identity.profileID] == identity.revision
  }

  private func finishRoutingMutationQueue(profileID: UUID, token: UUID) {
    guard routingMutationQueueTokens[profileID] == token else { return }
    routingMutationQueues[profileID] = nil
    routingMutationQueueTokens[profileID] = nil
  }

  private func staleRoutingMutationMessage(for kind: RoutingMutationKind) -> String {
    "The profile changed while the \(kind.routingName.lowercased()) was validated. Try again."
  }

  private func replacingApplicationRoutingRules(
    _ rules: [ApplicationRoutingRule],
    in payload: CoreProfile
  ) -> CoreProfile {
    switch payload {
    case .compatibility(let profile):
      return .compatibility(
        VPNProfile(
          connections: profile.connections,
          routingPolicy: profile.routingPolicy,
          nodeGroups: profile.nodeGroups ?? [],
          applicationRoutingRules: rules,
          websiteRoutingRules: profile.websiteRoutingRules
        )
      )
    case .native(let profile):
      return .native(
        NativeProfile(
          configuration: profile.configuration,
          selectorTag: profile.selectorTag,
          nodes: profile.nodes,
          applicationRoutingRules: rules,
          websiteRoutingRules: profile.websiteRoutingRules
        )
      )
    }
  }

  private func replacingWebsiteRoutingRules(
    _ rules: [WebsiteRoutingRule],
    in payload: CoreProfile
  ) -> CoreProfile {
    switch payload {
    case .compatibility(let profile):
      return .compatibility(
        VPNProfile(
          connections: profile.connections,
          routingPolicy: profile.routingPolicy,
          nodeGroups: profile.nodeGroups ?? [],
          applicationRoutingRules: profile.applicationRoutingRules,
          websiteRoutingRules: rules
        )
      )
    case .native(let profile):
      return .native(
        NativeProfile(
          configuration: profile.configuration,
          selectorTag: profile.selectorTag,
          nodes: profile.nodes,
          applicationRoutingRules: profile.applicationRoutingRules,
          websiteRoutingRules: rules
        )
      )
    }
  }

  private func shouldApplyDesiredRuntime(for profileID: UUID) -> Bool {
    selectedProfileID == profileID
      && desiredCoreRunning != false
      && (coreRunning || runtimeApplyCoordinator.isApplying)
  }

  private func presentSubscriptionStatus(
    _ message: String,
    level: SubscriptionStatusLevel,
    profileID: UUID
  ) {
    guard selectedProfileID == profileID else { return }
    setSubscriptionStatus(message, level: level)
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

  private func send(
    _ request: HelperRequest,
    completion: (@MainActor (Result<HelperResponse, any Error>) -> Void)? = nil
  ) {
    guard currentHelperIsReady else {
      let failure = AppModelFailure.helperNotReady
      lastError = failure.localizedDescription
      completion?(.failure(failure))
      return
    }
    let runtimeGeneration = runtimeApplyCoordinator.currentGeneration
    let errorBasis = lastError
    beginBusyOperation()
    Task {
      defer { endBusyOperation() }
      do {
        let response = try await helperRequestSender(request)
        apply(
          response,
          policy: .observation(
            runtimeCurrent: runtimeGeneration == runtimeApplyCoordinator.currentGeneration,
            adoptDesiredRuntime: false
          )
        )
        guard response.protocolVersion == HelperConstants.protocolVersion,
          response.helperVersion == HelperConstants.helperVersion,
          response.helperRevision == HelperConstants.helperRevision
        else {
          let failure = AppModelFailure.helperRevisionMismatch
          if lastError == errorBasis { lastError = failure.localizedDescription }
          completion?(.failure(failure))
          return
        }
        if lastError == errorBasis {
          lastError = response.success ? nil : response.message
        }
        if response.success {
          completion?(.success(response))
        } else {
          completion?(.failure(AppModelFailure.helperRequestFailed(response.message)))
        }
      } catch {
        helperReachable = false
        observedCoreState = .unknown
        if lastError == errorBasis { lastError = error.localizedDescription }
        completion?(.failure(error))
      }
    }
  }

  private func submitRuntimeApply(
    _ request: HelperRequest,
    onCurrentResult: (@MainActor (Result<HelperResponse, any Error>) -> Void)? = nil,
    onSuperseded: (@MainActor () -> Void)? = nil,
    visibleProfileID: UUID? = nil
  ) {
    func present(_ message: String?) {
      guard let message,
        visibleProfileID == nil || selectedProfileID == visibleProfileID
      else { return }
      lastError = message
    }
    guard currentHelperIsReady else {
      runtimeApplyStatus = .failed
      runtimeFailurePreservedPrevious = false
      runtimeFailureProfileID = request.profileID ?? visibleProfileID
      let failure = AppModelFailure.helperNotReady
      present(failure.localizedDescription)
      onCurrentResult?(.failure(failure))
      return
    }
    runtimeApplyStatus = .applying
    runtimeFailurePreservedPrevious = false
    runtimeFailureProfileID = nil
    let previouslyActiveProfileID = helperActiveProfileID
    let previouslyRunning = coreRunning
    let knownGoodProfileID = previouslyActiveProfileID ?? request.profileID
    runtimeApplyCoordinator.submit(request) { [weak self] outcome in
      guard let self else { return }
      switch outcome.result {
      case .success(let response):
        self.apply(response, policy: outcome.isCurrent ? .currentMutation : .staleMutation)
        guard outcome.isCurrent else {
          onSuperseded?()
          return
        }
        if response.protocolVersion != HelperConstants.protocolVersion
          || response.helperVersion != HelperConstants.helperVersion
          || response.helperRevision != HelperConstants.helperRevision
        {
          self.runtimeApplyStatus = .failed
          self.runtimeFailurePreservedPrevious = false
          self.runtimeFailureProfileID = request.profileID ?? visibleProfileID
          self.helperReachable = false
          let failure = AppModelFailure.helperRevisionMismatch
          present(failure.localizedDescription)
          onCurrentResult?(.failure(failure))
        } else if response.success && response.runtimeOutcome == .reconnectRequired {
          self.deferredRuntimeApplyPending = true
          if self.deferredRuntimeApplyPhase != .reconnecting {
            self.deferredRuntimeApplyPhase = .pending
            self.deferredRuntimeApplyError = nil
          }
          self.runtimeApplyStatus = .reconnectRequired
          self.runtimeFailurePreservedPrevious = false
          self.runtimeFailureProfileID = nil
          if visibleProfileID == nil || self.selectedProfileID == visibleProfileID {
            self.lastError = nil
          }
          onCurrentResult?(.success(response))
        } else if response.success {
          let hadDeferredRuntimeApplyPending = self.deferredRuntimeApplyPending
          if request.action == .start,
            self.deferredRuntimeApplyPhase != .reconnecting
          {
            self.deferredRuntimeApplyPending = false
            self.deferredRuntimeApplyPhase = .idle
            self.deferredRuntimeApplyError = nil
            if hadDeferredRuntimeApplyPending,
              response.coreRunning,
              response.runtimeOutcome == .applied,
              response.activeProfileID == self.selectedProfileID
            {
              self.clearDeferredRuntimePendingPresentations()
            }
          }
          self.runtimeApplyStatus =
            self.deferredRuntimeApplyPending
            ? .reconnectRequired
            : (response.coreRunning ? .active : .saved)
          self.runtimeFailurePreservedPrevious = false
          self.runtimeFailureProfileID = nil
          if visibleProfileID == nil || self.selectedProfileID == visibleProfileID {
            self.lastError = nil
          }
          onCurrentResult?(.success(response))
        } else {
          self.runtimeApplyStatus = .failed
          self.runtimeFailureProfileID = request.profileID ?? visibleProfileID
          self.runtimeFailurePreservedPrevious =
            previouslyRunning && response.coreRunning
            && response.activeProfileID == knownGoodProfileID
          let failure = AppModelFailure.profileActivationFailed(response.message)
          present(failure.localizedDescription)
          onCurrentResult?(.failure(failure))
        }
      case .failure(let error):
        guard outcome.isCurrent else {
          onSuperseded?()
          return
        }
        self.runtimeApplyStatus = .failed
        self.runtimeFailurePreservedPrevious = false
        self.runtimeFailureProfileID = request.profileID ?? visibleProfileID
        present(error.localizedDescription)
        Task {
          do {
            let observed = try await self.runtimeStateReader()
            guard outcome.generation == self.runtimeApplyCoordinator.currentGeneration else {
              return
            }
            self.apply(
              observed,
              policy: .observation(runtimeCurrent: true, adoptDesiredRuntime: false)
            )
            self.helperReachable = true
            self.runtimeApplyStatus = .failed
            self.runtimeFailurePreservedPrevious =
              previouslyRunning && observed.coreRunning
              && observed.activeProfileID == knownGoodProfileID
            self.runtimeFailureProfileID = request.profileID ?? visibleProfileID
          } catch {
            guard outcome.generation == self.runtimeApplyCoordinator.currentGeneration else {
              return
            }
            self.helperReachable = false
            self.observedCoreState = .unknown
          }
          onCurrentResult?(.failure(error))
        }
      }
    }
  }

  private func applyCurrentDesiredRuntimeIfNeeded(
    onCurrentResult: (@MainActor (Result<HelperResponse, any Error>) -> Void)? = nil,
    onSuperseded: (@MainActor () -> Void)? = nil
  ) {
    runtimeApplyCoordinator.markSaved()
    if !runtimeApplyCoordinator.isApplying {
      runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
    }
    guard desiredCoreRunning != false else { return }
    guard coreRunning || runtimeApplyCoordinator.isApplying else { return }
    guard let payload = selectedProfile?.payload else {
      cancelLatencyOperation()
      submitRuntimeApply(
        HelperRequest(action: .stop),
        onCurrentResult: onCurrentResult,
        onSuperseded: onSuperseded
      )
      return
    }
    submitRuntimeApply(
      makeStartRequest(profile: payload, profileID: selectedProfileID),
      onCurrentResult: onCurrentResult,
      onSuperseded: onSuperseded
    )
  }

  private func apply(_ response: HelperResponse, policy: HelperResponsePolicy) {
    let runtimeCurrent: Bool
    let adoptDesiredRuntime: Bool
    switch policy {
    case .observation(let isCurrent, let shouldAdopt):
      runtimeCurrent = isCurrent
      adoptDesiredRuntime = shouldAdopt
    case .currentMutation:
      runtimeCurrent = true
      adoptDesiredRuntime = false
    case .staleMutation:
      runtimeCurrent = false
      adoptDesiredRuntime = false
    }
    helperStatus = response.message
    helperProtocolVersion = response.protocolVersion
    helperVersion = response.helperVersion
    helperRevision = response.helperRevision
    guard response.protocolVersion == HelperConstants.protocolVersion,
      response.helperVersion == HelperConstants.helperVersion,
      response.helperRevision == HelperConstants.helperRevision
    else {
      helperReachable = false
      return
    }
    guard runtimeCurrent else { return }
    let shouldPrimeLatency = response.coreRunning && !coreRunning
    coreRunning = response.coreRunning
    coreVersion = response.coreVersion
    automaticRecoveryExhausted = response.automaticRecoveryExhausted
    if response.success && response.runtimeOutcome == .reconnectRequired {
      deferredRuntimeApplyPending = true
      if deferredRuntimeApplyPhase != .reconnecting {
        deferredRuntimeApplyPhase = .pending
        deferredRuntimeApplyError = nil
      }
    } else if response.success,
      response.coreRunning,
      response.runtimeOutcome == .applied,
      response.activeProfileID == selectedProfileID,
      !runtimeApplyCoordinator.isApplying
    {
      deferredRuntimeApplyPending = false
      deferredRuntimeApplyPhase = .idle
      deferredRuntimeApplyError = nil
      clearDeferredRuntimePendingPresentations()
    }
    if !runtimeApplyCoordinator.isApplying {
      runtimeApplyStatus =
        deferredRuntimeApplyPending
        ? .reconnectRequired
        : (response.coreRunning ? .active : .saved)
    }
    if adoptDesiredRuntime, desiredCoreRunning == nil {
      if response.coreRunning { desiredCoreRunning = true }
      routingMode = response.mode
    }
    helperActiveProfileID = response.activeProfileID
    let responseMatchesSelectedProfile =
      selectedProfileID != nil && response.activeProfileID == selectedProfileID
    let responseMatchesRunningSelection = response.coreRunning && responseMatchesSelectedProfile
    let responseNodeExistsInSelectedProfile =
      response.selectedNode == .auto
      || selectedProfile?.payload?.nodes.contains(where: { $0.id == response.selectedNode }) == true
    if responseMatchesSelectedProfile, responseNodeExistsInSelectedProfile, adoptDesiredRuntime {
      selectedNodeID = response.selectedNode
    }
    if responseMatchesRunningSelection, !response.nodes.isEmpty {
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
      observedCoreState = .unknown
      helperRequiresApproval = true
      helperStatus = "Approval required"
    case .notRegistered:
      helperEnabled = false
      helperReachable = false
      observedCoreState = .unknown
      helperRequiresApproval = false
      helperStatus = "Helper not enabled"
    case .notFound:
      helperEnabled = false
      helperReachable = false
      observedCoreState = .unknown
      helperRequiresApproval = false
      helperStatus = "Helper missing"
    case .unknown:
      helperEnabled = false
      helperReachable = false
      observedCoreState = .unknown
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
    observedCoreState = .unknown
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
      observedCoreState = .unknown
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
    guard desiredCoreRunning != false else { return }
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
    desiredCoreRunning = true
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
      && helperProtocolVersion == HelperConstants.protocolVersion
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

  private func recordRecentError(_ value: String) {
    let sanitized = SafeDiagnosticError.sanitize(
      value,
      secrets: DiagnosticSecrets.collect(from: profiles)
    )
    guard !sanitized.isEmpty else { return }
    if let lastIndex = recentErrors.indices.last,
      recentErrors[lastIndex].message == sanitized
    {
      recentErrors[lastIndex].occurredAt = Date()
      recentErrors[lastIndex].repeatCount = min(recentErrors[lastIndex].repeatCount + 1, 999)
      return
    }
    recentErrors.append(
      RecentError(id: UUID(), occurredAt: Date(), message: sanitized, repeatCount: 1)
    )
    if recentErrors.count > 50 {
      recentErrors.removeFirst(recentErrors.count - 50)
    }
  }

  private func endBusyOperation() {
    busyOperationCount = max(0, busyOperationCount - 1)
  }

  private func beginSyncingOperation() {
    syncingOperationCount += 1
  }

  private func endSyncingOperation() {
    syncingOperationCount = max(0, syncingOperationCount - 1)
  }

  private func cancelLatencyOperation() {
    latencyOperationGeneration &+= 1
    latencyRefreshTask?.cancel()
    latencyRefreshTask = nil
    latencyOperationTask?.cancel()
    latencyOperationTask = nil
    latencyTestInProgress = false
  }

  private func synchronizeLatencyTarget(_ target: String) {
    guard !latencyApplyInProgress else { return }
    latencyApplyInProgress = true
    send(
      HelperRequest(action: .setLatencyTarget, latencyTestURL: target)
    ) { [weak self] result in
      guard let self else { return }
      self.latencyApplyInProgress = false
      switch result {
      case .success:
        self.latencySettingsIssue = nil
        self.lastError = nil
      case .failure(let error):
        let message = self.setSettingsError(
          "Latency runtime synchronization failed",
          error: error,
          additionalSecrets: [target]
        )
        self.latencySettingsIssue = .runtimeSynchronization(message)
      }
    }
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
  case helperRequestFailed(String)
  case coreStopFailed(String)
  case profileLibraryUnavailable(String)
  case staleProfileOperation
  case runtimeMutationSuperseded

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
    case .helperRequestFailed(let message):
      "The background helper rejected the request: " + message
    case .coreStopFailed(let message):
      "The VPN core did not stop: \(message)"
    case .profileLibraryUnavailable(let message): message
    case .staleProfileOperation:
      "The profile or source changed while the operation was in progress. Try again."
    case .runtimeMutationSuperseded:
      "The shutdown request was superseded by a newer runtime change."
    }
  }
}
