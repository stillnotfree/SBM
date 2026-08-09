import AppKit
import Foundation
import Observation
import SBMShared
import ServiceManagement

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

enum SubscriptionStatusLevel {
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
  var subscriptionURL = ""
  var subscriptionUserAgent = SubscriptionHeaders.defaultUserAgent
  var subscriptionDeviceOS = SubscriptionHeaders.defaultDeviceOS
  var subscriptionHWID = UUID().uuidString
  var subscriptionStatus = "No subscription synced"
  var subscriptionStatusLevel: SubscriptionStatusLevel = .neutral
  var isSyncing = false
  var profileAvailable = false
  var localSOCKSEnabled = false
  var localSOCKSPort: UInt16 = 1082
  var latencyIntervalMinutes = 10
  private var subscriptionRefreshTask: Task<Void, Never>?
  private var latencyRefreshTask: Task<Void, Never>?
  private var profileStoreLoadError: String?
  private var helperRepairTask: Task<Void, Never>?
  private var refreshGeneration = 0
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
  private let subscriptionManager: SubscriptionManager
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
    subscriptionManager: SubscriptionManager = SubscriptionManager()
  ) {
    self.helperService = helperService
    self.subscriptionManager = subscriptionManager
    let stored: ProfileLibrary
    do {
      stored = try ProfileStore.loadProfileLibrary() ?? .empty
    } catch {
      stored = .empty
      profileStoreLoadError = error.localizedDescription
    }
    profiles = stored.profiles
    selectedProfileID = stored.selectedProfileID
    localSOCKSEnabled = stored.localSOCKSEnabled
    localSOCKSPort = stored.localSOCKSPort
    latencyIntervalMinutes = stored.latencyIntervalMinutes
    if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
      selectedProfileID = profiles.first?.id
    }
    loadSelectedProfileEditor()
    updateNodes()
    if let profileStoreLoadError {
      lastError = profileStoreLoadError
    }
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

  var routingPolicyStatus: String {
    guard case .compatibility(let profile) = selectedProfile?.payload else {
      return "Available for Reality + Hysteria2 subscriptions"
    }
    return profile.routingPolicy == nil ? "No routing policy" : "Routing policy active"
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

  var diagnosticReport: String {
    let appVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
    let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
    let profileKind: String
    switch selectedProfile?.payload {
    case .compatibility: profileKind = "compatibility subscription"
    case .native: profileKind = "native JSON"
    case nil: profileKind = "none"
    }
    let updated = selectedProfile?.updatedAt?.formatted(.iso8601) ?? "never"
    let nodeLines = nodes.map { node in
      "  - \(node.name) [\(node.id.rawValue)]: \(node.delay.map { "\($0) ms" } ?? "not measured")"
    }
    var lines = [
      "SBM \(appVersion) (\(appBuild))",
      "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
      "Helper: \(helperStatus)",
      "Helper version: \(helperVersion ?? "unknown")",
      "Helper revision: \(helperRevision.map(String.init) ?? "unknown")",
      "Helper reachable: \(helperReachable ? "yes" : "no")",
      "Launch at login: \(launchAtLoginEnabled ? "enabled" : "not enabled")",
      "Core: \(coreVersion ?? "unknown")",
      "VPN: \(coreRunning ? "connected" : "disconnected")",
      "Mode: \(routingMode.rawValue)",
      "Profile: \(selectedProfileName)",
      "Profile type: \(profileKind)",
      "Profile updated: \(updated)",
      "Profile library: \(profileStoreLoadError == nil ? "available" : "unavailable")",
      "Subscription sources: \(selectedProfile?.sources.count ?? 0)",
      "Selected server: \(selectedNodeID.rawValue)",
      "Local SOCKS5: \(localSOCKSEnabled ? "127.0.0.1:\(localSOCKSPort)" : "disabled")",
      "Servers:",
    ]
    lines.append(contentsOf: nodeLines)
    lines.append("")
    lines.append(lastError.map { "Last error: \($0)" } ?? "No current error.")
    lines.append("")
    lines.append("Subscription URLs and known credentials are redacted.")
    return SecretRedactor.redact(
      lines.joined(separator: "\n"),
      secrets: DiagnosticSecrets.collect(from: profiles)
    )
  }

  func refresh() {
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
        let response = try await Task.detached {
          try HelperClient.send(.status, receiveTimeoutSeconds: 5)
        }.value
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
      helperService.openSystemSettings()
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
        connectAutomaticallyIfNeeded()
      } catch HelperLifecycleFailure.approvalRequired,
        HelperLifecycleFailure.registrationDidNotFinish
      {
        presentHelperApproval()
      } catch {
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
          if let current = try? await Task.detached(operation: {
            try HelperClient.send(.status, receiveTimeoutSeconds: 5)
          }).value,
            current.helperVersion == HelperConstants.helperVersion,
            current.helperRevision == HelperConstants.helperRevision
          {
            apply(current)
            helperReachable = true
            helperStatus = "Helper ready"
            lastError = current.success ? nil : current.message
            connectAutomaticallyIfNeeded()
            return
          }
          helperStatus = "Stopping previous helper…"
          _ = try? await Task.detached {
            try HelperClient.send(.stop, receiveTimeoutSeconds: 5)
          }.value
        }
        helperStatus = "Replacing background helper…"
        let response = try await HelperLifecycle.replace(
          service: helperService,
          waiting: { [weak self] in
            self?.helperStatus = "Waiting for macOS to replace helper…"
          }
        ) {
          try await Task.detached {
            try HelperClient.send(.status, receiveTimeoutSeconds: 5)
          }.value
        }
        apply(response)
        helperReachable = true
        helperStatus = "Helper updated"
        connectAutomaticallyIfNeeded()
      } catch HelperLifecycleFailure.approvalRequired,
        HelperLifecycleFailure.registrationDidNotFinish
      {
        presentHelperApproval()
      } catch is CancellationError {
        refreshRegistrationStatus()
      } catch {
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
    beginBusyOperation()
    Task {
      defer { endBusyOperation() }
      do {
        let request: HelperRequest
        if enabled, let payload = selectedProfile?.payload {
          request = makeStartRequest(profile: payload, profileID: selectedProfileID)
        } else {
          request = HelperRequest(action: .stop)
        }
        let response = try await Task.detached {
          try HelperClient.send(request)
        }.value
        apply(response)
        lastError = response.success ? nil : response.message
      } catch {
        helperReachable = false
        lastError = error.localizedDescription
        refresh()
      }
    }
  }

  func disconnectBeforeQuit() async -> Bool {
    subscriptionRefreshTask?.cancel()
    helperRepairTask?.cancel()

    beginBusyOperation()
    defer { endBusyOperation() }
    do {
      let response = try await Task.detached {
        try HelperClient.send(.shutdown, receiveTimeoutSeconds: 5)
      }.value
      apply(response)
      guard response.success, !response.coreRunning else {
        throw AppModelFailure.coreStopFailed(response.message)
      }
      lastError = nil
      return true
    } catch {
      lastError = "Unable to disconnect before quitting: \(error.localizedDescription)"
      return true
    }
  }

  func setRoutingMode(_ mode: RoutingMode) {
    routingMode = mode
    send(HelperRequest(action: .setMode, mode: mode))
  }

  func setSelectedNode(_ node: ProxyNodeID) {
    selectedNodeID = node
    send(HelperRequest(action: .setNode, node: node))
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
    let interval = TimeInterval(latencyIntervalMinutes) * 60
    if let lastLatencyTestAt,
      Date().timeIntervalSince(lastLatencyTestAt) < interval
    {
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
      if coreRunning, self.selectedProfileID == selectedProfileID {
        if let payload = profiles[profileIndex].payload {
          send(makeStartRequest(profile: payload, profileID: selectedProfileID))
        } else {
          send(.init(action: .stop))
        }
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
      deviceOS: subscriptionDeviceOS,
      hardwareID: subscriptionHWID
    ).resettingRequestPreset()
    subscriptionUserAgent = reset.userAgent
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
    let replacement = UUID().uuidString
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

  func applyLocalSOCKSSettings() {
    guard (1024...65535).contains(Int(localSOCKSPort)), localSOCKSPort != 19090 else {
      lastError = "Choose a local SOCKS5 port from 1024 to 65535, except 19090."
      return
    }
    do {
      try persistProfileLibrary()
    } catch {
      lastError = error.localizedDescription
      return
    }
    guard coreRunning, let payload = selectedProfile?.payload else {
      lastError = nil
      return
    }
    send(makeStartRequest(profile: payload, profileID: selectedProfileID))
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
        if coreRunning {
          send(
            makeStartRequest(profile: payload, profileID: imported.id)
          )
        }
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
            vless: current.vless,
            hysteria2: current.hysteria2,
            routingPolicy: policy
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
          if coreRunning {
            let request = makeStartRequest(profile: updated, profileID: selectedProfileID)
            let response = try await Task.detached {
              try HelperClient.send(request)
            }.value
            apply(response)
            guard response.success else {
              throw AppModelFailure.profileActivationFailed(response.message)
            }
          }
        } catch {
          profiles = previous
          try? persistProfileLibrary()
          throw error
        }
        setSubscriptionStatus(
          coreRunning ? "Routing policy active" : "Routing policy ready",
          level: .success
        )
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
      VPNProfile(vless: current.vless, hysteria2: current.hysteria2)
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
    if coreRunning {
      send(makeStartRequest(profile: updated, profileID: selectedProfileID))
    }
    setSubscriptionStatus("Routing policy removed", level: .success)
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
    guard coreRunning else { return }
    beginBusyOperation()
    Task {
      defer { endBusyOperation() }
      do {
        let request: HelperRequest
        if let payload = selectedProfile?.payload {
          request = makeStartRequest(profile: payload, profileID: self.selectedProfileID)
        } else {
          request = HelperRequest(action: .stop)
        }
        let response = try await Task.detached {
          try HelperClient.send(request)
        }.value
        apply(response)
        guard response.success else {
          throw AppModelFailure.profileActivationFailed(response.message)
        }
        lastError = nil
      } catch {
        profiles = previousProfiles
        self.selectedProfileID = previousSelection
        loadSelectedProfileEditor()
        updateNodes()
        try? persistProfileLibrary()
        if let previous = profiles.first(where: { $0.id == previousSelection })?.payload {
          let request = makeStartRequest(profile: previous, profileID: previousSelection)
          _ = try? await Task.detached {
            try HelperClient.send(request)
          }.value
        }
        lastError = error.localizedDescription
      }
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
      lastError = error.localizedDescription
    }

    if coreRunning, let payload = selectedProfile?.payload {
      beginBusyOperation()
      Task {
        defer { endBusyOperation() }
        do {
          let request = makeStartRequest(profile: payload, profileID: id)
          let response = try await Task.detached {
            try HelperClient.send(request)
          }.value
          apply(response)
          guard response.success else {
            throw AppModelFailure.profileActivationFailed(response.message)
          }
          lastError = nil
        } catch {
          if let status = try? await Task.detached(operation: {
            try HelperClient.send(.status)
          }).value {
            apply(status)
          } else {
            selectedProfileID = previousSelection
            loadSelectedProfileEditor()
            updateNodes()
          }
          try? persistProfileLibrary()
          lastError = error.localizedDescription
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
    let value = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let headers = SubscriptionHeaders(
      userAgent: subscriptionUserAgent.trimmingCharacters(in: .whitespacesAndNewlines),
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
        let fetched = result.profile
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
        profiles[currentProfileIndex].sources[currentSourceIndex].payload = fetched
        profiles[currentProfileIndex].sources[currentSourceIndex].updatedAt = Date()
        try rebuildCompatibilityPayload(at: currentProfileIndex)
        guard let effective = profiles[currentProfileIndex].payload else {
          throw SubscriptionFailure.missingProtocols
        }
        try await validateProfile(effective)
        profiles[currentProfileIndex].updatedAt = Date()
        try persistProfileLibrary()
        if coreRunning, self.selectedProfileID == targetProfileID {
          let request = makeStartRequest(profile: effective, profileID: targetProfileID)
          let response = try await Task.detached {
            try HelperClient.send(request)
          }.value
          apply(response)
          guard response.success else {
            throw AppModelFailure.profileActivationFailed(response.message)
          }
          if let warning = result.warningDescription {
            setSubscriptionStatus(warning, level: .warning)
          } else {
            setSubscriptionStatus("Sources updated and active", level: .success)
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
        lastError = nil
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
    let interval = TimeInterval(latencyIntervalMinutes) * 60
    let elapsed = lastLatencyTestAt.map { Date().timeIntervalSince($0) } ?? 0
    scheduleLatencyRefresh(after: max(1, interval - elapsed))
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
    let response = try await Task.detached {
      try HelperClient.send(HelperRequest(action: .validateProfile, profile: profile))
    }.value
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
              let fetched = result.profile
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
          if profiles[profileIndex].id == selectedProfileID, oldPayload != payload {
            selectedProfileChanged = true
          }
        }
        try persistProfileLibrary()
        if selectedProfileChanged, coreRunning, let payload = selectedProfile?.payload {
          let request = makeStartRequest(profile: payload, profileID: selectedProfileID)
          let response = try await Task.detached {
            try HelperClient.send(request)
          }.value
          apply(response)
          guard response.success else {
            throw AppModelFailure.profileActivationFailed(response.message)
          }
        }
        updateNodes()
        if let selectedFailure {
          setSubscriptionStatus("Some sources could not be refreshed", level: .warning)
          lastError = selectedFailure.localizedDescription
        } else if !selectedWarnings.isEmpty {
          setSubscriptionStatus(
            Array(Set(selectedWarnings)).sorted().joined(separator: "; "),
            level: .warning
          )
          lastError = nil
        } else {
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
  }

  private func loadSelectedSourceEditor() {
    guard let selectedSourceID,
      let source = selectedProfile?.sources.first(where: { $0.id == selectedSourceID })
    else {
      sourceName = ""
      sourceExcludeRegex = ""
      subscriptionURL = ""
      subscriptionUserAgent = SubscriptionHeaders.defaultUserAgent
      subscriptionDeviceOS = SubscriptionHeaders.defaultDeviceOS
      subscriptionHWID = UUID().uuidString
      return
    }
    sourceName = source.name
    sourceExcludeRegex = source.excludeRegex ?? ""
    subscriptionURL = source.value
    subscriptionUserAgent = source.headers.userAgent
    subscriptionDeviceOS = source.headers.deviceOS
    subscriptionHWID = source.headers.hardwareID
  }

  private func persistProfileLibrary() throws {
    if let profileStoreLoadError {
      throw AppModelFailure.profileLibraryUnavailable(profileStoreLoadError)
    }
    try ProfileStore.saveProfileLibrary(
      ProfileLibrary(
        profiles: profiles,
        selectedProfileID: selectedProfileID,
        localSOCKSEnabled: localSOCKSEnabled,
        localSOCKSPort: localSOCKSPort,
        latencyIntervalMinutes: latencyIntervalMinutes
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
      localSOCKSEnabled: localSOCKSEnabled,
      localSOCKSPort: localSOCKSPort
    )
  }

  private func rebuildCompatibilityPayload(at profileIndex: Int) throws {
    let policy: RoutingPolicy?
    if case .compatibility(let current) = profiles[profileIndex].payload {
      policy = current.routingPolicy
    } else {
      policy = nil
    }
    guard profiles[profileIndex].sources.contains(where: { $0.payload != nil }) else {
      profiles[profileIndex].payload = nil
      profiles[profileIndex].updatedAt = nil
      return
    }
    profiles[profileIndex].payload = try ProfileAggregator.merge(
      sources: profiles[profileIndex].sources,
      routingPolicy: policy
    )
  }

  private func updateNodes() {
    lastLatencyTestAt = nil
    latencyTestCompleted = false
    let descriptors =
      selectedProfile?.payload?.nodes ?? [
        ProxyNodeDescriptor(id: .auto, name: "Auto")
      ]
    nodes = descriptors.map { descriptor in
      let metadata = groupMetadata(for: descriptor.id)
      return ProxyNode(
        id: descriptor.id,
        name: descriptor.name,
        symbol: symbol(for: descriptor.id),
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

  private func apply(_ response: HelperResponse) {
    let shouldPrimeLatency = response.coreRunning && !coreRunning
    helperStatus = response.message
    helperVersion = response.helperVersion
    helperRevision = response.helperRevision
    coreRunning = response.coreRunning
    coreVersion = response.coreVersion
    automaticRecoveryExhausted = response.automaticRecoveryExhausted
    routingMode = response.mode
    helperActiveProfileID = response.activeProfileID
    let responseMatchesSelection =
      response.coreRunning && response.activeProfileID == selectedProfileID
    if responseMatchesSelection {
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
          symbol: symbol(for: descriptor.id),
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

  private func symbol(for id: ProxyNodeID) -> String {
    if id == .auto { return "wand.and.stars" }
    if id.rawValue.hasPrefix("vless-") { return "shield.lefthalf.filled" }
    if id.rawValue.hasPrefix("hysteria2-") { return "bolt.horizontal.fill" }
    return "network"
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
      try await Task.detached {
        try HelperClient.send(.status, receiveTimeoutSeconds: 5)
      }.value
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

  private func presentHelperApproval() {
    helperEnabled = false
    helperReachable = false
    helperRequiresApproval = true
    helperStatus = "Approval required"
    lastError = nil
    helperService.openSystemSettings()
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
    beginBusyOperation()
    Task {
      defer { endBusyOperation() }
      do {
        let request = makeStartRequest(profile: payload, profileID: selectedProfileID)
        let response = try await Task.detached {
          try HelperClient.send(request)
        }.value
        apply(response)
        guard response.success, response.coreRunning else {
          throw AppModelFailure.profileActivationFailed(response.message)
        }
        lastError = nil
      } catch {
        lastError = "Automatic connection failed: \(error.localizedDescription)"
      }
    }
  }

  private var isInstalledInApplications: Bool {
    Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/")
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
    let count = profile.vless.count + profile.hysteria2.count
    return "\(count) server\(count == 1 ? "" : "s")"
  }
}

private enum AppModelFailure: LocalizedError {
  case profileActivationFailed(String)
  case profileValidationFailed(String)
  case helperRequiredForValidation
  case helperRevisionMismatch
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
    case .coreStopFailed(let message):
      "The VPN core did not stop: \(message)"
    case .profileLibraryUnavailable(let message): message
    }
  }
}
