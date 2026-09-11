import Dispatch
import Foundation

/// Lends reader and writer connections to asynchronous tasks and blocking threads from one queue.
final class SQLitePoolScheduler: Sendable {
  private enum Kind: Equatable, Sendable {
    case read
    case write
    case exclusiveWrite
  }

  private struct Lease: Sendable {
    let kind: Kind
    let connection: SQLiteConnection
    let blockingHolder: ObjectIdentifier?
  }

  private struct State {
    var idleReaders: [SQLiteConnection]
    var idleWriters: [SQLiteConnection]
    var activeOrdinaryAccesses = 0
    var isExclusiveWriteActive = false
    var waiting: [Waiter] = []
    var settled: [Int: Result<Lease, any Error>] = [:]
    var blockingHolders: Set<ObjectIdentifier> = []
    var nextRequestID = 0

    mutating func claimRequestID() -> Int {
      nextRequestID += 1
      return nextRequestID
    }
  }

  private struct Waiter {
    let id: Int
    let kind: Kind
    let blockingHolder: ObjectIdentifier?
    var wake: Wake

    enum Wake {
      case blocking(DispatchSemaphore)
      case asynchronous(CheckedContinuation<Lease, any Error>?)
    }
  }

  private struct Wakeup {
    let wake: Waiter.Wake
    let outcome: Result<Lease, any Error>

    func deliver() {
      switch wake {
      case .blocking(let semaphore): semaphore.signal()
      case .asynchronous(let continuation?): continuation.resume(with: outcome)
      case .asynchronous(nil): break
      }
    }
  }

  private let state: Lock<State>

  init(readers: [SQLiteConnection], writers: [SQLiteConnection]) {
    precondition(!readers.isEmpty)
    precondition(!writers.isEmpty)
    self.state = Lock(State(idleReaders: readers, idleWriters: writers))
  }

  // MARK: - Scoped access

  func read<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    let lease = try await acquire(.read)
    defer { release(lease) }
    return try await lease.connection.read(observers: observers, body)
  }

  func write<Result: Sendable>(
    mode: SQLiteWriteTransactionMode = .immediate,
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    let lease = try await acquire(mode == .immediate ? .exclusiveWrite : .write)
    defer { release(lease) }
    return try await lease.connection.write(mode: mode, observers: observers, body)
  }

  func readBlocking<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    let lease = acquireBlocking(.read)
    defer { release(lease) }
    return try lease.connection.readBlocking(observers: observers, body)
  }

  func writeBlocking<Result: Sendable>(
    mode: SQLiteWriteTransactionMode = .immediate,
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    let lease = acquireBlocking(mode == .immediate ? .exclusiveWrite : .write)
    defer { release(lease) }
    return try lease.connection.writeBlocking(mode: mode, observers: observers, body)
  }

  // MARK: - Acquiring

  private func acquire(_ kind: Kind) async throws -> Lease {
    try Task.checkCancellation()
    let request = join(kind, blockingHolder: nil)
    request.wakeups.forEach { $0.deliver() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { install($0, for: request.id) }
    } onCancel: {
      cancel(request.id)
    }
  }

  private func acquireBlocking(_ kind: Kind) -> Lease {
    let semaphore = DispatchSemaphore(value: 0)
    let request = join(kind, blockingHolder: Self.currentThread, semaphore: semaphore)
    request.wakeups.forEach { $0.deliver() }
    semaphore.wait()
    return state.withLock { state in
      guard case .success(let lease) = state.settled.removeValue(forKey: request.id) else {
        preconditionFailure("A blocking pool request was not settled by a grant.")
      }
      return lease
    }
  }

  private func join(
    _ kind: Kind,
    blockingHolder: ObjectIdentifier?,
    semaphore: DispatchSemaphore? = nil
  ) -> (id: Int, wakeups: [Wakeup]) {
    state.withLock { state in
      if let blockingHolder {
        precondition(
          !state.blockingHolders.contains(blockingHolder),
          """
          A blocking database access cannot be nested inside another one on the same database: \
          the inner access may wait for a connection the outer access still holds. Use the \
          transaction already in hand rather than opening a second one.
          """
        )
        state.blockingHolders.insert(blockingHolder)
      }

      let id = state.claimRequestID()
      let wake: Waiter.Wake = semaphore.map { .blocking($0) } ?? .asynchronous(nil)
      state.waiting.append(
        Waiter(id: id, kind: kind, blockingHolder: blockingHolder, wake: wake)
      )
      return (id, Self.grant(&state))
    }
  }

  private static var currentThread: ObjectIdentifier {
    ObjectIdentifier(Thread.current)
  }

  // MARK: - Releasing

  private func release(_ lease: Lease) {
    let wakeups = state.withLock { state -> [Wakeup] in
      switch lease.kind {
      case .read:
        state.idleReaders.append(lease.connection)
        state.activeOrdinaryAccesses -= 1
      case .write:
        state.idleWriters.append(lease.connection)
        state.activeOrdinaryAccesses -= 1
      case .exclusiveWrite:
        state.idleWriters.append(lease.connection)
        state.isExclusiveWriteActive = false
      }
      if let blockingHolder = lease.blockingHolder {
        state.blockingHolders.remove(blockingHolder)
      }
      return Self.grant(&state)
    }
    wakeups.forEach { $0.deliver() }
  }

  // MARK: - Granting

  private static func grant(_ state: inout State) -> [Wakeup] {
    guard !state.isExclusiveWriteActive else { return [] }
    var wakeups: [Wakeup] = []

    while true {
      // An exclusive write is a fairness boundary: accesses behind it cannot keep it waiting.
      let boundary =
        state.waiting.firstIndex { $0.kind == .exclusiveWrite }
        ?? state.waiting.endIndex
      let grantable = state.waiting.indices.first { index in
        guard index < boundary else { return false }
        switch state.waiting[index].kind {
        case .read: return !state.idleReaders.isEmpty
        case .write: return !state.idleWriters.isEmpty
        case .exclusiveWrite: return false
        }
      }

      if let index = grantable {
        let waiter = state.waiting.remove(at: index)
        let connection =
          waiter.kind == .read
          ? state.idleReaders.removeLast()
          : state.idleWriters.removeLast()
        state.activeOrdinaryAccesses += 1
        wakeups.append(
          settle(
            &state,
            waiter,
            with: .success(
              Lease(
                kind: waiter.kind,
                connection: connection,
                blockingHolder: waiter.blockingHolder
              )
            )
          )
        )
        continue
      }

      guard
        state.waiting.first?.kind == .exclusiveWrite,
        state.activeOrdinaryAccesses == 0,
        let connection = state.idleWriters.popLast()
      else { break }

      let waiter = state.waiting.removeFirst()
      state.isExclusiveWriteActive = true
      wakeups.append(
        settle(
          &state,
          waiter,
          with: .success(
            Lease(
              kind: .exclusiveWrite,
              connection: connection,
              blockingHolder: waiter.blockingHolder
            )
          )
        )
      )
      break
    }

    return wakeups
  }

  private static func settle(
    _ state: inout State,
    _ waiter: Waiter,
    with outcome: Result<Lease, any Error>
  ) -> Wakeup {
    switch waiter.wake {
    case .asynchronous(.some): break
    case .blocking, .asynchronous(.none): state.settled[waiter.id] = outcome
    }
    return Wakeup(wake: waiter.wake, outcome: outcome)
  }

  private func install(
    _ continuation: CheckedContinuation<Lease, any Error>,
    for id: Int
  ) {
    let settled = state.withLock { state -> Result<Lease, any Error>? in
      if let outcome = state.settled.removeValue(forKey: id) { return outcome }
      if let index = state.waiting.firstIndex(where: { $0.id == id }) {
        state.waiting[index].wake = .asynchronous(continuation)
      }
      return nil
    }
    if let settled { continuation.resume(with: settled) }
  }

  private func cancel(_ id: Int) {
    let wakeups = state.withLock { state -> [Wakeup] in
      guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return [] }
      let waiter = state.waiting.remove(at: index)
      return [Self.settle(&state, waiter, with: .failure(CancellationError()))]
        + Self.grant(&state)
    }
    wakeups.forEach { $0.deliver() }
  }
}
