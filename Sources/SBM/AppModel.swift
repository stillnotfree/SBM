import AppKit
import Foundation
import Observation
import SBMShared
import ServiceManagement

struct ProxyNode: Identifiable, Hashable {
  let id: ProxyNodeID
  let name: String
  let symbol: String
  var delay: Int?
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
  var subscriptionURL = ""
  var subscriptionStatus = "No subscription synced"
  var isSyncing = false
  var profileAvailable = false
  var localSOCKSEnabled = false
  var localSOCKSPort: UInt16 = 1082
  private var subscriptionRefreshTask: Task<Void, Never>?
  private var helperRepairTask: Task<Void, Never>?
  private var refreshGeneration = 0
  private var refreshInProgress = false
  private var lastLatencyTestAt: Date?
  private var didAttemptAutomaticConnection = false
  private var helperActiveProfileID: UUID?
  private var availableUpdate: AppUpdate?

  var nodes: [ProxyNode] = [
    ProxyNode(id: .auto, name: "Auto", symbol: "wand.and.stars", delay: nil)
  ]

  private let helperService: any HelperServiceManaging
  private let loginItemService = SMAppService.mainApp

  init(helperService: any HelperServiceManaging = SystemHelperService()) {
    self.helperService = helperService
    let stored = ProfileStore.loadProfileLibrary() ?? .empty
    profiles = stored.profiles
    selectedProfileID = stored.selectedProfileID
    localSOCKSEnabled = stored.localSOCKSEnabled
    localSOCKSPort = stored.localSOCKSPort
    if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
      selectedProfileID = profiles.first?.id
    }
    loadSelectedProfileEditor()
    updateNodes()
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
      "Selected server: \(selectedNodeID.rawValue)",
      "Local SOCKS5: \(localSOCKSEnabled ? "127.0.0.1:\(localSOCKSPort)" : "disabled")",
      "Servers:",
    ]
    lines.append(contentsOf: nodeLines)
    lines.append("")
    lines.append(lastError.map { "Last error: \($0)" } ?? "No current error.")
    lines.append("")
    lines.append("Subscription URLs are omitted. Review error text before sharing this report.")
    return lines.joined(separator: "\n")
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
          helperStatus = "Stopping previous helper…"
          _ = try? await Task.detached {
            try HelperClient.send(.stop)
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
    for index in nodes.indices { nodes[index].delay = nil }
    beginBusyOperation()
    Task {
      defer { endBusyOperation() }
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
        lastError = response.success ? nil : response.message
      } catch {
        helperReachable = false
        lastError = error.localizedDescription
      }
    }
  }

  func refreshLatencyIfNeeded() {
    guard coreRunning, !isBusy else { return }
    if let lastLatencyTestAt, Date().timeIntervalSince(lastLatencyTestAt) < 30 {
      return
    }
    lastLatencyTestAt = Date()
    testLatency()
  }

  func saveAndSyncSubscription() {
    syncSelectedProfile(persistEditor: true)
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
      subscriptionStatus = "Profile name saved"
      lastError = nil
    } catch {
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
        subscriptionStatus = "Imported JSON profile"
        try persistProfileLibrary()
        lastError = nil
        if coreRunning {
          send(
            makeStartRequest(profile: payload, profileID: imported.id)
          )
        }
      } catch {
        lastError = error.localizedDescription
        subscriptionStatus = "Import failed"
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
        subscriptionStatus = coreRunning ? "Routing policy active" : "Routing policy ready"
        lastError = nil
      } catch {
        subscriptionStatus = "Routing import failed"
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
    subscriptionStatus = "Routing policy removed"
    lastError = nil
  }

  func addProfile() {
    let profile = ManagedProfile(name: "New Profile")
    profiles.append(profile)
    selectedProfileID = profile.id
    loadSelectedProfileEditor()
    updateNodes()
    profileAvailable = false
    subscriptionStatus = "Enter a subscription URL"
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
    subscriptionStatus = profileAvailable ? "Ready" : "No subscription synced"
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
    subscriptionStatus = profileAvailable ? "Ready" : "Not synced"
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
    } else if selectedProfile?.payload == nil, !subscriptionURL.isEmpty {
      syncSelectedProfile(persistEditor: false)
    }
  }

  private var selectedProfile: ManagedProfile? {
    guard let selectedProfileID else { return nil }
    return profiles.first(where: { $0.id == selectedProfileID })
  }

  private func syncSelectedProfile(persistEditor: Bool) {
    let value = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetProfileID: UUID
    if let selectedProfileID {
      targetProfileID = selectedProfileID
    } else {
      let profile = ManagedProfile(
        name: name.isEmpty ? "Profile" : name,
        subscriptionURL: value
      )
      profiles.append(profile)
      selectedProfileID = profile.id
      targetProfileID = profile.id
    }
    if persistEditor,
      let index = profiles.firstIndex(where: { $0.id == targetProfileID })
    {
      profiles[index].name = name.isEmpty ? "Profile" : name
      profiles[index].subscriptionURL = value
      do {
        try persistProfileLibrary()
      } catch {
        lastError = error.localizedDescription
        return
      }
    }
    guard !value.isEmpty else {
      subscriptionStatus = selectedProfile?.payload == nil ? "Choose a profile source" : "Saved"
      return
    }
    isSyncing = true
    subscriptionStatus = "Syncing…"
    Task {
      defer { isSyncing = false }
      var rollbackProfiles: [ManagedProfile]?
      do {
        let fetched = try await SubscriptionClient.fetch(from: value)
        guard let index = profiles.firstIndex(where: { $0.id == targetProfileID }) else {
          return
        }
        let effective = applyingCurrentRoutingPolicy(
          to: fetched,
          current: profiles[index].payload
        )
        try await validateProfile(effective)
        let previousProfiles = profiles
        rollbackProfiles = previousProfiles
        profiles[index].name = name.isEmpty ? "Profile" : name
        profiles[index].subscriptionURL = value
        profiles[index].payload = effective
        profiles[index].updatedAt = Date()
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
          subscriptionStatus = "Updated and active"
        } else {
          switch effective {
          case .compatibility(let profile):
            subscriptionStatus = profileSummary(profile) + " ready"
          case .native:
            subscriptionStatus = "Native JSON profile ready"
          }
        }
        profileAvailable = true
        updateNodes()
        lastError = nil
        connectAutomaticallyIfNeeded()
      } catch {
        if let rollbackProfiles {
          profiles = rollbackProfiles
          try? persistProfileLibrary()
          updateNodes()
        }
        profileAvailable = selectedProfile?.payload != nil
        subscriptionStatus = profileAvailable ? "Using cached profile; sync failed" : "Sync failed"
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
    let refreshable = profiles.filter {
      SubscriptionClient.isRemoteSource($0.subscriptionURL)
    }
    guard !refreshable.isEmpty else { return }
    isSyncing = true
    Task {
      defer { isSyncing = false }
      var selectedFailure: Error?
      for profile in refreshable {
        do {
          let fetched = try await SubscriptionClient.fetch(from: profile.subscriptionURL)
          guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            continue
          }
          let effective = applyingCurrentRoutingPolicy(
            to: fetched,
            current: profiles[index].payload
          )
          try await validateProfile(effective)
          let changed = profiles[index].payload != effective
          guard changed else {
            profiles[index].updatedAt = Date()
            continue
          }
          let previousProfiles = profiles
          profiles[index].payload = effective
          profiles[index].updatedAt = Date()
          try persistProfileLibrary()
          if changed, coreRunning, selectedProfileID == profile.id {
            do {
              let request = makeStartRequest(profile: effective, profileID: profile.id)
              let response = try await Task.detached {
                try HelperClient.send(request)
              }.value
              apply(response)
              guard response.success else {
                throw AppModelFailure.profileActivationFailed(response.message)
              }
            } catch {
              profiles = previousProfiles
              try? persistProfileLibrary()
              updateNodes()
              throw error
            }
          }
        } catch {
          if selectedProfileID == profile.id {
            selectedFailure = error
          }
        }
      }
      do {
        try persistProfileLibrary()
        updateNodes()
        if let selectedFailure {
          subscriptionStatus = "Using cached profile; refresh failed"
          lastError = selectedFailure.localizedDescription
        } else {
          subscriptionStatus = "Profiles refreshed"
        }
        connectAutomaticallyIfNeeded()
      } catch {
        lastError = error.localizedDescription
      }
    }
  }

  private func loadSelectedProfileEditor() {
    profileName = selectedProfile?.name ?? ""
    subscriptionURL = selectedProfile?.subscriptionURL ?? ""
  }

  private func persistProfileLibrary() throws {
    try ProfileStore.saveProfileLibrary(
      ProfileLibrary(
        profiles: profiles,
        selectedProfileID: selectedProfileID,
        localSOCKSEnabled: localSOCKSEnabled,
        localSOCKSPort: localSOCKSPort
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

  private func applyingCurrentRoutingPolicy(
    to fetched: CoreProfile,
    current: CoreProfile?
  ) -> CoreProfile {
    guard case .compatibility(let newProfile) = fetched,
      case .compatibility(let currentProfile) = current,
      let policy = currentProfile.routingPolicy
    else { return fetched }
    return .compatibility(
      VPNProfile(
        vless: newProfile.vless,
        hysteria2: newProfile.hysteria2,
        routingPolicy: policy
      )
    )
  }

  private func updateNodes() {
    lastLatencyTestAt = nil
    let descriptors =
      selectedProfile?.payload?.nodes ?? [
        ProxyNodeDescriptor(id: .auto, name: "Auto")
      ]
    nodes = descriptors.map { descriptor in
      ProxyNode(
        id: descriptor.id,
        name: descriptor.name,
        symbol: symbol(for: descriptor.id),
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
        ProxyNode(
          id: descriptor.id,
          name: descriptor.name,
          symbol: symbol(for: descriptor.id),
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
    }
  }

  private func symbol(for id: ProxyNodeID) -> String {
    switch id {
    case .auto: "wand.and.stars"
    case .reality: "shield.lefthalf.filled"
    case .hysteria2: "bolt.horizontal.fill"
    default: "network"
    }
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
    guard !didAttemptAutomaticConnection, currentHelperIsReady else { return }
    guard let payload = selectedProfile?.payload else { return }
    guard !coreRunning || helperActiveProfileID != selectedProfileID else { return }
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
        didAttemptAutomaticConnection = false
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
    switch (profile.vless != nil, profile.hysteria2 != nil) {
    case (true, true): "Reality + Hysteria2"
    case (true, false): "Reality"
    case (false, true): "Hysteria2"
    case (false, false): "Profile"
    }
  }
}

private enum AppModelFailure: LocalizedError {
  case profileActivationFailed(String)
  case profileValidationFailed(String)
  case helperRequiredForValidation
  case helperRevisionMismatch
  case coreStopFailed(String)

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
    }
  }
}
