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

  func register() throws
  func unregister() async throws
  func openSystemSettings()
}

@MainActor
final class SystemHelperService: HelperServiceManaging {
  private let service = SMAppService.daemon(
    plistName: HelperConstants.daemonPlistName
  )

  var registrationState: HelperRegistrationState {
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

enum HelperLifecycleFailure: LocalizedError {
  case approvalRequired
  case registrationDidNotFinish
  case replacementDidNotFinish(String?)
  case startupTimedOut(String?)

  var errorDescription: String? {
    switch self {
    case .approvalRequired:
      "Approve SBMHelper in System Settings, then return to SBM."
    case .registrationDidNotFinish:
      "macOS did not enable the background helper. Approve it in System Settings, then return to SBM."
    case .replacementDidNotFinish(let detail):
      if let detail, !detail.isEmpty {
        "macOS did not finish replacing the background helper: \(detail)"
      } else {
        "macOS did not finish replacing the background helper."
      }
    case .startupTimedOut(let detail):
      if let detail, !detail.isEmpty {
        "The background helper did not start: \(detail)"
      } else {
        "The background helper did not start."
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
    probe: @escaping @Sendable () async throws -> HelperResponse
  ) async throws -> HelperResponse {
    switch service.registrationState {
    case .requiresApproval:
      throw HelperLifecycleFailure.approvalRequired
    case .notRegistered, .notFound:
      try service.register()
    case .enabled:
      break
    case .unknown:
      throw HelperLifecycleFailure.registrationDidNotFinish
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var mostRecentError: (any Error)?

    while clock.now < deadline {
      switch service.registrationState {
      case .requiresApproval:
        throw HelperLifecycleFailure.approvalRequired
      case .enabled:
        do {
          let response = try await probe()
          guard response.helperVersion == HelperConstants.helperVersion,
            response.helperRevision == HelperConstants.helperRevision
          else {
            mostRecentError = HelperLifecycleFailure.startupTimedOut(
              "macOS is still running an older helper."
            )
            try await Task.sleep(for: pollInterval)
            continue
          }
          return response
        } catch {
          mostRecentError = error
        }
      case .notRegistered, .notFound, .unknown:
        break
      }
      try await Task.sleep(for: pollInterval)
    }

    guard service.registrationState == .enabled else {
      throw HelperLifecycleFailure.registrationDidNotFinish
    }
    throw HelperLifecycleFailure.startupTimedOut(
      mostRecentError?.localizedDescription
    )
  }

  static func replace(
    service: any HelperServiceManaging,
    registrationTimeout: Duration = .seconds(25),
    startupTimeout: Duration = .seconds(15),
    pollInterval: Duration = .milliseconds(500),
    waiting: @escaping () -> Void = {},
    probe: @escaping @Sendable () async throws -> HelperResponse
  ) async throws -> HelperResponse {
    switch service.registrationState {
    case .enabled:
      try await service.unregister()
    case .notRegistered, .notFound:
      break
    case .requiresApproval:
      throw HelperLifecycleFailure.approvalRequired
    case .unknown:
      throw HelperLifecycleFailure.registrationDidNotFinish
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: registrationTimeout)
    var mostRecentError: (any Error)?

    while clock.now < deadline {
      try Task.checkCancellation()

      switch service.registrationState {
      case .requiresApproval:
        throw HelperLifecycleFailure.approvalRequired
      case .enabled:
        do {
          return try await enable(
            service: service,
            timeout: startupTimeout,
            pollInterval: .milliseconds(250),
            probe: probe
          )
        } catch {
          guard isTransientReplacementError(error) else { throw error }
          mostRecentError = error
          waiting()
        }
      case .notRegistered, .notFound:
        do {
          try service.register()
          return try await enable(
            service: service,
            timeout: startupTimeout,
            pollInterval: .milliseconds(250),
            probe: probe
          )
        } catch {
          guard isTransientReplacementError(error) else { throw error }
          mostRecentError = error
          waiting()
        }
      case .unknown:
        break
      }

      try await Task.sleep(for: pollInterval)
    }

    throw HelperLifecycleFailure.replacementDidNotFinish(
      mostRecentError?.localizedDescription
    )
  }

  private static func isTransientReplacementError(_ error: any Error) -> Bool {
    // SMAppService can return EPERM for a short period after its asynchronous
    // unregister completion while Background Task Management still retains the
    // old item. Retrying only this error avoids hiding signature or approval
    // failures.
    if let failure = error as? HelperLifecycleFailure,
      case .startupTimedOut = failure
    {
      return true
    }
    let nsError = error as NSError
    return nsError.code == Int(POSIXErrorCode.EPERM.rawValue)
  }
}
