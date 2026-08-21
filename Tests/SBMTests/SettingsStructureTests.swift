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

@Test func missingFixedApplicationNodeRemainsRepresentedInPicker() throws {
  let source = try settingsSource("SettingsView.swift")
  #expect(
    source.contains(
      #"Text("Missing server").tag(ApplicationRoutingTarget.node(selectedNode))"#
    )
  )
  #expect(source.contains("!model.fixedApplicationRoutingNodes.contains"))
}

@Test func settingsTabsPreserveCommonAndAdvancedFeatures() throws {
  let source = try settingsSource("SettingsView.swift")
  for required in [
    #"Label("Profiles""#,
    #"Label("Routing""#,
    #"Label("Advanced""#,
    #"DisclosureGroup("Advanced Source Settings")"#,
    #"isSubscriptionURLVisible"#,
    #"Image(systemName: isSubscriptionURLVisible ? "eye.slash" : "eye")"#,
    #"Section("Website Routing")"#,
    #"Section("Application Routing")"#,
    #"Section("Routing Inspector")"#,
    #"DisclosureGroup("Advanced Routing JSON")"#,
    #"Button("Import Routing…")"#,
    #"Button("Import Full JSON as New Profile…")"#,
    #"Section("Latency")"#,
    #"Section("Local SOCKS5")"#,
    "private var deferredRuntimeApplyCallout",
    "case .reconnectRequired:",
    "settingsHelperText()",
  ] {
    #expect(source.contains(required))
  }
  #expect(source.components(separatedBy: "deferredRuntimeApplyCallout").count - 1 == 4)
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
    performStartup: false
  )
  #expect(model.websiteRoutingControlsEnabled)
  model.helperSetupInProgress = true
  #expect(!model.websiteRoutingControlsEnabled)
}
