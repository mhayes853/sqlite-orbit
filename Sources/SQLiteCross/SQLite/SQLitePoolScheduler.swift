/// Decides which of a pool's accesses may run: any number of reads, or exactly one write.
///
/// Requests are granted in the order they arrive. A write waits for the reads already running,
/// and reads that arrive behind a queued write wait for it to commit, so a read issued after a
/// write observes that write. Waiting suspends rather than blocks, which is why this is an actor
/// and not a lock around a free list.
actor SQLitePoolScheduler {
  private enum Request {
    case read(CheckedContinuation<SQLiteConnection, any Error>)
    case write(CheckedContinuation<Void, any Error>)
  }

  /// Every reader the pool owns, minus the ones currently lent out.
  private var idleReaders: [SQLiteConnection]
  private let readerCount: Int
  private var isWriting = false
  private var waiting: [(id: Int, request: Request)] = []
  private var nextRequestID = 0

  init(readers: [SQLiteConnection]) {
    self.idleReaders = readers
    self.readerCount = readers.count
  }

  /// Whether any reader is lent out.
  private var hasActiveReaders: Bool {
    idleReaders.count < readerCount
  }

  /// Lends a reader once no write is running or queued ahead, and one is free.
  func acquireReader() async throws -> SQLiteConnection {
    try Task.checkCancellation()
    if waiting.isEmpty, !isWriting, let reader = idleReaders.popLast() {
      return reader
    }
    return try await wait { .read($0) }
  }

  func releaseReader(_ reader: SQLiteConnection) {
    idleReaders.append(reader)
    grant()
  }

  /// Waits until no read or write is running, then reserves the writer.
  func acquireWriter() async throws {
    try Task.checkCancellation()
    if waiting.isEmpty, !isWriting, !hasActiveReaders {
      isWriting = true
      return
    }
    try await wait { .write($0) }
  }

  func releaseWriter() {
    isWriting = false
    grant()
  }

  private func wait<Value>(
    _ request: (CheckedContinuation<Value, any Error>) -> Request
  ) async throws -> Value {
    nextRequestID += 1
    let id = nextRequestID
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiting.append((id, request(continuation)))
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  /// Grants requests from the head of the line for as long as they can run.
  private func grant() {
    while let next = waiting.first {
      switch next.request {
      case .read(let continuation):
        guard !isWriting, let reader = idleReaders.popLast() else { return }
        waiting.removeFirst()
        continuation.resume(returning: reader)
      case .write(let continuation):
        guard !isWriting, !hasActiveReaders else { return }
        isWriting = true
        waiting.removeFirst()
        continuation.resume()
      }
    }
  }

  private func cancel(_ id: Int) {
    // A request that was granted before its cancellation arrived is no longer here.
    guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
    switch waiting.remove(at: index).request {
    case .read(let continuation): continuation.resume(throwing: CancellationError())
    case .write(let continuation): continuation.resume(throwing: CancellationError())
    }
    // Whatever was queued behind the cancelled request may now be able to run.
    grant()
  }
}
