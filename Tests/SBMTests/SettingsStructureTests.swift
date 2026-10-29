import Foundation
import SBMShared
import Testing

@testable import SBM

private func settingsSource(_ name: String) throws -> String {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  return try String(
    contentsOf: root.appendingPathComponent("Sources/SBM/\(name)"),
    encoding: .utf8
  )
}

@Test func settingsMenuAndDiagnosticsRemainDiscoverable() throws {
  let app = try settingsSource("SBMApp.swift")
  #expect(app.contains(#"Label("Settings…", systemImage: "gearshape")"#))
  #expect(app.contains("presentWindow(.profiles)"))
  #expect(app.contains(#"Window("Settings", id: "profiles")"#))
  #expect(app.contains(".defaultPosition(.center)"))
  #expect(app.contains(#"Label("Diagnostics…", systemImage: "stethoscope")"#))
  #expect(!app.contains("if let lastError"))
  #expect(!app.contains(".disabled(model.isBusy)"))
  #expect(app.contains("model.connectionPresentation.systemImage"))
  #expect(app.contains("model.coreIsKnownStopped ? \"Quit\" : \"Disconnect & Quit\""))
  #expect(app.contains("model.reconnectToApply()"))
  #expect(app.contains("deferred.action.title"))
}

@Test func errorMenuRowIsInertAndKeepsSafeDiagnosticsDetails() throws {
  let app = try settingsSource("SBMApp.swift")
  let rowStart = try #require(app.range(of: "if let error = model.safeCurrentError"))
  let deferredStart = try #require(
    app.range(
      of: "if let deferred = model.deferredRuntimeApplyPresentation",
      range: rowStart.upperBound..<app.endIndex)
  )
  let row = String(app[rowStart.lowerBound..<deferredStart.lowerBound])
  #expect(row.contains("menuText(\n        menuErrorSummary("))
  #expect(!row.contains("Button"))
  #expect(!row.contains("presentWindow"))
  #expect(!row.contains("onTapGesture"))
  #expect(!row.contains("keyboardShortcut"))
  #expect(row.contains("menuErrorSummary("))
  #expect(row.contains("let isInstalledInApplications = model.isInstalledInApplications"))
  #expect(row.contains("let errorDetails ="))
  #expect(
    row.contains(
      #"Move SBM.app to the Applications folder, eject the DMG, then open the installed copy."#
    )
  )
  #expect(row.contains("? error"))
  #expect(row.contains(": SBMText.localized("))
  #expect(row.contains(".help(errorDetails)"))
  #expect(row.contains(".accessibilityLabel(errorDetails)"))
  #expect(!row.contains("model.lastError"))
  #expect(!row.contains(".help(error)"))
  #expect(!row.contains(".accessibilityLabel(error)"))

  let summaryStart = try #require(app.range(of: "func menuErrorSummary("))
  let menuStart = try #require(
    app.range(
      of: "private struct MenuContentView: View", range: summaryStart.upperBound..<app.endIndex)
  )
  let summary = String(app[summaryStart.lowerBound..<menuStart.lowerBound])
  #expect(summary.contains("if !isInstalledInApplications"))
  #expect(
    summary.contains(
      #"return SBMText.localized("Move SBM to Applications")"#
    )
  )

  let model = try settingsSource("AppModel.swift")
  #expect(model.contains("var isInstalledInApplications: Bool"))
  #expect(!model.contains("private var isInstalledInApplications: Bool"))
  #expect(model.contains(#"== "/Applications/SBM.app""#))
  let safeErrorStart = try #require(model.range(of: "var safeCurrentError: String?"))
  let recentErrorsStart = try #require(
    model.range(
      of: "private(set) var recentErrors", range: safeErrorStart.upperBound..<model.endIndex)
  )
  let safeError = String(model[safeErrorStart.lowerBound..<recentErrorsStart.lowerBound])
  #expect(safeError.contains("SafeDiagnosticError.sanitize("))

  let reconnectFailureStart = try #require(
    model.range(of: "private func finishDeferredRuntimeReconnectFailure(")
  )
  let disconnectStart = try #require(
    model.range(
      of: "func disconnectBeforeQuit()",
      range: reconnectFailureStart.upperBound..<model.endIndex
    )
  )
  let reconnectFailure = String(
    model[reconnectFailureStart.lowerBound..<disconnectStart.lowerBound])
  #expect(reconnectFailure.contains("lastError = message"))
  #expect(reconnectFailure.contains("deferredRuntimeApplyError = message"))
  #expect(app.contains("Text(snapshot.statusText)"))
  #expect(app.contains("entry.message"))

  let presenterStart = try #require(
    app.range(
      of: "private func presentWindow(_ target: SBMWindow)",
      range: menuStart.upperBound..<app.endIndex
    )
  )
  let menu = String(app[menuStart.lowerBound..<presenterStart.lowerBound])
  #expect(
    menu.contains(
      "Button {\n      presentWindow(.diagnostics)\n    } label: {\n      Label(\"Diagnostics…\", systemImage: \"stethoscope\")"
    )
  )
}

@Test func manualUpdateActionLivesInSettingsAndAboutWindowIsRemoved() throws {
  let app = try settingsSource("SBMApp.swift")
  let settings = try settingsSource("SettingsView.swift")
  let menuStart = try #require(app.range(of: "private struct MenuContentView: View"))
  let presenterStart = try #require(
    app.range(
      of: "private func presentWindow(_ target: SBMWindow)",
      range: menuStart.upperBound..<app.endIndex
    ))
  let menu = String(app[menuStart.lowerBound..<presenterStart.lowerBound])
  #expect(!menu.contains(#"Button("About SBM…")"#))
  #expect(!menu.contains(#"Button("Check for Updates…")"#))
  #expect(!menu.contains("model.checkForUpdates()"))
  #expect(!app.contains("private struct AboutView: View"))
  #expect(!app.contains(#"Window("About SBM", id: "about")"#))
  #expect(!app.contains("case about"))
  #expect(!app.contains("presentWindow(.about)"))

  let settingsTabStart = try #require(settings.range(of: "private var settingsTab: some View"))
  let startupStart = try #require(
    settings.range(
      of: "private var startupLifecycleSection",
      range: settingsTabStart.upperBound..<settings.endIndex)
  )
  let settingsTab = String(settings[settingsTabStart.lowerBound..<startupStart.lowerBound])
  #expect(settingsTab.contains("aboutSection"))
}

@Test func diagnosticsWindowKeepsActionsWithoutRepeatingItsTitle() throws {
  let app = try settingsSource("SBMApp.swift")
  #expect(app.contains(#"Label("Diagnostics…", systemImage: "stethoscope")"#))
  #expect(app.contains(#"Window("Diagnostics", id: "diagnostics")"#))

  let diagnosticsStart = try #require(app.range(of: "private struct DiagnosticsView: View"))
  let diagnostics = String(app[diagnosticsStart.lowerBound...])
  #expect(!diagnostics.contains(#"Label("Diagnostics", systemImage: "stethoscope")"#))
  #expect(diagnostics.contains(#"Button("Copy Text")"#))
  #expect(diagnostics.contains(#"Button("Copy JSON")"#))
  #expect(diagnostics.contains(#"Button("Refresh")"#))
  #expect(diagnostics.contains(#"Text("Current Status")"#))
  #expect(diagnostics.contains(#"Text("Recent Errors")"#))
  let leadingSpacer = try #require(diagnostics.range(of: "Spacer()"))
  let copyText = try #require(diagnostics.range(of: #"Button("Copy Text")"#))
  #expect(leadingSpacer.lowerBound < copyText.lowerBound)
}

@Test func requestedWindowActivatesBeforeDeferredOpenAndBecomesKey() throws {
  let app = try settingsSource("SBMApp.swift")
  let start = try #require(app.range(of: "private func presentWindow(_ target: SBMWindow)"))
  let end = try #require(app.range(of: "\n  @ViewBuilder", range: start.upperBound..<app.endIndex))
  let presenter = String(app[start.lowerBound..<end.lowerBound])
  let open = try #require(presenter.range(of: "openWindow(id: target.rawValue)"))
  let activate = try #require(presenter.range(of: "NSApplication.shared.activate()"))
  let deferredOpen = try #require(presenter.range(of: "DispatchQueue.main.async {"))
  let materializationDelay = try #require(
    presenter.range(of: "DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)"))
  let identifierLookup = try #require(presenter.range(of: "$0.identifier == target.identifier"))
  let titleLookup = try #require(presenter.range(of: "$0.title == target.title"))
  let makeKey = try #require(presenter.range(of: "window.makeKeyAndOrderFront(nil)"))
  #expect(activate.lowerBound < deferredOpen.lowerBound)
  #expect(deferredOpen.lowerBound < open.lowerBound)
  #expect(open.lowerBound < materializationDelay.lowerBound)
  #expect(materializationDelay.lowerBound < identifierLookup.lowerBound)
  #expect(identifierLookup.lowerBound < titleLookup.lowerBound)
  #expect(titleLookup.lowerBound < makeKey.lowerBound)
  #expect(presenter.contains("window.identifier = target.identifier"))
  #expect(presenter.contains("window.level = target.level"))
  #expect(app.contains("var level: NSWindow.Level {\n    .normal\n  }"))
  #expect(!presenter[open.upperBound...].contains("NSApplication.shared.activate()"))
  #expect(!presenter.contains("activateIgnoringOtherApps"))
  #expect(!presenter.contains("orderFrontRegardless"))
  #expect(!presenter.contains(".floating"))
}

@Test func helperMenuUsesShortProgressLabelsAndExpectedActions() throws {
  let app = try settingsSource("SBMApp.swift")
  let menuStart = try #require(app.range(of: "private struct MenuContentView: View"))
  let presenterStart = try #require(
    app.range(
      of: "private func presentWindow(_ target: SBMWindow)",
      range: menuStart.upperBound..<app.endIndex
    ))
  let menu = String(app[menuStart.lowerBound..<presenterStart.lowerBound])
  #expect(!menu.contains("model.helperStatus"))
  for label in [
    "Waiting for approval…", "Enabling helper…", "Updating helper…", "Repairing helper…",
  ] {
    #expect(menu.contains("\"\(label)\""))
  }
  for label in ["Enable Helper", "Repair Helper", "Update Helper", "Approve Helper…"] {
    #expect(menu.contains("\"\(label)\""))
  }
  for obsoleteLabel in [
    "Enable Background Helper", "Repair Background Helper", "Update Background Helper",
    "Approve Background Helper…",
  ] {
    #expect(!menu.contains("\"\(obsoleteLabel)\""))
  }
  for controlTitle in [
    #"menuText(SBMText.format("Profile: %@", model.selectedProfileName))"#,
    #"menuText(SBMText.format("Mode: %@", SBMText.localized(model.routingMode.rawValue)))"#,
    #"menuText(SBMText.format("Server: %@", selectedNodeName))"#,
  ] {
    let title = try #require(menu.range(of: controlTitle))
    let guardRange = try #require(
      menu.range(
        of: ".disabled(!model.runtimeMenuControlsEnabled)",
        range: title.upperBound..<menu.endIndex
      ))
    #expect(title.upperBound < guardRange.lowerBound)
    let nextMenu = menu.range(of: "Menu {", range: title.upperBound..<menu.endIndex)
    if let nextMenu {
      #expect(guardRange.lowerBound < nextMenu.lowerBound)
    }
  }
  #expect(menu.contains("model.enableHelper()"))
  #expect(menu.contains("model.repairHelper()"))
  #expect(menu.contains("model.connectionAction"))
  #expect(menu.contains("model.safeCurrentError"))
  #expect(menu.contains(".disabled(!model.connectionActionEnabled)"))
  #expect(
    menu.components(separatedBy: "model.runtimeMenuControlsEnabled").count - 1 == 5)
  #expect(menu.contains("presentWindow(.profiles)"))
  #expect(menu.contains("presentWindow(.diagnostics)"))
  #expect(!menu.contains("model.checkForUpdates()"))
  #expect(menu.contains("NSApplication.shared.terminate(nil)"))
  #expect(menu.contains(".disabled(model.helperSetupInProgress)"))
}

@Test func nativeMenuLocalizesFixedActionTitlesAtTheirCallSites() throws {
  let app = try settingsSource("SBMApp.swift")
  let menuStart = try #require(app.range(of: "private struct MenuContentView: View"))
  let presenterStart = try #require(
    app.range(
      of: "private func presentWindow(_ target: SBMWindow)",
      range: menuStart.upperBound..<app.endIndex
    ))
  let menu = String(app[menuStart.lowerBound..<presenterStart.lowerBound])

  for title in [
    "Approve Helper…", "Enable Helper", "Update Helper", "Repair Helper",
    "Waiting for approval…", "Enabling helper…", "Updating helper…", "Repairing helper…",
    "Refresh", "Refreshing…", "Quit", "Disconnect & Quit",
  ] {
    let titleRange = try #require(menu.range(of: "\"\(title)\""))
    let beforeTitle = menu[..<titleRange.lowerBound]
    let menuTextCall = try #require(beforeTitle.range(of: "menuText(", options: .backwards))
    let localizedCall = try #require(
      beforeTitle.range(of: "SBMText.localized(", options: .backwards))
    #expect(menuTextCall.lowerBound < localizedCall.lowerBound)
  }

  for dynamicTitle in [
    "menuText(profile.name)", "menuText(node.name)", "menuText(section.name)",
    "menuText(deferred.headline)", "menuText(model.connectionPresentation.title)",
  ] {
    #expect(app.contains(dynamicTitle))
  }
  #expect(menu.contains("if let error = model.safeCurrentError"))
  #expect(menu.contains("menuErrorSummary("))
}

@Test func settingsAboutShowsLocalizedIdentityVersionAndUpdateControls() throws {
  let settings = try settingsSource("SettingsView.swift")
  let aboutStart = try #require(settings.range(of: "private var aboutSection: some View"))
  let versionStart = try #require(
    settings.range(of: "private var version", range: aboutStart.upperBound..<settings.endIndex))
  let about = String(settings[aboutStart.lowerBound..<versionStart.lowerBound])
  #expect(about.contains("Image(nsImage: NSApplication.shared.applicationIconImage)"))
  #expect(about.contains(#"Text("SBM")"#))
  #expect(about.contains("Text(SBMText.format(\"Version %@ (%@)\", version, build))"))
  #expect(about.contains(#"Text(SBMText.format("sing-box %@", CoreBuildInfo.version))"#))
  #expect(about.contains(#"Text("Native Apple Silicon menu bar client for sing-box.")"#))
  #expect(about.contains("!model.isCheckingForUpdates,"))
  #expect(about.contains("!model.updateStatus.isEmpty"))
  let checkButton = try #require(about.range(of: #"Button("Check for Updates")"#))
  let updateStatus = try #require(about.range(of: "Text(model.updateStatus)"))
  let statusRowStart = try #require(
    about.range(
      of: "HStack {",
      options: .backwards,
      range: about.startIndex..<checkButton.lowerBound
    )
  )
  let statusSpacer = try #require(
    about.range(of: "Spacer(minLength: 8)", range: checkButton.lowerBound..<updateStatus.lowerBound)
  )
  #expect(statusRowStart.lowerBound < checkButton.lowerBound)
  #expect(checkButton.lowerBound < statusSpacer.lowerBound)
  #expect(statusSpacer.lowerBound < updateStatus.lowerBound)
  #expect(!about.contains(#"Text("© 2026 stillnotfree")"#))
  #expect(about.contains("ProgressView(value: model.updateDownloadProgress ?? 0)"))
  #expect(about.contains("model.availableUpdateVersion != nil"))
  #expect(about.contains("model.downloadAndOpenUpdate()"))
  #expect(about.contains("model.checkForUpdates()"))
  #expect(about.contains(".disabled(model.isDownloadingUpdate || model.isCheckingForUpdates)"))
  #expect(about.contains(".disabled(model.isCheckingForUpdates || model.isDownloadingUpdate)"))
  #expect(about.contains(".font(.caption)"))
  #expect(about.contains(".foregroundStyle(.secondary)"))
  #expect(!about.contains("Core: sing-box %@"))
  #expect(!about.contains("Ядро: sing-box %@"))
  #expect(!about.contains("核心：sing-box %@"))

  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let localizationKey = #""sing-box %@" = "sing-box %@";"#
  for language in ["en", "ru", "zh-Hans"] {
    let url = root.appendingPathComponent(
      "Sources/SBM/Resources/\(language).lproj/Localizable.strings")
    let localization = try String(contentsOf: url, encoding: .utf8)
    #expect(localization.components(separatedBy: localizationKey).count - 1 == 1)
    #expect(localization.components(separatedBy: #""About SBM" = "#).count - 1 == 1)
    #expect(!localization.contains(#""About SBM…" = "#))
  }
}

@Test func livenessObservationsAndLatencyScheduling() throws {
  let model = try settingsSource("AppModel.swift")
  let refreshStart = try #require(model.range(of: "func refresh(observeAutoNode:"))
  let livenessStart = try #require(model.range(of: "private func startRuntimeLivenessPolling()"))
  let refreshBody = model[refreshStart.lowerBound..<livenessStart.lowerBound]
  let installGuard = try #require(refreshBody.range(of: "guard isInstalledInApplications else"))
  let autoObservation = try #require(refreshBody.range(of: "if observeAutoNode"))
  let registrationLookup = try #require(refreshBody.range(of: "refreshRegistrationStatus()"))
  let approvalContinuation = try #require(refreshBody.range(of: "continueHelperApprovalFlow()"))
  let statusTask = try #require(refreshBody.range(of: "Task {"))
  #expect(installGuard.lowerBound < autoObservation.lowerBound)
  #expect(installGuard.lowerBound < registrationLookup.lowerBound)
  #expect(installGuard.lowerBound < approvalContinuation.lowerBound)
  #expect(installGuard.lowerBound < statusTask.lowerBound)
  #expect(refreshBody.contains("updateNodeDescriptors: false"))

  let publicationStart = try #require(model.range(of: "private func publishLatency("))
  let publicationEnd = try #require(
    model.range(
      of: "func refreshLatencyIfNeeded()", range: publicationStart.upperBound..<model.endIndex))
  #expect(
    model[publicationStart.lowerBound..<publicationEnd.lowerBound].contains(
      "updateNodeDescriptors: false"))

  let applyStart = try #require(model.range(of: "private func apply("))
  let startupRestore = try #require(model.range(of: "private func restoreStartupVPNIfNeeded"))
  let applyBody = model[applyStart.lowerBound..<startupRestore.lowerBound]
  #expect(applyBody.contains("if shouldPrimeLatency"))
  #expect(applyBody.contains("scheduleLatencyRefresh(after: 0.25)"))
  #expect(applyBody.contains("if !isObservation { scheduleNextLatencyRefresh() }"))
  #expect(applyBody.contains("else {\n      cancelLatencyOperation()"))

  let timerStart = try #require(model.range(of: "private func scheduleLatencyRefresh(after"))
  let timerEnd = try #require(
    model.range(of: "private func validateProfile", range: timerStart.upperBound..<model.endIndex))
  let timerBody = model[timerStart.lowerBound..<timerEnd.lowerBound]
  let clear = try #require(timerBody.range(of: "self.latencyRefreshTask = nil"))
  let fire = try #require(timerBody.range(of: "self.refreshLatencyIfNeeded()"))
  #expect(clear.lowerBound < fire.lowerBound)
}

@Test func deletedProfilesReleaseRoutingAndSubscriptionTasks() throws {
  let model = try settingsSource("AppModel.swift")
  let loopStart = try #require(model.range(of: "private func startSubscriptionRefreshLoop()"))
  let loopEnd = try #require(model.range(of: "private func scheduleNextLatencyRefresh()"))
  let loop = model[loopStart.lowerBound..<loopEnd.lowerBound]
  let remoteCheck = try #require(loop.range(of: "SubscriptionClient.isRemoteSource($0.value)"))
  let taskCreation = try #require(loop.range(of: "subscriptionRefreshTask = Task"))
  let freshSource = try #require(ProfileLibrary.freshInstall().profiles.first?.sources.first)
  #expect(!SubscriptionClient.isRemoteSource(freshSource.value))
  #expect(loop.contains("subscriptionRefreshTask?.cancel()"))
  #expect(loop.contains("subscriptionRefreshTask = nil"))
  #expect(remoteCheck.lowerBound < taskCreation.lowerBound)
  #expect(loop.contains(".seconds(6 * 60 * 60)"))

  let deletionStart = try #require(
    model.range(of: "func deleteSelectedProfile(profileID: UUID)"))
  let deletionEnd = try #require(
    model.range(of: "func selectProfile(", range: deletionStart.upperBound..<model.endIndex))
  let deletion = model[deletionStart.lowerBound..<deletionEnd.lowerBound]
  let persist = try #require(deletion.range(of: "try persistProfileLibrary()"))
  let cleanup = try #require(
    deletion.range(of: "discardRoutingMutationState(for: profileID)"))
  let reconcile = try #require(deletion.range(of: "startSubscriptionRefreshLoop()"))
  #expect(persist.lowerBound < cleanup.lowerBound)
  #expect(cleanup.lowerBound < reconcile.lowerBound)

  let mutationStart = try #require(model.range(of: "private func performRoutingMutation("))
  let mutationEnd = try #require(
    model.range(
      of: "private func completeRoutingMutation(", range: mutationStart.upperBound..<model.endIndex)
  )
  let mutation = model[mutationStart.lowerBound..<mutationEnd.lowerBound]
  let validation = try #require(mutation.range(of: "try await validateProfile(updated)"))
  let cancellation = try #require(
    mutation.range(of: "guard !Task.isCancelled", range: validation.upperBound..<mutation.endIndex))
  #expect(validation.lowerBound < cancellation.lowerBound)
  for field in [
    "routingMutationQueues[profileID] = nil",
    "routingMutationQueueTokens[profileID] = nil",
    "routingMutationRevisions[profileID] = nil",
    "routingMutationStatuses[profileID] = nil",
  ] {
    #expect(model.contains(field))
  }
}

@Test func updaterUsesOneBoundedHTTPSOwnerAndMenuRowsAvoidPlaceholderImages() throws {
  let update = try settingsSource("UpdateService.swift")
  #expect(!update.contains("private static let session"))
  #expect(update.contains("sessionConfiguration: URLSessionConfiguration = .ephemeral"))
  #expect(update.contains("configuration.urlCache = nil"))
  #expect(update.contains("configuration.httpCookieStorage = nil"))
  #expect(update.contains("configuration.requestCachePolicy = .reloadIgnoringLocalCacheData"))
  #expect(update.contains("queue.maxConcurrentOperationCount = 1"))
  #expect(update.contains("session.finishTasksAndInvalidate()"))
  #expect(update.contains("maximumReleaseResponseSize: Int64 = 1_048_576"))
  #expect(update.contains("oversizeFailure: .invalidResponse"))
  #expect(!update.contains("UpdateHTTPSOnlySessionDelegate"))
  #expect(!update.contains("releaseURL:"))
  #expect(!update.contains("download(for: request)"))
  #expect(update.contains("let htmlURL: URL"))
  #expect(update.contains("release.htmlURL.scheme?.lowercased() == \"https\""))
  #expect(update.components(separatedBy: "willPerformHTTPRedirection").count - 1 == 1)
  let byteProgressStart = try #require(update.range(of: "didWriteData bytesWritten: Int64"))
  let byteProgressEnd = try #require(
    update.range(of: "func urlSession(", range: byteProgressStart.upperBound..<update.endIndex))
  let byteProgress = update[byteProgressStart.lowerBound..<byteProgressEnd.lowerBound]
  #expect(byteProgress.contains("totalBytesWritten > maximumBytes"))
  #expect(byteProgress.contains("totalBytesExpectedToWrite > maximumBytes"))
  #expect(byteProgress.contains("downloadTask.cancel()"))
  #expect(update.contains("request.timeoutInterval = 15"))

  let latestStart = try #require(update.range(of: "static func latest("))
  let downloadStart = try #require(
    update.range(of: "\n  static func download(", range: latestStart.upperBound..<update.endIndex))
  let latest = update[latestStart.lowerBound..<downloadStart.lowerBound]
  let metadataCleanup = try #require(
    latest.range(of: "defer { try? FileManager.default.removeItem(at: stagingURL) }")
  )
  let metadataAwait = try #require(latest.range(of: "try await transfer.start(request)"))
  #expect(metadataCleanup.lowerBound < metadataAwait.lowerBound)
  #expect(latest.contains("maximumBytes: maximumReleaseResponseSize"))

  let directoryStart = try #require(
    update.range(
      of: "\n  private static func updateDirectory(",
      range: downloadStart.upperBound..<update.endIndex))
  let download = update[downloadStart.lowerBound..<directoryStart.lowerBound]
  let downloadCleanup = try #require(
    download.range(of: "defer { try? FileManager.default.removeItem(at: stagingURL) }")
  )
  let downloadAwait = try #require(download.range(of: "try await transfer.start(request)"))
  #expect(downloadCleanup.lowerBound < downloadAwait.lowerBound)

  let app = try settingsSource("SBMApp.swift")
  #expect(!app.contains("selectionPlaceholderImage"))
  #expect(!app.contains("NSImage(size:"))
  #expect(app.contains(#"Image(systemName: "checkmark").hidden()"#))
}

@Test func missingFixedApplicationNodeRemainsRepresentedInPicker() throws {
  let source = try settingsSource("SettingsView.swift")
  #expect(
    source.contains(
      #"Text("Missing server").tag(ApplicationRoutingTarget.node(selectedNode))"#
    )
  )
  #expect(source.contains("!model.fixedApplicationRoutingNodes.contains"))
}

@Test func launchAtLoginHasNoAutomaticRegistrationAndUsesExplicitOSActions() throws {
  let model = try settingsSource("AppModel.swift")
  let settings = try settingsSource("SettingsView.swift")
  let startup = try #require(model.range(of: "guard performStartup else { return }"))
  let profileName = try #require(model.range(of: "var selectedProfileName"))
  let startupBody = String(model[startup.lowerBound..<profileName.lowerBound])
  #expect(startupBody.contains("refreshLaunchAtLoginStatus()"))
  #expect(!startupBody.contains("register()"))
  #expect(!startupBody.contains("enableLaunchAtLoginIfNeeded"))

  let loginAction = try #require(model.range(of: "func setLaunchAtLoginEnabled"))
  let restoreAction = try #require(model.range(of: "func setRestoreLastVPNStateEnabled"))
  let actionBody = String(model[loginAction.lowerBound..<restoreAction.lowerBound])
  let installGuard = try #require(actionBody.range(of: "guard isInstalledInApplications"))
  let taskStart = try #require(actionBody.range(of: "Task {"))
  let registerCall = try #require(actionBody.range(of: "loginItemService.register()"))
  let unregisterCall = try #require(actionBody.range(of: "loginItemService.unregister()"))
  #expect(installGuard.lowerBound < taskStart.lowerBound)
  #expect(installGuard.lowerBound < registerCall.lowerBound)
  #expect(installGuard.lowerBound < unregisterCall.lowerBound)
  #expect(
    actionBody.contains(
      #""Move SBM.app to the Applications folder, eject the DMG, then open the installed copy.""#
    ))
  #expect(actionBody.contains("loginItemService.register()"))
  #expect(actionBody.contains("loginItemService.unregister()"))
  #expect(actionBody.contains("refreshLaunchAtLoginStatus()"))
  #expect(!actionBody.contains("launchAtLoginEnabled = enabled"))

  let activation = try #require(model.range(of: "func applicationDidBecomeActive()"))
  let refresh = try #require(model.range(of: "func refresh(observeAutoNode:"))
  #expect(
    model[activation.lowerBound..<refresh.lowerBound].contains("refreshLaunchAtLoginStatus()"))
  #expect(settings.contains("\"Launch SBM at login\""))
  #expect(settings.contains("model.setLaunchAtLoginEnabled($0)"))
  #expect(settings.contains("\"Restore Last Connection State\""))
  #expect(!settings.contains("\"Restore\""))
  #expect(!settings.contains("Remember/Restore last VPN connection state"))
  #expect(settings.contains("get: { model.restoreLastVPNStateEnabled }"))
  #expect(settings.contains("model.setRestoreLastVPNStateEnabled($0)"))
  #expect(
    settings.contains(
      #"Text("When enabled, SBM reconnects after launch only if you last explicitly connected.")"#))

  for (language, translation) in [
    ("en", "Restore Last Connection State"),
    ("ru", "Восстанавливать последнее состояние подключения"),
    ("zh-Hans", "恢复上次连接状态"),
  ] {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let localizationURL = root.appendingPathComponent(
      "Sources/SBM/Resources/\(language).lproj/Localizable.strings")
    let localization = try String(contentsOf: localizationURL, encoding: .utf8)
    #expect(
      localization.contains(
        "\"Restore Last Connection State\" = \"\(translation)\";"))
    #expect(!localization.contains("\"Restore\" ="))
    #expect(!localization.contains("\"Remember/Restore last VPN connection state\" ="))
  }

  let connectAction = try #require(model.range(of: "func setCoreEnabled(_ enabled: Bool)"))
  let reconnectAction = try #require(model.range(of: "func reconnectToApply()"))
  let explicitIntentWrite =
    "userDefaults.set(enabled, forKey: lastExplicitVPNConnectedDefaultsKey)"
  #expect(
    model[connectAction.lowerBound..<reconnectAction.lowerBound].contains(explicitIntentWrite))
  #expect(model.components(separatedBy: explicitIntentWrite).count - 1 == 1)
}

@Test func settingsTabsPreserveCommonAndAdvancedFeatures() throws {
  let source = try settingsSource("SettingsView.swift")
  for required in [
    #"Label("Profiles""#,
    #"Label("Routing""#,
    #"Label("Advanced""#,
    #"Label("Settings", systemImage: "gearshape")"#,
    #"Text("Advanced Source Settings")"#,
    ".contentShape(Rectangle())",
    #"isSubscriptionURLVisible"#,
    #"Image(systemName: isSubscriptionURLVisible ? "eye.slash" : "eye")"#,
    #"Section("Website Routing")"#,
    #"Section("Application Routing")"#,
    #"Section("Routing Inspector")"#,
    #"DisclosureGroup("Routing Rules and Rule Sets (JSON)")"#,
    #"Button("Import Routing…")"#,
    #"Section("Latency")"#,
    #"Section("Local SOCKS5")"#,
    #"Section("DNS")"#,
    #"Picker("Direct DNS""#,
    #"Picker("Proxy DNS""#,
    #"Button("Save")"#,
    "dnsSettingsDraft",
    "model.ipv6PolicyDescription",
    "private var deferredRuntimeApplyCallout",
    "case .reconnectRequired:",
    "settingsHelperText()",
  ] {
    #expect(source.contains(required))
  }
  let advancedTabItem = try #require(
    source.range(of: #"Label("Advanced", systemImage: "gearshape.2")"#))
  let settingsTabItem = try #require(
    source.range(of: #"Label("Settings", systemImage: "gearshape")"#))
  #expect(advancedTabItem.lowerBound < settingsTabItem.lowerBound)
  #expect(!source.contains("Import Full JSON as New Profile"))
  #expect(source.components(separatedBy: "deferredRuntimeApplyCallout").count - 1 == 5)
  #expect(source.components(separatedBy: #"TextField("DoH URL""#).count - 1 == 2)
}

@Test func manualProfileBackupRestoreSettingsStayNativeAndUseExistingImporter() throws {
  let source = try settingsSource("SettingsView.swift")

  let profilesStart = try #require(source.range(of: "private var profilesTab: some View"))
  let recoveryStart = try #require(source.range(of: "@ViewBuilder private var recoverySection"))
  let profilesTab = String(source[profilesStart.lowerBound..<recoveryStart.lowerBound])
  #expect(!profilesTab.contains("profileLibraryTransferSection"))

  let advancedStart = try #require(source.range(of: "private var advancedTab: some View"))
  let settingsTabStart = try #require(
    source.range(
      of: "private var settingsTab: some View", range: advancedStart.upperBound..<source.endIndex)
  )
  let advancedTab = String(source[advancedStart.lowerBound..<settingsTabStart.lowerBound])
  #expect(advancedTab.contains("dnsSection"))
  #expect(!advancedTab.contains("startupLifecycleSection"))
  #expect(!advancedTab.contains("profileLibraryTransferSection"))

  let startupStart = try #require(
    source.range(
      of: "private var startupLifecycleSection",
      range: settingsTabStart.upperBound..<source.endIndex)
  )
  let settingsTab = String(source[settingsTabStart.lowerBound..<startupStart.lowerBound])
  let startupPosition = try #require(settingsTab.range(of: "startupLifecycleSection"))
  let transferPosition = try #require(settingsTab.range(of: "profileLibraryTransferSection"))
  let aboutPosition = try #require(settingsTab.range(of: "aboutSection"))
  #expect(startupPosition.lowerBound < transferPosition.lowerBound)
  #expect(transferPosition.lowerBound < aboutPosition.lowerBound)
  #expect(
    settingsTab.contains(
      "if !model.profileRecoveryRequired && model.profileLoadIssueMessage == nil {\n"
        + "        profileLibraryTransferSection\n      }"
    ))

  #expect(source.contains(#"Section("Backup & Restore")"#))
  #expect(source.contains(#"Button("Back Up…")"#))
  #expect(source.contains(#"Button("Restore…")"#))
  #expect(source.contains("model.backUpProfileLibrary(to: url)"))
  #expect(source.contains("model.restoreProfileLibrary(from: url)"))
  #expect(source.contains("NSSavePanel()"))
  #expect(source.contains("panel.allowedContentTypes = [.json]"))
  #expect(source.contains("panel.nameFieldStringValue = \"SBM-Profiles.json\""))
  #expect(source.contains(".disabled(!model.canBackUpProfileLibrary)"))
  #expect(source.contains(".disabled(!model.canRestoreProfileLibrary)"))
  #expect(source.contains("case .profileRestore: model.restoreProfileLibrary(from: url)"))
  #expect(source.components(separatedBy: "case .profileRestore:").count - 1 == 1)
  #expect(source.components(separatedBy: ".fileImporter(").count - 1 == 1)
  #expect(
    source.contains(
      "This backup includes profile, subscription, and connection credentials. Restore replaces the current profile library and is available only while the VPN runtime is safely stopped."
    )
  )
  #expect(!source.contains("FileDocument"))
}

@Test func manualProfileRestoreImportsBeforeResetAndSkipsRuntimeSideEffects() throws {
  let source = try settingsSource("AppModel.swift")
  let restoreStart = try #require(source.range(of: "func restoreProfileLibrary(from url: URL)"))
  let restoreEnd = try #require(
    source.range(of: "func importRecoveredProfileLibrary(from url: URL)"))
  let body = String(source[restoreStart.lowerBound..<restoreEnd.lowerBound])
  let gate = try #require(body.range(of: "guard canRestoreProfileLibrary"))
  let cancelStartup = try #require(body.range(of: "startupRestorePending = false"))
  let importLibrary = try #require(body.range(of: "ProfileStore.importProfileLibrary(from: url)"))
  let reset = try #require(body.range(of: "deferredRuntimeApplyPending = false"))
  let apply = try #require(body.range(of: "applyProfileLibrary(stored, reconcileRuntime: false)"))

  #expect(gate.lowerBound < cancelStartup.lowerBound)
  #expect(cancelStartup.lowerBound < importLibrary.lowerBound)
  #expect(importLibrary.lowerBound < reset.lowerBound)
  #expect(reset.lowerBound < apply.lowerBound)
  for assignment in [
    "deferredRuntimeApplyPending = false",
    "deferredRuntimeApplyPhase = .idle",
    "deferredRuntimeApplyError = nil",
    "routingMutationRevisions.removeAll()",
    "routingMutationQueueTokens.removeAll()",
    "routingMutationStatuses.removeAll()",
    "runtimeApplyStatus = .saved",
    "runtimeFailurePreservedPrevious = false",
    "runtimeFailureProfileID = nil",
  ] {
    #expect(body.contains(assignment))
  }
  #expect(!body.contains("submitRuntimeApply"))
  #expect(!body.contains("syncSubscriptions"))
  #expect(!body.contains("fetch("))
  #expect(!body.contains("restoreLastVPNStateDefaultsKey"))
  #expect(!body.contains("lastExplicitVPNConnectedDefaultsKey"))
  #expect(!body.contains("runtimeMutationController.desiredRunning"))
  #expect(!body.contains("userDefaults.set("))

  let backupEligibilityStart = try #require(source.range(of: "var canBackUpProfileLibrary"))
  let runtimeSafetyStart = try #require(source.range(of: "var profileReplacementRuntimeIsSafe"))
  let restoreEligibilityStart = try #require(source.range(of: "var canRestoreProfileLibrary"))
  let helperFields = try #require(source.range(of: "private let helperService"))
  let backupEligibility = String(
    source[backupEligibilityStart.lowerBound..<restoreEligibilityStart.lowerBound]
  )
  let runtimeSafety = String(
    source[runtimeSafetyStart.lowerBound..<restoreEligibilityStart.lowerBound]
  )
  let restoreEligibility = String(
    source[restoreEligibilityStart.lowerBound..<helperFields.lowerBound]
  )
  #expect(!runtimeSafety.contains("observedCoreState != .running"))
  #expect(runtimeSafety.contains("let registrationState = helperService.registrationState"))
  #expect(
    runtimeSafety.contains(
      "return coreIsKnownStopped || registrationState == .notRegistered"
    )
  )
  #expect(runtimeSafety.contains("|| registrationState == .notFound"))
  #expect(runtimeSafety.contains("!runtimeMutationController.isApplying"))
  #expect(runtimeSafety.contains("!helperSetupInProgress"))
  #expect(restoreEligibility.contains("canBackUpProfileLibrary && profileReplacementRuntimeIsSafe"))
  #expect(backupEligibility.contains("!isSyncing"))
  #expect(backupEligibility.contains("routingMutationQueues.isEmpty"))

  let resetStart = try #require(source.range(of: "func resetCorruptProfileLibrary()"))
  let revealStart = try #require(source.range(of: "func revealPreservedProfileLibrary()"))
  let resetBody = String(source[resetStart.lowerBound..<revealStart.lowerBound])
  #expect(resetBody.contains("guard profileRecoveryRequired else { return }"))
  #expect(resetBody.contains("guard profileReplacementRuntimeIsSafe else"))
  #expect(!resetBody.contains("guard !coreRunning else"))
}

@Test func startEmptyRecoveryUsesTheRestoreRuntimeSafetyPredicate() throws {
  let settings = try settingsSource("SettingsView.swift")
  let recoveryStart = try #require(settings.range(of: "private var recoverySection"))
  let transferStart = try #require(settings.range(of: "private var profileLibraryTransferSection"))
  let recovery = String(settings[recoveryStart.lowerBound..<transferStart.lowerBound])

  #expect(recovery.contains(".disabled(!model.profileReplacementRuntimeIsSafe)"))
  #expect(recovery.contains("if !model.profileReplacementRuntimeIsSafe"))
  #expect(
    recovery.contains(
      #"Text("Disconnect the VPN before starting with an empty profile library.")"#
    )
  )
}

@Test func profileStoreAdmissionAndCanonicalSaveStayBoundedAndAtomic() throws {
  let source = try settingsSource("ProfileStore.swift")
  let readerStart = try #require(
    source.range(of: "private static func readRegularFileWithoutFollowingSymlinks"))
  let storageStart = try #require(source.range(of: "private static func storageURL"))
  let reader = String(source[readerStart.lowerBound..<storageStart.lowerBound])
  #expect(reader.contains("O_RDONLY | O_NONBLOCK | O_NOFOLLOW"))
  #expect(
    reader.range(of: "open(url.path")!.lowerBound < reader.range(of: "fstat(descriptor")!.lowerBound
  )

  let saveStart = try #require(
    source.range(of: "static func saveProfileLibrary(_ library: ProfileLibrary, to url: URL)"))
  let backupStart = try #require(source.range(of: "private static func writeBackup"))
  let save = String(source[saveStart.lowerBound..<backupStart.lowerBound])
  let rename = try #require(save.range(of: "Darwin.rename(temporaryURL.path, url.path)"))
  #expect(save.contains("data.count <= maximumFileSize"))
  #expect(save.contains("fchmod(descriptor, 0o600)"))
  #expect(save.contains("(info.st_mode & 0o777) == 0o600"))
  #expect(save.contains("O_NOFOLLOW"))
  #expect(!save.contains("replaceItemAt"))
  #expect(!save.contains("setAttributes"))
  #expect(!save[rename.upperBound...].contains("try "))
}

@Test func manualProfileBackupWriterUsesAtomicSiblingReplacement() throws {
  let source = try settingsSource("ProfileStore.swift")
  let writerStart = try #require(source.range(of: "private static func writeBackup"))
  let writerEnd = try #require(source.range(of: "private static func decodeImportedProfileLibrary"))
  let writer = String(source[writerStart.lowerBound..<writerEnd.lowerBound])

  let destinationCheck = try #require(writer.range(of: "lstat(url.path, &existing)"))
  let temporarySibling = try #require(writer.range(of: "deletingLastPathComponent()"))
  let temporaryOpen = try #require(writer.range(of: "open(\n      temporaryURL.path"))
  let descriptorCheck = try #require(writer.range(of: "guard descriptor >= 0"))
  let deferredCleanup = try #require(writer.range(of: "defer {"))
  let cleanup = try #require(writer.range(of: "if !renamed { _ = unlink(temporaryURL.path) }"))
  let descriptorAdmission = try #require(writer.range(of: "fstat(descriptor, &info)"))
  let regularFileCheck = try #require(writer.range(of: "(info.st_mode & S_IFMT) == S_IFREG"))
  let linkCountCheck = try #require(writer.range(of: "info.st_nlink == 1"))
  let writeLoop = try #require(writer.range(of: "while offset < bytes.count"))
  let sync = try #require(writer.range(of: "fsync(descriptor)"))
  let close = try #require(writer.range(of: "let closeResult = close(descriptor)"))
  let replacement = try #require(writer.range(of: "Darwin.rename(temporaryURL.path, url.path)"))
  let renamed = try #require(writer.range(of: "renamed = true"))

  #expect(destinationCheck.lowerBound < replacement.lowerBound)
  #expect(temporarySibling.lowerBound < temporaryOpen.lowerBound)
  let openCall = String(writer[temporaryOpen.lowerBound..<descriptorCheck.lowerBound])
  for flag in ["O_WRONLY", "O_CREAT", "O_EXCL", "O_NOFOLLOW", "O_NONBLOCK"] {
    #expect(openCall.contains(flag))
  }
  #expect(openCall.contains("0o600"))
  #expect(descriptorCheck.lowerBound < deferredCleanup.lowerBound)
  #expect(deferredCleanup.lowerBound < cleanup.lowerBound)
  #expect(cleanup.lowerBound < descriptorAdmission.lowerBound)
  #expect(descriptorAdmission.lowerBound < regularFileCheck.lowerBound)
  #expect(regularFileCheck.lowerBound < linkCountCheck.lowerBound)
  #expect(linkCountCheck.lowerBound < writeLoop.lowerBound)
  #expect(writeLoop.lowerBound < sync.lowerBound)
  #expect(sync.lowerBound < close.lowerBound)
  #expect(close.lowerBound < replacement.lowerBound)
  #expect(replacement.lowerBound < renamed.lowerBound)
  #expect(!writer.contains("O_TRUNC"))
  #expect(!writer.contains("ftruncate"))
  #expect(!writer.contains("data.write(to:"))
  #expect(!writer.contains("write(to: url"))
}

@Test func automaticSelectionEditorIsScopedToTheSelectedSource() throws {
  let settings = try settingsSource("SettingsView.swift")
  let sourceStart = try #require(settings.range(of: "private var sourceSection"))
  let routingStart = try #require(
    settings.range(
      of: "private func settingsRow", range: sourceStart.upperBound..<settings.endIndex))
  let source = String(settings[sourceStart.lowerBound..<routingStart.lowerBound])
  let button = try #require(source.range(of: #"Button("Servers for Auto…")"#))
  let sourceStatus = try #require(source.range(of: "if let error = model.sourceEditorError"))
  #expect(sourceStatus.lowerBound < button.lowerBound)
  let footer = source[button.lowerBound...]
  #expect(footer.contains(".disabled(model.selectedSourceID == nil)"))
  #expect(footer.contains(".frame(maxWidth: .infinity, alignment: .center)"))
  #expect(source.contains("autoSelectionTarget = (profileID: profileID, sourceID: sourceID)"))
  #expect(!settings.contains(#"private var autoSelectionSection"#))
  #expect(settings.contains("$0.id == target.sourceID.uuidString"))
  #expect(settings.contains("model.autoSelectionExcludedNodeIDs.contains(node.id)"))
  #expect(settings.contains("profileID: target.profileID"))
  #expect(settings.contains("sourceID: target.sourceID"))
  #expect(settings.contains("Auto blocks until you include at least one node."))
}

@Test func settingsRenderTheSafeCurrentErrorAtTheTopOfEveryForm() throws {
  let settings = try settingsSource("SettingsView.swift")
  for (startMarker, endMarker) in [
    ("private var profilesTab", "@ViewBuilder private var recoverySection"),
    ("private var routingTab", "private var websiteRoutingSection"),
    ("private var advancedTab", "private var settingsTab"),
    ("private var settingsTab", "private var startupLifecycleSection"),
  ] {
    let start = try #require(settings.range(of: startMarker))
    let end = try #require(
      settings.range(of: endMarker, range: start.upperBound..<settings.endIndex))
    let form = settings[start.lowerBound..<end.lowerBound]
    let safeError = try #require(form.range(of: "currentErrorCallout"))
    let deferredCallout = try #require(form.range(of: "deferredRuntimeApplyCallout"))
    #expect(safeError.lowerBound < deferredCallout.lowerBound)
  }
  #expect(settings.contains("if let error = model.safeCurrentError"))
  #expect(settings.contains(#"Text(SBMText.format("Last error: %@", error))"#))
}

@Test func profileDeletionConfirmationCapturesAndConfirmsExactIDs() throws {
  let settings = try settingsSource("SettingsView.swift")
  #expect(settings.components(separatedBy: "@State private var deletionTarget:").count - 1 == 1)
  #expect(settings.contains("deletionTarget = (profileID, nil)"))
  #expect(settings.contains("deletionTarget = (profileID, sourceID)"))
  #expect(settings.contains("Text(deletionConfirmationTitle)"))
  #expect(settings.contains("model.deleteSelectedProfile(profileID: target.profileID)"))
  #expect(
    settings.contains(
      "model.deleteSelectedSource(profileID: target.profileID, sourceID: sourceID)"))
  #expect(settings.contains("Button(\"Cancel\", role: .cancel) { deletionTarget = nil }"))
  #expect(settings.contains("Delete source %@ from profile %@"))
  #expect(settings.contains("Delete profile: %@"))
}

@Test func dnsSettingsActionUsesApplyWithoutChangingItsDirtySaveBehavior() throws {
  let settings = try settingsSource("SettingsView.swift")
  let dnsStart = try #require(settings.range(of: "private var dnsSection"))
  let helperStart = try #require(
    settings.range(
      of: "private func customDNSTag",
      range: dnsStart.upperBound..<settings.endIndex
    ))
  let dns = String(settings[dnsStart.lowerBound..<helperStart.lowerBound])
  #expect(dns.contains(#"Button("Apply")"#))
  #expect(!dns.contains(#"Button("Save")"#))
  #expect(dns.contains(".buttonStyle(.borderedProminent)"))
  #expect(!dns.contains(".keyboardShortcut(.defaultAction)"))
  #expect(dns.contains("model.saveDNSSettings(dnsSettingsDraft)"))
  #expect(
    dns.contains(".disabled(model.helperSetupInProgress || dnsSettingsDraft == model.dnsSettings)"))
  #expect(settings.contains(".onChange(of: dnsSettingsDraft)"))
  #expect(settings.contains("model.clearStaleDNSValidationError(for: draft)"))
  #expect(
    dns.contains("dnsSettingsError != SBMText.localized(\"DNS settings are invalid\")")
  )
  #expect(dns.contains("(try? dnsSettingsDraft.validated()) == nil"))
  #expect(settings.contains(".onAppear { dnsSettingsDraft = model.dnsSettings }"))
}

@Test func presentationLocalizationKeysAreUniqueAndReplacedKeysAreUnused() throws {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let requiredKeys = [
    "Enable Helper",
    "Repair Helper",
    "Update Helper",
    "Approve Helper…",
    "Waiting for approval…",
    "Enabling helper…",
    "Updating helper…",
    "Repairing helper…",
    "Servers for Auto…",
    "Choose which servers Auto can use. Other servers remain available for manual selection.",
    "Auto servers for %@",
    "This source has no servers yet.",
    "This source is no longer available.",
    "Apply",
    "Waiting for macOS to replace helper…",
    "Waiting for macOS to update helper approval…",
    "Delete",
    "Delete profile: %@",
    "Delete source %@ from profile %@",
    "SBM support snapshot",
    "Local SOCKS5 saved configuration: enabled on 127.0.0.1:%@",
    "Local SOCKS5 saved configuration: disabled",
    "Local SOCKS5 listener presence: not observed by this snapshot",
    "Routing Rules and Rule Sets (JSON)",
    "Save and Refresh",
    "Enter a domain or IP address",
    "Subscription %@",
    "Main",
    "Done",
    "Expanded",
    "Collapsed",
  ]
  let removedKeys = [
    "Enable Background Helper",
    "Repair Background Helper",
    "Update Background Helper",
    "Approve Background Helper…",
    "Automatic Selection",
    "Servers for Auto",
    "HTTPS URL · vless:// · hysteria2:// · hy2:// · ss://",
    "Enter a domain or IP address to explain traffic routing.",
    "Excluded nodes remain available in the Server menu.",
    "SBM support snapshot (observations only)",
  ]

  for language in ["en", "ru", "zh-Hans"] {
    let url = root.appendingPathComponent(
      "Sources/SBM/Resources/\(language).lproj/Localizable.strings")
    let localization = try String(contentsOf: url, encoding: .utf8)
    for key in requiredKeys {
      let entry = "\"\(key)\" ="
      #expect(localization.components(separatedBy: entry).count - 1 == 1)
    }
    for key in removedKeys {
      #expect(!localization.contains("\"\(key)\" ="))
    }
  }
}

@Test func foregroundActivationUsesCurrentAppKitAPI() throws {
  let app = try settingsSource("SBMApp.swift")
  let settings = try settingsSource("SettingsView.swift")
  #expect(app.contains("NSApplication.shared.activate()"))
  #expect(settings.contains("NSApplication.shared.activate()"))
  #expect(!app.contains("ignoringOtherApps"))
  #expect(!settings.contains("ignoringOtherApps"))
}

@Test func routingTabUsesStableExplicitControlLayout() throws {
  let source = try settingsSource("SettingsView.swift")
  #expect(source.contains(#"Text("Domain or URL")"#))
  #expect(!source.contains(#"Domain or HTTP/HTTPS URL"#))
  #expect(source.contains("private let routingLabelWidth: CGFloat = 110"))
  #expect(source.contains("private let routingTargetWidth: CGFloat = 92"))
  #expect(source.contains("private let routingApplicationPickerWidth: CGFloat = 180"))
  #expect(source.contains("private let routingInspectorPickerWidth: CGFloat = 180"))
  #expect(source.contains(".frame(width: routingLabelWidth, alignment: .leading)"))
  #expect(source.contains(".frame(minWidth: 180, maxWidth: .infinity)"))
  #expect(source.contains(".frame(width: routingTargetWidth, alignment: .center)"))
  #expect(source.contains(".frame(width: routingApplicationPickerWidth, alignment: .center)"))
  #expect(source.contains(".frame(width: routingInspectorPickerWidth, alignment: .trailing)"))
  #expect(source.contains(#"TextField("Domain or URL", text: $model.websiteRoutingInput)"#))
  #expect(source.contains(#"TextField(text: $model.routingInspectorInput"#))
  #expect(source.contains(".multilineTextAlignment(.trailing)"))
}

@Test func applicationPickerCapturesItsProfileBeforePresentingTheSheet() throws {
  let source = try settingsSource("SettingsView.swift")
  let capture = try #require(source.range(of: "guard let profileID = model.selectedProfileID"))
  let sheet = try #require(source.range(of: "panel.beginSheetModal(for: window)"))
  #expect(capture.lowerBound < sheet.lowerBound)
  #expect(source.contains("replaceApplicationRoutingRule(ruleID, from: url, profileID: profileID)"))
  #expect(source.contains("addApplicationRoutingRule(from: url, profileID: profileID)"))
}

@Test @MainActor func websiteControlsDisableOnlyForUnavailableProfileOrHelperSetup() {
  let profile = ManagedProfile(
    name: "Website",
    payload: .compatibility(
      VPNProfile(connections: [
        ManagedConnection(
          outbound: .shadowsocks(
            ShadowsocksProfile(
              server: "proxy.example.test",
              port: 443,
              method: "aes-256-gcm",
              password: "synthetic-test-password",
              displayName: "Test"
            )
          )
        )
      ])
    )
  )
  let model = AppModel(
    profileLibraryLoader: {
      ProfileLibrary(profiles: [profile], selectedProfileID: profile.id)
    },
    profileLibrarySaver: { _ in },
    userDefaults: IsolatedTestUserDefaults(),
    performStartup: false
  )
  #expect(model.websiteRoutingControlsEnabled)
  model.helperSetupInProgress = true
  #expect(!model.websiteRoutingControlsEnabled)
}
