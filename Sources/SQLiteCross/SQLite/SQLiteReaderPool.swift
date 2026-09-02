import Foundation

/// A fixed set of reader connections, lent one at a time.
///
/// Waiting for a reader suspends rather than blocks. That is the whole reason this is an actor and
/// not a lock around a free list: a pool sized to the machine's cores would otherwise be able to
/// occupy every cooperative thread with tasks that are merely queueing.
actor SQLiteReaderPool {
  private var idle: [SQLiteConnectionActor]
  private var waiters: [UUID: CheckedContinuation<SQLiteConnectionActor, any Error>] = [:]

  init(readers: [SQLiteConnectionActor]) {
    self.idle = readers
  }

  /// Lends a reader, waiting for one to come free when they are all busy.
  func acquire() async throws -> SQLiteConnectionActor {
    try Task.checkCancellation()
    if let reader = idle.popLast() {
      return reader
    }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters[id] = continuation
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  /// Takes a reader back, handing it straight to whoever is waiting for one.
  func release(_ reader: SQLiteConnectionActor) {
    guard let id = waiters.keys.first, let continuation = waiters.removeValue(forKey: id) else {
      idle.append(reader)
      return
    }
    continuation.resume(returning: reader)
  }

  private func cancelWaiter(_ id: UUID) {
    // A waiter that was handed a reader before its cancellation arrived is no longer here.
    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }
}
