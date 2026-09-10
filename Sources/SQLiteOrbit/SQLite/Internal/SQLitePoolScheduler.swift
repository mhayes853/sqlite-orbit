import Dispatch
import Foundation

final class SQLitePoolScheduler: Sendable {
  private let state: Lock<State>

  init(readers: [SQLiteSerialConnection]) {
    self.state = Lock(State(idleReaders: readers, readerCount: readers.count))
  }

  private struct State {
    var idleReaders: [SQLiteSerialConnection]
    let readerCount: Int
    var isWriting = false
    var waiting: [Waiter] = []

    var settled: [Int: Result<SQLiteSerialConnection?, any Error>] = [:]

    var blockingHolders: Set<ObjectIdentifier> = []

    var nextRequestID = 0

    var hasActiveReaders: Bool { idleReaders.count < readerCount }

    mutating func claimRequestID() -> Int {
      nextRequestID += 1
      return nextRequestID
    }
  }

  private struct Waiter {
    let id: Int
    let isRead: Bool
    var wake: Wake

    enum Wake {
      case blocking(DispatchSemaphore)
      case asynchronous(CheckedContinuation<SQLiteSerialConnection?, any Error>?)
    }
  }

  private struct Wakeup {
    let wake: Waiter.Wake
    let outcome: Result<SQLiteSerialConnection?, any Error>

    func deliver() {
      switch wake {
      case .blocking(let semaphore): semaphore.signal()
      case .asynchronous(let continuation?): continuation.resume(with: outcome)
      case .asynchronous(nil): break  // `install` collects this one itself.
      }
    }
  }

  private enum Admission {
    case granted(SQLiteSerialConnection?)
    case queued(id: Int, semaphore: DispatchSemaphore?)
  }

  // MARK: - Acquiring

  func acquireReader() async throws -> SQLiteSerialConnection {
    try Task.checkCancellation()
    switch join(isRead: true, isBlocking: false) {
    case .granted(let reader): return reader!
    case .queued(let id, _): return try await suspend(untilGranted: id)!
    }
  }

  func acquireWriter() async throws {
    try Task.checkCancellation()
    guard case .queued(let id, _) = join(isRead: false, isBlocking: false) else { return }
    _ = try await suspend(untilGranted: id)
  }

  func acquireReaderBlocking() -> SQLiteSerialConnection {
    switch join(isRead: true, isBlocking: true) {
    case .granted(let reader): reader!
    case .queued(let id, let semaphore): park(on: semaphore!, until: id)!
    }
  }

  func acquireWriterBlocking() {
    if case .queued(let id, let semaphore) = join(isRead: false, isBlocking: true) {
      _ = park(on: semaphore!, until: id)
    }
  }

  private func join(isRead: Bool, isBlocking: Bool) -> Admission {
    let holder = isBlocking ? Self.currentThread : nil
    return state.withLock { state in
      if let holder {
        precondition(
          !state.blockingHolders.contains(holder),
          """
          A blocking database access cannot be nested inside another one on the same database: \
          the inner access waits for a connection the outer access still holds, so neither can \
          ever finish. Use the transaction already in hand rather than opening a second one.
          """
        )
        state.blockingHolders.insert(holder)
      }
      if state.waiting.isEmpty, !state.isWriting {
        if isRead {
          if let reader = state.idleReaders.popLast() { return .granted(reader) }
        } else if !state.hasActiveReaders {
          state.isWriting = true
          return .granted(nil)
        }
      }
      let semaphore = isBlocking ? DispatchSemaphore(value: 0) : nil
      let id = state.claimRequestID()
      let wake: Waiter.Wake = semaphore.map { .blocking($0) } ?? .asynchronous(nil)
      state.waiting.append(Waiter(id: id, isRead: isRead, wake: wake))
      return .queued(id: id, semaphore: semaphore)
    }
  }

  private func suspend(untilGranted id: Int) async throws -> SQLiteSerialConnection? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        install(continuation, for: id)
      }
    } onCancel: {
      cancel(id)
    }
  }

  private func park(on semaphore: DispatchSemaphore, until id: Int) -> SQLiteSerialConnection? {
    semaphore.wait()
    return state.withLock { state in
      // A blocking request carries no task, so a grant is the only thing that can settle it.
      guard case .success(let reader) = state.settled.removeValue(forKey: id) else {
        preconditionFailure("A blocking pool request was settled by something other than a grant.")
      }
      return reader
    }
  }

  private static var currentThread: ObjectIdentifier {
    ObjectIdentifier(Thread.current)
  }

  // MARK: - Releasing

  func releaseReader(_ reader: SQLiteSerialConnection) {
    release(.reader(reader), blockingHolder: nil)
  }

  func releaseReaderBlocking(_ reader: SQLiteSerialConnection) {
    release(.reader(reader), blockingHolder: Self.currentThread)
  }

  func releaseWriter() {
    release(.writer, blockingHolder: nil)
  }

  func releaseWriterBlocking() {
    release(.writer, blockingHolder: Self.currentThread)
  }

  private enum Released {
    case reader(SQLiteSerialConnection)
    case writer
  }

  private func release(_ released: Released, blockingHolder: ObjectIdentifier?) {
    let wakeups = state.withLock { state -> [Wakeup] in
      switch released {
      case .reader(let reader): state.idleReaders.append(reader)
      case .writer: state.isWriting = false
      }
      if let blockingHolder { state.blockingHolders.remove(blockingHolder) }
      return Self.grant(&state)
    }
    for wakeup in wakeups { wakeup.deliver() }
  }

  // MARK: - Granting

  private static func grant(_ state: inout State) -> [Wakeup] {
    var wakeups: [Wakeup] = []
    while let next = state.waiting.first {
      if next.isRead {
        guard !state.isWriting, let reader = state.idleReaders.popLast() else { break }
        state.waiting.removeFirst()
        wakeups.append(settle(&state, next, with: .success(reader)))
      } else {
        guard !state.isWriting, !state.hasActiveReaders else { break }
        state.isWriting = true
        state.waiting.removeFirst()
        wakeups.append(settle(&state, next, with: .success(nil)))
      }
    }
    return wakeups
  }

  private static func settle(
    _ state: inout State,
    _ waiter: Waiter,
    with outcome: Result<SQLiteSerialConnection?, any Error>
  ) -> Wakeup {
    switch waiter.wake {
    case .asynchronous(.some):
      break  // Resumed with the outcome directly.
    case .blocking, .asynchronous(.none):
      // A blocking caller reads this after its semaphore is signalled. An asynchronous one whose
      // grant arrived before its continuation did finds it here when it installs.
      state.settled[waiter.id] = outcome
    }
    return Wakeup(wake: waiter.wake, outcome: outcome)
  }

  private func install(
    _ continuation: CheckedContinuation<SQLiteSerialConnection?, any Error>,
    for id: Int
  ) {
    let granted = state.withLock { state -> Result<SQLiteSerialConnection?, any Error>? in
      if let outcome = state.settled.removeValue(forKey: id) { return outcome }
      if let index = state.waiting.firstIndex(where: { $0.id == id }) {
        state.waiting[index].wake = .asynchronous(continuation)
      }
      return nil
    }
    if let granted { continuation.resume(with: granted) }
  }

  private func cancel(_ id: Int) {
    let wakeups = state.withLock { state -> [Wakeup] in
      // A request that was granted before its cancellation arrived is no longer here.
      guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return [] }
      let waiter = state.waiting.remove(at: index)
      // Whatever was queued behind the cancelled request may now be able to run.
      return [Self.settle(&state, waiter, with: .failure(CancellationError()))]
        + Self.grant(&state)
    }
    for wakeup in wakeups { wakeup.deliver() }
  }
}
