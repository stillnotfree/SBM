import Foundation
import SBMShared
import Testing

@Test func stableCoreUpdaterPinsSourceMetadataAndDropsPrebuiltAssetPath() throws {
  let root = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let source = try String(
    contentsOf: root.appending(path: "scripts/update-core.swift"), encoding: .utf8)

  for required in [
    "git/ref/tags/v", "object.type == \"commit\"", "go.mod", "release/LDFLAGS",
    ".github/workflows/build.yml", "parseWorkflowGoVersion", "CORE_REVISION :=",
    "CORE_GO_DIRECTIVE :=", "CORE_GO_VERSION :=", "CORE_BUILD_TAGS :=",
    "Source Go directive:", "Compiler toolchain:",
    "CORE_CGO_ENABLED :=", "CORE_LDFLAGS :=", "options: .atomic",
  ] {
    #expect(source.contains(required))
  }
  for removed in [
    "browserDownloadURL", "archiveDestination", "extractedCore", "sha256(of:",
    "extractionFailed", "digestMismatch",
  ] {
    #expect(!source.contains(removed))
  }
}

@Test func stableCoreUpdaterParsesSourceDirectiveSeparatelyFromWorkflowCompiler() throws {
  let results = try runUpdaterParsers([
    ("directive", "module example.test/core\n\ngo 1.25.5\n"),
    (
      "workflow",
      "jobs:\n  build:\n    steps:\n      - uses: actions/setup-go@v5\n        with:\n          go-version: 1.26.8\n"
    ),
  ])

  #expect(results == ["OK:1.25.5", "OK:1.26.8"])
}

@Test func stableCoreUpdaterAcceptsRepeatedQuotedAndUnquotedStrictPatchVersions() throws {
  let workflow = """
    jobs:
      build:
        steps:
          - uses: actions/setup-go@v5
            with:
              go-version: 1.26.8
          - uses: actions/setup-go@v5
            with:
              go-version : '1.26.8'
          - uses: actions/setup-go@v5
            with:
              go-version: "1.26.8"
    """
  let results = try runUpdaterParsers([("workflow", workflow)])

  #expect(results == ["OK:1.26.8"])
}

@Test func stableCoreUpdaterRejectsMissingAmbiguousDynamicAndMalformedWorkflowVersions() throws {
  let invalidWorkflows = [
    "jobs:\n  build:\n    steps: []\n",
    "go-version: 1.26.8\ngo-version: 1.27.1\n",
    "go-version: ${{ inputs.go-version }}\n",
    "go-version: 1.26\n",
    "go-version: '01.26.8'\n",
    "go-version: \"1.26.8\n",
  ]
  let results = try runUpdaterParsers(invalidWorkflows.map { ("workflow", $0) })

  #expect(results == Array(repeating: "ERROR", count: invalidWorkflows.count))
}

@Test func stableCoreBuildReadonlyModeIgnoresAndCannotAdmitVendoredCode() throws {
  let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let makefile = try String(
    contentsOf: repositoryRoot.appending(path: "Makefile"),
    encoding: .utf8
  )
  #expect(makefile.contains("go build \\\n\t\t-mod=readonly"))

  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMCoreVendorAdmission-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try write("vendor/\n", to: ".gitignore", in: root)
  let gitInit = try TestProcessSupport.run(
    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
    arguments: ["git", "init", "-q"],
    currentDirectoryURL: root
  )
  #expect(gitInit.status == 0)
  try write(
    """
    module example.test/app

    go 1.23.0

    require example.test/dep v1.0.0

    replace example.test/dep => ./dep
    """, to: "go.mod", in: root)
  try write(
    """
    module example.test/dep

    go 1.23.0
    """, to: "dep/go.mod", in: root)
  try write("package dep\nconst Value = \"pinned\"\n", to: "dep/dep.go", in: root)
  try write(
    "package dep\nconst Value = \"vendor\"\n", to: "vendor/example.test/dep/dep.go", in: root)
  try write(
    """
    # example.test/dep v1.0.0 => ./dep
    ## explicit; go 1.23.0
    example.test/dep
    # example.test/dep => ./dep
    """, to: "vendor/modules.txt", in: root)
  let ignoredVendor = try TestProcessSupport.run(
    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
    arguments: ["git", "check-ignore", "-q", "vendor/example.test/dep/dep.go"],
    currentDirectoryURL: root
  )
  #expect(ignoredVendor.status == 0)
  try write(
    """
    package main

    import (
      "fmt"
      "example.test/dep"
    )

    func main() { fmt.Print(dep.Value) }
    """, to: "main.go", in: root)

  let cache = root.appending(path: "go-cache")
  let temporary = root.appending(path: "go-tmp")
  try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  var environment = ProcessInfo.processInfo.environment
  environment["GOCACHE"] = cache.path
  environment["GOTMPDIR"] = temporary.path
  environment["GOTOOLCHAIN"] = "local"
  environment["GOWORK"] = "off"
  environment["GOFLAGS"] = ""

  let readonlyBinary = root.appending(path: "readonly-app")
  let readonlyBuild = try TestProcessSupport.run(
    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
    arguments: ["go", "build", "-mod=readonly", "-o", readonlyBinary.path, "."],
    currentDirectoryURL: root,
    environment: environment
  )
  #expect(readonlyBuild.status == 0)
  let readonlyRun = try TestProcessSupport.run(
    executableURL: readonlyBinary,
    arguments: [],
    currentDirectoryURL: root
  )
  #expect(readonlyRun.output == "pinned")

  let vendorBinary = root.appending(path: "vendor-app")
  let vendorBuild = try TestProcessSupport.run(
    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
    arguments: ["go", "build", "-mod=vendor", "-o", vendorBinary.path, "."],
    currentDirectoryURL: root,
    environment: environment
  )
  #expect(vendorBuild.status == 0)
  let vendorRun = try TestProcessSupport.run(
    executableURL: vendorBinary,
    arguments: [],
    currentDirectoryURL: root
  )
  #expect(vendorRun.output == "vendor")
}

@Test func stableCoreUpdaterStreamsAndRejectsAnOversizedResponse() throws {
  let fixture = try CoreUpdaterNetworkFixture(scenario: "bounded-oversize")
  let result = try fixture.run(arguments: ["bounded"])

  #expect(result.status == 0)
  #expect(result.output.contains("REJECTED:Could not read bounded HTTPS metadata"))
}

@Test func stableCoreUpdaterAcceptsAResponseAtTheBound() throws {
  let fixture = try CoreUpdaterNetworkFixture(scenario: "bounded-exact")
  let result = try fixture.run(arguments: ["bounded"])

  #expect(result.status == 0)
  #expect(result.output.contains("ACCEPTED:3"))
}

@Test func stableCoreUpdaterLeavesCoreLockUnchangedWhenLateMetadataExceedsItsBound() throws {
  let fixture = try CoreUpdaterNetworkFixture(scenario: "oversized-linker")
  let original = try Data(contentsOf: fixture.coreLockURL)
  let result = try fixture.run(arguments: ["stable"])

  #expect(result.status == 0)
  #expect(result.output.contains("REJECTED:Could not read bounded HTTPS metadata"))
  #expect(result.output.contains("release/LDFLAGS"))
  #expect(try Data(contentsOf: fixture.coreLockURL) == original)
}

@Test func stableCoreUpdaterLeavesCoreLockUnchangedWhenFinalRecipeMetadataIsInvalid() throws {
  let fixture = try CoreUpdaterNetworkFixture(scenario: "invalid-workflow")
  let original = try Data(contentsOf: fixture.coreLockURL)
  let result = try fixture.run(arguments: ["stable"])

  #expect(result.status == 0)
  #expect(
    result.output.contains(
      "REJECTED:The exact upstream revision has invalid or missing release workflow Go version metadata."
    ))
  #expect(try Data(contentsOf: fixture.coreLockURL) == original)
}

@Test func stableCoreUpdaterSkipsTagAndMetadataWhenPinnedVersionIsAlreadyCurrent() throws {
  let fixture = try CoreUpdaterNetworkFixture(scenario: "already-current")
  let original = try Data(contentsOf: fixture.coreLockURL)
  let result = try fixture.run(arguments: ["stable"])

  #expect(result.status == 0)
  #expect(result.output.contains("Pinned sing-box 1.14.4 is already current."))
  #expect(
    requestURLs(from: result.output) == [
      "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    ])
  #expect(try Data(contentsOf: fixture.coreLockURL) == original)
}

@Test func stableCoreUpdaterRejectsDowngradeBeforeFetchingTagOrMetadata() throws {
  let fixture = try CoreUpdaterNetworkFixture(scenario: "downgrade")
  let original = try Data(contentsOf: fixture.coreLockURL)
  let result = try fixture.run(arguments: ["stable"])

  #expect(result.status == 0)
  #expect(
    result.output.contains(
      "Refusing to downgrade the pinned sing-box core from 1.14.4 to 1.14.1."))
  #expect(
    requestURLs(from: result.output) == [
      "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    ])
  #expect(try Data(contentsOf: fixture.coreLockURL) == original)
}

@Test func stableCoreUpdaterRejectsReleaseDiscoveryFailuresWithoutChangingCoreLock() throws {
  let cases: [(scenario: String, requests: [String])] = [
    (
      "status-failure",
      ["https://api.github.com/repos/SagerNet/sing-box/releases/latest"]
    ),
    (
      "transport-failure",
      ["https://api.github.com/repos/SagerNet/sing-box/releases/latest"]
    ),
    (
      "malformed-release",
      ["https://api.github.com/repos/SagerNet/sing-box/releases/latest"]
    ),
    (
      "unstable-release",
      ["https://api.github.com/repos/SagerNet/sing-box/releases/latest"]
    ),
    (
      "invalid-tag-reference",
      [
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest",
        "https://api.github.com/repos/SagerNet/sing-box/git/ref/tags/v1.14.5",
      ]
    ),
  ]

  for testCase in cases {
    let fixture = try CoreUpdaterNetworkFixture(scenario: testCase.scenario)
    let original = try Data(contentsOf: fixture.coreLockURL)
    let result = try fixture.run(arguments: ["stable"])

    #expect(result.status == 0)
    #expect(result.output.contains("REJECTED:"))
    #expect(requestURLs(from: result.output) == testCase.requests)
    #expect(try Data(contentsOf: fixture.coreLockURL) == original)
  }
}

@Test func stableCoreUpdaterRejectsHTTPSRedirectToHTTPWithoutChangingCoreLock() throws {
  let fixture = try CoreUpdaterNetworkFixture(scenario: "http-redirect")
  let original = try Data(contentsOf: fixture.coreLockURL)
  let result = try fixture.run(arguments: ["stable"])

  #expect(result.status == 0)
  #expect(result.output.contains("REJECTED:Could not read bounded HTTPS metadata"))
  #expect(
    result.output.contains(
      "REDIRECT:https://api.github.com/repos/SagerNet/sing-box/releases/latest -> "
        + "http://redirect.example/repos/SagerNet/sing-box/releases/latest"))
  #expect(
    requestURLs(from: result.output) == [
      "https://api.github.com/repos/SagerNet/sing-box/releases/latest",
      "http://redirect.example/repos/SagerNet/sing-box/releases/latest",
    ])
  #expect(try Data(contentsOf: fixture.coreLockURL) == original)
}

@Test func stableCoreUpdaterRejectsUnexpectedFinalRedirectStatusWithoutChangingCoreLock() throws {
  let fixture = try CoreUpdaterNetworkFixture(scenario: "redirect-final-status")
  let original = try Data(contentsOf: fixture.coreLockURL)
  let result = try fixture.run(arguments: ["stable"])

  #expect(result.status == 0)
  #expect(result.output.contains("REJECTED:Could not read bounded HTTPS metadata"))
  #expect(
    requestURLs(from: result.output) == [
      "https://api.github.com/repos/SagerNet/sing-box/releases/latest",
      "https://redirect.example/repos/SagerNet/sing-box/releases/latest",
    ])
  #expect(try Data(contentsOf: fixture.coreLockURL) == original)
}

@Test func stableCoreUpdaterFollowsHTTPSRedirectAndWritesTheExactAcceptedRecipe() throws {
  let fixture = try CoreUpdaterNetworkFixture(scenario: "https-redirect")
  let original = try Data(contentsOf: fixture.coreLockURL)
  let result = try fixture.run(arguments: ["stable"])
  let updatedData = try Data(contentsOf: fixture.coreLockURL)
  let expectedRecipe =
    "CORE_VERSION := 1.14.5\n"
    + "CORE_REVISION := \(String(repeating: "c", count: 40))\n"
    + "CORE_GO_DIRECTIVE := 1.25.5\n"
    + "CORE_GO_VERSION := 1.26.8\n"
    + "CORE_BUILD_TAGS := with_clash_api,with_quic,with_utls\n"
    + "CORE_CGO_ENABLED := 1\n"
    + "CORE_LDFLAGS := -X runtime.test=value\n"

  #expect(result.status == 0)
  #expect(result.output.contains("ACCEPTED"))
  #expect(original != updatedData)
  #expect(updatedData == Data(expectedRecipe.utf8))
  #expect(
    result.output.contains(
      "REDIRECT:https://api.github.com/repos/SagerNet/sing-box/releases/latest -> "
        + "https://redirect.example/repos/SagerNet/sing-box/releases/latest"))
  #expect(
    requestURLs(from: result.output) == [
      "https://api.github.com/repos/SagerNet/sing-box/releases/latest",
      "https://redirect.example/repos/SagerNet/sing-box/releases/latest",
      "https://api.github.com/repos/SagerNet/sing-box/git/ref/tags/v1.14.5",
      "https://raw.githubusercontent.com/SagerNet/sing-box/\(String(repeating: "c", count: 40))/go.mod",
      "https://raw.githubusercontent.com/SagerNet/sing-box/\(String(repeating: "c", count: 40))/release/LDFLAGS",
      "https://raw.githubusercontent.com/SagerNet/sing-box/\(String(repeating: "c", count: 40))/.github/workflows/build.yml",
    ])
}

private func requestURLs(from output: String) -> [String] {
  output.split(whereSeparator: \.isNewline).compactMap { line in
    guard line.hasPrefix("REQUEST:") else { return nil }
    return String(line.dropFirst("REQUEST:".count))
  }
}

private func runUpdaterParsers(_ cases: [(String, String)]) throws -> [String] {
  var source = try coreUpdaterSource()
  source = source.replacingOccurrences(of: "private enum UpdateCore", with: "enum UpdateCore")
  source = source.replacingOccurrences(
    of: "private static func parseGoVersion(", with: "static func parseGoVersion(")
  source = source.replacingOccurrences(
    of: "private static func parseWorkflowGoVersion(",
    with: "static func parseWorkflowGoVersion("
  )
  let runner = try #require(source.range(of: "\ndo {\n  try await UpdateCore.runUpdate()"))
  source =
    String(source[..<runner.lowerBound]) + """

      for argument in CommandLine.arguments.dropFirst() {
        let parts = argument.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
          let data = Data(base64Encoded: String(parts[1])),
          let input = String(data: data, encoding: .utf8)
        else {
          print("ERROR")
          continue
        }
        do {
          let version: String
          switch parts[0] {
          case "directive": version = try UpdateCore.parseGoVersion(input)
          case "workflow": version = try UpdateCore.parseWorkflowGoVersion(input)
          default: throw UpdateCoreFailure.invalidSourceMetadata("test input")
          }
          print("OK:\\(version)")
        } catch {
          print("ERROR")
        }
      }
      """

  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SBMCoreUpdaterParserTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = directory.appendingPathComponent("parser.swift")
  try Data(source.utf8).write(to: script)
  let arguments = cases.map { mode, input in
    "\(mode):\(Data(input.utf8).base64EncodedString())"
  }
  let result = try TestProcessSupport.run(
    executableURL: URL(fileURLWithPath: "/usr/bin/swift"),
    arguments: [script.path] + arguments,
    timeoutSeconds: 30,
    currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  )
  #expect(result.status == 0)
  return result.output.split(whereSeparator: \.isNewline).map(String.init)
}

private func coreUpdaterSource() throws -> String {
  let root = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  return try String(contentsOf: root.appending(path: "scripts/update-core.swift"), encoding: .utf8)
}

private func write(_ contents: String, to path: String, in root: URL) throws {
  let url = root.appending(path: path)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data(contents.utf8).write(to: url)
}

private final class CoreUpdaterNetworkFixture {
  let root: URL
  let script: URL
  let coreLockURL: URL
  private let environment: [String: String]

  init(scenario: String) throws {
    let scratchRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SBMCoreUpdaterNetwork-\(UUID().uuidString)", isDirectory: true)
    root = scratchRoot
    script = scratchRoot.appendingPathComponent("update-core-test.swift")
    coreLockURL = scratchRoot.appendingPathComponent("Core.lock")
    do {
      try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)

      let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      try FileManager.default.copyItem(
        at: repositoryRoot.appending(path: "Core.lock"),
        to: coreLockURL
      )
      try write("", to: "Makefile", in: scratchRoot)
      try write("", to: "Package.swift", in: scratchRoot)
      try Data(try updaterNetworkHarness().utf8).write(to: script)

      let swiftModules = scratchRoot.appending(path: "swift-modules")
      let clangModules = scratchRoot.appending(path: "clang-modules")
      try FileManager.default.createDirectory(at: swiftModules, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: clangModules, withIntermediateDirectories: true)
      var environment = ProcessInfo.processInfo.environment
      environment["CP01_UPDATE_CORE_CASE"] = scenario
      environment["SWIFT_MODULECACHE_PATH"] = swiftModules.path
      environment["CLANG_MODULE_CACHE_PATH"] = clangModules.path
      self.environment = environment
    } catch {
      try? FileManager.default.removeItem(at: scratchRoot)
      throw error
    }
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func run(arguments: [String]) throws -> TestProcessResult {
    try TestProcessSupport.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/swift"),
      arguments: [script.path] + arguments,
      timeoutSeconds: 60,
      currentDirectoryURL: root,
      environment: environment
    )
  }
}

private func updaterNetworkHarness() throws -> String {
  var source = try coreUpdaterSource()
  source = source.replacingOccurrences(of: "private enum UpdateCore", with: "enum UpdateCore")
  source = source.replacingOccurrences(
    of: "private static func getData(",
    with: "static func getData("
  )
  let runner = try #require(source.range(of: "\ndo {\n  try await UpdateCore.runUpdate()"))
  return String(source[..<runner.lowerBound]) + #"""

    private final class CoreUpdaterURLProtocol: URLProtocol {
      override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
      }

      override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

      override func startLoading() {
        let scenario = ProcessInfo.processInfo.environment["CP01_UPDATE_CORE_CASE"] ?? "valid"
        guard let url = request.url, let host = url.host else {
          client?.urlProtocol(self, didFailWithError: URLError(.badURL))
          return
        }
        let path = request.url?.path ?? ""
        FileHandle.standardOutput.write(Data("REQUEST:\(url.absoluteString)\n".utf8))

        if host == "api.github.com", path == "/repos/SagerNet/sing-box/releases/latest",
          ["https-redirect", "http-redirect", "redirect-final-status"].contains(scenario)
        {
          let destinationScheme = scenario == "http-redirect" ? "http" : "https"
          let destination = URL(
            string:
              "\(destinationScheme)://redirect.example/repos/SagerNet/sing-box/releases/latest"
          )!
          let response = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": destination.absoluteString]
          )!
          FileHandle.standardOutput.write(
            Data("REDIRECT:\(url.absoluteString) -> \(destination.absoluteString)\n".utf8))
          client?.urlProtocol(
            self,
            wasRedirectedTo: URLRequest(url: destination),
            redirectResponse: response
          )
          return
        }
        if host == "api.github.com", path == "/repos/SagerNet/sing-box/releases/latest",
          scenario == "transport-failure"
        {
          client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
          return
        }

        let status: Int
        let body: Data
        if host == "api.github.com", path == "/bounded" {
          status = 200
          body = Data((scenario == "bounded-exact" ? "abc" : "abcd").utf8)
        } else if (host == "api.github.com" || host == "redirect.example"),
          path == "/repos/SagerNet/sing-box/releases/latest"
        {
          if scenario == "status-failure" {
            status = 503
            body = Data("service unavailable".utf8)
          } else if scenario == "redirect-final-status" {
            status = 201
            body = Data(#"{"tag_name":"v1.14.5","draft":false,"prerelease":false}"#.utf8)
          } else if scenario == "malformed-release" {
            status = 200
            body = Data("not json".utf8)
          } else if scenario == "unstable-release" {
            status = 200
            body = Data(#"{"tag_name":"v1.14.5","draft":false,"prerelease":true}"#.utf8)
          } else if scenario == "already-current" {
            status = 200
            body = Data(#"{"tag_name":"v1.14.4","draft":false,"prerelease":false}"#.utf8)
          } else if scenario == "downgrade" {
            status = 200
            body = Data(#"{"tag_name":"v1.14.1","draft":false,"prerelease":false}"#.utf8)
          } else {
            status = 200
            body = Data(#"{"tag_name":"v1.14.5","draft":false,"prerelease":false}"#.utf8)
          }
        } else if host == "api.github.com",
          path == "/repos/SagerNet/sing-box/git/ref/tags/v1.14.5"
        {
          status = 200
          let reference = scenario == "invalid-tag-reference"
            ? #"{"object":{"type":"tag","sha":"cccccccccccccccccccccccccccccccccccccccc"}}"#
            : #"{"object":{"type":"commit","sha":"cccccccccccccccccccccccccccccccccccccccc"}}"#
          body = Data(reference.utf8)
        } else if host == "raw.githubusercontent.com",
          path.hasPrefix("/SagerNet/sing-box/\(String(repeating: "c", count: 40))/")
        {
          if path.hasSuffix("/go.mod") {
            status = 200
            body = Data("module github.com/SagerNet/sing-box\n\ngo 1.25.5\n".utf8)
          } else if path.hasSuffix("/release/LDFLAGS") {
            status = 200
            body = Data((
              scenario == "oversized-linker"
                ? String(repeating: "x", count: 64 * 1_024 + 1)
                : "-X runtime.test=value\n"
            ).utf8)
          } else if path.hasSuffix("/.github/workflows/build.yml") {
            status = 200
            let workflow = scenario == "invalid-workflow"
              ? "go-version: 1.26\n"
              : "go-version: 1.26.8\n"
            body = Data(workflow.utf8)
          } else {
            client?.urlProtocol(
              self,
              didFailWithError: URLError(.unsupportedURL, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected updater URL: \(url.absoluteString)"
              ]))
            return
          }
        } else {
          client?.urlProtocol(
            self,
            didFailWithError: URLError(.unsupportedURL, userInfo: [
              NSLocalizedDescriptionKey: "Unexpected updater URL: \(url.absoluteString)"
            ]))
          return
        }

        let response = HTTPURLResponse(
          url: url,
          statusCode: status,
          httpVersion: "HTTP/1.1",
          headerFields: ["Cache-Control": "no-store"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
      }

      override func stopLoading() {}
    }

    guard URLProtocol.registerClass(CoreUpdaterURLProtocol.self) else {
      FileHandle.standardError.write(Data("URLProtocol registration failed\n".utf8))
      exit(EXIT_FAILURE)
    }
    do {
      if CommandLine.arguments.last == "bounded" {
        let data = try await UpdateCore.getData(
          at: URL(string: "https://api.github.com/bounded")!,
          maximumBytes: 3
        )
        print("ACCEPTED:\(data.count)")
      } else {
        try await UpdateCore.runUpdate()
        print("ACCEPTED")
      }
    } catch {
      print("REJECTED:\(error.localizedDescription)")
    }
    """#
}
