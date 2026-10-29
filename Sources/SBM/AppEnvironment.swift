import Foundation
import SBMShared

enum AppEnvironmentKind: Equatable, Sendable {
  case production
  case hermetic
}

enum AppEnvironmentFailure: LocalizedError, Equatable {
  case liveRuntimeUnavailable
  case networkUnavailable

  var errorDescription: String? {
    switch self {
    case .liveRuntimeUnavailable:
      "The hermetic test environment has no live helper or runtime transport."
    case .networkUnavailable:
      "The hermetic test environment has no network transport."
    }
  }
}

@MainActor
struct AppEnvironment {
  let kind: AppEnvironmentKind
  let helperService: any HelperServiceManaging
  let subscriptionManager: SubscriptionManager
  let helperLifecycleSender: @Sendable (HelperRequest, Int) async throws -> HelperResponse
  let helperApprovalPollDuration: Duration
  let helperApprovalPollInterval: Duration
  let applicationBundleURL: URL
  let runtimeSender: @Sendable (HelperRequest) async throws -> HelperResponse
  let helperRequestSender: @Sendable (HelperRequest) async throws -> HelperResponse
  let profileValidator: @Sendable (CoreProfile) async throws -> HelperResponse
  let profileLibraryLoader: () throws -> ProfileLibrary?
  let profileLibrarySaver: (ProfileLibrary) throws -> Void
  let runtimeStateReader: @Sendable () async throws -> HelperResponse
  let latencySender: @Sendable (ProxyNodeID?) async throws -> HelperResponse
  let latencySettleDelay: Duration

  static var production: AppEnvironment {
    AppEnvironment(
      kind: .production,
      helperService: SystemHelperService(),
      subscriptionManager: SubscriptionManager(),
      helperLifecycleSender: { request, timeout in
        try await Task.detached {
          try HelperClient.send(request, receiveTimeoutSeconds: timeout)
        }.value
      },
      helperApprovalPollDuration: .seconds(60),
      helperApprovalPollInterval: .milliseconds(500),
      applicationBundleURL: Bundle.main.bundleURL,
      runtimeSender: { request in
        try await Task.detached {
          try HelperClient.send(
            request,
            receiveTimeoutSeconds: HelperClient.runtimeMutationReceiveTimeoutSeconds
          )
        }.value
      },
      helperRequestSender: { request in
        try await Task.detached {
          try HelperClient.send(request)
        }.value
      },
      profileValidator: { profile in
        try await Task.detached {
          try HelperClient.send(HelperRequest(action: .validateProfile, profile: profile))
        }.value
      },
      profileLibraryLoader: {
        try ProfileStore.loadProfileLibrary()
      },
      profileLibrarySaver: {
        try ProfileStore.saveProfileLibrary($0)
      },
      runtimeStateReader: {
        try await Task.detached {
          try HelperClient.send(HelperRequest(action: .status))
        }.value
      },
      latencySender: { node in
        try await Task.detached {
          try HelperClient.send(
            HelperRequest(action: .testLatency, node: node),
            receiveTimeoutSeconds: 2
          )
        }.value
      },
      latencySettleDelay: .milliseconds(5_400)
    )
  }

  static func hermetic() -> AppEnvironment {
    let helperService = HermeticHelperService()
    let unavailableRequest: @Sendable (HelperRequest) async throws -> HelperResponse = { _ in
      throw AppEnvironmentFailure.liveRuntimeUnavailable
    }
    let unavailableLifecycle: @Sendable (HelperRequest, Int) async throws -> HelperResponse = {
      _, _ in
      throw AppEnvironmentFailure.liveRuntimeUnavailable
    }
    return AppEnvironment(
      kind: .hermetic,
      helperService: helperService,
      subscriptionManager: SubscriptionManager { _, _ in
        throw AppEnvironmentFailure.networkUnavailable
      },
      helperLifecycleSender: unavailableLifecycle,
      helperApprovalPollDuration: .milliseconds(100),
      helperApprovalPollInterval: .milliseconds(10),
      applicationBundleURL: URL(fileURLWithPath: "/private/tmp/SBMTests/SBM.app"),
      runtimeSender: unavailableRequest,
      helperRequestSender: unavailableRequest,
      profileValidator: { _ in
        throw AppEnvironmentFailure.liveRuntimeUnavailable
      },
      profileLibraryLoader: { .empty },
      profileLibrarySaver: { _ in },
      runtimeStateReader: {
        throw AppEnvironmentFailure.liveRuntimeUnavailable
      },
      latencySender: { _ in
        throw AppEnvironmentFailure.liveRuntimeUnavailable
      },
      latencySettleDelay: .zero
    )
  }
}

@MainActor
private final class HermeticHelperService: HelperServiceManaging {
  var registrationState: HelperRegistrationState { .notRegistered }
  var legacyRegistrationState: HelperRegistrationState { .notRegistered }

  func register() throws {}

  func unregister() async throws {}
  func unregisterLegacy() async throws {}

  func openSystemSettings() {}
}
