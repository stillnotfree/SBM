// This harness uses the production Settings scene with a probe view/model.
// It proves native form subtree teardown, not the full Settings form's malloc footprint.
import AppKit
import SwiftUI

@MainActor private final class AppModel {
  var saved = "saved"
  var closed = 0
  func endSettingsEditing() { closed += 1 }
}

@MainActor private final class LifetimeProbe {
  static var destroyed = 0
  deinit { MainActor.assumeIsolated { Self.destroyed += 1 } }
}

private struct SettingsView: View {
  let model: AppModel
  @State private var probe = LifetimeProbe()
  @State private var draft = ""
  @State private var validationError: String?
  @State private var selectedTab = 0

  init(model: AppModel) {
    self.model = model
    _draft = State(initialValue: model.saved)
  }

  var body: some View {
    TextField("Draft", text: $draft)
      .padding()
      .onAppear {
        precondition(draft == model.saved && validationError == nil && selectedTab == 0)
        Driver.probe = probe
        draft = Driver.cycle == 0 ? "invalid Custom DoH" : "valid unapplied text"
        validationError = Driver.cycle == 0 ? "invalid" : nil
        selectedTab = 2
      }
  }
}

@MainActor private enum Driver {
  static weak var probe: LifetimeProbe?
  static weak var window: NSWindow?
  static var cycle = 0

  static func close() {
    let visible = NSApp.windows.filter { $0.title == "Settings" && $0.isVisible }
    precondition(visible.count == 1, "Settings count \(visible.count)")
    window = visible.first
    window?.performClose(nil)  // The native red close control's action.
  }

  static func run(_ openWindow: OpenWindowAction, model: AppModel) {
    Task { @MainActor in
      for index in 0..<3 {
        cycle = index
        openWindow(id: "profiles")
        openWindow(id: "profiles")
        try? await Task.sleep(for: .seconds(1))
        precondition(probe != nil)
        close()
        try? await Task.sleep(for: .seconds(1))
        precondition(window != nil && probe == nil)
        precondition(LifetimeProbe.destroyed == index + 1 && model.closed == index + 1)
        if index == 1 { model.saved = "committed" }
      }
      print("PASS: 3 native close/reopen cycles; singleton window and released view state")
      NSApp.terminate(nil)
    }
  }
}

private struct DriverView: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Text("SBM isolated native window lifetime test")
      .task { Driver.run(openWindow, model: model) }
  }
}

@main private struct Harness: App {
  @State private var model = AppModel()
  @State private var settingsEditing = false
  var body: some Scene {
    Window("Lifetime driver", id: "driver") { DriverView(model: model) }
    // SETTINGS_SCENE
  }
}
