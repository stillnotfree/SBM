import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Bindable var model: AppModel
  @State private var isImportingProfile = false
  @State private var isImportingRouting = false

  var body: some View {
    Form {
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

          DisclosureGroup("Request headers") {
            TextField("User-Agent", text: $model.subscriptionUserAgent)
              .textFieldStyle(.roundedBorder)
            TextField("X-Device-OS", text: $model.subscriptionDeviceOS)
              .textFieldStyle(.roundedBorder)
            TextField("X-HWID", text: $model.subscriptionHWID)
              .textFieldStyle(.roundedBorder)
            HStack {
              Spacer()
              Button("Reset Defaults") {
                model.resetSubscriptionHeaders()
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
          isImportingProfile = true
        }
        .disabled(model.helperSetupInProgress)
      }

      Section("Routing") {
        HStack {
          Text(model.routingPolicyStatus)
            .foregroundStyle(model.hasRoutingPolicy ? .green : .secondary)
          Spacer()
          Button("Import Routing…") {
            isImportingRouting = true
          }
          .disabled(
            !model.canManageRoutingPolicy || model.isSyncing
              || model.helperSetupInProgress
          )
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
            model.applyLocalSOCKSSettings()
          }
          .disabled(model.helperSetupInProgress)
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
    .fileImporter(
      isPresented: $isImportingProfile,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else {
        return
      }
      model.importNativeProfile(from: url)
    }
    .fileImporter(
      isPresented: $isImportingRouting,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else {
        return
      }
      model.importRoutingPolicy(from: url)
    }
  }
}
