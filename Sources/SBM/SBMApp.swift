import AppKit
import SBMShared
import ServiceManagement
import SwiftUI

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  private var terminationPending = false
  private var terminationAuthorized = false
  private var wakeObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.model?.refresh()
      }
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    model?.applicationDidBecomeActive()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    if terminationAuthorized {
      terminationAuthorized = false
      terminationPending = false
      return .terminateNow
    }
    guard !terminationPending else { return .terminateCancel }
    terminationPending = true
    Task {
      let stopped = await model.disconnectBeforeQuit()
      if stopped {
        terminationAuthorized = true
        sender.terminate(nil)
        return
      }

      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = SBMText.localized("Disconnect Not Confirmed")
      alert.informativeText = SBMText.localized(
        "SBM remains open because it could not verify that the VPN stopped."
      )
      if let safeError = model.safeCurrentError {
        alert.informativeText += "\n\n\(safeError)"
      }
      alert.addButton(withTitle: SBMText.localized("OK"))
      NSApplication.shared.activate()
      alert.runModal()
      terminationPending = false
    }
    return .terminateCancel
  }

}

@main
struct SBMApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel(environment: .production)
  @State private var settingsEditing = false

  init() {
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContentView(model: model)
        .onAppear {
          model.refresh(observeAutoNode: true)
        }
    } label: {
      Image(
        systemName: model.connectionPresentation.systemImage
      )
      .onAppear {
        appDelegate.model = model
      }
    }
    .menuBarExtraStyle(.menu)

    Window("Settings", id: "profiles") {
      ZStack {
        if settingsEditing {
          SettingsView(model: model)
        }
      }
      .onAppear { settingsEditing = true }
      .onDisappear {
        settingsEditing = false
        model.endSettingsEditing()
      }
    }
    .defaultSize(width: 720, height: 620)
    .defaultPosition(.center)

    Window("Diagnostics", id: "diagnostics") {
      DiagnosticsView(model: model)
    }
    .defaultSize(width: 620, height: 420)
  }
}

enum SBMWindow: String, CaseIterable {
  case profiles
  case diagnostics

  var title: String {
    switch self {
    case .profiles: SBMText.localized("Settings")
    case .diagnostics: SBMText.localized("Diagnostics")
    }
  }

  var level: NSWindow.Level {
    .normal
  }

  var identifier: NSUserInterfaceItemIdentifier {
    NSUserInterfaceItemIdentifier("sbm.\(rawValue)")
  }
}

@MainActor
func menuPresentationTitle(_ value: String) -> String {
  let font = NSFont.menuFont(ofSize: 0)
  let attributes: [NSAttributedString.Key: Any] = [.font: font]
  let maxWidth: CGFloat = 180
  func width(_ text: String) -> CGFloat {
    (text as NSString).size(withAttributes: attributes).width
  }

  guard width(value) > maxWidth else { return value }

  let characters = Array(value)
  var lower = 0
  var upper = characters.count
  while lower < upper {
    let middle = (lower + upper + 1) / 2
    let prefix = String(characters.prefix(middle))
    if width(prefix + "…") <= maxWidth {
      lower = middle
    } else {
      upper = middle - 1
    }
  }
  return String(characters.prefix(lower)) + "…"
}

func menuErrorSummary(
  isInstalledInApplications: Bool,
  helperEnabled: Bool,
  helperReachable: Bool
) -> String {
  if !isInstalledInApplications {
    return SBMText.localized("Move SBM to Applications")
  }
  if !helperEnabled { return SBMText.localized("Helper not enabled") }
  if !helperReachable { return SBMText.localized("Helper unavailable") }
  return SBMText.localized("Something went wrong")
}

private struct MenuContentView: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      if let enabled = model.connectionAction {
        model.setCoreEnabled(enabled)
      }
    } label: {
      Label {
        menuText(model.connectionPresentation.title)
      } icon: {
        Image(systemName: model.connectionPresentation.systemImage)
      }
    }
    .disabled(!model.connectionActionEnabled)

    if let error = model.safeCurrentError {
      let isInstalledInApplications = model.isInstalledInApplications
      let errorDetails =
        isInstalledInApplications
        ? error
        : SBMText.localized(
          "Move SBM.app to the Applications folder, eject the DMG, then open the installed copy."
        )
      menuText(
        menuErrorSummary(
          isInstalledInApplications: isInstalledInApplications,
          helperEnabled: model.helperEnabled,
          helperReachable: model.helperReachable
        )
      )
      .font(.caption)
      .foregroundStyle(.orange)
      .accessibilityLabel(errorDetails)
      .help(errorDetails)
    }

    if let deferred = model.deferredRuntimeApplyPresentation {
      Label {
        menuText(deferred.headline)
      } icon: {
        Image(systemName: "arrow.triangle.2.circlepath")
      }
      if deferred.phase == .applying || deferred.phase == .reconnecting {
        ProgressView()
          .controlSize(.small)
      }
      if let error = model.deferredRuntimeApplyError {
        menuText(error)
          .foregroundStyle(.secondary)
      }
      Button {
        model.reconnectToApply()
      } label: {
        menuText(deferred.action.title)
      }
      .disabled(
        !model.runtimeMenuControlsEnabled
          || model.observedCoreState == .unknown
          || !deferred.actionEnabled
      )
    }

    Divider()

    Menu {
      ForEach(model.profiles) { profile in
        Button {
          model.selectProfile(profile.id)
        } label: {
          if model.selectedProfileID == profile.id {
            menuLabel(profile.name, systemImage: "checkmark")
          } else {
            menuText(profile.name)
          }
        }
      }
    } label: {
      menuText(SBMText.format("Profile: %@", model.selectedProfileName))
    }
    .disabled(!model.runtimeMenuControlsEnabled)

    Menu {
      ForEach(RoutingMode.allCases, id: \.self) { mode in
        Button {
          model.setRoutingMode(mode)
        } label: {
          if model.routingMode == mode {
            menuLabel(SBMText.localized(mode.rawValue), systemImage: "checkmark")
          } else {
            menuText(SBMText.localized(mode.rawValue))
          }
        }
      }
    } label: {
      menuText(SBMText.format("Mode: %@", SBMText.localized(model.routingMode.rawValue)))
    }
    .disabled(!model.runtimeMenuControlsEnabled)

    Menu {
      if let automaticNode = model.automaticNode {
        serverButton(automaticNode)
      }
      if !model.nodeSections.isEmpty {
        Divider()
        ForEach(model.nodeSections) { section in
          Section {
            ForEach(section.nodes) { node in
              serverButton(node)
            }
          } header: {
            menuText(section.name)
          }
        }
      }
    } label: {
      menuText(SBMText.format("Server: %@", selectedNodeName))
    }
    .disabled(!model.runtimeMenuControlsEnabled)

    Divider()

    Button {
      presentWindow(.profiles)
    } label: {
      Label("Settings…", systemImage: "gearshape")
    }

    Button {
      presentWindow(.diagnostics)
    } label: {
      Label("Diagnostics…", systemImage: "stethoscope")
    }

    if !model.helperEnabled {
      if model.helperRequiresApproval {
        Button {
          model.enableHelper()
        } label: {
          menuText(
            SBMText.localized(
              model.helperApprovalPending
                ? "Waiting for approval…" : "Approve Helper…"
            )
          )
        }
      } else {
        Button {
          model.enableHelper()
        } label: {
          menuText(
            SBMText.localized(
              model.helperSetupInProgress
                ? "Enabling helper…" : "Enable Helper"
            )
          )
        }
        .disabled(model.helperSetupInProgress)
      }
    } else if !model.helperReachable {
      Button {
        model.repairHelper()
      } label: {
        menuText(
          SBMText.localized(
            model.helperSetupInProgress
              ? (model.helperUpdateRequired ? "Updating helper…" : "Repairing helper…")
              : model.helperUpdateRequired
                ? "Update Helper" : "Repair Helper"
          )
        )
      }
      .disabled(model.helperSetupInProgress)
    }

    Button {
      model.refreshExternalState()
    } label: {
      menuText(
        SBMText.localized(model.isRefreshing ? "Refreshing…" : "Refresh")
      )
    }
    .disabled(!model.runtimeMenuControlsEnabled || model.isRefreshing)
    .keyboardShortcut("r")

    Divider()

    Button {
      NSApplication.shared.terminate(nil)
    } label: {
      menuText(
        SBMText.localized(model.coreIsKnownStopped ? "Quit" : "Disconnect & Quit")
      )
    }
    .keyboardShortcut("q")
  }

  private var selectedNodeName: String {
    if let childName = model.effectiveAutoNodeName {
      return SBMText.format("Auto → %@", childName)
    }
    return model.nodes.first(where: { $0.id == model.selectedNodeID })?.name
      ?? SBMText.localized("Unknown")
  }

  private func menuText(_ value: String) -> some View {
    Text(menuPresentationTitle(value))
      .accessibilityLabel(value)
  }

  private func menuLabel(_ value: String, systemImage: String) -> some View {
    Label(menuPresentationTitle(value), systemImage: systemImage)
      .accessibilityLabel(value)
  }

  private func presentWindow(_ target: SBMWindow) {
    NSApplication.shared.activate()
    DispatchQueue.main.async {
      openWindow(id: target.rawValue)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        guard
          let window = NSApplication.shared.windows.first(where: {
            $0.identifier == target.identifier
          })
            ?? NSApplication.shared.windows.first(where: { $0.title == target.title })
        else {
          return
        }
        window.identifier = target.identifier
        window.level = target.level
        window.makeKeyAndOrderFront(nil)
      }
    }
  }

  @ViewBuilder
  private func serverButton(_ node: ProxyNode) -> some View {
    let selected = model.selectedNodeID == node.id
    let latency = ProxyNodeMenuPresentation.latencyLabel(
      delay: node.delay,
      testCompleted: model.latencyTestCompleted
    )
    Button {
      model.setSelectedNode(node.id)
    } label: {
      if selected {
        menuLabel(node.name, systemImage: "checkmark")
      } else {
        Label {
          menuText(node.name)
        } icon: {
          Image(systemName: "checkmark").hidden()
        }
      }
    }
    .badge(latency)
    .accessibilityLabel(
      selected ? SBMText.format("%@, selected", node.name) : node.name
    )
  }

}

private struct DiagnosticsView: View {
  @Bindable var model: AppModel

  var body: some View {
    let snapshot = model.supportSnapshot
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Spacer()
        Button("Copy Text") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(snapshot.text, forType: .string)
        }
        Button("Copy JSON") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(snapshot.jsonText(), forType: .string)
        }
        Button("Refresh") {
          model.refresh()
        }
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Current Status").font(.headline)
          Text(snapshot.statusText)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
          HStack {
            Text("Recent Errors").font(.headline)
            Spacer()
            Button("Clear History") { model.clearRecentErrors() }
              .disabled(model.recentErrors.isEmpty)
          }
          if model.recentErrors.isEmpty {
            Text("No recent errors.").foregroundStyle(.secondary)
          } else {
            ForEach(model.recentErrors.reversed()) { entry in
              Text(
                entry.repeatCount == 1
                  ? entry.message : "\(entry.message) (×\(entry.repeatCount))"
              )
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(12)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
    .padding(18)
    .frame(minWidth: 560, minHeight: 340)
  }
}
