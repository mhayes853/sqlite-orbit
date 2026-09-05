import Dispatch
import Foundation

/// Decides which of a pool's accesses may run: any number of reads, or exactly one write.
///
/// Requests are granted in the order they arrive. A write waits for the reads already running,
/// and reads that arrive behind a queued write wait for it to commit, so a read issued after a
/// write observes that write.
///
/// Waiters come in two kinds. An asynchronous caller suspends on a continuation; a blocking caller
/// parks on a semaphore. Both stand in one arrival-ordered line, which is why this is a lock and
/// not an actor: a blocking caller has no way to await an actor, and giving the two kinds separate
/// lines would lose the ordering guarantee between them.
final class SQLitePoolScheduler: Sendable {
  /// Every mutable field lives here rather than in the waiters, so that holding this one lock is
  /// the whole of the scheduler's synchronization.
  private let state: Lock<State>

  init(readers: [SQLiteConnection]) {
    self.state = Lock(State(idleReaders: readers, readerCount: readers.count))
  }

  private struct State {
    var idleReaders: [SQLiteConnection]
    let readerCount: Int
    var isWriting = false
    var waiting: [Waiter] = []

    /// Outcomes for requests granted before their caller was ready to receive them.
    var settled: [Int: Result<SQLiteConnection?, any Error>] = [:]

    /// The threads currently inside a blocking access, so that a nested one can be reported.
    var blockingHolders: Set<ObjectIdentifier> = []

    var nextRequestID = 0

    /// Whether any reader is lent out.
    var hasActiveReaders: Bool { idleReaders.count < readerCount }

    mutating func claimRequestID() -> Int {
      nextRequestID += 1
      return nextRequestID
    }
  }

  /// One caller's place in line, and how to wake it once its request is granted.
  private struct Waiter {
    let id: Int
    let isRead: Bool
    var wake: Wake

    enum Wake {
      /// A blocking caller, parked on a semaphore of its own.
      case blocking(DispatchSemaphore)
      /// An asynchronous caller, whose continuation may not have been installed yet.
      case asynchronous(CheckedContinuation<SQLiteConnection?, any Error>?)
    }
  }

  /// A grant decided under the lock and delivered once it has been released.
  ///
  /// Neither signalling a semaphore nor resuming a continuation runs caller code on this thread,
  /// so waking under the lock would be safe here. It is done outside anyway: nothing about this
  /// scheduler should depend on that staying true of code it wakes.
  private struct Wakeup {
    let wake: Waiter.Wake
    let outcome: Result<SQLiteConnection?, any Error>

    func deliver() {
      switch wake {
      case .blocking(let semaphore): semaphore.signal()
      case .asynchronous(let continuation?): continuation.resume(with: outcome)
      case .asynchronous(nil): break  // `install` collects this one itself.
      }
    }
  }

  private enum Admission {
    /// The request ran straight through, holding the reader it was lent or the writer it reserved.
    case granted(SQLiteConnection?)
    case queued(id: Int, semaphore: DispatchSemaphore?)
  }

  // MARK: - Acquiring

  /// Lends a reader once no write is running or queued ahead, and one is free.
  func acquireReader() async throws -> SQLiteConnection {
    try Task.checkCancellation()
    switch join(isRead: true, isBlocking: false) {
    case .granted(let reader): return reader!
    case .queued(let id, _): return try await suspend(untilGranted: id)!
    }
  }

  /// Waits until no read or write is running, then reserves the writer.
  func acquireWriter() async throws {
    try Task.checkCancellation()
    guard case .queued(let id, _) = join(isRead: false, isBlocking: false) else { return }
    _ = try await suspend(untilGranted: id)
  }

  /// Lends a reader on the calling thread, blocking it until the request is granted.
  func acquireReaderBlocking() -> SQLiteConnection {
    switch join(isRead: true, isBlocking: true) {
    case .granted(let reader): reader!
    case .queued(let id, let semaphore): park(on: semaphore!, until: id)!
    }
  }

  /// Reserves the writer on the calling thread, blocking it until the request is granted.
  func acquireWriterBlocking() {
    if case .queued(let id, let semaphore) = join(isRead: false, isBlocking: true) {
      _ = park(on: semaphore!, until: id)
    }
  }

  /// Joins the line, or reports that the request could run without waiting at all.
  ///
  /// Deciding and joining happen in one lock hold, so a request cannot be overtaken between
  /// finding the line empty and standing in it. That is what keeps arrival order honest.
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

  private func suspend(untilGranted id: Int) async throws -> SQLiteConnection? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        install(continuation, for: id)
      }
    } onCancel: {
      cancel(id)
    }
  }

  private func park(on semaphore: DispatchSemaphore, until id: Int) -> SQLiteConnection? {
    semaphore.wait()
    return state.withLock { state in
      // A blocking request carries no task, so a grant is the only thing that can settle it.
      guard case .success(let reader) = state.settled.removeValue(forKey: id) else {
        preconditionFailure("A blocking pool request was settled by something other than a grant.")
      }
      return reader
    }
  }

  /// The identity of the calling thread, used only to report a nested blocking access.
  private static var currentThread: ObjectIdentifier {
    ObjectIdentifier(Thread.current)
  }

  // MARK: - Releasing

  func releaseReader(_ reader: SQLiteConnection) {
    release(.reader(reader), blockingHolder: nil)
  }

  func releaseReaderBlocking(_ reader: SQLiteConnection) {
    release(.reader(reader), blockingHolder: Self.currentThread)
  }

  func releaseWriter() {
    release(.writer, blockingHolder: nil)
  }

  func releaseWriterBlocking() {
    release(.writer, blockingHolder: Self.currentThread)
  }

  private enum Released {
    case reader(SQLiteConnection)
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

  /// Grants requests from the head of the line for as long as they can run.
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

  /// Settles a request, leaving the waking to be done once the lock is released.
  private static func settle(
    _ state: inout State,
    _ waiter: Waiter,
    with outcome: Result<SQLiteConnection?, any Error>
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
    _ continuation: CheckedContinuation<SQLiteConnection?, any Error>,
    for id: Int
  ) {
    let granted = state.withLock { state -> Result<SQLiteConnection?, any Error>? in
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
