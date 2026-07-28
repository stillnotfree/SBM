import AppKit
import SBMShared
import ServiceManagement
import SwiftUI

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  private var terminationPending = false

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
          model.refreshLatencyIfNeeded()
        }
    } label: {
      Image(systemName: model.coreRunning ? "shield.fill" : "shield")
        .onAppear {
          appDelegate.model = model
        }
    }
    .menuBarExtraStyle(.menu)

    Window("Profiles", id: "profiles") {
      SettingsView(model: model)
    }
    .defaultSize(width: 560, height: 340)
    .windowResizability(.contentSize)

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

private struct MenuContentView: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      model.setCoreEnabled(!model.coreRunning)
    } label: {
      Label(
        model.coreRunning ? "VPN Connected" : "VPN Disconnected",
        systemImage: model.coreRunning ? "lock.shield.fill" : "lock.shield"
      )
    }
    .disabled(model.isBusy)

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
      ForEach(model.nodes) { node in
        Button {
          model.setSelectedNode(node.id)
        } label: {
          if model.selectedNodeID == node.id {
            Label(nodeTitle(node), systemImage: "checkmark")
          } else {
            Text(nodeTitle(node))
          }
        }
      }
    }
    .disabled(model.helperSetupInProgress)

    Divider()

    Button {
      presentWindow(id: "profiles", title: "Profiles")
    } label: {
      Label("Profiles…", systemImage: "rectangle.stack")
    }

    if model.lastError != nil {
      Button {
        presentWindow(id: "diagnostics", title: "Diagnostics")
      } label: {
        Label("Error…", systemImage: "exclamationmark.triangle.fill")
      }
    }

    if !model.helperEnabled {
      if model.helperRequiresApproval {
        Button("Approve Background Helper…") {
          model.openBackgroundItems()
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

    Button("Refresh") {
      model.refresh()
    }
    .disabled(model.helperSetupInProgress)
    .keyboardShortcut("r")

    Divider()

    Button("About SBM…") {
      presentWindow(id: "about", title: "About SBM")
    }

    Button("Check for Updates…") {
      model.checkForUpdates()
      presentWindow(id: "about", title: "About SBM")
    }

    Button(model.coreRunning ? "Disconnect & Quit" : "Quit") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  private var selectedNodeName: String {
    model.nodes.first(where: { $0.id == model.selectedNodeID })?.name ?? "Unknown"
  }

  private func nodeTitle(_ node: ProxyNode) -> String {
    guard let delay = node.delay else { return node.name }
    return "\(node.name) — \(delay) ms"
  }

  private func presentWindow(id: String, title: String) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    openWindow(id: id)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      guard let window = NSApplication.shared.windows.first(where: { $0.title == title }) else {
        return
      }
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()
    }
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

      if model.availableUpdateVersion != nil {
        Button("Download Verified Update") {
          model.downloadAndOpenUpdate()
        }
        .disabled(model.isBusy)
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
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Diagnostics", systemImage: "stethoscope")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(model.diagnosticReport, forType: .string)
        }
        Button("Refresh") {
          model.refresh()
          if model.coreRunning {
            model.testLatency()
          }
        }
      }

      ScrollView {
        Text(model.diagnosticReport)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(12)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
    .padding(18)
    .frame(minWidth: 560, minHeight: 340)
  }
}
