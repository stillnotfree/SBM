import Foundation
import Testing

private func appTerminationHarnessSource() throws -> String {
  let sourceURL = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/SBM/SBMApp.swift")
  let source = try String(contentsOf: sourceURL, encoding: .utf8)
  let start = "@MainActor\nprivate final class AppDelegate: NSObject, NSApplicationDelegate {"
  let end = "\n\n@main\nstruct SBMApp: App {"
  guard let classStart = source.range(of: start),
    let classEnd = source.range(of: end, range: classStart.lowerBound..<source.endIndex)
  else {
    throw CocoaError(.coderInvalidValue)
  }

  var appDelegate = String(source[classStart.lowerBound..<classEnd.lowerBound])
  appDelegate =
    appDelegate
    .replacingOccurrences(of: "NSApplication.shared", with: "RecordingApplication.shared")
    .replacingOccurrences(of: "NSApp.", with: "RecordingApplication.shared.")
    .replacingOccurrences(of: "NSApplicationDelegate", with: "RecordingApplicationDelegate")
    .replacingOccurrences(of: "NSApplication", with: "RecordingApplication")
    .replacingOccurrences(of: "NSWorkspace", with: "RecordingWorkspace")
    .replacingOccurrences(of: "NSAlert", with: "RecordingAlert")

  return """
    import Foundation

    @MainActor protocol RecordingApplicationDelegate {}

    @MainActor final class RecordingApplication: NSObject {
      enum TerminateReply { case terminateNow, terminateCancel, terminateLater }
      static let shared = RecordingApplication()
      fileprivate var delegate: AppDelegate?
      var modalWindow: AnyObject?
      private(set) var terminationCalls = 0
      private(set) var replyCalls = 0
      private(set) var didTerminate = false

      func activate() {}
      func terminate(_ sender: Any?) {
        terminationCalls += 1
        if delegate?.applicationShouldTerminate(self) == .terminateNow {
          didTerminate = true
        }
      }
      func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
        replyCalls += 1
        if shouldTerminate { didTerminate = true }
      }
    }

    @MainActor final class RecordingWorkspace {
      static let shared = RecordingWorkspace()
      static let didWakeNotification = Notification.Name("RecordingWorkspaceDidWake")
      let notificationCenter = NotificationCenter()
    }

    @MainActor final class RecordingAlert {
      enum Style { case warning }
      static var calls = 0
      static var duringModal: (@MainActor () -> Void)?
      var alertStyle: Style = .warning
      var messageText = ""
      var informativeText = ""
      func addButton(withTitle: String) {}
      func runModal() {
        Self.calls += 1
        Self.duringModal?()
      }
    }

    @MainActor final class AppModel {
      let proof: Bool
      var safeCurrentError: String? { nil }
      init(proof: Bool) { self.proof = proof }
      func disconnectBeforeQuit() async -> Bool { proof }
      func applicationDidBecomeActive() {}
      func refresh() {}
    }

    enum SBMText {
      static func localized(_ value: String) -> String { value }
    }

    \(appDelegate)

    @main struct HarnessMain {
      @MainActor static func main() async {
        let proof = CommandLine.arguments.last == "success"
        let application = RecordingApplication.shared
        let delegate = AppDelegate()
        let model = AppModel(proof: proof)
        delegate.model = model
        application.delegate = delegate
        var modalRepeat: RecordingApplication.TerminateReply?
        RecordingAlert.duringModal = {
          modalRepeat = delegate.applicationShouldTerminate(application)
        }

        let first = delegate.applicationShouldTerminate(application)
        let repeated = delegate.applicationShouldTerminate(application)
        try? await Task.sleep(for: .milliseconds(50))
        let retry = proof ? nil : delegate.applicationShouldTerminate(application)
        if !proof { try? await Task.sleep(for: .milliseconds(50)) }
        print(
          "first=\\(label(first)) repeated=\\(label(repeated)) "
            + "modalRepeat=\\(modalRepeat.map(label) ?? \"none\") "
            + "retry=\\(retry.map(label) ?? \"none\") "
            + "terminateCalls=\\(application.terminationCalls) "
            + "replyCalls=\\(application.replyCalls) "
            + "terminated=\\(application.didTerminate) alerts=\\(RecordingAlert.calls)"
        )
      }

      static func label(_ reply: RecordingApplication.TerminateReply) -> String {
        switch reply {
        case .terminateNow: "now"
        case .terminateCancel: "cancel"
        case .terminateLater: "later"
        }
      }
    }
    """
}

@Test func appDelegateUsesCancelUntilProofThenOneAuthorizedReentry() throws {
  let result = try runAppTerminationHarness(mode: "success")
  #expect(result.status == 0, Comment(rawValue: result.output))
  #expect(
    result.output.contains(
      "first=cancel repeated=cancel modalRepeat=none retry=none "
        + "terminateCalls=1 replyCalls=0 terminated=true alerts=0"
    ),
    Comment(rawValue: result.output)
  )
}

@Test func appDelegateDoesNotTerminateWhenProofFails() throws {
  let result = try runAppTerminationHarness(mode: "failure")
  #expect(result.status == 0, Comment(rawValue: result.output))
  #expect(
    result.output.contains(
      "first=cancel repeated=cancel modalRepeat=cancel retry=cancel "
        + "terminateCalls=0 replyCalls=0 terminated=false alerts=2"
    ),
    Comment(rawValue: result.output)
  )
}

private func runAppTerminationHarness(mode: String) throws -> TestProcessResult {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMAppTerminationHarness-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let sourceURL = directory.appendingPathComponent("harness.swift")
  let executableURL = directory.appendingPathComponent("harness")
  let moduleCacheURL = directory.appendingPathComponent("module-cache", isDirectory: true)
  try FileManager.default.createDirectory(at: moduleCacheURL, withIntermediateDirectories: true)
  try Data(try appTerminationHarnessSource().utf8).write(to: sourceURL)

  var compilerArguments = [
    "swiftc", "-parse-as-library", "-module-cache-path", moduleCacheURL.path, sourceURL.path,
    "-o", executableURL.path,
  ]
  if ProcessInfo.processInfo.environment["SBM_APP_TERMINATION_TSAN"] == "1" {
    compilerArguments.insert("-sanitize=thread", at: 1)
  }
  let compile = try TestProcessSupport.run(
    executableURL: URL(filePath: "/usr/bin/xcrun"),
    arguments: compilerArguments,
    timeoutSeconds: 30
  )
  guard compile.status == 0 else {
    throw NSError(
      domain: "AppTerminationHarness",
      code: Int(compile.status),
      userInfo: [NSLocalizedDescriptionKey: compile.output]
    )
  }
  return try TestProcessSupport.run(
    executableURL: executableURL,
    arguments: [mode],
    timeoutSeconds: 5
  )
}
