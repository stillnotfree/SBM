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
  case startupTimedOut(String?)

  var errorDescription: String? {
    switch self {
    case .approvalRequired:
      "Approve SBMHelper in System Settings, then return to SBM."
    case .registrationDidNotFinish:
      "macOS did not enable the background helper. Approve it in System Settings, then return to SBM."
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
    timeout: Duration = .seconds(3),
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
}
