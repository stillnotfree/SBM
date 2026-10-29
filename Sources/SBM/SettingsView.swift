import AppKit
import SBMShared
import SwiftUI
import UniformTypeIdentifiers

private struct SettingsHelperTextModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 1)
  }
}

private struct FullWidthDisclosureGroupStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(spacing: 8) {
      Button {
        withAnimation { configuration.isExpanded.toggle() }
      } label: {
        HStack {
          configuration.label
          Spacer(minLength: 8)
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(Text(configuration.isExpanded ? "Expanded" : "Collapsed"))

      if configuration.isExpanded {
        configuration.content
      }
    }
  }
}

extension View {
  fileprivate func settingsHelperText() -> some View {
    modifier(SettingsHelperTextModifier())
  }
}

struct SettingsView: View {
  private enum JSONImportKind { case routing, profileRecovery, profileRestore }

  private let formControlWidth: CGFloat = 300
  private let routingLabelWidth: CGFloat = 110
  private let routingTargetWidth: CGFloat = 92
  private let routingApplicationPickerWidth: CGFloat = 180
  private let routingInspectorPickerWidth: CGFloat = 180
  private let routingActionButtonWidth: CGFloat = 72
  private let routingInspectorActionButtonWidth: CGFloat = 92

  @Bindable var model: AppModel
  @State private var isImportingJSON = false
  @State private var jsonImportKind = JSONImportKind.routing
  @State private var isConfirmingHWIDRegeneration = false
  @State private var isSubscriptionURLVisible = false
  @State private var isConfirmingProfileReset = false
  @State private var deletionTarget: (profileID: UUID, sourceID: UUID?)?
  @State private var dnsSettingsDraft = ManagedDNSSettings.defaults
  @State private var dnsSettingsError: String?
  @State private var autoSelectionTarget: (profileID: UUID, sourceID: UUID)?

  var body: some View {
    TabView {
      profilesTab
        .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
      routingTab
        .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
      advancedTab
        .tabItem { Label("Advanced", systemImage: "gearshape.2") }
      settingsTab
        .tabItem { Label("Settings", systemImage: "gearshape") }
    }
    .frame(minWidth: 620, minHeight: 520)
    .padding()
    .confirmationDialog(
      Text(deletionConfirmationTitle),
      isPresented: Binding(
        get: { deletionTarget.map { _ in true } ?? false },
        set: { if !$0 { deletionTarget = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        guard let target = deletionTarget else { return }
        deletionTarget = nil
        if let sourceID = target.sourceID {
          model.deleteSelectedSource(profileID: target.profileID, sourceID: sourceID)
        } else {
          model.deleteSelectedProfile(profileID: target.profileID)
        }
      }
      Button("Cancel", role: .cancel) { deletionTarget = nil }
    }
    .confirmationDialog(
      "Regenerate subscription HWID?",
      isPresented: $isConfirmingHWIDRegeneration,
      titleVisibility: .visible
    ) {
      Button("Regenerate HWID", role: .destructive) { model.regenerateSubscriptionHWID() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Changing HWID may make providers with a device limit treat this Mac as a new device.")
    }
    .confirmationDialog(
      "Start with an empty profile library?",
      isPresented: $isConfirmingProfileReset,
      titleVisibility: .visible
    ) {
      Button("Preserve Current File and Start Empty", role: .destructive) {
        model.resetCorruptProfileLibrary()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("SBM will preserve the current profile file unchanged before creating an empty library.")
    }
    .fileImporter(
      isPresented: $isImportingJSON,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else { return }
      switch jsonImportKind {
      case .routing: model.importRoutingPolicy(from: url)
      case .profileRecovery: model.importRecoveredProfileLibrary(from: url)
      case .profileRestore: model.restoreProfileLibrary(from: url)
      }
    }
    .sheet(
      isPresented: Binding(
        get: { autoSelectionTarget != nil },
        set: { if !$0 { autoSelectionTarget = nil } }
      ),
      onDismiss: { autoSelectionTarget = nil }
    ) {
      autoSelectionSheet
    }
    .onChange(of: model.selectedProfileID) { _, profileID in
      if profileID != autoSelectionTarget?.profileID { autoSelectionTarget = nil }
    }
    .onChange(of: model.selectedSourceID) { _, sourceID in
      if sourceID != autoSelectionTarget?.sourceID { autoSelectionTarget = nil }
    }
    .onDisappear {
      isSubscriptionURLVisible = false
    }
  }

  private var deletionConfirmationTitle: String {
    guard let target = deletionTarget,
      let profile = model.profiles.first(where: { $0.id == target.profileID })
    else { return SBMText.localized("Delete") }
    if let sourceID = target.sourceID {
      guard let source = profile.sources.first(where: { $0.id == sourceID }) else {
        return SBMText.localized("Delete")
      }
      return SBMText.format("Delete source %@ from profile %@", source.name, profile.name)
    }
    return SBMText.format("Delete profile: %@", profile.name)
  }

  @ViewBuilder private var currentErrorCallout: some View {
    if let error = model.safeCurrentError {
      Text(SBMText.format("Last error: %@", error))
        .font(.caption)
        .foregroundStyle(.orange)
        .textSelection(.enabled)
    }
  }

  private var profilesTab: some View {
    Form {
      currentErrorCallout
      deferredRuntimeApplyCallout
      if model.profileRecoveryRequired { recoverySection }
      if let profileLoadIssueMessage = model.profileLoadIssueMessage {
        profileLoadIssueSection(profileLoadIssueMessage)
      }
      profileSection
      sourceSection
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private var recoverySection: some View {
    Section("Profile Library Recovery") {
      Label(model.profileRecoveryMessage, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      HStack {
        Button("Import Recovered Library…") {
          jsonImportKind = .profileRecovery
          isImportingJSON = true
        }
        Button("Show Preserved Copy") { model.revealPreservedProfileLibrary() }
        Spacer()
        Button("Start Empty…", role: .destructive) { isConfirmingProfileReset = true }
          .disabled(!model.profileReplacementRuntimeIsSafe)
      }
      if !model.profileReplacementRuntimeIsSafe {
        Text("Disconnect the VPN before starting with an empty profile library.")
          .settingsHelperText()
      }
    }
  }

  private func profileLoadIssueSection(_ message: String) -> some View {
    Section("Profile Data") {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
  }

  private var profileLibraryTransferSection: some View {
    Section("Backup & Restore") {
      HStack {
        Button("Back Up…") {
          let panel = NSSavePanel()
          panel.allowedContentTypes = [.json]
          panel.nameFieldStringValue = "SBM-Profiles.json"
          guard panel.runModal() == .OK, let url = panel.url else { return }
          model.backUpProfileLibrary(to: url)
        }
        .disabled(!model.canBackUpProfileLibrary)
        Button("Restore…") {
          jsonImportKind = .profileRestore
          isImportingJSON = true
        }
        .disabled(!model.canRestoreProfileLibrary)
      }
      Text(
        "This backup includes profile, subscription, and connection credentials. Restore replaces the current profile library and is available only while the VPN runtime is safely stopped."
      )
      .settingsHelperText()
    }
  }

  private var profileSection: some View {
    Section("Profile") {
      settingsRow("Active profile") {
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          Picker(
            "Active profile",
            selection: Binding(
              get: { model.selectedProfileID },
              set: { if let id = $0 { model.selectProfile(id) } }
            )
          ) {
            ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
          }
          .labelsHidden()
          .frame(width: 150)
          ControlGroup {
            Button {
              model.addProfile()
            } label: {
              Label("Add profile", systemImage: "plus").labelStyle(.iconOnly).frame(width: 24)
            }
            .help("Add profile")
            Button {
              if let profileID = model.selectedProfileID {
                deletionTarget = (profileID, nil)
              }
            } label: {
              Label("Delete selected profile", systemImage: "minus")
                .labelStyle(.iconOnly).frame(width: 24)
            }
            .help("Delete selected profile")
            .disabled(model.selectedProfileID == nil)
          }
        }
      }
      settingsRow("Profile name") {
        HStack(spacing: 8) {
          TextField("Profile name", text: $model.profileName)
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.saveProfileName() }
          Button("Save") { model.saveProfileName() }
            .disabled(!model.profileNameSaveEnabled)
        }
      }
      if let error = model.profileNameError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
    }
  }

  @ViewBuilder private var sourceSection: some View {
    Section("Subscription Sources") {
      if model.canManageSources {
        settingsRow("Source") {
          HStack(spacing: 8) {
            Spacer(minLength: 0)
            Picker(
              "Source",
              selection: Binding(
                get: { model.selectedSourceID },
                set: { if let id = $0 { model.selectSource(id) } }
              )
            ) {
              ForEach(model.selectedProfileSources) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .frame(width: 150)
            ControlGroup {
              Button {
                model.addSource()
              } label: {
                Label("Add source", systemImage: "plus").labelStyle(.iconOnly).frame(width: 24)
              }
              .help("Add subscription or connection")
              Button {
                if let profileID = model.selectedProfileID,
                  let sourceID = model.selectedSourceID
                {
                  deletionTarget = (profileID, sourceID)
                }
              } label: {
                Label("Delete source", systemImage: "minus")
                  .labelStyle(.iconOnly).frame(width: 24)
              }
              .help("Delete selected source")
              .disabled(model.selectedSourceID == nil)
            }
          }
        }
        settingsRow("Source name") {
          TextField("Source name", text: $model.sourceName)
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .disabled(model.selectedSourceID == nil)
        }
        VStack(spacing: 3) {
          settingsRow("Subscription") {
            HStack(spacing: 8) {
              Group {
                if isSubscriptionURLVisible {
                  TextField("Subscription", text: $model.subscriptionURL)
                    .multilineTextAlignment(.trailing)
                } else {
                  SecureField("Subscription", text: $model.subscriptionURL)
                    .multilineTextAlignment(.trailing)
                }
              }
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              Button {
                isSubscriptionURLVisible.toggle()
              } label: {
                Image(systemName: isSubscriptionURLVisible ? "eye.slash" : "eye")
                  .frame(width: 18, height: 18)
              }
              .buttonStyle(.borderless)
              .help(isSubscriptionURLVisible ? "Hide subscription URL" : "Show subscription URL")
            }
          }
        }
        .disabled(model.selectedSourceID == nil || model.isSyncing)

        DisclosureGroup {
          settingsRow("Exclude regex") {
            TextField(text: $model.sourceExcludeRegex, prompt: Text("(?i)lte|russia")) {
              Text("Exclude regex")
            }
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
          }
          settingsRow("User-Agent") {
            TextField("User-Agent", text: $model.subscriptionUserAgent)
              .multilineTextAlignment(.trailing)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
          }
          settingsRow("X-App-Version") {
            TextField("X-App-Version", text: $model.subscriptionAppVersion)
              .multilineTextAlignment(.trailing)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
          }
          settingsRow("X-Device-OS") {
            TextField("X-Device-OS", text: $model.subscriptionDeviceOS)
              .multilineTextAlignment(.trailing)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
          }
          settingsRow("X-Ver-OS") {
            TextField("X-Ver-OS", text: $model.subscriptionDeviceOSVersion)
              .multilineTextAlignment(.trailing)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
          }
          settingsRow("X-Device-Model") {
            TextField("X-Device-Model", text: $model.subscriptionDeviceModel)
              .multilineTextAlignment(.trailing)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
          }
          settingsRow("X-HWID") {
            TextField("X-HWID", text: $model.subscriptionHWID)
              .multilineTextAlignment(.trailing)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
          }
          HStack {
            Button("Copy HWID") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(model.subscriptionHWID, forType: .string)
            }
            .disabled(model.subscriptionHWID.isEmpty)
            Button("Regenerate HWID…", role: .destructive) {
              isConfirmingHWIDRegeneration = true
            }
            Spacer()
            Button("Reset Request Preset") { model.resetSubscriptionRequestPreset() }
          }
          Text("Each source keeps its own filter and request headers.")
            .settingsHelperText()
        } label: {
          Text("Advanced Source Settings")
        }
        .disclosureGroupStyle(FullWidthDisclosureGroupStyle())
        .disabled(model.selectedSourceID == nil || model.isSyncing)

        HStack {
          Button("Save and Refresh") { model.saveAndSyncSubscription() }
            .disabled(
              model.isSyncing || model.helperSetupInProgress
                || !model.sourceDraftIsValid || !model.sourceDraftNeedsSaveOrSync
            )
          if model.isSyncing { ProgressView().controlSize(.small) }
          Text(model.subscriptionStatus)
            .foregroundStyle(statusColor)
        }
        if let error = model.sourceEditorError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }
        Button("Servers for Auto…") {
          guard let profileID = model.selectedProfileID,
            let sourceID = model.selectedSourceID
          else { return }
          autoSelectionTarget = (profileID: profileID, sourceID: sourceID)
        }
        .disabled(model.selectedSourceID == nil)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
  }

  private func settingsRow<Content: View>(
    _ title: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 12) {
      Text(title)
        .lineLimit(1)
        .layoutPriority(1)
      Spacer(minLength: 12)
      content()
        .frame(width: formControlWidth, alignment: .trailing)
    }
    .frame(maxWidth: .infinity)
  }

  private var routingTab: some View {
    Form {
      currentErrorCallout
      deferredRuntimeApplyCallout
      websiteRoutingSection
      applicationRoutingSection
      routingInspectorSection
      advancedRoutingSection
    }
    .formStyle(.grouped)
  }

  private var websiteRoutingSection: some View {
    Section("Website Routing") {
      HStack(spacing: 12) {
        Text("Domain or URL")
          .lineLimit(1)
          .frame(width: routingLabelWidth, alignment: .leading)
        TextField("Domain or URL", text: $model.websiteRoutingInput)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .frame(minWidth: 180, maxWidth: .infinity)
          .layoutPriority(1)
          .onSubmit { model.addWebsiteRoutingRule() }
        Picker("Route", selection: $model.websiteRoutingTarget) {
          Text("Proxy").tag(WebsiteRoutingTarget.selectedProxy)
          Text("Direct").tag(WebsiteRoutingTarget.direct)
          Text("Reject").tag(WebsiteRoutingTarget.reject)
        }
        .labelsHidden()
        .frame(width: routingTargetWidth, alignment: .center)
        Button(model.websiteRoutingActionTitle) { model.addWebsiteRoutingRule() }
          .frame(width: routingActionButtonWidth)
          .disabled(!model.websiteRoutingControlsEnabled || model.websiteRoutingInput.isEmpty)
      }
      .frame(maxWidth: .infinity)

      ForEach(model.websiteRoutingRules) { rule in
        HStack(spacing: 8) {
          Text(rule.domain)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
              Button("Edit Domain…") { model.beginWebsiteRoutingEdit(rule.id) }
              if model.websiteRoutingEditingRuleID == rule.id {
                Button("Cancel Edit") { model.cancelWebsiteRoutingEdit() }
              }
            }
          Picker(
            SBMText.format("Route for %@", rule.domain),
            selection: Binding(
              get: { rule.target },
              set: { model.setWebsiteRoutingTarget(rule.id, target: $0) }
            )
          ) {
            Text("Proxy").tag(WebsiteRoutingTarget.selectedProxy)
            Text("Direct").tag(WebsiteRoutingTarget.direct)
            Text("Reject").tag(WebsiteRoutingTarget.reject)
          }
          .labelsHidden()
          .frame(width: routingTargetWidth, alignment: .center)
          .disabled(!model.websiteRoutingControlsEnabled)
          HStack {
            Spacer(minLength: 0)
            Button(role: .destructive) {
              model.removeWebsiteRoutingRule(rule.id)
            } label: {
              Label(SBMText.format("Remove %@", rule.domain), systemImage: "trash")
                .labelStyle(.iconOnly)
            }
            .frame(width: routingActionButtonWidth)
            .help("Remove website rule")
            .disabled(!model.websiteRoutingControlsEnabled)
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
      Text(
        "A domain rule also applies to its subdomains. Application Routing precedes broader Website and imported policy."
      )
      .settingsHelperText()
      routingMutationFeedback(model.websiteRoutingStatus)
    }
  }

  private var applicationRoutingSection: some View {
    Section("Application Routing") {
      HStack {
        Text("Route traffic by an application's exact main executable.")
          .settingsHelperText()
        Spacer()
        Button("Add Application…") { selectRoutedApplication() }
          .disabled(model.selectedProfileID == nil || model.helperSetupInProgress)
      }
      ForEach(model.applicationRoutingRules) { rule in
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(rule.displayName)
              .lineLimit(1)
              .truncationMode(.middle)
            Text(model.applicationRoutingRuleIsResolved(rule) ? "Resolved" : "Unresolved")
              .font(.caption)
              .foregroundStyle(model.applicationRoutingRuleIsResolved(rule) ? .green : .orange)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Picker(
            "Route",
            selection: Binding(
              get: { rule.target },
              set: { model.setApplicationRoutingTarget(rule.id, target: $0) }
            )
          ) {
            Text("Direct").tag(ApplicationRoutingTarget.direct)
            Text("Proxy").tag(ApplicationRoutingTarget.selectedProxy)
            Text("Reject").tag(ApplicationRoutingTarget.reject)
            if case .node(let selectedNode) = rule.target,
              !model.fixedApplicationRoutingNodes.contains(where: { $0.id == selectedNode })
            {
              Divider()
              Text("Missing server").tag(ApplicationRoutingTarget.node(selectedNode))
            }
            if !model.fixedApplicationRoutingNodes.isEmpty {
              Divider()
              ForEach(model.fixedApplicationRoutingNodes) {
                Text($0.name).tag(ApplicationRoutingTarget.node($0.id))
              }
            }
          }
          .labelsHidden()
          .frame(width: routingApplicationPickerWidth, alignment: .center)
          .disabled(model.helperSetupInProgress)
          HStack {
            Spacer(minLength: 0)
            Button(role: .destructive) {
              model.removeApplicationRoutingRule(rule.id)
            } label: {
              Label("Remove application rule", systemImage: "trash")
                .labelStyle(.iconOnly)
            }
            .frame(width: routingActionButtonWidth)
            .help("Remove application rule")
            .disabled(model.helperSetupInProgress)
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
          .contextMenu {
            Button("Change Application…") { selectRoutedApplication(for: rule.id) }
          }
        }
      }
      routingMutationFeedback(model.applicationRoutingStatus)
    }
  }

  private var routingInspectorSection: some View {
    Section("Routing Inspector") {
      HStack(spacing: 12) {
        Text("Traffic from")
          .lineLimit(1)
          .frame(width: routingLabelWidth, alignment: .leading)
        Spacer(minLength: 0)
        Picker("Traffic from", selection: $model.routingInspectorApplicationID) {
          Text("Default traffic").tag(UUID?.none)
          ForEach(model.applicationRoutingRules) { Text($0.displayName).tag(Optional($0.id)) }
        }
        .labelsHidden()
        .frame(width: routingInspectorPickerWidth, alignment: .trailing)
      }
      .frame(maxWidth: .infinity)

      HStack(spacing: 12) {
        Text("Domain or IP")
          .lineLimit(1)
          .frame(width: routingLabelWidth, alignment: .leading)
        TextField(text: $model.routingInspectorInput, prompt: Text("Enter a domain or IP address"))
        {
          Text("Domain or IP")
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(minWidth: 180, maxWidth: .infinity)
        .layoutPriority(1)
        .onSubmit { model.inspectRouting() }
        Button("Explain") { model.inspectRouting() }
          .frame(width: routingInspectorActionButtonWidth)
          .disabled(model.selectedProfileID == nil || model.routingInspectorInput.isEmpty)
      }
      .frame(maxWidth: .infinity)

      if !model.routingInspectorOutput.isEmpty {
        Text(model.routingInspectorOutput)
          .font(.callout.weight(.medium)).textSelection(.enabled)
      }
      if !model.routingInspectorDetails.isEmpty {
        DisclosureGroup("Details") {
          Text(model.routingInspectorDetails)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary).textSelection(.enabled)
        }
        .disclosureGroupStyle(FullWidthDisclosureGroupStyle())
      }
      Text(
        "Explain uses saved policy only; remote rule-set membership remains unknown locally."
      )
      .settingsHelperText()
    }
  }

  private var advancedRoutingSection: some View {
    Section {
      DisclosureGroup("Routing Rules and Rule Sets (JSON)") {
        Text(model.routingPolicyStatus).foregroundStyle(statusColor)
        HStack {
          Button("Import Routing…") {
            jsonImportKind = .routing
            isImportingJSON = true
          }
          .disabled(!model.canManageRoutingPolicy || model.helperSetupInProgress)
          Button("Open Current…") { model.openCurrentRoutingPolicy() }
            .disabled(!model.hasRoutingPolicy)
          Button("Remove", role: .destructive) { model.clearRoutingPolicy() }
            .disabled(!model.hasRoutingPolicy || model.helperSetupInProgress)
        }
        Text("Advanced custom sing-box route rules and remote source/binary rule sets.")
          .settingsHelperText()
      }
      .disclosureGroupStyle(FullWidthDisclosureGroupStyle())
    }
  }

  private var advancedTab: some View {
    Form {
      currentErrorCallout
      deferredRuntimeApplyCallout
      latencySection
      localSOCKSSection
      ipv6Section
      dnsSection
    }
    .formStyle(.grouped)
    .onAppear { dnsSettingsDraft = model.dnsSettings }
    .onChange(of: dnsSettingsDraft) { _, draft in
      model.clearStaleDNSValidationError(for: draft)
    }
  }

  private var settingsTab: some View {
    Form {
      currentErrorCallout
      deferredRuntimeApplyCallout
      startupLifecycleSection
      if !model.profileRecoveryRequired && model.profileLoadIssueMessage == nil {
        profileLibraryTransferSection
      }
      aboutSection
    }
    .formStyle(.grouped)
  }

  private var startupLifecycleSection: some View {
    Section("Startup") {
      Toggle(
        "Launch SBM at login",
        isOn: Binding(
          get: { model.launchAtLoginEnabled },
          set: { model.setLaunchAtLoginEnabled($0) }
        )
      )
      Toggle(
        "Restore Last Connection State",
        isOn: Binding(
          get: { model.restoreLastVPNStateEnabled },
          set: { model.setRestoreLastVPNStateEnabled($0) }
        )
      )
      Text("When enabled, SBM reconnects after launch only if you last explicitly connected.")
        .settingsHelperText()
      if let error = model.launchAtLoginError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if let error = model.startupRestoreError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  private var aboutSection: some View {
    Section("About SBM") {
      HStack(spacing: 12) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .scaledToFit()
          .frame(width: 48, height: 48)
        VStack(alignment: .leading, spacing: 4) {
          Text("SBM")
            .font(.headline)
          Text(SBMText.format("Version %@ (%@)", version, build))
            .foregroundStyle(.secondary)
          Text(SBMText.format("sing-box %@", CoreBuildInfo.version))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }

      Text("Native Apple Silicon menu bar client for sing-box.")
        .font(.callout)
        .foregroundStyle(.secondary)

      if model.isDownloadingUpdate {
        ProgressView(value: model.updateDownloadProgress ?? 0)
        Text("\(Int(((model.updateDownloadProgress ?? 0) * 100).rounded()))%")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      HStack {
        if model.availableUpdateVersion != nil {
          Button("Download Update") {
            model.downloadAndOpenUpdate()
          }
          .disabled(model.isDownloadingUpdate || model.isCheckingForUpdates)
        } else {
          Button("Check for Updates") {
            model.checkForUpdates()
          }
          .disabled(model.isCheckingForUpdates || model.isDownloadingUpdate)
        }
        Spacer(minLength: 8)
        if !model.isCheckingForUpdates,
          !model.updateStatus.isEmpty
        {
          Text(model.updateStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(model.updateStatus)
        }
      }
    }
  }

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "Development"
  }

  private var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
  }

  private var autoSelectionSheet: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let target = autoSelectionTarget,
        model.selectedProfileID == target.profileID,
        model.selectedSourceID == target.sourceID,
        let source = model.selectedProfileSources.first(where: { $0.id == target.sourceID })
      {
        Text(SBMText.format("Auto servers for %@", source.name))
          .font(.headline)
        Text(
          "Choose which servers Auto can use. Other servers remain available for manual selection."
        )
        .settingsHelperText()
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            if let section = model.autoSelectionSections.first(where: {
              $0.id == target.sourceID.uuidString
            }) {
              ForEach(section.nodes) { node in
                Toggle(
                  isOn: Binding(
                    get: { !model.autoSelectionExcludedNodeIDs.contains(node.id) },
                    set: {
                      model.setNodeIncludedInAuto(
                        node.id, included: $0, profileID: target.profileID,
                        sourceID: target.sourceID
                      )
                    }
                  )
                ) {
                  Text(node.name)
                }
                .disabled(model.helperSetupInProgress)
              }
            } else {
              Text("This source has no servers yet.")
                .foregroundStyle(.secondary)
            }
          }
        }
        .frame(maxHeight: 360)
        if model.autoSelectionAllExcluded {
          Text("Auto blocks until you include at least one node.")
            .settingsHelperText()
        }
        routingMutationFeedback(model.autoSelectionStatus)
      } else {
        Text("This source is no longer available.")
          .foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Done") { autoSelectionTarget = nil }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding()
    .frame(minWidth: 360, minHeight: 220, maxHeight: 480)
  }

  private var latencySection: some View {
    Section("Latency") {
      settingsRow("Automatic interval") {
        HStack(spacing: 6) {
          TextField(
            "Minutes",
            value: $model.latencyIntervalMinutesDraft,
            format: .number.grouping(.never)
          )
          .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 74)
          Text("min").foregroundStyle(.secondary)
        }
      }
      settingsRow("Test target") {
        TextField("Test target", text: $model.latencyTestURLDraft)
          .labelsHidden().textFieldStyle(.roundedBorder)
      }
      HStack(spacing: 8) {
        Button("Reset to Default") { model.resetLatencySettings() }
          .disabled(
            model.latencyIntervalMinutesDraft == 10
              && model.latencyTestURLDraft == LatencyTargetPolicy.defaultURL
          )
        Spacer()
        applyProgress(model.latencyApplyInProgress)
        Button("Apply") { _ = model.applyLatencySettings() }
          .keyboardShortcut(.defaultAction)
          .disabled(
            model.latencyApplyInProgress || !model.latencySettingsDirty
              || !model.latencySettingsValid
          )
      }
      if let error = model.latencySettingsError {
        HStack(spacing: 8) {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
          Spacer()
          if model.canRetryLatencySynchronization {
            Button("Retry Sync") { model.retryLatencySynchronization() }
              .disabled(model.latencyApplyInProgress)
          }
        }
      }
      Text("Latency requests use the configured HTTPS target through each tested proxy.")
        .settingsHelperText()
    }
  }

  private var localSOCKSSection: some View {
    Section("Local SOCKS5") {
      settingsRow("Enable local SOCKS5 proxy") {
        Toggle("Enable local SOCKS5 proxy", isOn: $model.localSOCKSEnabledDraft)
          .labelsHidden()
      }
      settingsRow("Port") {
        TextField(
          "Port",
          value: $model.localSOCKSPortDraft,
          format: .number.grouping(.never)
        )
        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
      }
      HStack {
        Spacer()
        applyProgress(model.localSOCKSApplyInProgress)
        Button("Apply") { _ = model.applyLocalSOCKSSettings() }
          .keyboardShortcut(.defaultAction)
          .disabled(
            model.localSOCKSApplyInProgress || !model.localSOCKSSettingsDirty
              || !model.localSOCKSSettingsValid
          )
      }
      if let error = model.localSOCKSError {
        HStack(spacing: 8) {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
          Spacer()
          if model.canRetryLocalSOCKSSynchronization {
            Button("Retry Sync") { model.retryLocalSOCKSSynchronization() }
              .disabled(model.localSOCKSApplyInProgress)
          }
        }
      }
      Text("The loopback listener is available only while the VPN is connected.")
        .settingsHelperText()
    }
  }

  private var ipv6Section: some View {
    Section("Network Policy") {
      settingsRow("IPv6") {
        Toggle(
          "IPv6",
          isOn: Binding(
            get: { model.ipv6Enabled },
            set: { model.setIPv6Enabled($0) }
          )
        )
        .labelsHidden()
      }
      Text(model.ipv6PolicyDescription).settingsHelperText()
    }
  }

  private var dnsSection: some View {
    Section("DNS") {
      Picker("Direct DNS", selection: $dnsSettingsDraft.direct) {
        Text("System").tag(ManagedDNSChoice.system)
        Text("Cloudflare").tag(ManagedDNSChoice.cloudflare)
        Text("Google").tag(ManagedDNSChoice.google)
        Text("Yandex").tag(ManagedDNSChoice.yandex)
        Text("Quad9").tag(ManagedDNSChoice.quad9)
        Text("AdGuard").tag(ManagedDNSChoice.adguard)
        Text("Custom DoH").tag(customDNSTag(for: dnsSettingsDraft.direct))
      }
      if case .customDoH = dnsSettingsDraft.direct {
        TextField("DoH URL", text: dnsURLBinding(for: \.direct))
      }
      Text("Direct DNS serves Direct traffic and managed proxy-server hostname resolution.")
        .settingsHelperText()
      Picker("Proxy DNS", selection: $dnsSettingsDraft.proxy) {
        Text("Cloudflare").tag(ManagedDNSChoice.cloudflare)
        Text("Google").tag(ManagedDNSChoice.google)
        Text("Yandex").tag(ManagedDNSChoice.yandex)
        Text("Quad9").tag(ManagedDNSChoice.quad9)
        Text("AdGuard").tag(ManagedDNSChoice.adguard)
        Text("Custom DoH").tag(customDNSTag(for: dnsSettingsDraft.proxy))
      }
      if case .customDoH = dnsSettingsDraft.proxy {
        TextField("DoH URL", text: dnsURLBinding(for: \.proxy))
      }
      Text("Proxy DNS is sent through the selected proxy.").settingsHelperText()
      if let dnsSettingsError,
        dnsSettingsError != SBMText.localized("DNS settings are invalid")
          || (try? dnsSettingsDraft.validated()) == nil
      {
        Label(dnsSettingsError, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
      }
      HStack {
        Spacer()
        Button("Apply") {
          let saved = model.saveDNSSettings(dnsSettingsDraft)
          dnsSettingsError =
            saved ? nil : model.lastError ?? SBMText.localized("DNS settings were not saved")
          if saved { dnsSettingsDraft = model.dnsSettings }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.helperSetupInProgress || dnsSettingsDraft == model.dnsSettings)
      }
    }
  }

  private func customDNSTag(for choice: ManagedDNSChoice) -> ManagedDNSChoice {
    if case .customDoH = choice { return choice }
    return .customDoH("")
  }

  private func dnsURLBinding(
    for keyPath: WritableKeyPath<ManagedDNSSettings, ManagedDNSChoice>
  ) -> Binding<String> {
    Binding(
      get: {
        if case .customDoH(let value) = dnsSettingsDraft[keyPath: keyPath] { return value }
        return ""
      },
      set: { dnsSettingsDraft[keyPath: keyPath] = .customDoH($0) }
    )
  }

  private var statusColor: Color {
    model.subscriptionStatusLevel == .warning
      ? .orange : model.subscriptionStatusLevel == .success ? .green : .secondary
  }

  private func applyProgress(_ isVisible: Bool) -> some View {
    ZStack {
      ProgressView()
        .controlSize(.small)
        .opacity(isVisible ? 1 : 0)
    }
    .frame(width: 16, height: 16)
    .accessibilityHidden(!isVisible)
  }

  private var deferredRuntimeApplyCallout: some View {
    Group {
      if let presentation = model.deferredRuntimeApplyPresentation {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(presentation.headline)
              .font(.callout.weight(.medium))
            Spacer()
            if presentation.phase == .applying || presentation.phase == .reconnecting {
              ProgressView().controlSize(.small)
            }
            Button(presentation.action.title) { model.reconnectToApply() }
              .disabled(
                !presentation.actionEnabled
                  || model.observedCoreState == .unknown
                  || model.helperSetupInProgress
              )
          }
          if let error = model.deferredRuntimeApplyError {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
              .textSelection(.enabled)
          }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
      }
    }
  }

  @ViewBuilder private func routingMutationFeedback(
    _ status: RoutingMutationPresentation
  ) -> some View {
    if status.state != .saved || !(status.message ?? "").isEmpty {
      HStack(spacing: 6) {
        switch status.state {
        case .saved:
          if let message = status.message {
            Text(message).font(.caption).foregroundStyle(.secondary)
          }
        case .applying:
          ProgressView().controlSize(.small)
          Text(status.message ?? "Routing change applying…")
            .font(.caption).foregroundStyle(.secondary)
        case .failed:
          if let message = status.message {
            Label(message, systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(.orange)
              .textSelection(.enabled)
          }
        case .reconnectRequired:
          Text("Saved; reconnect to apply")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
    }
  }

  private func selectRoutedApplication(for ruleID: UUID? = nil) {
    guard let profileID = model.selectedProfileID else { return }
    let panel = NSOpenPanel()
    panel.title = SBMText.localized("Choose an Application")
    panel.prompt = SBMText.localized(ruleID == nil ? "Add" : "Change")
    panel.message = SBMText.localized(
      "Choose a macOS application. SBM will use its declared main executable."
    )
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.treatsFilePackagesAsDirectories = false
    panel.resolvesAliases = true
    if let window = NSApplication.shared.keyWindow {
      panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        Task { @MainActor in
          if let ruleID {
            model.replaceApplicationRoutingRule(ruleID, from: url, profileID: profileID)
          } else {
            model.addApplicationRoutingRule(from: url, profileID: profileID)
          }
        }
      }
      return
    }
    NSApplication.shared.activate()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if let ruleID {
      model.replaceApplicationRoutingRule(ruleID, from: url, profileID: profileID)
    } else {
      model.addApplicationRoutingRule(from: url, profileID: profileID)
    }
  }
}
