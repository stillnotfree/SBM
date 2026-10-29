import AppKit
import Foundation
import OSLog
import Observation
import SBMShared
import ServiceManagement

enum RuntimeApplyStatus: Equatable, Sendable {
  case saved
  case applying
  case active
  case reconnectRequired
  case failed
}

private let restoreLastVPNStateDefaultsKey = "RestoreLastVPNStateEnabled"
private let lastExplicitVPNConnectedDefaultsKey = "LastExplicitVPNIntentConnected"

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
      SBMText.localized("The selected .app does not declare an accessible main executable.")
    case .mainExecutableOutsideBundle:
      SBMText.localized("The selected application's main executable is outside its .app bundle.")
    case .missingDisplayName:
      SBMText.localized("The selected application has no usable display name.")
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

struct LatencyPublication: Sendable {
  let response: HelperResponse
  let profileID: UUID?
  let activeProfileID: UUID?
  let operationGeneration: Int
  let runtimeGeneration: UInt64
}

@MainActor
final class LatencyPublicationCoordinator {
  private var trackingDepth = 0
  private var pendingPublication: LatencyPublication?

  var isMenuTracking: Bool { trackingDepth > 0 }

  func beginMenuTracking() {
    trackingDepth += 1
  }

  func submit(_ publication: LatencyPublication) -> LatencyPublication? {
    guard isMenuTracking else { return publication }
    pendingPublication = publication
    return nil
  }

  func endMenuTracking() -> LatencyPublication? {
    guard trackingDepth > 0 else { return nil }
    trackingDepth -= 1
    guard trackingDepth == 0 else { return nil }
    defer { pendingPublication = nil }
    return pendingPublication
  }

  func cancelPendingPublication() {
    pendingPublication = nil
  }
}

enum ProxyNodeMenuPresentation {
  static func latencyLabel(delay: Int?, testCompleted: Bool) -> String {
    if let delay { return "\(delay) ms" }
    return testCompleted ? SBMText.localized("timeout") : ""
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
        name: first?.groupName ?? SBMText.localized("Servers"),
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
    case .disconnected: SBMText.localized("VPN Disconnected")
    case .unknown: SBMText.localized("VPN state unknown")
    case .connecting: SBMText.localized("Connecting…")
    case .connected: SBMText.localized("VPN Connected")
    case .disconnecting: SBMText.localized("Disconnecting…")
    case .failed(let preserved):
      preserved
        ? SBMText.localized("Connection change failed — previous VPN active")
        : SBMText.localized("Connection failed")
    }
  }

  var systemImage: String {
    switch self {
    case .connected, .failed(previousRuntimePreserved: true): "shield.fill"
    case .connecting, .disconnecting: "arrow.trianglehead.2.clockwise.rotate.90"
    case .unknown: "exclamationmark.shield"
    case .disconnected, .failed(previousRuntimePreserved: false): "shield"
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
    SBMText.localized("Reconnect to Apply")
  }
}

enum DeferredRuntimeApplyPhase: Equatable, Sendable {
  case idle
  case pending
  case applying
  case reconnecting
  case failed
}

struct DeferredRuntimeApplyPresentation: Equatable, Sendable {
  let headline: String
  let action: DeferredRuntimeApplyAction
  let phase: DeferredRuntimeApplyPhase

  static let changesReadyToApply = SBMText.localized("Changes ready to apply")

  var actionEnabled: Bool {
    phase == .pending || phase == .failed
  }
}

enum ObservedCoreState: String, Codable, Equatable, Sendable {
  case running
  case stopped
  case unknown
}

enum RuntimeLivenessPolicy {
  static let refreshInterval: Duration = .seconds(30)
  static let freshnessWindow: TimeInterval = 90

  static func isFresh(lastObservationAt: Date?, now: Date) -> Bool {
    guard let lastObservationAt else { return false }
    return now.timeIntervalSince(lastObservationAt) <= freshnessWindow
  }
}

@MainActor
@Observable
final class AppModel {
  private enum RoutingMutationKind: Hashable, Sendable {
    case website
    case application
    case policy
    case autoSelection

    var routingName: String {
      switch self {
      case .website: SBMText.localized("Website rule")
      case .application: SBMText.localized("Application rule")
      case .policy: SBMText.localized("Routing policy")
      case .autoSelection: SBMText.localized("Auto selection")
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
  var routingMode: RoutingMode = .rule {
    didSet {
      if oldValue != routingMode { invalidateRoutingInspector() }
    }
  }
  var selectedNodeID: ProxyNodeID = .auto {
    didSet {
      if oldValue != selectedNodeID, selectedNodeID != .auto {
        effectiveAutoNodeID = nil
      }
      if oldValue != selectedNodeID { invalidateRoutingInspector() }
    }
  }
  var helperUpdateRequired = false
  var helperEnabled = false
  var helperReachable = false {
    didSet {
      if !helperReachable { effectiveAutoNodeID = nil }
    }
  }
  var helperRequiresApproval = false
  private(set) var helperApprovalPending = false
  private(set) var helperApprovalPolling = false
  /// Authoritative IPv6 policy reported for the currently running core.
  /// `nil` is intentional for stopped or unknown state; desired settings must
  /// never be presented as active merely because they were persisted.
  private(set) var activeIPv6Enabled: Bool?
  /// Prevents repeated full-snapshot submissions while a running legacy core
  /// still reports its historical IPv6 policy as unknown. The helper persists
  /// the authoritative unknown state; this flag only coalesces one app-session
  /// observation until a concrete active policy is returned.
  private var legacyIPv6ConvergenceAttempted = false
  private var lastRuntimeObservationAt: Date?
  private var runtimeLivenessTask: Task<Void, Never>?
  var observedCoreState: ObservedCoreState = .unknown {
    didSet {
      if observedCoreState != .running {
        effectiveAutoNodeID = nil
        activeIPv6Enabled = nil
        lastRuntimeObservationAt = nil
        stopRuntimeLivenessPolling()
      } else {
        lastRuntimeObservationAt = Date()
        startRuntimeLivenessPolling()
      }
    }
  }
  var coreRunning: Bool {
    get { observedCoreState == .running }
    set { observedCoreState = newValue ? .running : .stopped }
  }
  var helperProtocolVersion: Int? = HelperConstants.protocolVersion
  var helperVersion: String?
  var helperRevision: Int?
  var coreVersion: String?
  var launchAtLoginEnabled = false
  var restoreLastVPNStateEnabled = false
  private(set) var launchAtLoginError: String?
  private(set) var startupRestoreError: String?
  private var startupRestorePending = false
  private var terminalAdmissionClosed = false
  private var durableStopProofRequired = false
  private var busyOperationCount = 0
  var isBusy: Bool { busyOperationCount > 0 }
  var helperSetupInProgress = false
  var lastError: String? {
    didSet {
      if let lastError, !lastError.isEmpty { recordRecentError(lastError) }
    }
  }
  var safeCurrentError: String? {
    guard let lastError, !lastError.isEmpty else { return nil }
    return SafeDiagnosticError.sanitize(
      lastError, secrets: DiagnosticSecrets.collect(from: profiles))
  }
  private(set) var recentErrors: [RecentError] = []
  var updateStatus = ""
  var availableUpdateVersion: String? { availableUpdate?.version }
  var isCheckingForUpdates = false
  var isDownloadingUpdate = false
  var updateDownloadProgress: Double?

  var profiles: [ManagedProfile] = []
  var selectedProfileID: UUID? {
    didSet {
      if oldValue != selectedProfileID {
        effectiveAutoNodeID = nil
        invalidateRoutingInspector()
      }
    }
  }
  private(set) var effectiveAutoNodeID: ProxyNodeID?
  var profileName = ""
  private(set) var profileNameError: String?
  var selectedSourceID: UUID?
  var sourceName = ""
  var sourceExcludeRegex = ""
  var routingInspectorInput = "" {
    didSet {
      if oldValue != routingInspectorInput { invalidateRoutingInspector() }
    }
  }
  var routingInspectorApplicationID: UUID? {
    didSet {
      if oldValue != routingInspectorApplicationID { invalidateRoutingInspector() }
    }
  }
  private(set) var routingInspectorState: RoutingInspectorState = .idle
  var routingInspectorOutput: String {
    guard let snapshot = routingInspectorState.snapshot,
      snapshot == currentRoutingInspectionSnapshot()
    else {
      return RoutingInspectorState.idleOutput
    }
    return routingInspectorState.output
  }
  var routingInspectorDetails: String {
    guard let snapshot = routingInspectorState.snapshot,
      snapshot == currentRoutingInspectionSnapshot()
    else { return "" }
    return routingInspectorState.details
  }
  var websiteRoutingInput = ""
  var websiteRoutingTarget: WebsiteRoutingTarget = .selectedProxy
  var websiteRoutingEditingRuleID: UUID?
  var subscriptionURL = ""
  var subscriptionUserAgent = SubscriptionHeaders.defaultUserAgent
  var subscriptionAppVersion = SubscriptionHeaders.defaultAppVersion ?? ""
  var subscriptionDeviceOS = SubscriptionHeaders.defaultDeviceOS
  var subscriptionDeviceOSVersion = SubscriptionHeaders.defaultDeviceOSVersion ?? ""
  var subscriptionDeviceModel = SubscriptionHeaders.defaultDeviceModel ?? ""
  var subscriptionHWID = SubscriptionHeaders.makeHardwareID()
  var subscriptionStatus = SBMText.localized("No subscription synced")
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
    localSOCKSIssue?.canRetrySynchronization == true && shouldApplyDesiredRuntime
  }
  var runtimeApplyStatus: RuntimeApplyStatus = .saved
  private var syncingOperationCount = 0
  var isSyncing: Bool { syncingOperationCount > 0 }
  var profileAvailable = false
  var ipv6Enabled = false {
    didSet {
      if oldValue != ipv6Enabled {
        legacyIPv6ConvergenceAttempted = false
        invalidateRoutingInspector()
      }
    }
  }
  var ipv6PolicyDescription: String {
    guard observedCoreState != .unknown else {
      return SBMText.localized(
        "Active IPv6 policy is unknown; the saved preference will apply after status recovers."
      )
    }
    guard coreRunning else {
      return SBMText.localized("IPv6 policy will be used the next time you connect.")
    }
    guard let activeIPv6Enabled else {
      return SBMText.localized(
        "Active IPv6 policy is unknown; SBM is reconciling the saved preference."
      )
    }
    guard activeIPv6Enabled != ipv6Enabled else {
      return ipv6Enabled
        ? SBMText.localized("IPv6 traffic follows the composed routing policy.")
        : SBMText.localized("IPv6 remains captured and is rejected before traffic sniffing.")
    }
    return activeIPv6Enabled
      ? SBMText.localized(
        "IPv6 is still enabled in the running core; the saved disabled policy will apply after reconnect."
      )
      : SBMText.localized(
        "IPv6 is still rejected in the running core; the saved enabled policy will apply after reconnect."
      )
  }
  var localSOCKSEnabled = false
  var localSOCKSPort: UInt16 = 1082
  var localSOCKSEnabledDraft = false
  var localSOCKSPortDraft: UInt16 = 1082
  private(set) var localSOCKSApplyInProgress = false
  var latencyIntervalMinutes = 10
  var latencyIntervalMinutesDraft = 10
  var latencyTestURL = LatencyTargetPolicy.defaultURL
  var latencyTestURLDraft = LatencyTargetPolicy.defaultURL
  var dnsSettings = ManagedDNSSettings.defaults
  var latencyApplyInProgress: Bool { latencySyncTask != nil }
  private var subscriptionRefreshTask: Task<Void, Never>?
  private var profileRefreshTask: Task<Void, Never>?
  private var refreshRequestedByUser = false
  private var latencyRefreshTask: Task<Void, Never>?
  private var latencyOperationTask: Task<Void, Never>?
  private var latencyOperationGeneration = 0
  private var profileStoreLoadFailure: (any Error)?
  private var helperRepairTask: Task<Void, Never>?
  private var helperApprovalPollTask: Task<Void, Never>?
  private var helperApprovalSettingsPresented = false
  private var refreshGeneration = 0
  private var statusRefreshTask: Task<Void, Never>?
  private var sourceSyncTask: Task<Void, Never>?
  private var runtimeReadbackTask: Task<Void, Never>?
  private var latencySyncTask: Task<Void, Never>?
  private var routingMutationRevisions: [UUID: UInt64] = [:]
  private var routingMutationQueues: [UUID: Task<Void, Never>] = [:]
  private var routingMutationQueueTokens: [UUID: UUID] = [:]
  private var routingMutationStatuses: [UUID: [RoutingMutationKind: RoutingMutationStatus]] = [:]
  private var runtimeFailurePreservedPrevious = false
  private var runtimeFailureProfileID: UUID?
  private var deferredRuntimeApplyPending = false
  private(set) var deferredRuntimeApplyPhase: DeferredRuntimeApplyPhase = .idle
  private(set) var deferredRuntimeApplyError: String?
  var isRefreshing: Bool { refreshRequestedByUser && profileRefreshTask != nil }
  private var lastLatencyTestAt: Date?
  var latencyTestCompleted = false
  var latencyTestInProgress = false
  private var helperActiveProfileID: UUID?
  private var availableUpdate: AppUpdate?

  var nodes: [ProxyNode] = [
    ProxyNode(
      id: .auto,
      name: SBMText.localized("Auto"),
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

  var autoSelectionSections: [ProxyNodeSection] {
    guard case .compatibility(let profile) = selectedProfile?.payload else { return [] }
    let desiredNodes = CoreProfile.compatibility(profile).nodes.filter { $0.id != .auto }
      .map { descriptor in
        let metadata = groupMetadata(for: descriptor.id)
        return ProxyNode(
          id: descriptor.id,
          name: descriptor.name,
          groupID: metadata?.id,
          groupName: metadata?.name,
          groupOrder: metadata?.groupOrder,
          nodeOrder: metadata?.nodeOrder,
          delay: nil
        )
      }
    return ProxyNodeSectionBuilder.make(from: desiredNodes)
  }

  var autoSelectionExcludedNodeIDs: Set<ProxyNodeID> {
    guard case .compatibility(let profile) = selectedProfile?.payload else { return [] }
    return Set(profile.autoExcludedNodeIDs)
  }

  var autoSelectionAllExcluded: Bool {
    guard case .compatibility(let profile) = selectedProfile?.payload else { return false }
    return !profile.connections.isEmpty
      && profile.connections.allSatisfy { profile.autoExcludedNodeIDs.contains($0.id) }
  }

  var autoSelectionStatus: RoutingMutationPresentation {
    routingMutationPresentation(for: .autoSelection, profileID: selectedProfileID)
  }

  var effectiveAutoNodeName: String? {
    guard selectedNodeID == .auto,
      observedCoreState == .running,
      helperActiveProfileID == selectedProfileID,
      let effectiveAutoNodeID
    else { return nil }
    return nodes.first(where: { $0.id == effectiveAutoNodeID })?.name
  }

  var profileRecoveryRequired: Bool {
    (profileStoreLoadFailure as? ProfileStoreFailure)?.isMalformedCurrentLibrary == true
  }

  var profileRecoveryMessage: String {
    profileStoreLoadFailure?.localizedDescription
      ?? SBMText.localized("Profile library is available.")
  }

  var profileLoadIssueMessage: String? {
    guard let profileStoreLoadFailure, !profileRecoveryRequired else { return nil }
    return profileStoreLoadFailure.localizedDescription
  }

  var canBackUpProfileLibrary: Bool {
    profileStoreLoadFailure == nil && !isSyncing && routingMutationQueues.isEmpty
  }

  var profileReplacementRuntimeIsSafe: Bool {
    guard !runtimeMutationController.isApplying,
      !helperSetupInProgress
    else { return false }
    let registrationState = helperService.registrationState
    return coreIsKnownStopped || registrationState == .notRegistered
      || registrationState == .notFound
  }

  var canRestoreProfileLibrary: Bool {
    canBackUpProfileLibrary && profileReplacementRuntimeIsSafe
  }

  private let helperService: any HelperServiceManaging
  private let helperLifecycleSender: @Sendable (HelperRequest, Int) async throws -> HelperResponse
  private let helperRequestSender: @Sendable (HelperRequest) async throws -> HelperResponse
  private let helperApprovalPollDuration: Duration
  private let helperApprovalPollInterval: Duration
  private let applicationBundleURL: URL
  private let subscriptionManager: SubscriptionManager
  private let runtimeMutationController: RuntimeMutationController
  private let profileValidator: @Sendable (CoreProfile) async throws -> HelperResponse
  private let profileLibrarySaver: (ProfileLibrary) throws -> Void
  private let runtimeStateReader: @Sendable () async throws -> HelperResponse
  private let latencySender: @Sendable (ProxyNodeID?) async throws -> HelperResponse
  private let latencySettleDelay: Duration
  private let updateChecker: @Sendable (String) async throws -> AppUpdate?
  private let updateDownloader:
    @Sendable (
      AppUpdate, @escaping @Sendable (Double) -> Void
    ) async throws -> URL
  private let updateOpener: (URL) -> Bool
  private static let lifecycleLogger = Logger(
    subsystem: "com.stillnotfree.sbm",
    category: "helper-lifecycle"
  )
  private var terminalColdOffClaim: ColdOffProof?
  private let latencyPublicationCoordinator = LatencyPublicationCoordinator()
  private let userDefaults: UserDefaults
  private var menuTrackingObservers: [NSObjectProtocol] = []
  private var updateOperationTask: Task<Void, Never>?
  private var updateDownloadAttemptID: UUID?
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
    guard detail != SafeDiagnosticError.redactedMessage, !detail.isEmpty else { return prefix }
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
    environment: AppEnvironment = AppEnvironment.hermetic(),
    helperService: (any HelperServiceManaging)? = nil,
    subscriptionManager: SubscriptionManager? = nil,
    helperLifecycleSender:
      (@Sendable (HelperRequest, Int) async throws -> HelperResponse)? = nil,
    helperApprovalPollDuration: Duration? = nil,
    helperApprovalPollInterval: Duration? = nil,
    applicationBundleURL: URL? = nil,
    runtimeSender: (@Sendable (HelperRequest) async throws -> HelperResponse)? = nil,
    helperRequestSender: (@Sendable (HelperRequest) async throws -> HelperResponse)? = nil,
    profileValidator: (@Sendable (CoreProfile) async throws -> HelperResponse)? = nil,
    profileLibraryLoader: (() throws -> ProfileLibrary?)? = nil,
    profileLibrarySaver: ((ProfileLibrary) throws -> Void)? = nil,
    userDefaults: UserDefaults = .standard,
    runtimeStateReader: (@Sendable () async throws -> HelperResponse)? = nil,
    latencySender: (@Sendable (ProxyNodeID?) async throws -> HelperResponse)? = nil,
    latencySettleDelay: Duration? = nil,
    updateChecker: (@Sendable (String) async throws -> AppUpdate?)? = nil,
    updateDownloader: (
      @Sendable (
        AppUpdate, @escaping @Sendable (Double) -> Void
      ) async throws -> URL
    )? = nil,
    updateOpener: ((URL) -> Bool)? = nil,
    performStartup: Bool = true
  ) {
    self.userDefaults = userDefaults
    let restoreEnabled = userDefaults.bool(forKey: restoreLastVPNStateDefaultsKey)
    restoreLastVPNStateEnabled = restoreEnabled
    startupRestorePending =
      restoreEnabled
      && userDefaults.bool(forKey: lastExplicitVPNConnectedDefaultsKey)
    self.helperService = helperService ?? environment.helperService
    self.helperLifecycleSender = helperLifecycleSender ?? environment.helperLifecycleSender
    self.helperRequestSender = helperRequestSender ?? environment.helperRequestSender
    self.helperApprovalPollDuration =
      helperApprovalPollDuration ?? environment.helperApprovalPollDuration
    self.helperApprovalPollInterval =
      helperApprovalPollInterval ?? environment.helperApprovalPollInterval
    self.applicationBundleURL = applicationBundleURL ?? environment.applicationBundleURL
    self.subscriptionManager = subscriptionManager ?? environment.subscriptionManager
    runtimeMutationController = RuntimeMutationController(
      sender: runtimeSender ?? environment.runtimeSender
    )
    self.profileValidator = profileValidator ?? environment.profileValidator
    self.profileLibrarySaver = profileLibrarySaver ?? environment.profileLibrarySaver
    self.runtimeStateReader = runtimeStateReader ?? environment.runtimeStateReader
    self.latencySender = latencySender ?? environment.latencySender
    self.latencySettleDelay = latencySettleDelay ?? environment.latencySettleDelay
    self.updateChecker =
      updateChecker ?? { currentVersion in
        try await UpdateService.latest(currentVersion: currentVersion)
      }
    self.updateDownloader =
      updateDownloader ?? { update, progress in
        try await UpdateService.download(update, progress: progress)
      }
    self.updateOpener = updateOpener ?? { NSWorkspace.shared.open($0) }
    if environment.kind == .production {
      installMenuTrackingObservers()
    }
    let stored: ProfileLibrary
    do {
      if let loaded = try (profileLibraryLoader ?? environment.profileLibraryLoader)() {
        stored = loaded
      } else {
        let freshInstall = ProfileLibrary.freshInstall()
        try self.profileLibrarySaver(freshInstall)
        stored = freshInstall
      }
    } catch {
      stored = .empty
      profileStoreLoadFailure = error
    }
    profiles = stored.profiles
    selectedProfileID = stored.selectedProfileID
    routingMode = stored.routingMode
    selectedNodeID = stored.selectedNodeID
    localSOCKSEnabled = stored.localSOCKSEnabled
    localSOCKSPort = stored.localSOCKSPort
    localSOCKSEnabledDraft = stored.localSOCKSEnabled
    localSOCKSPortDraft = stored.localSOCKSPort
    latencyIntervalMinutes = stored.latencyIntervalMinutes
    latencyIntervalMinutesDraft = stored.latencyIntervalMinutes
    latencyTestURL = stored.latencyTestURL
    latencyTestURLDraft = stored.latencyTestURL
    ipv6Enabled = stored.ipv6Enabled
    dnsSettings = stored.dnsSettings
    if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
      selectedProfileID = profiles.first?.id
    }
    loadSelectedProfileEditor()
    updateNodes()
    if let profileStoreLoadFailure {
      lastError = profileStoreLoadFailure.localizedDescription
    }
    guard performStartup else { return }
    guard isInstalledInApplications else {
      lastError =
        SBMText.localized(
          "Move SBM.app to the Applications folder, eject the DMG, then open the installed copy."
        )
      return
    }
    refreshLaunchAtLoginStatus()
    refreshRegistrationStatus()
    bootstrapHelper()
    if !profiles.isEmpty {
      profileAvailable = selectedProfile?.payload != nil
      startSubscriptionRefreshLoop()
    }
    checkForUpdates(userInitiated: false)
  }

  var selectedProfileName: String {
    selectedProfile?.name
      ?? (coreRunning ? SBMText.localized("Active configuration") : SBMText.localized("None"))
  }

  func backUpProfileLibrary(to url: URL) {
    guard canBackUpProfileLibrary else {
      lastError = SBMText.localized("Backup is unavailable while profile changes are in progress.")
      return
    }
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      try ProfileStore.exportProfileLibrary(to: url)
      lastError = nil
    } catch {
      _ = setSettingsError(SBMText.localized("Profile backup failed"), error: error)
    }
  }

  func restoreProfileLibrary(from url: URL) {
    guard canRestoreProfileLibrary else {
      lastError = SBMText.localized("Restore requires idle profile changes and a stopped runtime.")
      return
    }
    startupRestorePending = false
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      let stored = try ProfileStore.importProfileLibrary(from: url)
      deferredRuntimeApplyPending = false
      deferredRuntimeApplyPhase = .idle
      deferredRuntimeApplyError = nil
      routingMutationRevisions.removeAll()
      routingMutationQueueTokens.removeAll()
      routingMutationStatuses.removeAll()
      runtimeApplyStatus = .saved
      runtimeFailurePreservedPrevious = false
      runtimeFailureProfileID = nil
      applyProfileLibrary(stored, reconcileRuntime: false)
      lastError = nil
    } catch {
      _ = setSettingsError(SBMText.localized("Profile restore failed"), error: error)
    }
  }

  func importRecoveredProfileLibrary(from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let stored = try ProfileStore.importProfileLibrary(from: url)
      profileStoreLoadFailure = nil
      applyProfileLibrary(stored)
      lastError = nil
      setSubscriptionStatus(SBMText.localized("Profile library recovered"), level: .success)
    } catch {
      lastError = SBMText.format("Profile recovery failed: %@", error.localizedDescription)
    }
  }

  func resetCorruptProfileLibrary() {
    guard profileRecoveryRequired else { return }
    guard profileReplacementRuntimeIsSafe else {
      lastError = SBMText.localized(
        "Disconnect the VPN before starting with an empty profile library.")
      return
    }
    do {
      let stored = try ProfileStore.resetProfileLibrary()
      profileStoreLoadFailure = nil
      applyProfileLibrary(stored)
      lastError = nil
      setSubscriptionStatus(
        SBMText.localized("Started with an empty profile library"), level: .warning)
    } catch {
      lastError = SBMText.format("Profile recovery failed: %@", error.localizedDescription)
    }
  }

  func revealPreservedProfileLibrary() {
    do {
      guard let url = try ProfileStore.latestPreservedProfileURL() else {
        lastError = SBMText.localized("No preserved profile-library copy was found.")
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
      lastError = SBMText.localized("The selected profile has no routing policy.")
      return
    }
    do {
      let url = try RoutingPolicyDocument.makeTemporaryCopy(policy.configuration)
      guard NSWorkspace.shared.open(url) else {
        lastError = SBMText.localized(
          "macOS could not open the routing JSON in its default application.")
        return
      }
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  var routingPolicyStatus: String {
    guard case .compatibility(let profile) = selectedProfile?.payload else {
      return SBMText.localized("Available for Reality + Hysteria2 subscriptions")
    }
    switch runtimeApplyStatus {
    case .applying:
      return SBMText.localized("Routing policy applying")
    case .failed
    where runtimeFailureProfileID == nil || runtimeFailureProfileID == selectedProfileID:
      return runtimeFailurePreservedPrevious
        ? SBMText.localized("Apply failed — previous routing remains active")
        : SBMText.localized("Apply failed — active routing is unknown")
    case .failed:
      return profile.routingPolicy == nil
        ? SBMText.localized("No routing policy")
        : SBMText.localized("Routing policy saved, not active")
    case .active where coreRunning && helperActiveProfileID == selectedProfileID:
      return profile.routingPolicy == nil
        ? SBMText.localized("No routing policy")
        : SBMText.localized("Routing policy active")
    case .reconnectRequired:
      return profile.routingPolicy == nil
        ? SBMText.localized("No routing policy")
        : SBMText.localized("Routing policy saved")
    case .saved, .active:
      return profile.routingPolicy == nil
        ? SBMText.localized("No routing policy")
        : SBMText.localized("Routing policy saved, not active")
    }
  }

  var connectionPresentation: ConnectionPresentation {
    if runtimeApplyStatus == .applying {
      return (runtimeMutationController.desiredRunning ?? coreRunning)
        ? .connecting : .disconnecting
    }
    if runtimeApplyStatus == .failed {
      guard observedCoreState != .unknown else { return .unknown }
      return .failed(previousRuntimePreserved: runtimeFailurePreservedPrevious)
    }
    switch observedCoreState {
    case .running:
      guard
        RuntimeLivenessPolicy.isFresh(
          lastObservationAt: lastRuntimeObservationAt,
          now: Date()
        )
      else { return .unknown }
      return .connected
    case .stopped: return .disconnected
    case .unknown: return .unknown
    }
  }

  var connectionAction: Bool? {
    if runtimeApplyStatus == .failed {
      switch observedCoreState {
      case .running: return false
      case .stopped: return true
      case .unknown: return connectionPresentation.nextEnabledState
      }
    }
    return connectionPresentation.nextEnabledState
  }

  var connectionActionEnabled: Bool {
    guard let action = connectionAction, !helperSetupInProgress else { return false }
    return action ? currentHelperIsReady : currentRegisteredHelperIsCompatible
  }

  var runtimeMenuControlsEnabled: Bool {
    currentHelperIsReady && !helperSetupInProgress
  }

  var deferredRuntimeApplyPresentation: DeferredRuntimeApplyPresentation? {
    guard deferredRuntimeApplyPending else { return nil }
    guard observedCoreState != .unknown || deferredRuntimeApplyPhase == .failed else {
      return nil
    }
    let isReconnecting = deferredRuntimeApplyPhase == .reconnecting
    let isApplying = runtimeApplyStatus == .applying && !isReconnecting
    return DeferredRuntimeApplyPresentation(
      headline: isReconnecting
        ? SBMText.localized("Reconnecting…")
        : isApplying
          ? SBMText.localized("Applying…")
          : DeferredRuntimeApplyPresentation.changesReadyToApply,
      action: .reconnect,
      phase: isReconnecting
        ? .reconnecting
        : isApplying ? .applying : deferredRuntimeApplyPhase
    )
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
    let normalizedName = candidateName.isEmpty ? SBMText.localized("Subscription") : candidateName
    guard (try? SubscriptionClient.validateDisplayName(normalizedName)) != nil else {
      return false
    }
    let appVersion = subscriptionAppVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    let deviceOSVersion = subscriptionDeviceOSVersion.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let deviceModel = subscriptionDeviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let headers = SubscriptionHeaders(
      userAgent: subscriptionUserAgent.trimmingCharacters(in: .whitespacesAndNewlines),
      appVersion: appVersion.isEmpty ? nil : appVersion,
      deviceOS: subscriptionDeviceOS.trimmingCharacters(in: .whitespacesAndNewlines),
      deviceOSVersion: deviceOSVersion.isEmpty ? nil : deviceOSVersion,
      deviceModel: deviceModel.isEmpty ? nil : deviceModel,
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

  var sourceDraftNeedsSaveOrSync: Bool {
    guard let selectedSourceID,
      let source = selectedProfile?.sources.first(where: { $0.id == selectedSourceID })
    else { return false }
    let trimmedName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidateName = trimmedName.isEmpty ? SBMText.localized("Subscription") : trimmedName
    let candidateURL =
      (try? SubscriptionClient.validateSourceValue(subscriptionURL))
      ?? subscriptionURL
    let candidateFilter =
      (try? SourceNameFilter.normalized(sourceExcludeRegex))
      ?? sourceExcludeRegex
    let appVersion = subscriptionAppVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    let deviceOSVersion = subscriptionDeviceOSVersion.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let deviceModel = subscriptionDeviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidateHeaders = SubscriptionHeaders(
      userAgent: subscriptionUserAgent.trimmingCharacters(in: .whitespacesAndNewlines),
      appVersion: appVersion.isEmpty ? nil : appVersion,
      deviceOS: subscriptionDeviceOS.trimmingCharacters(in: .whitespacesAndNewlines),
      deviceOSVersion: deviceOSVersion.isEmpty ? nil : deviceOSVersion,
      deviceModel: deviceModel.isEmpty ? nil : deviceModel,
      hardwareID: subscriptionHWID.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    return source.payload == nil || sourceEditorError != nil
      || candidateName != source.name
      || candidateURL != source.value
      || candidateFilter != (source.excludeRegex ?? "")
      || candidateHeaders != source.headers
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
      && runtimeMutationController.desiredRunning != false
      && (coreRunning || runtimeMutationController.isApplying)
  }

  var canManageRoutingPolicy: Bool {
    selectedProfile?.payload != nil
  }

  var canManageSources: Bool {
    selectedProfile != nil
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

  func setNodeIncludedInAuto(
    _ nodeID: ProxyNodeID,
    included: Bool,
    profileID: UUID,
    sourceID: UUID
  ) {
    enqueueRoutingMutation(
      profileID: profileID,
      kind: .autoSelection,
      successMessage: SBMText.localized(
        included ? "Node included in Auto" : "Node excluded from Auto"),
      operation: { payload in
        guard case .compatibility(let profile) = payload,
          nodeID != .auto,
          profile.nodeGroups?.contains(where: {
            $0.id == sourceID.uuidString && $0.nodes.contains(nodeID)
          }) == true,
          profile.connections.contains(where: { $0.id == nodeID })
        else {
          throw RoutingMutationFailure.ruleMissing(
            SBMText.localized("The selected node changed before Auto could be updated.")
          )
        }
        var exclusions = profile.autoExcludedNodeIDs
        if included {
          exclusions.removeAll { $0 == nodeID }
        } else if !exclusions.contains(nodeID) {
          exclusions.append(nodeID)
        }
        let ordered =
          profile.connections.flatMap { connection in
            exclusions.filter { $0 == connection.id }
          } + exclusions.filter { id in !profile.connections.contains { $0.id == id } }
        return .compatibility(
          VPNProfile(
            connections: profile.connections,
            routingPolicy: profile.routingPolicy,
            nodeGroups: profile.nodeGroups ?? [],
            applicationRoutingRules: profile.applicationRoutingRules,
            websiteRoutingRules: profile.websiteRoutingRules,
            autoExcludedNodeIDs: ordered
          )
        )
      }
    )
  }

  var websiteRoutingActionTitle: String {
    SBMText.localized(websiteRoutingEditingRuleID == nil ? "Add" : "Save")
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
        successMessage: SBMText.localized(
          editingRuleID == nil ? "Website rule saved" : "Website rule updated"
        ),
        operation: { payload in
          let currentRules = payload.websiteRoutingRules
          if let editingRuleID {
            guard currentRules.contains(where: { $0.id == editingRuleID }) else {
              throw RoutingMutationFailure.ruleMissing(
                SBMText.localized("The website rule changed before it could be updated.")
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
      successMessage: SBMText.localized("Website rule removed"),
      operation: { payload in
        guard payload.websiteRoutingRules.contains(where: { $0.id == id }) else {
          throw RoutingMutationFailure.ruleMissing(
            SBMText.localized("The website rule changed before it could be removed.")
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
      successMessage: SBMText.localized("Website rule updated"),
      operation: { payload in
        guard payload.websiteRoutingRules.contains(where: { $0.id == id }) else {
          throw RoutingMutationFailure.ruleMissing(
            SBMText.localized("The website rule changed before its route could be updated.")
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

  func addApplicationRoutingRule(from url: URL, profileID: UUID) {
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
        profileID: profileID
      )
      return
    }
    enqueueApplicationRoutingMutation(
      profileID: profileID,
      successMessage: SBMText.localized("Application rule saved")
    ) { payload in
      guard payload.applicationRoutingRules.count < 32 else {
        throw RoutingMutationFailure.ruleMissing(
          SBMText.localized("A profile may contain at most 32 application rules.")
        )
      }
      guard
        !payload.applicationRoutingRules.contains(where: {
          URL(fileURLWithPath: $0.executablePath).standardizedFileURL == resolved.executableURL
        })
      else {
        throw RoutingMutationFailure.ruleMissing(
          SBMText.localized("This application already has a routing rule.")
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

  func replaceApplicationRoutingRule(_ id: UUID, from url: URL, profileID: UUID) {
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
        profileID: profileID
      )
      return
    }
    enqueueApplicationRoutingMutation(
      profileID: profileID,
      successMessage: SBMText.localized("Application rule updated")
    ) { payload in
      guard let current = payload.applicationRoutingRules.first(where: { $0.id == id })
      else {
        throw RoutingMutationFailure.ruleMissing(
          SBMText.localized("The application rule changed before it could be updated.")
        )
      }
      guard
        !payload.applicationRoutingRules.contains(where: {
          $0.id != id
            && URL(fileURLWithPath: $0.executablePath).standardizedFileURL == resolved.executableURL
        })
      else {
        throw RoutingMutationFailure.ruleMissing(
          SBMText.localized("This application already has a routing rule.")
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
      successMessage: SBMText.localized("Application rule removed")
    ) { payload in
      guard payload.applicationRoutingRules.contains(where: { $0.id == id }) else {
        throw RoutingMutationFailure.ruleMissing(
          SBMText.localized("The application rule changed before it could be removed.")
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
      successMessage: SBMText.localized("Application rule updated")
    ) { payload in
      guard payload.applicationRoutingRules.contains(where: { $0.id == id }) else {
        throw RoutingMutationFailure.ruleMissing(
          SBMText.localized("The application rule changed before its route could be updated.")
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
    routingInspectorState = .idle
    if routingInspectorApplicationID != nil,
      applicationRoutingRules.first(where: { $0.id == routingInspectorApplicationID }) == nil
    {
      routingInspectorApplicationID = nil
    }
    do {
      guard let payload = selectedProfile?.payload else {
        throw RoutingInspectionFailure.unavailable
      }
      let composed = try ComposedRoutingInspection.make(
        profile: payload,
        selectedNode: selectedNodeID,
        ipv6Enabled: ipv6Enabled
      )
      let selectedApplication = routingInspectorApplicationID.flatMap { id in
        applicationRoutingRules.first(where: { $0.id == id })
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
        outboundDecisions: composed.outboundDecisions
      )
      let contextLabel = selectedApplication?.displayName ?? SBMText.localized("Default traffic")
      let output = composed.presentation(for: result)
      let details = composed.details(for: result, contextLabel: contextLabel)
      let snapshot = currentRoutingInspectionSnapshot()
      routingInspectorState = .result(
        snapshot: snapshot,
        output: output,
        details: details
      )
    } catch {
      routingInspectorState = .failed(
        snapshot: currentRoutingInspectionSnapshot(),
        output: error.localizedDescription,
        details: ""
      )
    }
  }

  private func currentRoutingInspectionSnapshot() -> RoutingInspectionSnapshot {
    let profile = selectedProfile
    let application = routingInspectorApplicationID.flatMap { id in
      applicationRoutingRules.first(where: { $0.id == id })
    }
    let applicationPath = application.map {
      URL(fileURLWithPath: $0.executablePath).standardizedFileURL.path
    }
    return RoutingInspectionSnapshot(
      profileID: selectedProfileID,
      profileRevision: profile?.updatedAt,
      applicationID: application?.id,
      applicationPath: applicationPath,
      destination: routingInspectorInput.trimmingCharacters(in: .whitespacesAndNewlines),
      selectedNodeID: selectedNodeID,
      mode: routingMode,
      routingRevision: selectedProfileID.flatMap { routingMutationRevisions[$0] } ?? 0,
      ipv6Enabled: ipv6Enabled
    )
  }

  private func invalidateRoutingInspector() {
    routingInspectorState = .idle
  }

  var supportSnapshot: SupportSnapshot {
    let appVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
    let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
    let profileKind: SupportSnapshot.ProfileKind
    switch selectedProfile?.payload {
    case .compatibility: profileKind = .compatibilitySubscription
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
      profileLibraryAvailable: profileStoreLoadFailure == nil,
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

  func clearRecentErrors() {
    recentErrors.removeAll(keepingCapacity: true)
  }

  func applicationDidBecomeActive() {
    refreshLaunchAtLoginStatus()
    guard helperApprovalPending else {
      refresh()
      return
    }
    helperApprovalSettingsPresented = false
    continueHelperApprovalFlow()
  }

  func refresh(observeAutoNode: Bool = false) {
    guard isInstalledInApplications else { return }
    guard !terminalAdmissionClosed else { return }
    if observeAutoNode {
      effectiveAutoNodeID = nil
    }
    guard !runtimeMutationController.isApplying else { return }
    guard !helperApprovalPending else {
      continueHelperApprovalFlow()
      return
    }
    refreshRegistrationStatus()
    guard helperEnabled else {
      observedCoreState = .unknown
      return
    }
    guard !helperSetupInProgress, statusRefreshTask == nil else { return }

    refreshGeneration += 1
    let generation = refreshGeneration
    let selectedProfileBasis = selectedProfileID
    let runtimeGeneration = runtimeMutationController.currentGeneration
    let errorBasis = lastError
    statusRefreshTask = Task {
      defer { statusRefreshTask = nil }
      do {
        let authorizeDesiredRuntimeRecovery =
          !terminalAdmissionClosed
          && !durableStopProofRequired
          && observedCoreState == .running
          && runtimeMutationController.desiredRunning == true
        if authorizeDesiredRuntimeRecovery {
          terminalColdOffClaim?.release()
          terminalColdOffClaim = nil
        }
        let response = try await helperLifecycleSender(
          HelperRequest(
            action: .status,
            observeAutoNode: observeAutoNode ? true : nil,
            recoverDesiredRuntime: authorizeDesiredRuntimeRecovery ? true : nil
          ),
          5
        )
        guard refreshGeneration == generation, !helperSetupInProgress else { return }
        guard helperService.registrationState == .enabled else {
          refreshRegistrationStatus()
          return
        }
        let runtimeCurrent = runtimeGeneration == runtimeMutationController.currentGeneration
        guard response.protocolVersion == HelperConstants.protocolVersion,
          response.helperVersion == HelperConstants.helperVersion,
          response.helperRevision == HelperConstants.helperRevision
        else {
          guard runtimeCurrent else { return }
          helperUpdateRequired = true
          helperReachable = false
          observedCoreState = .unknown
          helperActiveProfileID = nil
          coreVersion = nil
          lastError = AppModelFailure.helperRevisionMismatch.localizedDescription
          return
        }
        let compatible = apply(
          response,
          policy: .observation(
            runtimeCurrent: runtimeCurrent,
            adoptDesiredRuntime: runtimeCurrent && runtimeGeneration == 0
          ),
          updateNodeDescriptors: false
        )
        if runtimeCurrent && compatible { helperReachable = true }
        if runtimeCurrent && lastError == errorBasis {
          lastError = response.success ? nil : SBMText.localized(response.message)
        }
        if observeAutoNode,
          let selectedProfileBasis,
          selectedProfileBasis == selectedProfileID,
          runtimeGeneration == runtimeMutationController.currentGeneration,
          selectedNodeID == .auto,
          response.coreRunning,
          response.activeProfileID == selectedProfileBasis,
          response.selectedNode == .auto,
          let effectiveAutoNode = response.effectiveAutoNode,
          nodes.contains(where: { $0.id == effectiveAutoNode })
        {
          effectiveAutoNodeID = effectiveAutoNode
        }
      } catch {
        guard refreshGeneration == generation, !helperSetupInProgress else { return }
        guard helperService.registrationState == .enabled else {
          refreshRegistrationStatus()
          return
        }
        guard runtimeGeneration == runtimeMutationController.currentGeneration else { return }
        helperUpdateRequired = false
        helperReachable = false
        observedCoreState = .unknown
        helperActiveProfileID = nil
        coreVersion = nil
        if lastError == errorBasis { lastError = error.localizedDescription }
      }
    }
  }

  private func startRuntimeLivenessPolling() {
    guard !terminalAdmissionClosed, runtimeLivenessTask == nil else { return }
    runtimeLivenessTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: RuntimeLivenessPolicy.refreshInterval)
        } catch {
          return
        }
        guard let self, self.observedCoreState == .running else { return }
        self.refresh()
      }
    }
  }

  private func stopRuntimeLivenessPolling() {
    runtimeLivenessTask?.cancel()
    runtimeLivenessTask = nil
  }

  func refreshExternalState() {
    refresh()
    refreshAllProfiles(userInitiated: true)
  }

  func checkForUpdates(userInitiated: Bool = true) {
    guard !terminalAdmissionClosed, updateOperationTask == nil else { return }
    if !userInitiated,
      let previous = userDefaults.object(
        forKey: "LastUpdateCheck"
      ) as? Date,
      Date().timeIntervalSince(previous) < 24 * 60 * 60
    {
      return
    }
    isCheckingForUpdates = true
    updateOperationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isCheckingForUpdates = false
        self.updateOperationTask = nil
      }
      do {
        let update = try await self.updateChecker(self.applicationVersion)
        guard !Task.isCancelled, !self.terminalAdmissionClosed else { return }
        self.userDefaults.set(Date(), forKey: "LastUpdateCheck")
        self.availableUpdate = update
        self.updateStatus =
          update.map { SBMText.format("Version %@ is available", $0.version) }
          ?? SBMText.localized("SBM is up to date")
      } catch {
        guard !Task.isCancelled, !self.terminalAdmissionClosed else { return }
        self.updateStatus = SBMText.localized("Update check failed")
        if userInitiated {
          self.lastError = error.localizedDescription
        }
      }
    }
  }

  func downloadAndOpenUpdate() {
    guard !terminalAdmissionClosed else { return }
    guard let update = availableUpdate else {
      checkForUpdates()
      return
    }
    guard updateOperationTask == nil else { return }
    isDownloadingUpdate = true
    updateDownloadProgress = 0
    updateStatus = SBMText.format("Downloading %@…", update.version)
    let attemptID = UUID()
    updateDownloadAttemptID = attemptID
    updateOperationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.updateDownloadAttemptID == attemptID {
          self.updateDownloadAttemptID = nil
          self.isDownloadingUpdate = false
          self.updateDownloadProgress = nil
        }
        self.updateOperationTask = nil
      }
      do {
        let image = try await self.updateDownloader(update) { [weak self] fraction in
          Task { @MainActor [weak self] in
            guard let self,
              !self.terminalAdmissionClosed,
              self.updateDownloadAttemptID == attemptID
            else { return }
            self.updateDownloadProgress = fraction
            self.updateStatus = SBMText.format(
              "Downloading %@… %lld%%",
              update.version,
              Int((fraction * 100).rounded())
            )
          }
        }
        guard !Task.isCancelled, !self.terminalAdmissionClosed else { return }
        guard self.updateOpener(image) else {
          throw UpdateFailure.downloadFailed
        }
        guard !Task.isCancelled, !self.terminalAdmissionClosed else { return }
        self.updateStatus = SBMText.localized(
          "DMG authenticated by the SBM project publisher and opened")
        self.lastError = nil
      } catch {
        guard !Task.isCancelled, !self.terminalAdmissionClosed else { return }
        self.updateStatus = SBMText.localized("Update failed")
        self.lastError = error.localizedDescription
      }
    }
  }

  func enableHelper() {
    guard !terminalAdmissionClosed else { return }
    guard isInstalledInApplications else {
      lastError = SBMText.localized(
        "Move SBM.app to the Applications folder, eject the DMG, then open the installed copy."
      )
      return
    }
    if terminalColdOffClaim != nil {
      repairHelper()
      return
    }
    if helperService.registrationState == .requiresApproval {
      beginHelperApprovalFlow(openSystemSettings: true)
      return
    }
    guard helperRepairTask == nil else {
      return
    }
    invalidateRefresh()
    beginBusyOperation()
    helperSetupInProgress = true
    lastError = nil
    helperRepairTask = Task {
      defer {
        endBusyOperation()
        helperSetupInProgress = false
        helperRepairTask = nil
        if startupRestorePending && helperEnabled && !durableStopProofRequired {
          refresh()
        }
      }
      do {
        await runtimeMutationController.drainAcceptedWork()
        try Task.checkCancellation()
        let runtimeGeneration = runtimeMutationController.currentGeneration
        let response = try await upgradeLegacyHelper()
        try Task.checkCancellation()
        let compatible = apply(
          response,
          policy: .observation(
            runtimeCurrent: runtimeGeneration == runtimeMutationController.currentGeneration,
            adoptDesiredRuntime: runtimeGeneration == 0
          )
        )
        helperReachable = compatible
        if !response.success { lastError = SBMText.localized(response.message) }
        completeHelperApprovalFlow()
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
        lastError = SBMText.format("Background helper setup failed: %@", error.localizedDescription)
        refreshRegistrationStatus()
      }
    }
  }

  func repairHelper() {
    guard !terminalAdmissionClosed else { return }
    guard isInstalledInApplications else {
      lastError = SBMText.localized(
        "Move SBM.app to the Applications folder, eject the DMG, then open the installed copy."
      )
      return
    }
    if helperService.registrationState == .requiresApproval {
      beginHelperApprovalFlow(openSystemSettings: true)
      return
    }
    guard helperRepairTask == nil else {
      return
    }
    invalidateRefresh()
    beginBusyOperation()
    helperSetupInProgress = true
    helperReachable = false
    observedCoreState = .unknown
    lastError = nil

    helperRepairTask = Task {
      var coldOffClaim: ColdOffProof?
      var coldOffProved = false
      var runtimeGeneration = runtimeMutationController.currentGeneration
      defer {
        endBusyOperation()
        helperSetupInProgress = false
        helperRepairTask = nil
        if startupRestorePending && helperEnabled && !durableStopProofRequired {
          refresh()
        }
      }
      do {
        await runtimeMutationController.drainAcceptedWork()
        try Task.checkCancellation()
        runtimeGeneration = runtimeMutationController.currentGeneration
        if let existingClaim = terminalColdOffClaim,
          (try? existingClaim.requireOFFMarker()) != nil
        {
          coldOffClaim = existingClaim
          coldOffProved = true
        } else {
          terminalColdOffClaim?.release()
          terminalColdOffClaim = nil
        }
        if helperEnabled && !coldOffProved {
          let current: HelperResponse?
          do {
            current = try await helperLifecycleSender(HelperRequest(action: .status), 5)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            current = nil
          }
          if let current,
            current.protocolVersion == HelperConstants.protocolVersion,
            current.helperVersion == HelperConstants.helperVersion,
            current.helperRevision == HelperConstants.helperRevision
          {
            if current.legacy1115Retired == false, current.success, !current.coreRunning {
              guard runtimeGeneration == runtimeMutationController.currentGeneration else {
                throw CancellationError()
              }
              let retired = try await upgradeLegacyHelper()
              try Task.checkCancellation()
              let compatible = apply(
                retired,
                policy: .observation(
                  runtimeCurrent: runtimeGeneration == runtimeMutationController.currentGeneration,
                  adoptDesiredRuntime: runtimeGeneration == 0
                )
              )
              helperReachable = compatible
              if !retired.success { lastError = SBMText.localized(retired.message) }
              completeHelperApprovalFlow()
              return
            }
            if current.legacy1115Retired == true {
              let compatible = apply(
                current,
                policy: .observation(
                  runtimeCurrent: runtimeGeneration == runtimeMutationController.currentGeneration,
                  adoptDesiredRuntime: runtimeGeneration == 0
                )
              )
              helperReachable = compatible
              lastError = current.success ? nil : SBMText.localized(current.message)
              completeHelperApprovalFlow()
              return
            }
            guard current.legacy1115Retired == nil else {
              throw HelperLifecycleFailure.startupTimedOut(
                "The registered helper has no valid legacy-retirement receipt."
              )
            }
          }
        }
        try Task.checkCancellation()
        durableStopProofRequired = true
        if let coldOffClaim {
          try HelperClient.validateHeldColdOffClaim(
            bundleURL: applicationBundleURL,
            claim: coldOffClaim
          )
        } else {
          coldOffClaim = try HelperClient.acquireColdOffClaim(bundleURL: applicationBundleURL)
          terminalColdOffClaim = coldOffClaim
          coldOffProved = true
        }
        guard runtimeGeneration == runtimeMutationController.currentGeneration else {
          throw CancellationError()
        }
        coldOffProved = true
        durableStopProofRequired = false
        runtimeMutationController.desiredRunning = false
        observedCoreState = .stopped
        startupRestorePending = false
        runtimeGeneration = runtimeMutationController.currentGeneration
        try Task.checkCancellation()
        durableStopProofRequired = true
        var response = try await HelperLifecycle.replace(
          service: helperService,
          coldOffClaim: coldOffClaim,
          candidateBundleURL: applicationBundleURL
        ) {
          try await self.helperLifecycleSender(
            HelperRequest(action: .status),
            5
          )
        }
        if response.legacy1115Retired != true {
          response = try await upgradeLegacyHelper()
        }
        try Task.checkCancellation()
        let compatible = apply(
          response,
          policy: .observation(
            runtimeCurrent: runtimeGeneration == runtimeMutationController.currentGeneration,
            adoptDesiredRuntime: runtimeGeneration == 0
          )
        )
        helperReachable = compatible
        durableStopProofRequired = !(compatible && response.success && !response.coreRunning)
        terminalColdOffClaim = nil
        if !response.success { lastError = SBMText.localized(response.message) }
        completeHelperApprovalFlow()
      } catch HelperLifecycleFailure.approvalRequired,
        HelperLifecycleFailure.registrationDidNotFinish
      {
        if coldOffProved {
          _ = retainCurrentColdOffClaim(
            coldOffClaim,
            expectedGeneration: runtimeGeneration
          )
        }
        beginHelperApprovalFlow(openSystemSettings: true)
      } catch is CancellationError {
        refreshRegistrationStatus()
        if coldOffProved {
          _ = retainCurrentColdOffClaim(
            coldOffClaim,
            expectedGeneration: runtimeGeneration
          )
        }
      } catch {
        completeHelperApprovalFlow()
        helperReachable = false
        if coldOffProved {
          _ = retainCurrentColdOffClaim(
            coldOffClaim,
            expectedGeneration: runtimeGeneration
          )
        } else {
          observedCoreState = .unknown
        }
        lastError = SBMText.format(
          "Background helper repair failed: %@", error.localizedDescription)
        refreshRegistrationStatus()
      }
    }
  }

  private func retainCurrentColdOffClaim(
    _ claim: ColdOffProof?,
    expectedGeneration: UInt64
  ) -> Bool {
    guard expectedGeneration == runtimeMutationController.currentGeneration else { return false }

    var retainedClaim = claim
    if let claim {
      do {
        try claim.requireOFFMarker()
      } catch {
        claim.release()
        if terminalColdOffClaim === claim { terminalColdOffClaim = nil }
        retainedClaim = nil
      }
    }
    if retainedClaim == nil {
      do {
        retainedClaim = try ColdOffProof.acquireClaim()
      } catch {
        guard expectedGeneration == runtimeMutationController.currentGeneration else {
          return false
        }
        terminalColdOffClaim?.release()
        terminalColdOffClaim = nil
        durableStopProofRequired = true
        observedCoreState = .unknown
        return false
      }
    }

    guard expectedGeneration == runtimeMutationController.currentGeneration else {
      retainedClaim?.release()
      return false
    }
    terminalColdOffClaim = retainedClaim
    durableStopProofRequired = false
    runtimeMutationController.desiredRunning = false
    observedCoreState = .stopped
    startupRestorePending = false
    Self.lifecycleLogger.notice("Retained a validated held Cold OFF claim.")
    return true
  }

  func setLaunchAtLoginEnabled(_ enabled: Bool) {
    guard isInstalledInApplications else {
      launchAtLoginError = SBMText.localized(
        "Move SBM.app to the Applications folder, eject the DMG, then open the installed copy."
      )
      return
    }
    launchAtLoginError = nil
    Task {
      do {
        if enabled {
          try loginItemService.register()
        } else {
          try await loginItemService.unregister()
        }
      } catch {
        refreshLaunchAtLoginStatus()
        launchAtLoginError = boundedSettingsError(
          SBMText.localized("Launch at Login could not be changed"),
          error: error
        )
        return
      }
      refreshLaunchAtLoginStatus()
      guard launchAtLoginEnabled != enabled else { return }
      launchAtLoginError = SBMText.localized(
        enabled && loginItemService.status == .requiresApproval
          ? "Allow SBM to launch at login in System Settings."
          : "Launch at Login did not reach the requested state. Check System Settings."
      )
    }
  }

  func setRestoreLastVPNStateEnabled(_ enabled: Bool) {
    guard enabled != restoreLastVPNStateEnabled else { return }
    userDefaults.set(enabled, forKey: restoreLastVPNStateDefaultsKey)
    restoreLastVPNStateEnabled = enabled
    if !enabled { startupRestorePending = false }
  }

  func setCoreEnabled(_ enabled: Bool) {
    guard !terminalAdmissionClosed else { return }
    let reconnectingDisconnect = deferredRuntimeApplyPhase == .reconnecting && !enabled
    if deferredRuntimeApplyPhase == .reconnecting, enabled { return }
    guard
      reconnectingDisconnect
        || runtimeMutationController.desiredRunning != enabled
        || !runtimeMutationController.isApplying
    else { return }
    guard !enabled || selectedProfile?.payload != nil else {
      lastError = SBMText.localized(
        "Connect could not start because the selected profile is unavailable.")
      return
    }
    startupRestorePending = false
    userDefaults.set(enabled, forKey: lastExplicitVPNConnectedDefaultsKey)
    runtimeMutationController.desiredRunning = enabled
    if !enabled {
      if deferredRuntimeApplyPhase == .reconnecting { deferredRuntimeApplyPhase = .pending }
      profileRefreshTask?.cancel()
      cancelLatencyOperation()
    }
    if enabled {
      guard helperEnabled else {
        lastError = SBMText.localized("Enable the background helper before connecting.")
        return
      }
      guard currentHelperIsReady else {
        lastError = SBMText.localized("Update or repair the background helper before connecting.")
        return
      }
    } else {
      guard currentRegisteredHelperIsCompatible else {
        lastError =
          helperUpdateRequired
          ? AppModelFailure.helperRevisionMismatch.localizedDescription
          : AppModelFailure.helperNotReady.localizedDescription
        return
      }
    }
    let request: HelperRequest
    if enabled, let payload = selectedProfile?.payload {
      request = makeStartRequest(profile: payload, profileID: selectedProfileID)
    } else {
      request = HelperRequest(action: .stop, stopReason: .userDisconnect)
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
        SBMText.localized("Reconnect to Apply is unavailable"),
        error: AppModelFailure.helperNotReady
      )
      return
    }

    deferredRuntimeApplyPhase = .reconnecting
    deferredRuntimeApplyError = nil
    let wasRunning = observedCoreState == .running
    runtimeMutationController.desiredRunning =
      wasRunning || runtimeMutationController.desiredRunning == true
    if wasRunning {
      runtimeMutationController.desiredRunning = false
      submitRuntimeApply(
        HelperRequest(action: .stop, stopReason: .reconnectToApply),
        onCurrentResult: { [weak self] result in
          guard let self else { return }
          switch result {
          case .success(let response) where response.success && !response.coreRunning:
            self.runtimeMutationController.desiredRunning = true
            self.startLatestDeferredRuntime()
          case .success(let response):
            self.finishDeferredRuntimeReconnectFailure(
              SBMText.format(
                "Reconnect to Apply could not confirm that the VPN stopped: %@",
                response.message
              )
            )
          case .failure(let error):
            self.finishDeferredRuntimeReconnectFailure(
              SBMText.localized("Reconnect to Apply could not stop the VPN"),
              error: error
            )
          }
        },
        onSuperseded: { [weak self] in
          self?.finishDeferredRuntimeReconnectFailure(
            SBMText.localized("Reconnect to Apply was superseded by another runtime change.")
          )
        }
      )
    } else {
      runtimeMutationController.desiredRunning = true
      startLatestDeferredRuntime()
    }
  }

  private func startLatestDeferredRuntime() {
    guard deferredRuntimeApplyPhase == .reconnecting else { return }
    guard let payload = selectedProfile?.payload else {
      finishDeferredRuntimeReconnectFailure(
        SBMText.localized(
          "Reconnect to Apply could not start because the selected profile is unavailable."
        )
      )
      return
    }
    let request = makeStartRequest(profile: payload, profileID: selectedProfileID)
    submitRuntimeApply(
      request,
      onCurrentResult: { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let response)
        where response.success && response.coreRunning
          && response.runtimeOutcome == .applied:
          self.confirmDeferredRuntimeReconnect(basis: request)
        case .success(let response):
          self.finishDeferredRuntimeReconnectFailure(
            SBMText.format(
              "Reconnect to Apply could not activate the saved configuration: %@",
              response.message
            )
          )
        case .failure(let error):
          self.finishDeferredRuntimeReconnectFailure(
            SBMText.localized("Reconnect to Apply failed; the VPN remains disconnected"),
            error: error
          )
        }
      },
      onSuperseded: { [weak self] in
        self?.finishDeferredRuntimeReconnectFailure(
          SBMText.localized("Reconnect to Apply was superseded by another runtime change."),
        )
      },
      visibleProfileID: selectedProfileID
    )
  }

  private func confirmDeferredRuntimeReconnect(basis: HelperRequest) {
    guard !terminalAdmissionClosed else { return }
    let generation = runtimeMutationController.currentGeneration
    let previousTask = runtimeReadbackTask
    previousTask?.cancel()
    runtimeReadbackTask = Task { [weak self] in
      if let previousTask { await previousTask.value }
      guard let self else { return }
      defer {
        if !Task.isCancelled || self.terminalAdmissionClosed {
          self.runtimeReadbackTask = nil
        }
      }
      guard self.reconnectConfirmationIsCurrent(generation: generation) else { return }
      do {
        let response = try await runtimeStateReader()
        guard self.reconnectConfirmationIsCurrent(generation: generation) else { return }
        guard response.protocolVersion == HelperConstants.protocolVersion,
          response.helperVersion == HelperConstants.helperVersion,
          response.helperRevision == HelperConstants.helperRevision
        else {
          self.finishDeferredRuntimeReconnectFailure(
            SBMText.localized(
              "Reconnect to Apply completed, but helper status is from an older helper."
            )
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
            SBMText.localized(
              "Reconnect to Apply completed, but authoritative helper status did not confirm the saved configuration."
            )
          )
          return
        }
        guard self.reconnectStartStillMatchesDesiredState(basis) else {
          self.deferredRuntimeApplyPending = true
          self.deferredRuntimeApplyPhase = .pending
          self.runtimeApplyStatus = .reconnectRequired
          return
        }
        self.deferredRuntimeApplyPending = false
        self.deferredRuntimeApplyPhase = .idle
        self.deferredRuntimeApplyError = nil
        self.clearDeferredRuntimePendingPresentations()
        self.runtimeMutationController.desiredRunning = true
        self.runtimeApplyStatus = .active
        self.runtimeFailurePreservedPrevious = false
        self.runtimeFailureProfileID = nil
        self.lastError = nil
      } catch {
        guard self.reconnectConfirmationIsCurrent(generation: generation) else { return }
        self.finishDeferredRuntimeReconnectFailure(
          SBMText.localized(
            "Reconnect to Apply completed, but authoritative helper status could not be read"
          ),
          error: error
        )
      }
    }
  }

  private func reconnectConfirmationIsCurrent(generation: UInt64) -> Bool {
    !terminalAdmissionClosed && !Task.isCancelled
      && generation == runtimeMutationController.currentGeneration
      && deferredRuntimeApplyPhase == .reconnecting
  }

  private func reconnectStartStillMatchesDesiredState(_ basis: HelperRequest) -> Bool {
    guard let profileID = selectedProfileID, let payload = selectedProfile?.payload else {
      return false
    }
    let current = makeStartRequest(profile: payload, profileID: profileID)
    return basis.profileID == current.profileID
      && basis.profile == current.profile
      && basis.mode == current.mode
      && basis.node == current.node
      && basis.localSOCKSEnabled == current.localSOCKSEnabled
      && basis.localSOCKSPort == current.localSOCKSPort
      && basis.latencyTestURL == current.latencyTestURL
      && basis.ipv6Enabled == current.ipv6Enabled
      && basis.dnsSettings == current.dnsSettings
  }

  private func finishDeferredRuntimeReconnectFailure(
    _ prefix: String,
    error: (any Error)? = nil
  ) {
    guard deferredRuntimeApplyPhase == .reconnecting else { return }
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
    runtimeMutationController.desiredRunning = observedCoreState == .running ? true : false
  }

  func disconnectBeforeQuit() async -> Bool {
    guard !terminalAdmissionClosed else { return false }
    let previousDesiredRunning = runtimeMutationController.desiredRunning
    let interruptedLatencySync = latencySyncTask != nil
    terminalAdmissionClosed = true
    startupRestorePending = false
    runtimeMutationController.desiredRunning = false
    await cancelAndDrainAcceptedWork()

    let registrationState = helperService.registrationState
    let legacyRegistrationState = helperService.legacyRegistrationState
    let legacyRegistrationIsAbsent =
      legacyRegistrationState == .notRegistered || legacyRegistrationState == .notFound
    let noCurrentHelperWasObserved =
      registrationState == .notRegistered || registrationState == .notFound
    if noCurrentHelperWasObserved, legacyRegistrationIsAbsent,
      !runtimeMutationController.isApplying
    {
      if !durableStopProofRequired {
        if let claim = terminalColdOffClaim {
          if retainCurrentColdOffClaim(
            claim,
            expectedGeneration: runtimeMutationController.currentGeneration
          ) {
            subscriptionRefreshTask?.cancel()
            return true
          }
        } else {
          subscriptionRefreshTask?.cancel()
          return true
        }
      }
    }

    var shutdownGeneration = runtimeMutationController.currentGeneration
    let result = await withCheckedContinuation { continuation in
      shutdownGeneration =
        submitRuntimeApply(
          HelperRequest(action: .shutdown, stopReason: .appTermination),
          onCurrentResult: { continuation.resume(returning: $0) },
          onSuperseded: {
            continuation.resume(
              returning: .failure(AppModelFailure.runtimeMutationSuperseded)
            )
          }
        ) ?? shutdownGeneration
    }
    switch result {
    case .success(let response) where response.success && !response.coreRunning:
      durableStopProofRequired = false
      observedCoreState = .stopped
      lastError = nil
      subscriptionRefreshTask?.cancel()
      return true
    case .success(let response):
      lastError =
        SBMText.localized("Unable to disconnect before quitting: ")
        + AppModelFailure.coreStopFailed(response.message).localizedDescription
    case .failure(let error):
      lastError = SBMText.format(
        "Unable to disconnect before quitting: %@", error.localizedDescription)
    }

    Self.lifecycleLogger.error(
      "Terminal Shutdown did not prove OFF; checking for a fresh Cold OFF claim."
    )
    if let claim = terminalColdOffClaim,
      retainCurrentColdOffClaim(
        claim,
        expectedGeneration: shutdownGeneration
      )
    {
      lastError = nil
      subscriptionRefreshTask?.cancel()
      return true
    }
    do {
      let claim = try ColdOffProof.acquireClaim()
      terminalColdOffClaim?.release()
      terminalColdOffClaim = claim
      durableStopProofRequired = false
      observedCoreState = .stopped
      lastError = nil
      subscriptionRefreshTask?.cancel()
      return true
    } catch {
      durableStopProofRequired = true
      lastError = SBMText.format(
        "Unable to disconnect before quitting: %@", error.localizedDescription)
    }
    if shutdownGeneration == runtimeMutationController.currentGeneration,
      runtimeMutationController.desiredRunning == false
    {
      runtimeMutationController.desiredRunning = previousDesiredRunning
    }
    if interruptedLatencySync { markLatencySynchronizationPending(showAsLastError: false) }
    reopenTerminalAdmission()
    return false
  }

  private func cancelAndDrainAcceptedWork() async {
    let statusTask = statusRefreshTask
    let syncTask = sourceSyncTask
    let refreshTask = profileRefreshTask
    let repairTask = helperRepairTask
    let approvalTask = helperApprovalPollTask
    let readbackTask = runtimeReadbackTask
    let latencySyncTask = self.latencySyncTask
    let latencyTask = latencyOperationTask
    let updateTask = updateOperationTask
    let routingTasks = Array(routingMutationQueues.values)

    statusTask?.cancel()
    syncTask?.cancel()
    refreshTask?.cancel()
    repairTask?.cancel()
    approvalTask?.cancel()
    readbackTask?.cancel()
    latencySyncTask?.cancel()
    updateTask?.cancel()
    for task in routingTasks { task.cancel() }
    cancelLatencyOperation()

    if let statusTask { await statusTask.value }
    if let syncTask { await syncTask.value }
    if let refreshTask { await refreshTask.value }
    if let repairTask { await repairTask.value }
    if let approvalTask { await approvalTask.value }
    if let readbackTask { await readbackTask.value }
    if let latencySyncTask { await latencySyncTask.value }
    for task in routingTasks { await task.value }
    if let latencyTask { await latencyTask.value }
    if let updateTask { await updateTask.value }
  }

  private func reopenTerminalAdmission() {
    terminalAdmissionClosed = false
    terminalColdOffClaim?.release()
    terminalColdOffClaim = nil
    if deferredRuntimeApplyPhase == .reconnecting {
      deferredRuntimeApplyPending = true
      deferredRuntimeApplyPhase = .pending
      runtimeApplyStatus = .reconnectRequired
    }
    if helperApprovalPending { startHelperApprovalPolling() }
    if coreRunning {
      startRuntimeLivenessPolling()
      scheduleNextLatencyRefresh()
    }
  }

  func setRoutingMode(_ mode: RoutingMode) {
    guard mode != routingMode else { return }
    do {
      try persistProfileLibrary(routingMode: mode)
    } catch {
      _ = setSettingsError(SBMText.localized("Routing mode was not saved"), error: error)
      return
    }
    routingMode = mode
    guard deferredRuntimeApplyPhase != .reconnecting else { return }
    guard runtimeMutationController.desiredRunning != false else {
      if !runtimeMutationController.isApplying {
        runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
      }
      return
    }
    if runtimeMutationController.isApplying {
      applyCurrentDesiredRuntimeIfNeeded()
    } else {
      submitRuntimeApply(HelperRequest(action: .setMode, mode: mode))
    }
  }

  func setSelectedNode(_ node: ProxyNodeID) {
    guard node != selectedNodeID else { return }
    do {
      try persistProfileLibrary(selectedNodeID: node)
    } catch {
      _ = setSettingsError(SBMText.localized("Selected node was not saved"), error: error)
      return
    }
    selectedNodeID = node
    guard deferredRuntimeApplyPhase != .reconnecting else { return }
    guard runtimeMutationController.desiredRunning != false else {
      if !runtimeMutationController.isApplying {
        runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
      }
      return
    }
    if coreRunning, helperActiveProfileID != selectedProfileID {
      deferredRuntimeApplyPending = true
      deferredRuntimeApplyPhase = .pending
      deferredRuntimeApplyError = nil
      if !runtimeMutationController.isApplying {
        runtimeApplyStatus = .reconnectRequired
      }
      return
    }
    if runtimeMutationController.isApplying {
      applyCurrentDesiredRuntimeIfNeeded()
    } else {
      submitRuntimeApply(HelperRequest(action: .setNode, node: node))
    }
  }

  private func installMenuTrackingObservers() {
    let center = NotificationCenter.default
    menuTrackingObservers = [
      center.addObserver(
        forName: NSMenu.didBeginTrackingNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.latencyPublicationCoordinator.beginMenuTracking()
        }
      },
      center.addObserver(
        forName: NSMenu.didEndTrackingNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self,
            let publication = self.latencyPublicationCoordinator.endMenuTracking()
          else { return }
          publishLatencyIfCurrent(publication)
        }
      },
    ]
  }

  func testLatency() {
    guard !terminalAdmissionClosed else { return }
    guard currentHelperIsReady else {
      lastError = SBMText.localized(
        "Update or repair the background helper before testing latency.")
      return
    }
    guard coreRunning else {
      lastError = SBMText.localized("Connect the VPN before testing latency.")
      return
    }
    guard helperActiveProfileID == selectedProfileID else {
      lastError = SBMText.localized(
        "Disconnect and reconnect before testing latency for the selected profile."
      )
      return
    }
    guard latencyOperationTask == nil else { return }
    lastLatencyTestAt = Date()
    latencyTestInProgress = true
    latencyOperationGeneration &+= 1
    let generation = latencyOperationGeneration
    let profileID = selectedProfileID
    let activeProfileID = helperActiveProfileID
    let runtimeGeneration = runtimeMutationController.currentGeneration
    let requestedNodes = nodes.map(\.id).filter { $0 != .auto }
    latencyOperationTask = Task {
      defer {
        if generation == latencyOperationGeneration {
          latencyTestInProgress = false
          latencyOperationTask = nil
          scheduleNextLatencyRefresh()
        }
      }
      do {
        for node in requestedNodes {
          try Task.checkCancellation()
          let response = try await latencySender(node)
          try Task.checkCancellation()
          guard response.protocolVersion == HelperConstants.protocolVersion,
            response.helperVersion == HelperConstants.helperVersion,
            response.helperRevision == HelperConstants.helperRevision
          else {
            throw AppModelFailure.helperRevisionMismatch
          }
          guard generation == latencyOperationGeneration,
            selectedProfileID == profileID,
            helperActiveProfileID == activeProfileID,
            runtimeMutationController.currentGeneration == runtimeGeneration
          else { return }
        }
        try await Task.sleep(for: latencySettleDelay)
        try Task.checkCancellation()
        let response = try await latencySender(nil)
        try Task.checkCancellation()
        guard response.protocolVersion == HelperConstants.protocolVersion,
          response.helperVersion == HelperConstants.helperVersion,
          response.helperRevision == HelperConstants.helperRevision
        else {
          throw AppModelFailure.helperRevisionMismatch
        }
        guard generation == latencyOperationGeneration,
          selectedProfileID == profileID,
          helperActiveProfileID == activeProfileID,
          runtimeMutationController.currentGeneration == runtimeGeneration
        else { return }
        let publication = LatencyPublication(
          response: response,
          profileID: profileID,
          activeProfileID: activeProfileID,
          operationGeneration: generation,
          runtimeGeneration: runtimeGeneration
        )
        if let publication = latencyPublicationCoordinator.submit(publication) {
          publishLatencyIfCurrent(publication)
        }
      } catch is CancellationError {
        return
      } catch {
        guard generation == latencyOperationGeneration,
          selectedProfileID == profileID,
          helperActiveProfileID == activeProfileID,
          runtimeMutationController.currentGeneration == runtimeGeneration
        else { return }
        helperReachable = false
        observedCoreState = .unknown
        lastError = error.localizedDescription
      }
    }
  }

  private func publishLatencyIfCurrent(_ publication: LatencyPublication) {
    guard publication.profileID == selectedProfileID,
      publication.activeProfileID == helperActiveProfileID,
      publication.operationGeneration == latencyOperationGeneration,
      publication.runtimeGeneration == runtimeMutationController.currentGeneration
    else { return }
    publishLatency(publication)
  }

  private func publishLatency(_ publication: LatencyPublication) {
    apply(
      publication.response,
      policy: .observation(runtimeCurrent: true, adoptDesiredRuntime: false),
      updateNodeDescriptors: false
    )
    var delaysByID: [ProxyNodeID: NodeDelay] = [:]
    for delay in publication.response.delays {
      delaysByID[delay.node] = delay
    }
    let updatedNodes = nodes.map { node in
      guard let delay = delaysByID[node.id] else { return node }
      var updated = node
      updated.delay = delay.milliseconds
      return updated
    }
    nodes = updatedNodes
    latencyTestCompleted = publication.response.success
    if publication.response.success { lastError = nil }
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

  @discardableResult
  func applyLatencySettings() -> Bool {
    guard latencySettingsValid else {
      let message = SBMText.localized("Choose a positive interval and a valid HTTPS target.")
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
        SBMText.localized("Latency settings were not saved"),
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
      markLatencySynchronizationPending()
    }
    return true
  }

  func retryLatencySynchronization() {
    guard canRetryLatencySynchronization else { return }
    guard currentHelperIsReady else {
      let message = SBMText.localized("Background helper is not ready; retry after it is enabled.")
      latencySettingsIssue = .runtimeSynchronization(message)
      lastError = message
      return
    }
    synchronizeLatencyTarget(latencyTestURL)
  }

  /// Discard only the closed Settings window's editor state. Saved work stays owned by the model.
  func endSettingsEditing() {
    var editorErrors = [profileNameError, sourceEditorError]
    if case .validation(let message) = latencySettingsIssue {
      editorErrors.append(message)
      latencySettingsIssue = nil
    }
    if case .validation(let message) = localSOCKSIssue {
      editorErrors.append(message)
      localSOCKSIssue = nil
    }
    if let lastError, editorErrors.contains(lastError) { self.lastError = nil }
    clearStaleDNSValidationError(for: dnsSettings)
    loadSelectedProfileEditor()
    localSOCKSEnabledDraft = localSOCKSEnabled
    localSOCKSPortDraft = localSOCKSPort
    latencyIntervalMinutesDraft = latencyIntervalMinutes
    latencyTestURLDraft = latencyTestURL
    cancelWebsiteRoutingEdit()
    websiteRoutingTarget = .selectedProxy
    routingInspectorInput = ""
    routingInspectorApplicationID = nil
    invalidateRoutingInspector()
  }

  func resetLatencySettings() {
    latencyIntervalMinutesDraft = 10
    latencyTestURLDraft = LatencyTargetPolicy.defaultURL
  }

  @discardableResult
  func applyLocalSOCKSSettings() -> Bool {
    guard localSOCKSSettingsValid else {
      let message = SBMText.localized(
        "Choose a local SOCKS5 port from 1024 to 65535, except 19090."
      )
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
        SBMText.localized("Local SOCKS5 settings were not saved"),
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
    applyCurrentDesiredRuntimeIfNeeded(
      onCurrentResult: { [weak self] result in
        guard let self else { return }
        self.localSOCKSApplyInProgress = false
        if case .failure(let error) = result {
          let message = self.setSettingsError(
            SBMText.localized("Local SOCKS5 runtime synchronization failed"),
            error: error
          )
          self.localSOCKSIssue = .runtimeSynchronization(message)
        } else {
          self.localSOCKSIssue = nil
        }
      },
      onSuperseded: { [weak self] in
        self?.localSOCKSApplyInProgress = false
      }
    )
    return true
  }

  func setIPv6Enabled(_ enabled: Bool) {
    guard ipv6Enabled != enabled else { return }
    do {
      try persistProfileLibrary(ipv6Enabled: enabled)
    } catch {
      _ = setSettingsError(SBMText.localized("IPv6 setting was not saved"), error: error)
      return
    }
    ipv6Enabled = enabled
    guard shouldApplyDesiredRuntime else {
      if !runtimeMutationController.isApplying {
        runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
      }
      lastError = nil
      return
    }
    applyCurrentDesiredRuntimeIfNeeded()
  }

  func saveDNSSettings(_ proposed: ManagedDNSSettings) -> Bool {
    guard let settings = try? proposed.validated() else {
      lastError = SBMText.localized("DNS settings are invalid")
      return false
    }
    if lastError == SBMText.localized("DNS settings are invalid") { lastError = nil }
    guard settings != dnsSettings else { return true }
    do {
      try persistProfileLibrary(dnsSettings: settings)
    } catch {
      _ = setSettingsError(SBMText.localized("DNS settings were not saved"), error: error)
      return false
    }
    dnsSettings = settings
    lastError = nil
    guard shouldApplyDesiredRuntime else {
      if !runtimeMutationController.isApplying {
        runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
      }
      return true
    }
    applyCurrentDesiredRuntimeIfNeeded()
    return true
  }

  func clearStaleDNSValidationError(for proposed: ManagedDNSSettings) {
    guard (try? proposed.validated()) != nil,
      lastError == SBMText.localized("DNS settings are invalid")
    else { return }
    lastError = nil
  }

  func retryLocalSOCKSSynchronization() {
    guard canRetryLocalSOCKSSynchronization, shouldApplyDesiredRuntime else { return }
    localSOCKSApplyInProgress = true
    applyCurrentDesiredRuntimeIfNeeded(
      onCurrentResult: { [weak self] result in
        guard let self else { return }
        self.localSOCKSApplyInProgress = false
        if case .failure(let error) = result {
          let message = self.setSettingsError(
            SBMText.localized("Local SOCKS5 runtime synchronization failed"),
            error: error
          )
          self.localSOCKSIssue = .runtimeSynchronization(message)
        } else {
          self.localSOCKSIssue = nil
        }
      },
      onSuperseded: { [weak self] in
        self?.localSOCKSApplyInProgress = false
      }
    )
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
      profileNameError = SBMText.localized("Profile name is empty or invalid.")
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
      setSubscriptionStatus(SBMText.localized("Profile name saved"), level: .success)
      profileNameError = nil
      lastError = nil
    } catch {
      profileNameError = setSettingsError(
        SBMText.localized("Profile name was not saved"), error: error
      )
    }
  }

  func addSource() {
    guard canManageSources, let selectedProfileID,
      let profileIndex = profiles.firstIndex(where: { $0.id == selectedProfileID })
    else { return }
    let source = ManagedSource(
      name: SBMText.format("Subscription %@", String(profiles[profileIndex].sources.count + 1))
    )
    let previousSelection = selectedSourceID
    profiles[profileIndex].sources.append(source)
    selectedSourceID = source.id
    loadSelectedSourceEditor()
    setSubscriptionStatus(SBMText.localized("Enter a subscription URL or connection link"))
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

  func deleteSelectedSource(profileID: UUID, sourceID: UUID) {
    guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
      let sourceIndex = profiles[profileIndex].sources.firstIndex(where: {
        $0.id == sourceID
      })
    else { return }

    let previous = profiles
    let selectedProfileIsTarget = selectedProfileID == profileID
    let selectedSourceIsTarget = selectedProfileIsTarget && selectedSourceID == sourceID
    profiles[profileIndex].sources.remove(at: sourceIndex)
    do {
      try rebuildCompatibilityPayload(at: profileIndex)
      if selectedSourceIsTarget {
        selectedSourceID = profiles[profileIndex].sources.first?.id
        loadSelectedSourceEditor()
      }
      try persistProfileLibrary()
      startSubscriptionRefreshLoop()
      if selectedProfileIsTarget {
        updateNodes()
        profileAvailable = profiles[profileIndex].payload != nil
        let status =
          profileAvailable
          ? SBMText.localized("Source removed")
          : SBMText.localized("No sources synced")
        setSubscriptionStatus(status, level: profileAvailable ? .success : .neutral)
      }
      lastError = nil
      if selectedProfileIsTarget { applyCurrentDesiredRuntimeIfNeeded() }
    } catch {
      profiles = previous
      if selectedProfileIsTarget {
        loadSelectedProfileEditor()
        updateNodes()
      }
      lastError = error.localizedDescription
    }
  }

  func selectSource(_ id: UUID) {
    guard selectedProfileSources.contains(where: { $0.id == id }) else { return }
    selectedSourceID = id
    loadSelectedSourceEditor()
  }

  func resetSubscriptionRequestPreset() {
    let reset = SubscriptionHeaders(hardwareID: subscriptionHWID).resettingRequestPreset()
    subscriptionUserAgent = reset.userAgent
    subscriptionAppVersion = reset.appVersion ?? ""
    subscriptionDeviceOS = reset.deviceOS
    subscriptionDeviceOSVersion = reset.deviceOSVersion ?? ""
    subscriptionDeviceModel = reset.deviceModel ?? ""
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

  func importRoutingPolicy(from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    guard let selectedProfileID,
      let initialIndex = profiles.firstIndex(where: { $0.id == selectedProfileID }),
      profiles[initialIndex].payload != nil
    else {
      lastError = SBMText.localized(
        "Sync a Reality + Hysteria2 subscription before importing routing."
      )
      return
    }
    let result = Result { try RoutingPolicyParser.parse(contentsOf: url) }
    beginSyncingOperation()
    Task {
      do {
        let policy = try result.get()
        enqueueRoutingMutation(
          profileID: selectedProfileID,
          kind: .policy,
          successMessage: SBMText.localized("Routing policy saved"),
          operation: { payload in
            let current: VPNProfile
            switch payload {
            case .compatibility(let profile): current = profile
            }
            return .compatibility(
              VPNProfile(
                connections: current.connections,
                routingPolicy: policy,
                nodeGroups: current.nodeGroups ?? [],
                applicationRoutingRules: current.applicationRoutingRules,
                websiteRoutingRules: current.websiteRoutingRules,
                autoExcludedNodeIDs: current.autoExcludedNodeIDs
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
      let profile = profiles.first(where: { $0.id == selectedProfileID }),
      case .compatibility(let current) = profile.payload,
      current.routingPolicy != nil
    else { return }
    enqueueRoutingMutation(
      profileID: selectedProfileID,
      kind: .policy,
      successMessage: SBMText.localized("Routing policy removed"),
      operation: { payload in
        guard case .compatibility(let current) = payload,
          current.routingPolicy != nil
        else {
          throw RoutingMutationFailure.profileChanged(
            self.staleRoutingMutationMessage(for: .policy)
          )
        }
        return .compatibility(
          VPNProfile(
            connections: current.connections,
            routingPolicy: nil,
            nodeGroups: current.nodeGroups ?? [],
            applicationRoutingRules: current.applicationRoutingRules,
            websiteRoutingRules: current.websiteRoutingRules,
            autoExcludedNodeIDs: current.autoExcludedNodeIDs
          )
        )
      }
    )
  }

  func addProfile() {
    let previousProfiles = profiles
    let previousSelection = selectedProfileID
    let previousProfileAvailable = profileAvailable
    let previousStatus = subscriptionStatus
    let previousStatusLevel = subscriptionStatusLevel
    let profile = ManagedProfile(
      name: SBMText.localized("New Profile"),
      sources: [ManagedSource(name: SBMText.localized("Subscription"))]
    )
    profiles.append(profile)
    selectedProfileID = profile.id
    loadSelectedProfileEditor()
    updateNodes()
    profileAvailable = false
    setSubscriptionStatus(SBMText.localized("Enter a subscription URL or connection link"))
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

  func deleteSelectedProfile(profileID: UUID) {
    guard let index = profiles.firstIndex(where: { $0.id == profileID })
    else { return }
    let previous = (
      profiles: profiles, profileID: selectedProfileID, nodeID: selectedNodeID,
      sourceID: selectedSourceID, available: profileAvailable, status: subscriptionStatus,
      level: subscriptionStatusLevel
    )
    func restore(
      _ snapshot: (
        profiles: [ManagedProfile], profileID: UUID?, nodeID: ProxyNodeID, sourceID: UUID?,
        available: Bool, status: String, level: SubscriptionStatusLevel
      ),
      on model: AppModel
    ) {
      (model.profiles, model.selectedProfileID, model.selectedNodeID, model.selectedSourceID) =
        (snapshot.profiles, snapshot.profileID, snapshot.nodeID, snapshot.sourceID)
      model.loadSelectedProfileEditor()
      model.updateNodes()
      model.profileAvailable = snapshot.available
      model.setSubscriptionStatus(snapshot.status, level: snapshot.level)
    }
    let deletedSelectedProfile = previous.profileID == profileID
    profiles.remove(at: index)
    self.selectedProfileID = deletedSelectedProfile ? profiles.first?.id : previous.profileID
    if deletedSelectedProfile {
      loadSelectedProfileEditor()
      updateNodes()
      profileAvailable = selectedProfile?.payload != nil
      setSubscriptionStatus(
        profileAvailable ? SBMText.localized("Ready") : SBMText.localized("No subscription synced"),
        level: profileAvailable ? .success : .neutral
      )
    }
    do {
      try persistProfileLibrary()
    } catch {
      profiles = previous.profiles
      if deletedSelectedProfile {
        restore(previous, on: self)
      }
      lastError = error.localizedDescription
      return
    }
    discardRoutingMutationState(for: profileID)
    startSubscriptionRefreshLoop()
    guard deletedSelectedProfile else { return }
    let committed = (
      profiles: profiles, profileID: self.selectedProfileID, nodeID: selectedNodeID,
      sourceID: selectedSourceID, available: profileAvailable, status: subscriptionStatus,
      level: subscriptionStatusLevel
    )
    let committedEditor = [
      profileName, profileNameError, sourceName, sourceEditorError, sourceExcludeRegex,
      subscriptionURL, subscriptionUserAgent, subscriptionAppVersion, subscriptionDeviceOS,
      subscriptionDeviceOSVersion, subscriptionDeviceModel, subscriptionHWID,
    ]
    guard shouldApplyDesiredRuntime else {
      runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
      return
    }
    applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
      guard let self, case .failure(let error) = result else { return }
      guard self.profiles == committed.profiles,
        self.selectedProfileID == committed.profileID,
        self.selectedNodeID == committed.nodeID,
        self.selectedSourceID == committed.sourceID,
        self.profileAvailable == committed.available,
        self.subscriptionStatus == committed.status,
        self.subscriptionStatusLevel == committed.level,
        [
          self.profileName, self.profileNameError, self.sourceName, self.sourceEditorError,
          self.sourceExcludeRegex, self.subscriptionURL, self.subscriptionUserAgent,
          self.subscriptionAppVersion, self.subscriptionDeviceOS,
          self.subscriptionDeviceOSVersion, self.subscriptionDeviceModel, self.subscriptionHWID,
        ] == committedEditor
      else {
        self.lastError = error.localizedDescription
        return
      }
      restore(previous, on: self)
      do {
        try self.persistProfileLibrary()
        self.startSubscriptionRefreshLoop()
        self.lastError = error.localizedDescription
      } catch let persistenceError {
        restore(committed, on: self)
        self.lastError =
          "\(error.localizedDescription) Rollback could not be saved: "
          + persistenceError.localizedDescription
      }
    }
  }

  func selectProfile(_ id: UUID) {
    guard id != selectedProfileID, profiles.contains(where: { $0.id == id }) else { return }
    let previous = (
      profileID: selectedProfileID, nodeID: selectedNodeID, available: profileAvailable,
      status: subscriptionStatus, level: subscriptionStatusLevel
    )
    func restore(
      _ snapshot: (
        profileID: UUID?, nodeID: ProxyNodeID, available: Bool, status: String,
        level: SubscriptionStatusLevel
      ),
      on model: AppModel
    ) {
      (model.selectedProfileID, model.selectedNodeID) = (snapshot.profileID, snapshot.nodeID)
      model.loadSelectedProfileEditor()
      model.updateNodes()
      model.profileAvailable = snapshot.available
      model.setSubscriptionStatus(snapshot.status, level: snapshot.level)
    }
    selectedProfileID = id
    websiteRoutingInput = ""
    websiteRoutingEditingRuleID = nil
    loadSelectedProfileEditor()
    updateNodes()
    profileAvailable = selectedProfile?.payload != nil
    setSubscriptionStatus(
      profileAvailable ? SBMText.localized("Ready") : SBMText.localized("Not synced"),
      level: profileAvailable ? .success : .neutral
    )
    do {
      try persistProfileLibrary()
      lastError = nil
    } catch {
      restore(previous, on: self)
      lastError = error.localizedDescription
      return
    }

    let committed = (
      profileID: selectedProfileID, nodeID: selectedNodeID, available: profileAvailable,
      status: subscriptionStatus, level: subscriptionStatusLevel
    )
    if shouldApplyDesiredRuntime {
      applyCurrentDesiredRuntimeIfNeeded { [weak self] result in
        guard let self, case .failure(let error) = result else { return }
        guard self.selectedProfileID == committed.profileID else {
          self.lastError = error.localizedDescription
          return
        }
        restore(previous, on: self)
        do {
          try self.persistProfileLibrary()
          self.lastError = error.localizedDescription
        } catch let persistenceError {
          restore(committed, on: self)
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
    guard !terminalAdmissionClosed, sourceSyncTask == nil else { return }
    sourceEditorError = nil
    let value: String
    let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let appVersion = subscriptionAppVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    let deviceOSVersion = subscriptionDeviceOSVersion.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let deviceModel = subscriptionDeviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let headers = SubscriptionHeaders(
      userAgent: subscriptionUserAgent.trimmingCharacters(in: .whitespacesAndNewlines),
      appVersion: appVersion.isEmpty ? nil : appVersion,
      deviceOS: subscriptionDeviceOS.trimmingCharacters(in: .whitespacesAndNewlines),
      deviceOSVersion: deviceOSVersion.isEmpty ? nil : deviceOSVersion,
      deviceModel: deviceModel.isEmpty ? nil : deviceModel,
      hardwareID: subscriptionHWID.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    guard let targetProfileID = selectedProfileID,
      let targetSourceID = selectedSourceID,
      let profileIndex = profiles.firstIndex(where: { $0.id == targetProfileID }),
      let sourceIndex = profiles[profileIndex].sources.firstIndex(where: {
        $0.id == targetSourceID
      })
    else {
      sourceEditorError = SBMText.localized("Add a subscription source first.")
      lastError = sourceEditorError
      return
    }
    do {
      value = try SubscriptionClient.validateSourceValue(subscriptionURL)
      try SubscriptionClient.validate(headers: headers)
      let effectiveName = try SubscriptionClient.validateDisplayName(
        name.isEmpty ? SBMText.localized("Subscription") : name
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
        SBMText.localized("Save and Sync did not save the source"),
        error: error,
        additionalSecrets: [subscriptionURL, subscriptionHWID]
      )
      return
    }
    sourceEditorError = nil
    guard !value.isEmpty else {
      setSubscriptionStatus(
        profiles[profileIndex].payload == nil
          ? SBMText.localized("Enter a source") : SBMText.localized("Saved"),
        level: profiles[profileIndex].payload == nil ? .neutral : .success
      )
      return
    }
    beginSyncingOperation()
    setSubscriptionStatus(SBMText.localized("Syncing…"))
    let sourceToSync = profiles[profileIndex].sources[sourceIndex]
    sourceSyncTask = Task {
      defer {
        endSyncingOperation()
        sourceSyncTask = nil
      }
      do {
        let result = try await subscriptionManager.synchronize(sourceToSync)
        try Task.checkCancellation()
        let fetched = ManagedConnectionReconciler.reconcile(
          existing: sourceToSync.payload,
          fetched: result.profile
        )
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
        let effectiveProfile: VPNProfile
        switch effective {
        case .compatibility(let profile): effectiveProfile = profile
        }
        try await validateProfile(effective)
        try Task.checkCancellation()
        guard try commitProfileUpdate(expected: currentProfile, updated: updatedProfile) else {
          throw AppModelFailure.staleProfileOperation
        }
        if selectedProfileID == targetProfileID {
          profileAvailable = selectedProfile?.payload != nil
          updateNodes()
        }
        if selectedProfileID == targetProfileID, shouldApplyDesiredRuntime,
          ManagedConnectionReconciler.requiresActivation(
            previous: currentProfile.payload,
            next: effective
          )
        {
          presentSubscriptionStatus(
            SBMText.localized("Sources updated; applying"), level: .neutral,
            profileID: targetProfileID, sourceID: targetSourceID
          )
          applyCurrentDesiredRuntimeIfNeeded(
            onCurrentResult: { [weak self] applyResult in
              guard let self else { return }
              switch applyResult {
              case .success(let response):
                let successMessage =
                  response.runtimeOutcome == .reconnectRequired
                  ? "Sources updated and saved" : "Sources updated and active"
                self.presentSubscriptionStatus(
                  result.warningDescription ?? SBMText.localized(successMessage),
                  level: result.warningDescription == nil ? .success : .warning,
                  profileID: targetProfileID, sourceID: targetSourceID
                )
              case .failure(let error):
                self.rollbackProfileUpdate(
                  profileID: targetProfileID,
                  committed: updatedProfile,
                  previous: currentProfile,
                  originalError: error,
                  visibleProfileID: targetProfileID,
                  visibleSourceID: targetSourceID
                )
                if self.selectedProfileID == targetProfileID {
                  if self.selectedSourceID == targetSourceID { self.loadSelectedProfileEditor() }
                  self.updateNodes()
                  self.profileAvailable = self.selectedProfile?.payload != nil
                }
                self.presentSubscriptionStatus(
                  SBMText.localized("Source apply failed"), level: .warning,
                  profileID: targetProfileID, sourceID: targetSourceID
                )
              }
            },
            visibleProfileID: targetProfileID, visibleSourceID: targetSourceID
          )
        } else if selectedProfileID == targetProfileID && selectedSourceID == targetSourceID {
          let message =
            result.warningDescription
            ?? SBMText.format("%@ ready", profileSummary(effectiveProfile))
          presentSubscriptionStatus(
            message, level: result.warningDescription == nil ? .success : .warning,
            profileID: targetProfileID, sourceID: targetSourceID
          )
        }
        if selectedProfileID == targetProfileID, selectedSourceID == targetSourceID,
          runtimeApplyStatus != .failed
        {
          lastError = nil
        }
      } catch is CancellationError {
        return
      } catch {
        guard selectedProfileID == targetProfileID,
          selectedSourceID == targetSourceID
        else { return }
        setSubscriptionStatus(
          profileAvailable
            ? SBMText.localized("Using cached sources; sync failed")
            : SBMText.localized("Sync failed"),
          level: .warning
        )
        sourceEditorError = setSettingsError(
          SBMText.localized("Save and Sync failed"),
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
    visibleProfileID: UUID? = nil,
    visibleSourceID: UUID? = nil
  ) {
    func present(_ message: String) {
      guard
        (visibleProfileID == nil || selectedProfileID == visibleProfileID)
          && (visibleSourceID == nil || selectedSourceID == visibleSourceID)
      else { return }
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
    guard !terminalAdmissionClosed else { return }
    subscriptionRefreshTask?.cancel()
    subscriptionRefreshTask = nil
    guard
      profiles.contains(where: { profile in
        profile.sources.contains { SubscriptionClient.isRemoteSource($0.value) }
      })
    else { return }
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
    guard !terminalAdmissionClosed, coreRunning else {
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
      guard !Task.isCancelled, let self else { return }
      self.latencyRefreshTask = nil
      self.refreshLatencyIfNeeded()
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
    guard !terminalAdmissionClosed else { return }
    if userInitiated { refreshRequestedByUser = true }
    guard currentHelperIsReady else {
      if userInitiated {
        refreshRequestedByUser = false
        setSubscriptionStatus(
          SBMText.localized("Refresh requires the background helper"), level: .warning
        )
      }
      return
    }
    if profileRefreshTask != nil {
      if userInitiated {
        setSubscriptionStatus(SBMText.localized("Refresh already in progress"), level: .neutral)
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
        setSubscriptionStatus(
          SBMText.localized("Refresh complete: no remote sources"), level: .success
        )
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
      var parserWarningSourceCount = 0
      var parserWarnings: [String] = []
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
          if let warning = result.warningDescription {
            parserWarningSourceCount += 1
            if parserWarnings.count < 4 { parserWarnings.append(warning) }
          }
          let fetched = ManagedConnectionReconciler.reconcile(
            existing: sourceSnapshot.payload,
            fetched: result.profile
          )
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
      let summary = SBMText.format(
        "Refresh complete: %@ updated, %@ unchanged, %@ failed",
        String(refreshed),
        String(unchanged),
        String(failed)
      )
      let omittedWarningCount = parserWarningSourceCount - parserWarnings.count
      let warningDetails = parserWarnings.joined(separator: "; ")
      var warningSuffix = ""
      if parserWarningSourceCount > 0 {
        warningSuffix = "; \(warningDetails)"
        if omittedWarningCount > 0 {
          warningSuffix +=
            "; "
            + SBMText.format("Additional source warnings: %@", String(omittedWarningCount))
        }
      }
      let summaryWithWarnings = summary + warningSuffix
      let sweepStatusLevel: SubscriptionStatusLevel =
        failed == 0 && parserWarningSourceCount == 0 ? .success : .warning
      if applying {
        setSubscriptionStatus(SBMText.localized("Refreshing current profile…"), level: .neutral)
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
          setSubscriptionStatus(summaryWithWarnings, level: sweepStatusLevel)
          lastError = firstFailure?.localizedDescription
        case .success?:
          setSubscriptionStatus(summaryWithWarnings, level: sweepStatusLevel)
          lastError = firstFailure?.localizedDescription
        case .failure(let error)?:
          loadSelectedProfileEditor()
          updateNodes()
          setSubscriptionStatus(
            (runtimeFailurePreservedPrevious
              ? SBMText.localized("Sources saved; apply failed — previous VPN remains active")
              : SBMText.localized("Sources saved; apply failed")) + warningSuffix,
            level: .warning
          )
          lastError = error.localizedDescription
        case nil:
          setSubscriptionStatus(
            "\(summaryWithWarnings); newer connection change is applying",
            level: parserWarningSourceCount > 0 || failed > 0 ? .warning : .neutral
          )
          lastError = firstFailure?.localizedDescription
        }
      } else {
        setSubscriptionStatus(summaryWithWarnings, level: sweepStatusLevel)
        lastError = firstFailure?.localizedDescription
      }
      profileAvailable = selectedProfile?.payload != nil
      updateNodes()
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

  private func applyProfileLibrary(_ stored: ProfileLibrary, reconcileRuntime: Bool = true) {
    subscriptionRefreshTask?.cancel()
    profiles = stored.profiles
    selectedProfileID = stored.selectedProfileID
    routingMode = stored.routingMode
    selectedNodeID = stored.selectedNodeID
    localSOCKSEnabled = stored.localSOCKSEnabled
    localSOCKSPort = stored.localSOCKSPort
    localSOCKSEnabledDraft = stored.localSOCKSEnabled
    localSOCKSPortDraft = stored.localSOCKSPort
    latencyIntervalMinutes = stored.latencyIntervalMinutes
    latencyIntervalMinutesDraft = stored.latencyIntervalMinutes
    latencyTestURL = stored.latencyTestURL
    latencyTestURLDraft = stored.latencyTestURL
    ipv6Enabled = stored.ipv6Enabled
    dnsSettings = stored.dnsSettings
    if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
      selectedProfileID = profiles.first?.id
    }
    selectedSourceID = nil
    loadSelectedProfileEditor()
    updateNodes()
    profileAvailable = selectedProfile?.payload != nil
    scheduleNextLatencyRefresh()
    startSubscriptionRefreshLoop()
    if reconcileRuntime { applyCurrentDesiredRuntimeIfNeeded() }
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
      subscriptionAppVersion = SubscriptionHeaders.defaultAppVersion ?? ""
      subscriptionDeviceOS = SubscriptionHeaders.defaultDeviceOS
      subscriptionDeviceOSVersion = SubscriptionHeaders.defaultDeviceOSVersion ?? ""
      subscriptionDeviceModel = SubscriptionHeaders.defaultDeviceModel ?? ""
      subscriptionHWID = SubscriptionHeaders.makeHardwareID()
      return
    }
    sourceName = source.name
    sourceExcludeRegex = source.excludeRegex ?? ""
    subscriptionURL = source.value
    subscriptionUserAgent = source.headers.userAgent
    subscriptionAppVersion = source.headers.appVersion ?? ""
    subscriptionDeviceOS = source.headers.deviceOS
    subscriptionDeviceOSVersion = source.headers.deviceOSVersion ?? ""
    subscriptionDeviceModel = source.headers.deviceModel ?? ""
    subscriptionHWID = source.headers.hardwareID
  }

  private func persistProfileLibrary(
    profiles: [ManagedProfile]? = nil,
    routingMode: RoutingMode? = nil,
    selectedNodeID: ProxyNodeID? = nil,
    localSOCKSEnabled: Bool? = nil,
    localSOCKSPort: UInt16? = nil,
    latencyIntervalMinutes: Int? = nil,
    latencyTestURL: String? = nil,
    ipv6Enabled: Bool? = nil,
    dnsSettings: ManagedDNSSettings? = nil
  ) throws {
    if let profileStoreLoadFailure {
      throw AppModelFailure.profileLibraryUnavailable(
        profileStoreLoadFailure.localizedDescription
      )
    }
    try profileLibrarySaver(
      ProfileLibrary(
        profiles: profiles ?? self.profiles,
        selectedProfileID: selectedProfileID,
        routingMode: routingMode ?? self.routingMode,
        selectedNodeID: selectedNodeID ?? self.selectedNodeID,
        localSOCKSEnabled: localSOCKSEnabled ?? self.localSOCKSEnabled,
        localSOCKSPort: localSOCKSPort ?? self.localSOCKSPort,
        latencyIntervalMinutes: latencyIntervalMinutes ?? self.latencyIntervalMinutes,
        latencyTestURL: latencyTestURL ?? self.latencyTestURL,
        ipv6Enabled: ipv6Enabled ?? self.ipv6Enabled,
        dnsSettings: dnsSettings ?? self.dnsSettings
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
      latencyTestURL: latencyTestURL,
      ipv6Enabled: ipv6Enabled,
      dnsSettings: dnsSettings
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
    guard !terminalAdmissionClosed else {
      onFinished?()
      return
    }
    guard let profileID,
      let profile = profiles.first(where: { $0.id == profileID }),
      profile.payload != nil
    else {
      let error = RoutingMutationFailure.profileChanged(
        SBMText.localized("The selected profile cannot store routing rules.")
      )
      presentRoutingMutationFailure(error, kind: kind, profileID: profileID)
      onFinished?()
      return
    }

    let revision = (routingMutationRevisions[profileID] ?? 0) &+ 1
    routingMutationRevisions[profileID] = revision
    invalidateRoutingInspector()
    let identity = RoutingMutationIdentity(profileID: profileID, revision: revision)
    routingMutationStatuses[profileID, default: [:]][kind] = RoutingMutationStatus(
      identity: identity,
      presentation: RoutingMutationPresentation(
        state: .applying,
        message: SBMText.localized("Routing change applying…")
      )
    )

    let predecessor = routingMutationQueues[profileID]
    let queueToken = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.finishRoutingMutationQueue(profileID: profileID, token: queueToken)
        onFinished?()
      }
      if let predecessor { await predecessor.value }
      guard !Task.isCancelled, !self.terminalAdmissionClosed else {
        self.completeSupersededRoutingMutation(
          identity: identity,
          kind: kind,
          onSuccess: onSuccess
        )
        return
      }
      await self.performRoutingMutation(
        identity: identity,
        kind: kind,
        successMessage: successMessage,
        operation: operation,
        onSuccess: onSuccess
      )
    }
    routingMutationQueues[profileID] = task
    routingMutationQueueTokens[profileID] = queueToken
  }

  private func performRoutingMutation(
    identity: RoutingMutationIdentity,
    kind: RoutingMutationKind,
    successMessage: String,
    operation: @escaping @MainActor (CoreProfile) throws -> CoreProfile,
    onSuccess: (@MainActor () -> Void)?
  ) async {
    guard !Task.isCancelled, !terminalAdmissionClosed else {
      completeSupersededRoutingMutation(identity: identity, kind: kind, onSuccess: onSuccess)
      return
    }
    do {
      guard let currentProfile = profiles.first(where: { $0.id == identity.profileID }),
        let basePayload = currentProfile.payload
      else {
        throw RoutingMutationFailure.profileChanged(
          SBMText.localized("The profile was removed while the routing change was pending.")
        )
      }
      let updated = try operation(basePayload)
      try await validateProfile(updated)
      guard !Task.isCancelled, !terminalAdmissionClosed else {
        completeSupersededRoutingMutation(identity: identity, kind: kind, onSuccess: onSuccess)
        return
      }
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
          SBMText.format("%@ applying", kind.routingName),
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
        if !runtimeMutationController.isApplying {
          runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
        }
        completeSavedRoutingMutation(
          identity: identity,
          kind: kind,
          message: successMessage,
          onSuccess: onSuccess
        )
      }
    } catch is CancellationError {
      completeSupersededRoutingMutation(identity: identity, kind: kind, onSuccess: onSuccess)
    } catch {
      guard !Task.isCancelled, !terminalAdmissionClosed else {
        completeSupersededRoutingMutation(identity: identity, kind: kind, onSuccess: onSuccess)
        return
      }
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
        message: SBMText.format("%@ and active", successMessage),
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
        ? SBMText.localized("Apply failed — previous routing remains active")
        : SBMText.format("%@ apply failed", kind.routingName)
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
          message: SBMText.localized("Saved; a newer routing change is applying")
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
      SBMText.format("%@ change failed", kind.routingName),
      level: .warning,
      profileID: identity.profileID
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
        SBMText.format("%@ change failed", kind.routingName), level: .warning, profileID: profileID
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
      for kind in [RoutingMutationKind.website, .application, .policy, .autoSelection] {
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

  private func discardRoutingMutationState(for profileID: UUID) {
    routingMutationQueues[profileID]?.cancel()
    routingMutationQueues[profileID] = nil
    routingMutationQueueTokens[profileID] = nil
    routingMutationRevisions[profileID] = nil
    routingMutationStatuses[profileID] = nil
  }

  private func staleRoutingMutationMessage(for kind: RoutingMutationKind) -> String {
    SBMText.format(
      "The profile changed while the %@ was validated. Try again.",
      kind.routingName.lowercased()
    )
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
          websiteRoutingRules: profile.websiteRoutingRules,
          autoExcludedNodeIDs: profile.autoExcludedNodeIDs
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
          websiteRoutingRules: rules,
          autoExcludedNodeIDs: profile.autoExcludedNodeIDs
        )
      )
    }
  }

  private func shouldApplyDesiredRuntime(for profileID: UUID) -> Bool {
    selectedProfileID == profileID
      && deferredRuntimeApplyPhase != .reconnecting
      && runtimeMutationController.desiredRunning != false
      && (coreRunning || runtimeMutationController.isApplying)
  }

  private func presentSubscriptionStatus(
    _ message: String,
    level: SubscriptionStatusLevel,
    profileID: UUID,
    sourceID: UUID? = nil
  ) {
    guard selectedProfileID == profileID, sourceID == nil || selectedSourceID == sourceID else {
      return
    }
    setSubscriptionStatus(message, level: level)
  }

  private func updateNodes() {
    invalidateRoutingInspector()
    latencyPublicationCoordinator.cancelPendingPublication()
    lastLatencyTestAt = nil
    latencyTestCompleted = false
    let descriptors =
      selectedProfile?.payload?.nodes ?? [
        ProxyNodeDescriptor(id: .auto, name: SBMText.localized("Auto"), kind: .automatic)
      ]
    nodes = descriptors.map { descriptor in
      let metadata = groupMetadata(for: descriptor.id)
      return ProxyNode(
        id: descriptor.id,
        name: descriptor.name,
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

  @discardableResult
  private func submitRuntimeApply(
    _ request: HelperRequest,
    onCurrentResult: (@MainActor (Result<HelperResponse, any Error>) -> Void)? = nil,
    onSuperseded: (@MainActor () -> Void)? = nil,
    visibleProfileID: UUID? = nil,
    visibleSourceID: UUID? = nil
  ) -> UInt64? {
    guard !terminalAdmissionClosed || request.action == .shutdown else {
      onSuperseded?()
      return nil
    }
    guard
      !helperSetupInProgress
        || request.action == .shutdown
        || (request.action == .stop && request.stopReason == .userDisconnect)
    else {
      let failure = AppModelFailure.helperNotReady
      if let onCurrentResult {
        onCurrentResult(.failure(failure))
      } else {
        onSuperseded?()
      }
      return nil
    }
    effectiveAutoNodeID = nil
    func mayPresent() -> Bool {
      (visibleProfileID == nil || selectedProfileID == visibleProfileID)
        && (visibleSourceID == nil || selectedSourceID == visibleSourceID)
    }
    func present(_ message: String?) {
      guard let message, mayPresent() else { return }
      lastError = message
    }
    guard
      currentHelperIsReady
        || (request.action == .stop && request.stopReason == .userDisconnect
          && currentRegisteredHelperIsCompatible)
        || request.action == .shutdown
    else {
      runtimeApplyStatus = .failed
      runtimeFailurePreservedPrevious = false
      runtimeFailureProfileID = request.profileID ?? visibleProfileID
      let failure = AppModelFailure.helperNotReady
      present(failure.localizedDescription)
      onCurrentResult?(.failure(failure))
      return nil
    }
    if request.action == .stop || request.action == .shutdown {
      durableStopProofRequired = true
    }
    if request.action == .start {
      terminalColdOffClaim?.release()
      terminalColdOffClaim = nil
    }
    runtimeApplyStatus = .applying
    runtimeFailurePreservedPrevious = false
    runtimeFailureProfileID = nil
    let previouslyActiveProfileID = helperActiveProfileID
    let previouslyRunning = coreRunning
    let knownGoodProfileID = previouslyActiveProfileID ?? request.profileID
    let generation = runtimeMutationController.submit(request) { [weak self] outcome in
      guard let self else {
        onSuperseded?()
        return
      }
      switch outcome.result {
      case .success(let response):
        let compatible = self.apply(
          response,
          policy: outcome.isCurrent ? .currentMutation : .staleMutation
        )
        guard outcome.isCurrent else {
          onSuperseded?()
          return
        }
        if compatible,
          request.action == .stop || request.action == .shutdown,
          response.success,
          !response.coreRunning
        {
          self.durableStopProofRequired = false
        }
        if !compatible {
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
          if mayPresent() { self.lastError = nil }
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
          if mayPresent() { self.lastError = nil }
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
      case .failure(let mutationError):
        guard outcome.isCurrent else {
          onSuperseded?()
          return
        }
        self.runtimeApplyStatus = .failed
        self.runtimeFailurePreservedPrevious = false
        self.runtimeFailureProfileID = request.profileID ?? visibleProfileID
        present(mutationError.localizedDescription)
        self.startRuntimeReadback(
          generation: outcome.generation,
          mutationError: mutationError,
          request: request,
          visibleProfileID: visibleProfileID,
          previouslyRunning: previouslyRunning,
          knownGoodProfileID: knownGoodProfileID,
          onCurrentResult: onCurrentResult,
          onSuperseded: onSuperseded
        )
      }
    }
    return generation
  }

  private func startRuntimeReadback(
    generation: UInt64,
    mutationError: any Error,
    request: HelperRequest,
    visibleProfileID: UUID?,
    previouslyRunning: Bool,
    knownGoodProfileID: UUID?,
    onCurrentResult: (@MainActor (Result<HelperResponse, any Error>) -> Void)?,
    onSuperseded: (@MainActor () -> Void)?
  ) {
    guard !terminalAdmissionClosed else {
      onSuperseded?()
      return
    }
    let previousTask = runtimeReadbackTask
    previousTask?.cancel()
    runtimeReadbackTask = Task { [weak self] in
      if let previousTask { await previousTask.value }
      guard let self else { return }
      defer {
        if !Task.isCancelled || self.terminalAdmissionClosed {
          self.runtimeReadbackTask = nil
        }
      }
      guard !self.terminalAdmissionClosed,
        generation == self.runtimeMutationController.currentGeneration,
        !Task.isCancelled
      else {
        onSuperseded?()
        return
      }
      let observed = try? await self.runtimeStateReader()
      guard generation == self.runtimeMutationController.currentGeneration else {
        onSuperseded?()
        return
      }
      self.runtimeFailurePreservedPrevious = false
      self.runtimeFailureProfileID = request.profileID ?? visibleProfileID
      if let observed {
        if self.apply(
          observed,
          policy: .observation(runtimeCurrent: true, adoptDesiredRuntime: false)
        ) {
          self.helperReachable = true
          self.runtimeFailurePreservedPrevious =
            previouslyRunning && observed.coreRunning
            && observed.activeProfileID == knownGoodProfileID
        }
      } else {
        self.helperReachable = false
        self.observedCoreState = .unknown
        self.helperActiveProfileID = nil
        self.coreVersion = nil
      }
      self.runtimeApplyStatus = .failed
      onCurrentResult?(.failure(mutationError))
    }
  }

  private func applyCurrentDesiredRuntimeIfNeeded(
    onCurrentResult: (@MainActor (Result<HelperResponse, any Error>) -> Void)? = nil,
    onSuperseded: (@MainActor () -> Void)? = nil,
    visibleProfileID: UUID? = nil,
    visibleSourceID: UUID? = nil
  ) {
    if !runtimeMutationController.isApplying {
      runtimeApplyStatus = deferredRuntimeApplyPending ? .reconnectRequired : .saved
    }
    guard runtimeMutationController.desiredRunning != false else { return }
    guard coreRunning || runtimeMutationController.isApplying else { return }
    guard let payload = selectedProfile?.payload else {
      cancelLatencyOperation()
      submitRuntimeApply(
        HelperRequest(action: .stop, stopReason: .other),
        onCurrentResult: onCurrentResult,
        onSuperseded: onSuperseded,
        visibleProfileID: visibleProfileID,
        visibleSourceID: visibleSourceID
      )
      return
    }
    submitRuntimeApply(
      makeStartRequest(profile: payload, profileID: selectedProfileID),
      onCurrentResult: onCurrentResult,
      onSuperseded: onSuperseded,
      visibleProfileID: visibleProfileID,
      visibleSourceID: visibleSourceID
    )
  }

  @discardableResult
  private func apply(
    _ response: HelperResponse,
    policy: HelperResponsePolicy,
    updateNodeDescriptors: Bool = true
  ) -> Bool {
    let runtimeCurrent: Bool
    let adoptDesiredRuntime: Bool
    let isObservation: Bool
    let isStaleMutation: Bool
    switch policy {
    case .observation(let isCurrent, let shouldAdopt):
      runtimeCurrent = isCurrent
      adoptDesiredRuntime = shouldAdopt
      isObservation = true
      isStaleMutation = false
    case .currentMutation:
      runtimeCurrent = true
      adoptDesiredRuntime = false
      isObservation = false
      isStaleMutation = false
    case .staleMutation:
      runtimeCurrent = false
      adoptDesiredRuntime = false
      isObservation = false
      isStaleMutation = true
    }
    guard !isStaleMutation else { return false }
    if response.coreRunning {
      terminalColdOffClaim?.release()
      terminalColdOffClaim = nil
    }
    guard response.legacy1115Retired == true else {
      if runtimeCurrent {
        helperReachable = false
        observedCoreState = .unknown
        helperActiveProfileID = nil
        coreVersion = nil
        lastError = "The one-time legacy helper retirement has not completed."
      }
      return false
    }
    helperUpdateRequired = false
    helperProtocolVersion = response.protocolVersion
    helperVersion = response.helperVersion
    helperRevision = response.helperRevision
    guard response.protocolVersion == HelperConstants.protocolVersion,
      response.helperVersion == HelperConstants.helperVersion,
      response.helperRevision == HelperConstants.helperRevision
    else {
      helperUpdateRequired = true
      if runtimeCurrent {
        helperReachable = false
        observedCoreState = .unknown
        helperActiveProfileID = nil
        coreVersion = nil
      }
      return false
    }
    guard runtimeCurrent else { return true }
    let shouldPrimeLatency = response.coreRunning && !coreRunning
    coreRunning = response.coreRunning
    if response.coreRunning {
      lastRuntimeObservationAt = Date()
      startRuntimeLivenessPolling()
    }
    coreVersion = response.coreVersion
    if response.success && response.runtimeOutcome == .reconnectRequired {
      deferredRuntimeApplyPending = true
      if deferredRuntimeApplyPhase != .reconnecting {
        deferredRuntimeApplyPhase = .pending
        deferredRuntimeApplyError = nil
      }
    }
    if !runtimeMutationController.isApplying {
      runtimeApplyStatus =
        deferredRuntimeApplyPending
        ? .reconnectRequired
        : (response.coreRunning ? .active : .saved)
    }
    if adoptDesiredRuntime, response.success,
      runtimeMutationController.desiredRunning == nil, response.coreRunning
    {
      runtimeMutationController.desiredRunning = true
    }
    helperActiveProfileID = response.activeProfileID
    activeIPv6Enabled = response.coreRunning ? response.activeIPv6Enabled : nil
    if !response.coreRunning || response.activeIPv6Enabled != nil {
      legacyIPv6ConvergenceAttempted = false
    }
    let responseMatchesSelectedProfile =
      selectedProfileID != nil && response.activeProfileID == selectedProfileID
    let responseMatchesRunningSelection = response.coreRunning && responseMatchesSelectedProfile
    if updateNodeDescriptors, responseMatchesRunningSelection, !response.nodes.isEmpty {
      let delays = Dictionary(
        uniqueKeysWithValues: nodes.compactMap { node in
          node.delay.map { (node.id, $0) }
        })
      nodes = response.nodes.map { descriptor in
        let metadata = groupMetadata(for: descriptor.id)
        return ProxyNode(
          id: descriptor.id,
          name: descriptor.name,
          groupID: metadata?.id,
          groupName: metadata?.name,
          groupOrder: metadata?.groupOrder,
          nodeOrder: metadata?.nodeOrder,
          delay: delays[descriptor.id]
        )
      }
    }
    if shouldPrimeLatency {
      scheduleLatencyRefresh(after: 0.25)
    } else if response.coreRunning {
      if !isObservation { scheduleNextLatencyRefresh() }
    } else {
      cancelLatencyOperation()
    }
    if let inspectionSnapshot = routingInspectorState.snapshot,
      inspectionSnapshot != currentRoutingInspectionSnapshot()
    {
      invalidateRoutingInspector()
    }
    if isObservation, response.success {
      reconcileDesiredIPv6IfNeeded()
      restoreStartupVPNIfNeeded(from: response)
    }
    return true
  }

  private func restoreStartupVPNIfNeeded(from response: HelperResponse) {
    guard
      !terminalAdmissionClosed,
      !helperSetupInProgress,
      !durableStopProofRequired,
      startupRestorePending
    else { return }
    startupRestorePending = false
    helperEnabled = true
    helperReachable = true
    guard !response.coreRunning else { return }
    guard let profileID = selectedProfileID, let payload = selectedProfile?.payload else {
      startupRestoreError = SBMText.localized(
        "Could not restore the VPN because the selected profile is unavailable."
      )
      return
    }
    startupRestoreError = nil
    runtimeMutationController.desiredRunning = true
    submitRuntimeApply(makeStartRequest(profile: payload, profileID: profileID))
  }

  private func reconcileDesiredIPv6IfNeeded() {
    guard observedCoreState == .running,
      runtimeMutationController.desiredRunning != false
    else { return }
    guard currentHelperIsReady,
      profileRefreshTask == nil,
      !runtimeMutationController.isApplying,
      !deferredRuntimeApplyPending,
      deferredRuntimeApplyPhase != .reconnecting,
      runtimeApplyStatus != .failed
    else { return }

    if let activeIPv6Enabled {
      guard activeIPv6Enabled != ipv6Enabled else { return }
      legacyIPv6ConvergenceAttempted = false
    } else {
      guard !legacyIPv6ConvergenceAttempted else { return }
      legacyIPv6ConvergenceAttempted = true
    }
    applyCurrentDesiredRuntimeIfNeeded()
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

  private func upgradeLegacyHelper() async throws -> HelperResponse {
    let generation = runtimeMutationController.currentGeneration
    let upgrade = try await HelperLifecycle.upgradeLegacy1115(
      service: helperService,
      bundleURL: applicationBundleURL,
      probe: {
        let response = try await self.helperLifecycleSender(HelperRequest(action: .status), 5)
        try await MainActor.run {
          try Task.checkCancellation()
          guard generation == self.runtimeMutationController.currentGeneration else {
            throw CancellationError()
          }
          if response.protocolVersion == HelperConstants.protocolVersion,
            response.helperVersion == HelperConstants.helperVersion,
            response.helperRevision == HelperConstants.helperRevision,
            response.success,
            !response.coreRunning,
            response.legacy1115Retired == false
          {
            self.durableStopProofRequired = true
          }
        }
        return response
      },
      finish: {
        try await self.helperLifecycleSender(
          HelperRequest(action: .finishLegacy1115Upgrade), 30
        )
      }
    )
    if upgrade.newlyRetired, !Task.isCancelled,
      generation == runtimeMutationController.currentGeneration
    {
      durableStopProofRequired = false
    }
    return upgrade.response
  }

  private func refreshRegistrationStatus() {
    helperUpdateRequired = false
    let registrationState = helperService.registrationState
    switch registrationState {
    case .enabled:
      helperEnabled = true
      helperRequiresApproval = false
    case .requiresApproval:
      helperEnabled = false
      helperReachable = false
      observedCoreState = .unknown
      helperRequiresApproval = true
    case .notRegistered:
      helperEnabled = false
      helperReachable = false
      observedCoreState = .unknown
      helperRequiresApproval = false
    case .notFound:
      helperEnabled = false
      helperReachable = false
      observedCoreState = .unknown
      helperRequiresApproval = false
    case .unknown:
      helperEnabled = false
      helperReachable = false
      observedCoreState = .unknown
      helperRequiresApproval = false
    }
    if registrationState != .enabled { invalidateRefresh() }
  }

  private func bootstrapHelper() {
    guard !terminalAdmissionClosed else { return }
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
    statusRefreshTask?.cancel()
  }

  private func beginHelperApprovalFlow(openSystemSettings: Bool) {
    guard !terminalAdmissionClosed else { return }
    helperApprovalPending = true
    helperEnabled = false
    helperReachable = false
    observedCoreState = .unknown
    helperRequiresApproval = true
    lastError = nil
    if openSystemSettings, !helperApprovalSettingsPresented {
      helperService.openSystemSettings()
      helperApprovalSettingsPresented = true
    }
    startHelperApprovalPolling()
  }

  private func completeHelperApprovalFlow() {
    helperApprovalPending = false
    helperApprovalPollTask?.cancel()
    helperApprovalPollTask = nil
    helperApprovalPolling = false
    helperApprovalSettingsPresented = false
  }

  private func continueHelperApprovalFlow() {
    guard !terminalAdmissionClosed else { return }
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
      enableHelper()
    case .notRegistered, .notFound:
      helperEnabled = false
      helperRequiresApproval = false
      enableHelper()
    case .unknown:
      helperEnabled = false
      helperReachable = false
      observedCoreState = .unknown
      helperRequiresApproval = false
      startHelperApprovalPolling()
    }
  }

  private func startHelperApprovalPolling() {
    guard !terminalAdmissionClosed, helperApprovalPending, helperApprovalPollTask == nil else {
      return
    }
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

  private func refreshLaunchAtLoginStatus() {
    launchAtLoginEnabled = loginItemService.status == .enabled
  }

  var isInstalledInApplications: Bool {
    applicationBundleURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
      == "/Applications/SBM.app"
  }

  private var currentHelperIsReady: Bool {
    helperEnabled
      && helperReachable
      && helperProtocolVersion == HelperConstants.protocolVersion
      && helperVersion == HelperConstants.helperVersion
      && helperRevision == HelperConstants.helperRevision
  }

  private var currentRegisteredHelperIsCompatible: Bool {
    helperEnabled
      && helperService.registrationState == .enabled
      && !helperUpdateRequired
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
    latencyPublicationCoordinator.cancelPendingPublication()
    latencyRefreshTask?.cancel()
    latencyRefreshTask = nil
    latencyOperationTask?.cancel()
    latencyOperationTask = nil
    latencyTestInProgress = false
  }

  private func synchronizeLatencyTarget(_ target: String) {
    guard !terminalAdmissionClosed else {
      markLatencySynchronizationPending()
      return
    }
    guard !latencyApplyInProgress else { return }
    beginBusyOperation()
    latencySyncTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.latencySyncTask = nil
        self.endBusyOperation()
      }

      var target = target
      while true {
        guard !self.terminalAdmissionClosed, !Task.isCancelled else { return }
        let result: Result<HelperResponse, any Error>
        do {
          let runtimeGeneration = self.runtimeMutationController.currentGeneration
          let runtimeMutationWasApplying = self.runtimeMutationController.isApplying
          let response = try await self.helperRequestSender(
            HelperRequest(action: .setLatencyTarget, latencyTestURL: target)
          )
          guard !self.terminalAdmissionClosed, !Task.isCancelled else { return }
          self.apply(
            response,
            policy: .observation(
              runtimeCurrent: !runtimeMutationWasApplying
                && !self.runtimeMutationController.isApplying
                && runtimeGeneration == self.runtimeMutationController.currentGeneration,
              adoptDesiredRuntime: false
            )
          )
          if response.protocolVersion != HelperConstants.protocolVersion
            || response.helperVersion != HelperConstants.helperVersion
            || response.helperRevision != HelperConstants.helperRevision
          {
            result = .failure(AppModelFailure.helperRevisionMismatch)
          } else if response.success {
            result = .success(response)
          } else {
            result = .failure(AppModelFailure.helperRequestFailed(response.message))
          }
        } catch {
          result = .failure(error)
        }

        guard !self.terminalAdmissionClosed, !Task.isCancelled else { return }
        if target != self.latencyTestURL {
          target = self.latencyTestURL
          continue
        }
        switch result {
        case .success:
          self.latencySettingsIssue = nil
          self.lastError = nil
        case .failure(let error):
          let message = self.setSettingsError(
            SBMText.localized("Latency runtime synchronization failed"),
            error: error,
            additionalSecrets: [target]
          )
          self.latencySettingsIssue = .runtimeSynchronization(message)
        }
        return
      }
    }
  }

  private func markLatencySynchronizationPending(showAsLastError: Bool = true) {
    let message = SBMText.localized("Saved locally; background helper synchronization is pending.")
    latencySettingsIssue = .runtimeSynchronization(message)
    if showAsLastError { lastError = message }
  }

  private func profileSummary(_ profile: VPNProfile) -> String {
    let count = profile.connections.count
    return count == 1
      ? SBMText.format("%@ server", String(count))
      : SBMText.format("%@ servers", String(count))
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
      SBMText.format(
        "The subscription was downloaded but could not be activated: %@", message
      )
    case .profileValidationFailed(let message):
      SBMText.format("The profile was rejected before activation: %@", message)
    case .helperRequiredForValidation:
      SBMText.localized("Enable the background helper before importing a profile.")
    case .helperRevisionMismatch:
      SBMText.localized(
        "macOS is still running an older background helper. Approve the updated item in System Settings, then repair it again."
      )
    case .helperNotReady:
      SBMText.localized("The background helper is not ready.")
    case .helperRequestFailed(let message):
      SBMText.format("The background helper rejected the request: %@", message)
    case .coreStopFailed(let message):
      SBMText.format("The VPN core did not stop: %@", message)
    case .profileLibraryUnavailable(let message): message
    case .staleProfileOperation:
      SBMText.localized(
        "The profile or source changed while the operation was in progress. Try again.")
    case .runtimeMutationSuperseded:
      SBMText.localized("The shutdown request was superseded by a newer runtime change.")
    }
  }
}
