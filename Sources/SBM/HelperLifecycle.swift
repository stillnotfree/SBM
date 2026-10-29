import Foundation
import SBMShared
import ServiceManagement

enum HelperRegistrationState: Equatable {
  case enabled
  case requiresApproval
  case notRegistered
  case notFound
  case unknown
}

@MainActor
protocol HelperServiceManaging: AnyObject {
  var registrationState: HelperRegistrationState { get }
  var legacyRegistrationState: HelperRegistrationState { get }

  func register() throws
  func unregister() async throws
  func unregisterLegacy() async throws
  func openSystemSettings()
}

@MainActor
final class SystemHelperService: HelperServiceManaging {
  private let service = SMAppService.daemon(
    plistName: HelperConstants.daemonPlistName
  )
  private let legacyService = SMAppService.daemon(
    plistName: HelperConstants.legacyDaemonPlistName
  )

  var registrationState: HelperRegistrationState {
    Self.registrationState(for: service)
  }

  var legacyRegistrationState: HelperRegistrationState {
    Self.registrationState(for: legacyService)
  }

  private static func registrationState(for service: SMAppService) -> HelperRegistrationState {
    switch service.status {
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    case .notRegistered:
      .notRegistered
    case .notFound:
      .notFound
    @unknown default:
      .unknown
    }
  }

  func register() throws {
    try service.register()
  }

  func unregister() async throws {
    try await unregister(service)
  }

  func unregisterLegacy() async throws {
    try await unregister(legacyService)
  }

  private func unregister(_ service: SMAppService) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      service.unregister { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

@MainActor
protocol HelperLifecycleTiming {
  var now: ContinuousClock.Instant { get }

  func sleep(for duration: Duration) async throws
}

@MainActor
struct ContinuousHelperLifecycleTiming: HelperLifecycleTiming {
  private let clock = ContinuousClock()

  var now: ContinuousClock.Instant {
    clock.now
  }

  func sleep(for duration: Duration) async throws {
    try await clock.sleep(for: duration)
  }
}

enum HelperLifecycleFailure: LocalizedError {
  case approvalRequired
  case registrationDidNotFinish
  case coldOffProofRequired
  case replacementDidNotFinish(String?)
  case startupTimedOut(String?)

  var errorDescription: String? {
    switch self {
    case .approvalRequired:
      SBMText.localized("Approve SBMHelper in System Settings, then return to SBM.")
    case .registrationDidNotFinish:
      SBMText.localized(
        "macOS did not enable the background helper. Approve it in System Settings, then return to SBM."
      )
    case .coldOffProofRequired:
      SBMText.localized("A verified Cold OFF claim is required before removing the helper.")
    case .replacementDidNotFinish(let detail):
      if let detail, !detail.isEmpty {
        SBMText.format("macOS did not finish replacing the background helper: %@", detail)
      } else {
        SBMText.localized("macOS did not finish replacing the background helper.")
      }
    case .startupTimedOut(let detail):
      if let detail, !detail.isEmpty {
        SBMText.format("The background helper did not start: %@", detail)
      } else {
        SBMText.localized("The background helper did not start.")
      }
    }
  }
}

@MainActor
enum HelperLifecycle {
  static func enable(
    service: any HelperServiceManaging,
    timeout: Duration = .seconds(15),
    pollInterval: Duration = .milliseconds(250),
    timing: any HelperLifecycleTiming = ContinuousHelperLifecycleTiming(),
    probe: @escaping @Sendable () async throws -> HelperResponse
  ) async throws -> HelperResponse {
    switch service.registrationState {
    case .requiresApproval:
      throw HelperLifecycleFailure.approvalRequired
    case .notRegistered, .notFound:
      try Task.checkCancellation()
      do {
        try service.register()
      } catch {
        guard service.registrationState == .requiresApproval else { throw error }
        throw HelperLifecycleFailure.approvalRequired
      }
    case .enabled:
      break
    case .unknown:
      throw HelperLifecycleFailure.registrationDidNotFinish
    }

    return try await waitForReadiness(
      service: service,
      timeout: timeout,
      pollInterval: pollInterval,
      timing: timing,
      disabledRegistrationFailure: .registrationDidNotFinish,
      probe: probe
    )
  }

  static func replace(
    service: any HelperServiceManaging,
    coldOffClaim: ColdOffProof? = nil,
    candidateBundleURL: URL? = nil,
    registrationTimeout: Duration = .seconds(60),
    startupTimeout: Duration = .seconds(15),
    pollInterval: Duration = .milliseconds(500),
    timing: any HelperLifecycleTiming = ContinuousHelperLifecycleTiming(),
    probe: @escaping @Sendable () async throws -> HelperResponse
  ) async throws -> HelperResponse {
    try Task.checkCancellation()
    switch service.registrationState {
    case .enabled:
      guard let coldOffClaim else {
        throw HelperLifecycleFailure.coldOffProofRequired
      }
      guard let candidateBundleURL else {
        throw HelperLifecycleFailure.coldOffProofRequired
      }
      try Task.checkCancellation()
      try HelperClient.validateHeldColdOffClaim(
        bundleURL: candidateBundleURL,
        claim: coldOffClaim
      )
      try await service.unregister()
      try Task.checkCancellation()
      try await timing.sleep(for: .seconds(2))
      try Task.checkCancellation()
      try HelperClient.validateHeldColdOffClaim(
        bundleURL: candidateBundleURL,
        claim: coldOffClaim
      )
      coldOffClaim.release()
    case .notRegistered, .notFound:
      coldOffClaim?.release()
      break
    case .requiresApproval:
      throw HelperLifecycleFailure.approvalRequired
    case .unknown:
      throw HelperLifecycleFailure.registrationDidNotFinish
    }

    let registrationDeadline = timing.now.advanced(by: registrationTimeout)
    var mostRecentError: (any Error)?
    var didRegister = false

    // SMAppService.unregister() can complete before Background Task Management
    // stops reporting the old item as enabled. Register the replacement
    // explicitly instead of treating that stale state as a successful update.
    while timing.now < registrationDeadline {
      try Task.checkCancellation()

      if service.registrationState == .requiresApproval {
        throw HelperLifecycleFailure.approvalRequired
      }

      do {
        if let candidateBundleURL {
          _ = try HelperClient.currentCandidateSnapshot(bundleURL: candidateBundleURL)
        }
        try Task.checkCancellation()
        try service.register()
        didRegister = true
        break
      } catch {
        guard isTransientRegistrationError(error) else { throw error }
        mostRecentError = error
      }
      try await timing.sleep(for: pollInterval)
    }

    guard didRegister else {
      throw HelperLifecycleFailure.replacementDidNotFinish(
        mostRecentError?.localizedDescription
      )
    }

    return try await waitForReadiness(
      service: service,
      timeout: startupTimeout,
      pollInterval: pollInterval,
      timing: timing,
      disabledRegistrationFailure: nil,
      probe: probe
    )
  }

  static func upgradeLegacy1115(
    service: any HelperServiceManaging,
    bundleURL: URL,
    startupTimeout: Duration = .seconds(15),
    pollInterval: Duration = .milliseconds(250),
    timing: any HelperLifecycleTiming = ContinuousHelperLifecycleTiming(),
    probe: @escaping @Sendable () async throws -> HelperResponse,
    finish: @escaping @Sendable () async throws -> HelperResponse
  ) async throws -> (response: HelperResponse, newlyRetired: Bool) {
    let inert = try await enable(
      service: service,
      timeout: startupTimeout,
      pollInterval: pollInterval,
      timing: timing,
      probe: probe
    )
    guard inert.protocolVersion == HelperConstants.protocolVersion,
      inert.helperVersion == HelperConstants.helperVersion,
      inert.helperRevision == HelperConstants.helperRevision
    else {
      throw HelperLifecycleFailure.startupTimedOut(
        "The current helper tuple changed during upgrade.")
    }

    if inert.legacy1115Retired == true {
      guard
        service.legacyRegistrationState == .notRegistered
          || service.legacyRegistrationState == .notFound
      else {
        throw HelperLifecycleFailure.startupTimedOut(
          "The completed retirement receipt conflicts with native legacy registration."
        )
      }
      return (inert, false)
    }
    guard inert.success, !inert.coreRunning, inert.legacy1115Retired == false else {
      throw HelperLifecycleFailure.startupTimedOut(
        "The current helper did not provide an authenticated inert retirement status."
      )
    }

    guard legacyTombstoneIsValid(bundleURL: bundleURL) else {
      throw HelperLifecycleFailure.replacementDidNotFinish(
        "The packaged legacy helper tombstone is missing or invalid."
      )
    }
    try Task.checkCancellation()
    switch service.legacyRegistrationState {
    case .enabled:
      try await service.unregisterLegacy()
    case .notRegistered, .notFound:
      break
    case .requiresApproval:
      throw HelperLifecycleFailure.approvalRequired
    case .unknown:
      throw HelperLifecycleFailure.registrationDidNotFinish
    }

    // Once the old native registration has been withdrawn, this task owns the
    // one bounded Finish request through reply loss or caller cancellation.
    let retired = try await finish()
    guard retired.protocolVersion == HelperConstants.protocolVersion,
      retired.helperVersion == HelperConstants.helperVersion,
      retired.helperRevision == HelperConstants.helperRevision
    else {
      throw HelperLifecycleFailure.startupTimedOut(
        "The helper tuple changed during legacy retirement."
      )
    }
    guard retired.success else {
      let message = retired.message.trimmingCharacters(in: .whitespacesAndNewlines)
      throw HelperLifecycleFailure.startupTimedOut(
        message.isEmpty
          ? "The helper reported a Finish failure without details."
          : message
      )
    }
    guard !retired.coreRunning, retired.legacy1115Retired == true else {
      throw HelperLifecycleFailure.startupTimedOut(
        "The helper did not return a successful stopped legacy-retirement receipt."
      )
    }
    return (retired, true)
  }

  static func legacyTombstoneIsValid(bundleURL: URL) -> Bool {
    let plistURL = bundleURL.appendingPathComponent(
      "Contents/Library/LaunchDaemons/\(HelperConstants.legacyDaemonPlistName)"
    )
    guard let data = try? Data(contentsOf: plistURL),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      plist["Label"] as? String == HelperConstants.legacyServiceLabel,
      plist["BundleProgram"] as? String == "Contents/Resources/SBMHelper",
      plist["Sockets"] == nil,
      let environment = plist["EnvironmentVariables"] as? [String: String],
      environment[HelperConstants.serviceLabelEnvironmentKey] == HelperConstants.legacyServiceLabel
    else { return false }
    return true
  }

  private static func waitForReadiness(
    service: any HelperServiceManaging,
    timeout: Duration,
    pollInterval: Duration,
    timing: any HelperLifecycleTiming,
    disabledRegistrationFailure: HelperLifecycleFailure?,
    probe: @escaping @Sendable () async throws -> HelperResponse
  ) async throws -> HelperResponse {
    let deadline = timing.now.advanced(by: timeout)
    var mostRecentError: (any Error)?

    while timing.now < deadline {
      try Task.checkCancellation()

      let registrationState = service.registrationState
      guard registrationState != .requiresApproval else {
        throw HelperLifecycleFailure.approvalRequired
      }

      if registrationState == .enabled {
        do {
          let response = try await probe()
          try Task.checkCancellation()
          guard response.protocolVersion == HelperConstants.protocolVersion,
            response.helperVersion == HelperConstants.helperVersion,
            response.helperRevision == HelperConstants.helperRevision
          else {
            throw HelperLifecycleFailure.startupTimedOut("macOS is still running an older helper.")
          }
          let registrationStateAfterProbe = service.registrationState
          guard registrationStateAfterProbe != .requiresApproval else {
            throw HelperLifecycleFailure.approvalRequired
          }
          if registrationStateAfterProbe == .enabled { return response }
        } catch HelperLifecycleFailure.approvalRequired {
          throw HelperLifecycleFailure.approvalRequired
        } catch {
          if Task.isCancelled || error is CancellationError { throw CancellationError() }
          mostRecentError = error
        }
      }

      try await timing.sleep(for: pollInterval)
    }

    if let disabledRegistrationFailure, service.registrationState != .enabled {
      throw disabledRegistrationFailure
    }
    throw HelperLifecycleFailure.startupTimedOut(mostRecentError?.localizedDescription)
  }

  private static func isTransientRegistrationError(_ error: any Error) -> Bool {
    // This classifier admits one replacement race, modeled in the existing tests.
    // Its signature is POSIX-domain EPERM and requires both fields below.
    // A code match in another domain is not evidence of that race.
    // Such registration errors therefore propagate unchanged.
    let nsError = error as NSError
    return nsError.domain == NSPOSIXErrorDomain
      && nsError.code == Int(POSIXErrorCode.EPERM.rawValue)
  }
}
