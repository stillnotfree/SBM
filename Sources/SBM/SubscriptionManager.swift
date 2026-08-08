import SBMShared

struct SubscriptionManager: Sendable {
  typealias FetchOperation =
    @Sendable (String, SubscriptionHeaders) async throws ->
    SubscriptionFetchResult

  private let fetchOperation: FetchOperation

  init(
    fetchOperation: @escaping FetchOperation = { value, headers in
      try await SubscriptionClient.fetch(from: value, headers: headers)
    }
  ) {
    self.fetchOperation = fetchOperation
  }

  func synchronize(_ source: ManagedSource) async throws -> SubscriptionFetchResult {
    try await fetchOperation(source.value, source.headers)
  }
}
