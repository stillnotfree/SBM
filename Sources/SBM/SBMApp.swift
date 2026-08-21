import AppKit
import SBMShared
import ServiceManagement
import SwiftUI

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  private var terminationPending = false
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
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    Task {
      let stopped = await model.disconnectBeforeQuit()
      terminationPending = false
      sender.reply(toApplicationShouldTerminate: stopped)
    }
    return .terminateLater
  }

}

@main
struct SBMApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel()

  init() {
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContentView(model: model)
        .onAppear {
          model.refresh()
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
      SettingsView(model: model)
    }
    .defaultSize(width: 720, height: 620)
    .defaultPosition(.center)

    Window("Diagnostics", id: "diagnostics") {
      DiagnosticsView(model: model)
    }
    .defaultSize(width: 620, height: 420)

    Window("About SBM", id: "about") {
      AboutView(model: model)
    }
    .defaultSize(width: 440, height: 330)
    .windowResizability(.contentSize)
  }
}

enum SBMWindow: String, CaseIterable {
  case profiles
  case diagnostics
  case about

  var title: String {
    switch self {
    case .profiles: "Settings"
    case .diagnostics: "Diagnostics"
    case .about: "About SBM"
    }
  }

  var level: NSWindow.Level {
    .normal
  }

  var identifier: NSUserInterfaceItemIdentifier {
    NSUserInterfaceItemIdentifier("sbm.\(rawValue)")
  }
}

private struct MenuContentView: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      if let enabled = model.connectionPresentation.nextEnabledState {
        model.setCoreEnabled(enabled)
      }
    } label: {
      Label(
        model.connectionPresentation.title,
        systemImage: model.connectionPresentation.systemImage
      )
    }
    .disabled(model.connectionPresentation.nextEnabledState == nil || model.helperSetupInProgress)

    if let deferred = model.deferredRuntimeApplyPresentation {
      Label(deferred.headline, systemImage: "arrow.triangle.2.circlepath")
      if deferred.phase == .reconnecting {
        ProgressView()
          .controlSize(.small)
      }
      if let error = model.deferredRuntimeApplyError {
        Text(error)
          .foregroundStyle(.secondary)
      }
      Button(deferred.action.title) {
        model.reconnectToApply()
      }
      .disabled(model.helperSetupInProgress || deferred.phase == .reconnecting)
    }

    Divider()

    Menu("Profile: \(model.selectedProfileName)") {
      ForEach(model.profiles) { profile in
        Button {
          model.selectProfile(profile.id)
        } label: {
          if model.selectedProfileID == profile.id {
            Label(profile.name, systemImage: "checkmark")
          } else {
            Text(profile.name)
          }
        }
      }
    }
    .disabled(model.helperSetupInProgress)

    Menu("Mode: \(model.routingMode.rawValue)") {
      ForEach(RoutingMode.allCases, id: \.self) { mode in
        Button {
          model.setRoutingMode(mode)
        } label: {
          if model.routingMode == mode {
            Label(mode.rawValue, systemImage: "checkmark")
          } else {
            Text(mode.rawValue)
          }
        }
      }
    }
    .disabled(model.helperSetupInProgress)

    Menu("Server: \(selectedNodeName)") {
      if let automaticNode = model.automaticNode {
        serverButton(automaticNode)
      }
      if !model.nodeSections.isEmpty {
        Divider()
        ForEach(model.nodeSections) { section in
          Section(section.name) {
            ForEach(section.nodes) { node in
              serverButton(node)
            }
          }
        }
      }
    }
    .disabled(model.helperSetupInProgress)

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
        Button(
          model.helperApprovalPending
            ? model.helperStatus : "Approve Background Helper…"
        ) {
          model.enableHelper()
        }
      } else {
        Button(
          model.helperSetupInProgress
            ? model.helperStatus : "Enable Background Helper"
        ) {
          model.enableHelper()
        }
        .disabled(model.helperSetupInProgress)
      }
    } else if !model.helperReachable {
      Button(
        model.helperSetupInProgress
          ? model.helperStatus
          : model.helperStatus == "Helper update required"
            ? "Update Background Helper" : "Repair Background Helper"
      ) {
        model.repairHelper()
      }
      .disabled(model.helperSetupInProgress)
    }

    Button(model.isRefreshing ? "Refreshing…" : "Refresh") {
      model.refreshExternalState()
    }
    .disabled(model.isRefreshing)
    .keyboardShortcut("r")

    Divider()

    Button("About SBM…") {
      presentWindow(.about)
    }

    Button("Check for Updates…") {
      model.checkForUpdates()
      presentWindow(.about)
    }

    Button(model.coreIsKnownStopped ? "Quit" : "Disconnect & Quit") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  private var selectedNodeName: String {
    model.nodes.first(where: { $0.id == model.selectedNodeID })?.name ?? "Unknown"
  }

  private func presentWindow(_ target: SBMWindow) {
    NSApplication.shared.activate(ignoringOtherApps: true)
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
        Label(node.name, systemImage: "checkmark")
      } else {
        Label {
          Text(node.name)
        } icon: {
          Image(nsImage: selectionPlaceholderImage())
        }
      }
    }
    .badge(latency)
    .accessibilityLabel(selected ? "\(node.name), selected" : node.name)
  }

  private func selectionPlaceholderImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
      true
    }
    image.isTemplate = true
    return image
  }
}

private struct AboutView: View {
  @Bindable var model: AppModel

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "Development"
  }

  private var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
  }

  var body: some View {
    VStack(spacing: 14) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .scaledToFit()
        .frame(width: 64, height: 64)

      Text("SBM")
        .font(.title2.weight(.semibold))
      Text("Version \(version) (\(build))")
        .foregroundStyle(.secondary)

      Text("Native Apple Silicon menu bar client for sing-box.")
        .font(.callout)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Text(model.updateStatus)
        .font(.caption)
        .foregroundStyle(.secondary)

      if model.isDownloadingUpdate {
        ProgressView(value: model.updateDownloadProgress ?? 0)
        Text(
          "\(Int(((model.updateDownloadProgress ?? 0) * 100).rounded()))%"
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }

      if model.availableUpdateVersion != nil {
        Button("Download Verified Update") {
          model.downloadAndOpenUpdate()
        }
        .disabled(model.isDownloadingUpdate)
      } else {
        Button("Check for Updates") {
          model.checkForUpdates()
        }
        .disabled(model.isCheckingForUpdates)
      }

      Text("© 2026 stillnotfree")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(24)
    .frame(width: 420)
  }
}

private struct DiagnosticsView: View {
  @Bindable var model: AppModel

  var body: some View {
    let snapshot = model.supportSnapshot
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Diagnostics", systemImage: "stethoscope")
          .font(.title2.weight(.semibold))
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
