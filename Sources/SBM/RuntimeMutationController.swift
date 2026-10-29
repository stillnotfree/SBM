import Foundation
import SBMShared

enum RuntimeMutationControllerFailure: LocalizedError, Sendable {
  case superseded

  var errorDescription: String? {
    SBMText.localized("The runtime change was superseded by a newer request.")
  }
}

@MainActor
final class RuntimeMutationController {
  struct Outcome: Sendable {
    let generation: UInt64
    let isCurrent: Bool
    let result: Result<HelperResponse, any Error>
  }

  typealias Sender = @Sendable (HelperRequest) async throws -> HelperResponse
  typealias Completion = @MainActor (Outcome) -> Void

  private struct Pending {
    let generation: UInt64
    let request: HelperRequest
    let completion: Completion
  }

  private let sender: Sender
  private var desiredGeneration: UInt64 = 0
  private var pending: Pending?
  private var worker: Task<Void, Never>?

  /// `nil` means startup has not adopted helper state or received explicit intent.
  /// Explicit Disconnect is stored as `false`.
  var desiredRunning: Bool?

  var isApplying: Bool { worker != nil }
  var currentGeneration: UInt64 { desiredGeneration }

  func drainAcceptedWork() async {
    if let worker { await worker.value }
  }

  init(sender: @escaping Sender) {
    self.sender = sender
  }

  @discardableResult
  func submit(_ request: HelperRequest, completion: @escaping Completion) -> UInt64 {
    desiredGeneration &+= 1
    let generation = desiredGeneration
    let superseded = pending
    pending = Pending(generation: generation, request: request, completion: completion)
    if let superseded {
      superseded.completion(
        Outcome(
          generation: superseded.generation,
          isCurrent: false,
          result: .failure(RuntimeMutationControllerFailure.superseded)
        )
      )
    }
    startWorkerIfNeeded()
    return generation
  }

  private func startWorkerIfNeeded() {
    guard worker == nil else { return }
    worker = Task { [weak self] in
      await self?.drain()
    }
  }

  private func drain() async {
    while let current = pending {
      pending = nil
      let result: Result<HelperResponse, any Error>
      do {
        result = .success(try await sender(current.request))
      } catch {
        result = .failure(error)
      }

      let isCurrent = current.generation == desiredGeneration
      current.completion(
        Outcome(generation: current.generation, isCurrent: isCurrent, result: result)
      )
    }
    worker = nil
  }
}
