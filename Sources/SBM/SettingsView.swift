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

extension View {
  fileprivate func settingsHelperText() -> some View {
    modifier(SettingsHelperTextModifier())
  }
}

struct SettingsView: View {
  private enum JSONImportKind { case nativeProfile, routing, profileRecovery }

  private let formControlWidth: CGFloat = 300
  private let routingLabelWidth: CGFloat = 110
  private let routingTargetWidth: CGFloat = 92
  private let routingApplicationPickerWidth: CGFloat = 180
  private let routingInspectorPickerWidth: CGFloat = 180
  private let routingActionButtonWidth: CGFloat = 72
  private let routingInspectorActionButtonWidth: CGFloat = 92

  @Bindable var model: AppModel
  @State private var isImportingJSON = false
  @State private var jsonImportKind = JSONImportKind.nativeProfile
  @State private var isConfirmingHWIDRegeneration = false
  @State private var isSubscriptionURLVisible = false
  @State private var isConfirmingProfileReset = false

  var body: some View {
    TabView {
      profilesTab
        .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
      routingTab
        .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
      advancedTab
        .tabItem { Label("Advanced", systemImage: "gearshape.2") }
    }
    .frame(minWidth: 620, minHeight: 520)
    .padding()
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
      case .nativeProfile: model.importNativeProfile(from: url)
      case .routing: model.importRoutingPolicy(from: url)
      case .profileRecovery: model.importRecoveredProfileLibrary(from: url)
      }
    }
    .onDisappear {
      isSubscriptionURLVisible = false
    }
  }

  private var profilesTab: some View {
    Form {
      deferredRuntimeApplyCallout
      if model.profileRecoveryRequired { recoverySection }
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
          .disabled(model.coreRunning)
      }
      if model.coreRunning {
        Text("Disconnect the VPN before starting with an empty library.")
          .settingsHelperText()
      }
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
              model.deleteSelectedProfile()
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
                model.deleteSelectedSource()
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
          Text("HTTPS URL · vless:// · hysteria2:// · hy2:// · ss://")
            .settingsHelperText()
        }
        .disabled(model.selectedSourceID == nil || model.isSyncing)

        DisclosureGroup("Advanced Source Settings") {
          settingsRow("Exclude regex (optional)") {
            TextField(text: $model.sourceExcludeRegex, prompt: Text("(?i)lte|russia")) {
              Text("Exclude regex (optional)")
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
        }
        .disabled(model.selectedSourceID == nil || model.isSyncing)

        HStack {
          Button("Save and Sync") { model.saveAndSyncSubscription() }
            .disabled(
              model.isSyncing || model.helperSetupInProgress
                || !model.sourceDraftIsValid
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
      } else {
        Text("Full JSON profiles cannot be combined with subscription sources.")
          .settingsHelperText()
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
            "Route for \(rule.domain)",
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
              Label("Remove \(rule.domain)", systemImage: "trash")
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
        "A domain rule also applies to its subdomains. Website rules precede application and imported routing."
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
        TextField(text: $model.routingInspectorInput, prompt: Text("gosuslugi.ru")) {
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

      Text(model.routingInspectorOutput)
        .font(.callout.weight(.medium)).textSelection(.enabled)
      if !model.routingInspectorDetails.isEmpty {
        DisclosureGroup("Details") {
          Text(model.routingInspectorDetails)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      Text(
        "Explain is local and probe-free; remote rule sets use only the active bounded cache check."
      )
      .settingsHelperText()
    }
  }

  private var advancedRoutingSection: some View {
    Section {
      DisclosureGroup("Advanced Routing JSON") {
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
    }
  }

  private var advancedTab: some View {
    Form {
      deferredRuntimeApplyCallout
      latencySection
      localSOCKSSection
      Section("Advanced Profile Import") {
        Button("Import Full JSON as New Profile…") {
          jsonImportKind = .nativeProfile
          isImportingJSON = true
        }
        .disabled(model.helperSetupInProgress)
      }
    }
    .formStyle(.grouped)
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
        if model.latencyApplyInProgress { ProgressView().controlSize(.small) }
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
        if model.localSOCKSApplyInProgress { ProgressView().controlSize(.small) }
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

  private var statusColor: Color {
    model.subscriptionStatusLevel == .warning
      ? .orange : model.subscriptionStatusLevel == .success ? .green : .secondary
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
            if presentation.phase == .reconnecting {
              ProgressView().controlSize(.small)
            }
            Button(presentation.action.title) { model.reconnectToApply() }
              .disabled(presentation.phase == .reconnecting || model.helperSetupInProgress)
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
    switch status.state {
    case .saved:
      if let message = status.message {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
    case .applying:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(status.message ?? "Routing change applying…")
      }
      .font(.caption).foregroundStyle(.secondary)
    case .failed:
      if let message = status.message {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
          .textSelection(.enabled)
      }
    case .reconnectRequired:
      EmptyView()
    }
  }

  private func selectRoutedApplication(for ruleID: UUID? = nil) {
    let panel = NSOpenPanel()
    panel.title = "Choose an Application"
    panel.prompt = ruleID == nil ? "Add" : "Change"
    panel.message = "Choose a macOS application. SBM will use its declared main executable."
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
            model.replaceApplicationRoutingRule(ruleID, from: url)
          } else {
            model.addApplicationRoutingRule(from: url)
          }
        }
      }
      return
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if let ruleID {
      model.replaceApplicationRoutingRule(ruleID, from: url)
    } else {
      model.addApplicationRoutingRule(from: url)
    }
  }
}
