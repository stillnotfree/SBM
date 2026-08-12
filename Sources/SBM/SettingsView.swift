import AppKit
import SBMShared
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  private enum JSONImportKind {
    case nativeProfile
    case routing
    case profileRecovery
  }

  @Bindable var model: AppModel
  @State private var isImportingJSON = false
  @State private var jsonImportKind = JSONImportKind.nativeProfile
  @State private var isConfirmingHWIDRegeneration = false
  @State private var isConfirmingProfileReset = false
  @State private var latencySavedIndicatorVisible = false
  @State private var localSOCKSSavedIndicatorVisible = false
  @State private var latencySavedIndicatorTask: Task<Void, Never>?
  @State private var localSOCKSSavedIndicatorTask: Task<Void, Never>?

  var body: some View {
    Form {
      if model.profileRecoveryRequired {
        Section("Profile Library Recovery") {
          Label(model.profileRecoveryMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          HStack {
            Button("Import Recovered Library…") {
              jsonImportKind = .profileRecovery
              isImportingJSON = true
            }
            Button("Show Preserved Copy") {
              model.revealPreservedProfileLibrary()
            }
            Spacer()
            Button("Start Empty…", role: .destructive) {
              isConfirmingProfileReset = true
            }
            .disabled(model.coreRunning)
          }
          if model.coreRunning {
            Text("Disconnect the VPN before starting with an empty library.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Section("Profile") {
        HStack {
          Picker(
            "Active profile",
            selection: Binding(
              get: { model.selectedProfileID },
              set: { id in
                if let id { model.selectProfile(id) }
              }
            )
          ) {
            ForEach(model.profiles) { profile in
              Text(profile.name).tag(Optional(profile.id))
            }
          }

          ControlGroup {
            Button {
              model.addProfile()
            } label: {
              Label("Add profile", systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(width: 24)
            }
            .help("Add profile")

            Button {
              model.deleteSelectedProfile()
            } label: {
              Label("Delete selected profile", systemImage: "minus")
                .labelStyle(.iconOnly)
                .frame(width: 24)
            }
            .help("Delete selected profile")
            .disabled(model.selectedProfileID == nil)
          }
        }

        HStack {
          TextField("Name", text: $model.profileName)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              model.saveProfileName()
            }
          Button("Save") {
            model.saveProfileName()
          }
          .disabled(model.selectedProfileID == nil || model.profileName.isEmpty)
        }
      }

      Section("Subscription sources") {
        if model.canManageSources {
          HStack {
            Picker(
              "Source",
              selection: Binding(
                get: { model.selectedSourceID },
                set: { id in
                  if let id { model.selectSource(id) }
                }
              )
            ) {
              ForEach(model.selectedProfileSources) { source in
                Text(source.name).tag(Optional(source.id))
              }
            }

            ControlGroup {
              Button {
                model.addSource()
              } label: {
                Label("Add source", systemImage: "plus")
                  .labelStyle(.iconOnly)
                  .frame(width: 24)
              }
              .help("Add subscription or connection")

              Button {
                model.deleteSelectedSource()
              } label: {
                Label("Delete source", systemImage: "minus")
                  .labelStyle(.iconOnly)
                  .frame(width: 24)
              }
              .help("Delete selected source")
              .disabled(model.selectedSourceID == nil)
            }
          }

          TextField("Source name", text: $model.sourceName)
            .textFieldStyle(.roundedBorder)
            .disabled(model.selectedSourceID == nil)

          SecureField(
            "HTTPS subscription, vless:// or hysteria2://",
            text: $model.subscriptionURL
          )
          .textFieldStyle(.roundedBorder)
          .disabled(model.selectedSourceID == nil)

          LabeledContent("Exclude regex (optional)") {
            TextField(
              text: $model.sourceExcludeRegex,
              prompt: Text("(?i)lte|russia")
            ) {
              Text("Exclude regex (optional)")
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .disabled(model.selectedSourceID == nil)
          }

          Text(
            "Connections whose names match this regular expression are omitted from the menu, Auto, and the generated sing-box configuration."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          DisclosureGroup("Request headers") {
            TextField("User-Agent", text: $model.subscriptionUserAgent)
              .textFieldStyle(.roundedBorder)
            TextField("X-App-Version", text: $model.subscriptionAppVersion)
              .textFieldStyle(.roundedBorder)
            TextField("X-Device-OS", text: $model.subscriptionDeviceOS)
              .textFieldStyle(.roundedBorder)
            TextField("X-HWID", text: $model.subscriptionHWID)
              .textFieldStyle(.roundedBorder)
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
              Button("Reset Request Preset") {
                model.resetSubscriptionRequestPreset()
              }
            }
          }
          .disabled(model.selectedSourceID == nil)

          Text(
            "Each source keeps its own headers. Credentials are stored in the user-only Application Support file and are never written to logs."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          HStack {
            Button("Save and Sync") {
              model.saveAndSyncSubscription()
            }
            .disabled(
              model.isSyncing || model.helperSetupInProgress
                || model.selectedSourceID == nil || model.subscriptionURL.isEmpty
            )

            if model.isSyncing {
              ProgressView().controlSize(.small)
            }
            Text(model.subscriptionStatus)
              .foregroundStyle(
                model.subscriptionStatusLevel == .warning
                  ? Color.orange
                  : model.subscriptionStatusLevel == .success ? Color.green : Color.secondary
              )
          }
        } else {
          Text("Full JSON profiles cannot be combined with subscription sources.")
            .foregroundStyle(.secondary)
        }

        Button("Import Full JSON as New Profile…") {
          jsonImportKind = .nativeProfile
          isImportingJSON = true
        }
        .disabled(model.helperSetupInProgress)
      }

      Section("Routing") {
        HStack {
          Text(model.routingPolicyStatus)
            .foregroundStyle(
              model.routingPolicyStatusLevel == .warning
                ? Color.orange
                : model.routingPolicyStatusLevel == .success ? Color.green : Color.secondary
            )
          Spacer()
          Button("Import Routing…") {
            jsonImportKind = .routing
            isImportingJSON = true
          }
          .disabled(
            !model.canManageRoutingPolicy || model.isSyncing
              || model.helperSetupInProgress
          )
          Button("Open Current…") {
            model.openCurrentRoutingPolicy()
          }
          .help(
            "Open a temporary copy in the default app for JSON files. Changes are not imported automatically."
          )
          .disabled(!model.hasRoutingPolicy || model.isSyncing)
          Button("Remove") {
            model.clearRoutingPolicy()
          }
          .disabled(
            !model.hasRoutingPolicy || model.isSyncing
              || model.helperSetupInProgress
          )
        }
        Text(
          "Optional routing JSON is stored with this profile and survives remote subscription updates. The file may contain only route rules and remote rule sets."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Traffic from")
              .frame(width: 90, alignment: .leading)
            Spacer(minLength: 12)
            Picker("Traffic from", selection: $model.routingInspectorApplicationID) {
              Text("Default traffic").tag(UUID?.none)
              ForEach(model.applicationRoutingRules) { rule in
                Text(rule.displayName).tag(Optional(rule.id))
              }
            }
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
          }
          HStack {
            Text("Domain or IP")
              .frame(width: 90, alignment: .leading)
            TextField(
              text: $model.routingInspectorInput,
              prompt: Text("gosuslugi.ru")
            ) {
              Text("Domain or IP")
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .layoutPriority(1)
            .onSubmit { model.inspectRouting() }
            Button("Explain") {
              model.inspectRouting()
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(model.selectedProfileID == nil || model.routingInspectorInput.isEmpty)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(model.routingInspectorOutput)
          .font(.callout.weight(.medium))
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
        if !model.routingInspectorDetails.isEmpty {
          DisclosureGroup {
            Text(model.routingInspectorDetails)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          } label: {
            Text("Details")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text(
          "Default traffic means no configured application override matches. Proxy uses the selected SBM server. Explain makes no DNS, network, process, or persistence probes; remote rule sets are checked against the active helper cache."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Application Routing") {
        HStack {
          Text("Route an application's traffic by its exact main executable.")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Add Application…") {
            selectRoutedApplication()
          }
          .disabled(
            model.selectedProfileID == nil || model.isSyncing || model.helperSetupInProgress
          )
        }

        ForEach(model.applicationRoutingRules) { rule in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(rule.displayName)
              Text(
                model.applicationRoutingRuleIsResolved(rule)
                  ? "Resolved" : "Unresolved — select the application again"
              )
              .font(.caption)
              .foregroundStyle(
                model.applicationRoutingRuleIsResolved(rule) ? .green : .orange
              )
            }
            Spacer()
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
              if !model.fixedApplicationRoutingNodes.isEmpty {
                Divider()
                ForEach(model.fixedApplicationRoutingNodes) { node in
                  Text(node.name).tag(ApplicationRoutingTarget.node(node.id))
                }
              }
              if case .node(let nodeID) = rule.target,
                !model.fixedApplicationRoutingNodes.contains(where: { $0.id == nodeID })
              {
                Divider()
                Text("Missing server").tag(rule.target)
              }
            }
            .labelsHidden()
            .frame(width: 210)
            .disabled(model.isSyncing || model.helperSetupInProgress)
            Button(role: .destructive) {
              model.removeApplicationRoutingRule(rule.id)
            } label: {
              Label("Remove", systemImage: "trash")
                .labelStyle(.iconOnly)
            }
            .help("Remove application rule")
            .disabled(model.isSyncing || model.helperSetupInProgress)
          }
        }

        Text(
          "Reject blocks the selected application's network connections through SBM. Moved or deleted applications stay visible but inactive until selected again. SBM does not guess processes by name; DNS continues to use the same system-wide VPN policy."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Latency") {
        HStack {
          Text("Automatic latency checks")
          Spacer()
          TextField(
            "Minutes",
            value: Binding(
              get: { model.latencyIntervalMinutes },
              set: { model.setLatencyIntervalMinutes($0) }
            ),
            format: .number.grouping(.never)
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .frame(width: 74)
          Text("min")
            .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("HTTPS test target")
          TextField("HTTPS test target", text: $model.latencyTestURLDraft)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
          HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Apply") {
              latencySavedIndicatorTask?.cancel()
              latencySavedIndicatorVisible = false
              if model.applyLatencyTestURL() {
                showLatencySavedIndicator()
              }
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(model.helperSetupInProgress)
            if latencySavedIndicatorVisible {
              savedIndicator
            }
            Button("Reset to default") {
              model.resetLatencyTestURL()
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(model.helperSetupInProgress)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(
          "SBM updates latency values while the VPN is connected. The HTTPS target receives a test request through each proxy; it is saved only when you apply it. Manual tests use it immediately; Auto uses it after the next normal connection."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Local SOCKS5") {
        Toggle("Enable local SOCKS5 proxy", isOn: $model.localSOCKSEnabled)
        HStack {
          Text("Port")
          Spacer()
          TextField(
            "",
            value: $model.localSOCKSPort,
            format: .number.grouping(.never)
          )
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 90)
          Button("Apply") {
            localSOCKSSavedIndicatorTask?.cancel()
            localSOCKSSavedIndicatorVisible = false
            if model.applyLocalSOCKSSettings() {
              showLocalSOCKSSavedIndicator()
            }
          }
          .disabled(model.helperSetupInProgress)
          if localSOCKSSavedIndicatorVisible {
            savedIndicator
          }
        }
        Text(
          "The listener is available only on this Mac while the VPN is connected."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 620, height: 620)
    .padding()
    .confirmationDialog(
      "Regenerate subscription HWID?",
      isPresented: $isConfirmingHWIDRegeneration,
      titleVisibility: .visible
    ) {
      Button("Regenerate HWID", role: .destructive) {
        model.regenerateSubscriptionHWID()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Changing HWID may make providers with a device limit treat this Mac as a new device."
      )
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
      Text(
        "SBM will preserve the current profile file unchanged before creating an empty library."
      )
    }
    .fileImporter(
      isPresented: $isImportingJSON,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else {
        return
      }
      switch jsonImportKind {
      case .nativeProfile:
        model.importNativeProfile(from: url)
      case .routing:
        model.importRoutingPolicy(from: url)
      case .profileRecovery:
        model.importRecoveredProfileLibrary(from: url)
      }
    }
    .onDisappear {
      latencySavedIndicatorTask?.cancel()
      localSOCKSSavedIndicatorTask?.cancel()
    }
  }

  private var savedIndicator: some View {
    Image(systemName: "circle.fill")
      .font(.system(size: 8))
      .foregroundStyle(.green)
      .accessibilityLabel("Saved")
      .help("Saved")
  }

  private func showLatencySavedIndicator() {
    latencySavedIndicatorTask?.cancel()
    latencySavedIndicatorVisible = true
    latencySavedIndicatorTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(2_500))
      guard !Task.isCancelled else { return }
      latencySavedIndicatorVisible = false
    }
  }

  private func showLocalSOCKSSavedIndicator() {
    localSOCKSSavedIndicatorTask?.cancel()
    localSOCKSSavedIndicatorVisible = true
    localSOCKSSavedIndicatorTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(2_500))
      guard !Task.isCancelled else { return }
      localSOCKSSavedIndicatorVisible = false
    }
  }

  private func selectRoutedApplication() {
    let panel = NSOpenPanel()
    panel.title = "Choose an Application"
    panel.prompt = "Add"
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
          model.addApplicationRoutingRule(from: url)
        }
      }
      return
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.addApplicationRoutingRule(from: url)
  }
}
