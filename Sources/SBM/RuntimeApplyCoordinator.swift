import Foundation

enum RuntimeApplyStatus: Equatable, Sendable {
  case saved
  case applying
  case active
  case failed
}

@MainActor
final class RuntimeApplyCoordinator<Request: Sendable, Response: Sendable> {
  struct Outcome: Sendable {
    let generation: UInt64
    let isCurrent: Bool
    let result: Result<Response, any Error>
  }

  typealias Sender = @Sendable (Request) async throws -> Response
  typealias Completion = @MainActor (Outcome) -> Void

  private struct Pending {
    let generation: UInt64
    let request: Request
    let completion: Completion
  }

  private let sender: Sender
  private var desiredGeneration: UInt64 = 0
  private var pending: Pending?
  private var worker: Task<Void, Never>?

  private(set) var status: RuntimeApplyStatus = .saved

  var isApplying: Bool { worker != nil }
  var currentGeneration: UInt64 { desiredGeneration }

  init(sender: @escaping Sender) {
    self.sender = sender
  }

  func markSaved() {
    guard worker == nil else { return }
    status = .saved
  }

  @discardableResult
  func submit(_ request: Request, completion: @escaping Completion) -> UInt64 {
    desiredGeneration &+= 1
    let generation = desiredGeneration
    pending = Pending(generation: generation, request: request, completion: completion)
    status = .applying
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
      let result: Result<Response, any Error>
      do {
        result = .success(try await sender(current.request))
      } catch {
        result = .failure(error)
      }

      let isCurrent = current.generation == desiredGeneration
      if isCurrent {
        switch result {
        case .success:
          status = .active
        case .failure:
          status = .failed
        }
      }
      current.completion(
        Outcome(generation: current.generation, isCurrent: isCurrent, result: result)
      )
    }
    worker = nil
  }
}
