import AppKit
import SBMShared
import Testing

@testable import SBM

@Test func serverMenuTitleShowsSelectionAndMeasuredDelay() {
  let title = ProxyNodeMenuPresentation.latencyLabel(
    delay: 42,
    testCompleted: true
  )
  #expect(title == "42 ms")
}

@Test func serverMenuTitleReservesSelectionSpaceBeforeTesting() {
  let title = ProxyNodeMenuPresentation.latencyLabel(
    delay: nil,
    testCompleted: false
  )
  #expect(title.isEmpty)
}

@Test func serverMenuLatencyShowsTimeoutAfterTesting() {
  let title = ProxyNodeMenuPresentation.latencyLabel(
    delay: nil,
    testCompleted: true
  )
  #expect(title == "timeout")
}

@Test func appWindowsUseNormalLevelAndStableIdentifier() {
  #expect(SBMWindow.profiles.level == .normal)
  #expect(SBMWindow.diagnostics.level == .normal)
  #expect(SBMWindow.allCases.count == 2)
  #expect(Set(SBMWindow.allCases.map(\.identifier)).count == SBMWindow.allCases.count)
}

@Test func dynamicMenuTitlesAreBoundBeforeNativePresentation() throws {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let source = try String(
    contentsOf: root.appendingPathComponent("Sources/SBM/SBMApp.swift"),
    encoding: .utf8
  )
  for dynamicRow in [
    "menuText(model.connectionPresentation.title)",
    "menuText(deferred.headline)",
    "menuText(error)",
    "menuText(deferred.action.title)",
    #"menuText(SBMText.format("Profile: %@", model.selectedProfileName))"#,
    #"menuText(SBMText.format("Server: %@", selectedNodeName))"#,
    "menuText(profile.name)",
    #"menuLabel(profile.name, systemImage: "checkmark")"#,
    #"menuLabel(SBMText.localized(mode.rawValue), systemImage: "checkmark")"#,
    #"menuText(SBMText.localized(mode.rawValue))"#,
    #"menuText(SBMText.format("Mode: %@", SBMText.localized(model.routingMode.rawValue)))"#,
    "menuText(section.name)",
    "menuText(node.name)",
    #"menuLabel(node.name, systemImage: "checkmark")"#,
  ] {
    #expect(source.contains(dynamicRow))
  }
  #expect(source.contains("menuErrorSummary("))
  #expect(source.contains("model.safeCurrentError"))
  #expect(source.contains("Text(menuPresentationTitle(value))"))
  #expect(source.contains("Label(menuPresentationTitle(value), systemImage: systemImage)"))
  #expect(source.components(separatedBy: ".accessibilityLabel(value)").count - 1 == 2)
  #expect(!source.contains(".frame(maxWidth: 300, alignment: .leading)"))
  #expect(!source.contains(".truncationMode(.middle)"))
  #expect(source.contains("Text(snapshot.statusText)"))
  #expect(source.contains("entry.message"))
  #expect(source.contains("selected ? SBMText.format(\"%@, selected\", node.name) : node.name"))
}

@Test @MainActor func menuPresentationTitleMeasuresAndBoundsLongLocalizedText() {
  let englishError =
    "Move SBM.app to the Applications folder, eject the DMG, then open the installed copy. "
    + String(repeating: "Check the app location. ", count: 12)
  let russianTitle =
    "Профиль: "
    + String(repeating: "Не удалось подключиться к выбранному серверу — ", count: 12)
  let chineseTitle = "服务器: " + String(repeating: "东京节点🚀 — ", count: 24)
  let unicodeProfile =
    "Profile: " + String(repeating: "Cafe\u{301} — 🧑🏽‍💻 сервер-", count: 24)
  let titles = [englishError, russianTitle, chineseTitle, unicodeProfile]
  let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]

  for title in titles {
    let displayTitle = menuPresentationTitle(title)
    #expect(displayTitle != title)
    #expect(displayTitle.hasSuffix("…"))
    #expect((displayTitle as NSString).size(withAttributes: attributes).width <= 180)
  }

  let displayedProfile = menuPresentationTitle(unicodeProfile)
  let displayedGraphemes = Array(displayedProfile.dropLast())
  #expect(
    Array(unicodeProfile).prefix(displayedGraphemes.count).elementsEqual(displayedGraphemes))

  let shortTitle = "SBM — 東京 👩🏽‍💻"
  let shortDisplay = menuPresentationTitle(shortTitle)
  #expect(Array(shortTitle.utf8).elementsEqual(shortDisplay.utf8))
}

@Test func menuErrorSummaryPrioritizesCanonicalInstallLocationOverHelperState() {
  let installationSummary = SBMText.localized("Move SBM to Applications")

  #expect(
    menuErrorSummary(
      isInstalledInApplications: false,
      helperEnabled: false,
      helperReachable: false
    ) == installationSummary
  )
  #expect(
    menuErrorSummary(
      isInstalledInApplications: false,
      helperEnabled: true,
      helperReachable: false
    ) == installationSummary
  )
  #expect(
    menuErrorSummary(
      isInstalledInApplications: false,
      helperEnabled: true,
      helperReachable: true
    ) == installationSummary
  )
  #expect(
    menuErrorSummary(
      isInstalledInApplications: true,
      helperEnabled: false,
      helperReachable: false
    ) == SBMText.localized("Helper not enabled")
  )
  #expect(
    menuErrorSummary(
      isInstalledInApplications: true,
      helperEnabled: true,
      helperReachable: false
    ) == SBMText.localized("Helper unavailable")
  )
  #expect(
    menuErrorSummary(
      isInstalledInApplications: true,
      helperEnabled: true,
      helperReachable: true
    ) == SBMText.localized("Something went wrong")
  )
}

@Test func menuErrorSummariesResolveAndFitAllSupportedLocalizations() throws {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let labelsByLocale: [String: [String: String]] = [
    "en": [
      "Move SBM to Applications": "Move SBM to Applications",
      "Helper not enabled": "Helper not enabled",
      "Helper unavailable": "Helper unavailable",
      "Something went wrong": "Something went wrong",
    ],
    "ru": [
      "Move SBM to Applications": "SBM → Программы",
      "Helper not enabled": "Помощник не включён",
      "Helper unavailable": "Помощник недоступен",
      "Something went wrong": "Произошла ошибка",
    ],
    "zh-Hans": [
      "Move SBM to Applications": "将 SBM 移至“应用程序”",
      "Helper not enabled": "后台助手未启用",
      "Helper unavailable": "后台助手不可用",
      "Something went wrong": "发生错误",
    ],
  ]
  let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]

  for (locale, expectedLabels) in labelsByLocale {
    let url = root.appendingPathComponent(
      "Sources/SBM/Resources/\(locale).lproj/Localizable.strings"
    )
    let data = try Data(contentsOf: url)
    let propertyList = try PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    )
    let strings = try #require(propertyList as? [String: String])

    for (key, expectedLabel) in expectedLabels {
      let label = try #require(strings[key])
      #expect(label == expectedLabel)
      #expect(!label.contains("Last error:"))
      #expect((label as NSString).size(withAttributes: attributes).width <= 180)
    }
  }
}

@Test func menuConnectionPresentationUsesStateSpecificIcons() {
  #expect(ConnectionPresentation.connected.systemImage == "shield.fill")
  #expect(ConnectionPresentation.disconnected.systemImage == "shield")
  #expect(ConnectionPresentation.unknown.systemImage == "exclamationmark.shield")
  #expect(
    ConnectionPresentation.connecting.systemImage
      == "arrow.trianglehead.2.clockwise.rotate.90")
  #expect(
    ConnectionPresentation.disconnecting.systemImage
      == "arrow.trianglehead.2.clockwise.rotate.90")

  let presentation = ConnectionPresentation.failed(previousRuntimePreserved: true)
  #expect(presentation.systemImage == "shield.fill")
  #expect(presentation.title.contains("previous VPN active"))
  #expect(
    ConnectionPresentation.failed(previousRuntimePreserved: false).systemImage == "shield")
}

@Test func deferredRuntimeApplyUsesOneExplicitActionForEachObservedState() {
  let running = DeferredRuntimeApplyPresentation(
    headline: DeferredRuntimeApplyPresentation.changesReadyToApply,
    action: .reconnect,
    phase: .pending
  )
  #expect(running.headline == "Changes ready to apply")
  #expect(running.action.title == "Reconnect to Apply")

  let stopped = DeferredRuntimeApplyPresentation(
    headline: DeferredRuntimeApplyPresentation.changesReadyToApply,
    action: .reconnect,
    phase: .pending
  )
  #expect(stopped.headline == "Changes ready to apply")
  #expect(stopped.action.title == "Reconnect to Apply")
}

@Test func deferredRuntimeApplyKeepsStableApplyingPresentationAndDisablesAction() {
  let applying = DeferredRuntimeApplyPresentation(
    headline: "Applying…",
    action: .reconnect,
    phase: .applying
  )
  #expect(applying.headline == "Applying…")
  #expect(!applying.actionEnabled)

  let pending = DeferredRuntimeApplyPresentation(
    headline: DeferredRuntimeApplyPresentation.changesReadyToApply,
    action: .reconnect,
    phase: .pending
  )
  #expect(pending.actionEnabled)
}
