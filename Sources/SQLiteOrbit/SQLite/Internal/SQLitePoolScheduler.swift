#if canImport(Dispatch)
  import Dispatch
  private typealias PoolSemaphore = DispatchSemaphore
#elseif _runtime(_multithreaded)
  // The threaded WASI SDK has pthread conditions but no libdispatch.
  private final class PoolSemaphore: Sendable {
    private let signaled = ConditionLock(false)

    init(value: Int) {
      precondition(value == 0)
    }

    func signal() {
      signaled.withLock { $0 = true }
    }

    func wait() {
      signaled.withLock(until: { $0 }, { _, _ in })
    }
  }
#else
  private final class PoolSemaphore: Sendable {
    init(value: Int) {
      precondition(value == 0)
    }

    func signal() {}

    func wait() {}
  }
#endif

/// A finite snapshot of writers that were still active when another writer finished.
final class SQLitePoolWriterBarrier: OrbitDatabaseWriterBarrier {
  private struct State {
    var remainingWriters: Int
    var continuations: [CheckedContinuation<Void, Never>] = []
  }

  private let state: Lock<State>

  init(writerCount: Int) {
    state = Lock(State(remainingWriters: writerCount))
  }

  var hasActiveWriters: Bool {
    state.withLock { $0.remainingWriters > 0 }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let isFinished = state.withLock { state in
        guard state.remainingWriters > 0 else { return true }
        state.continuations.append(continuation)
        return false
      }
      if isFinished { continuation.resume() }
    }
  }

  func writerDidFinish() {
    let continuations = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      precondition(state.remainingWriters > 0)
      state.remainingWriters -= 1
      guard state.remainingWriters == 0 else { return [] }
      defer { state.continuations.removeAll() }
      return state.continuations
    }
    for continuation in continuations { continuation.resume() }
  }
}

/// Lends reader and writer connections to asynchronous tasks and blocking threads from one queue.
///
/// Writers are open from the start. Readers open on demand, up to a maximum: a read that finds no
/// idle reader while fewer are open is granted a slot and opens its reader outside the lock, so
/// that opening one holds up no other access.
///
/// ``releaseMemory()`` starts a new reader generation. A reader of an older generation, lent out
/// or still opening at the time, is closed rather than kept when its read ends.
final class SQLitePoolScheduler: Sendable {
  private enum Kind: Equatable, Sendable {
    case read
    case concurrentWrite
    case barrierWrite
  }

  private struct Lease: Sendable {
    let id: Int
    let kind: Kind
    // The reader generation a read was granted in. Placed next to `kind` to keep the lease small.
    let readerGeneration: UInt32
    let connection: SQLiteSerialConnection
    let blockingHolder: ThreadID?
  }

  private enum Grant: Sendable {
    case lease(Lease)
    /// Room for one more reader, which the read opens itself.
    case readerSlot(id: Int, readerGeneration: UInt32, blockingHolder: ThreadID?)
  }

  private struct State {
    let maximumReaders: Int
    var idleReaders: [SQLiteSerialConnection] = []
    // Every reader idle, lent out, or being opened, of any generation.
    var readerCount = 0
    var readerGeneration: UInt32 = 0
    var idleWriters: [SQLiteSerialConnection]
    var activeOrdinaryAccesses = 0
    var isBarrierWriteActive = false
    var waiting: [Waiter] = []
    var settled: [Int: Result<Grant, any Error>] = [:]
    var blockingHolders: [ThreadID] = []
    var activeWriterIDs: Set<Int> = []
    var writerBarriers: [Int: [SQLitePoolWriterBarrier]] = [:]
    var nextRequestID = 0

    mutating func claimRequestID() -> Int {
      nextRequestID += 1
      return nextRequestID
    }
  }

  private struct Waiter {
    let id: Int
    let kind: Kind
    let blockingHolder: ThreadID?
    var wake: Wake

    enum Wake {
      case blocking(PoolSemaphore)
      case asynchronous(CheckedContinuation<Grant, any Error>?)
    }
  }

  private struct Wakeup {
    let wake: Waiter.Wake
    let outcome: Result<Grant, any Error>

    func deliver() {
      switch wake {
      case .blocking(let semaphore): semaphore.signal()
      case .asynchronous(let continuation?): continuation.resume(with: outcome)
      case .asynchronous(nil): break
      }
    }
  }

  private let state: Lock<State>
  private let openReader: @Sendable () throws -> SQLiteSerialConnection
  /// Every writer, whether idle or lent out.
  let writers: [SQLiteSerialConnection]

  /// - Parameters:
  ///   - maximumReaders: The most readers open at once.
  ///   - openReader: Opens one reader, on the task or thread of the read that needs it.
  ///   - writers: The writers, already open.
  init(
    maximumReaders: Int,
    openReader: @escaping @Sendable () throws -> SQLiteSerialConnection,
    writers: [SQLiteSerialConnection]
  ) {
    precondition(maximumReaders > 0)
    precondition(!writers.isEmpty)
    self.state = Lock(State(maximumReaders: maximumReaders, idleWriters: writers))
    self.openReader = openReader
    self.writers = writers
  }

  /// How many readers are open, counting those being opened, and how many of them are idle.
  var readerCounts: (open: Int, idle: Int) {
    state.withLock { ($0.readerCount, $0.idleReaders.count) }
  }

  /// How many accesses are waiting for a connection.
  var waitingAccessCount: Int {
    state.withLock { $0.waiting.count }
  }

  // MARK: - Scoped access

  func readWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    let lease = try await acquire(.read)
    defer { release(lease) }
    return try await lease.connection.withReadConnection(body)
  }

  func writeWithoutTransaction<Result: Sendable>(
    concurrent: Bool = false,
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    let lease = try await acquire(concurrent ? .concurrentWrite : .barrierWrite)
    defer { release(lease) }
    return try await lease.connection.withWriteConnection(body)
  }

  func readWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    let lease = try acquireBlocking(.read)
    defer { release(lease) }
    return try lease.connection.withReadConnectionBlocking(body)
  }

  func writeWithoutTransactionBlocking<Result: Sendable>(
    concurrent: Bool = false,
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    let lease = try acquireBlocking(concurrent ? .concurrentWrite : .barrierWrite)
    defer { release(lease) }
    return try lease.connection.withWriteConnectionBlocking(body)
  }

  func captureActiveWriters() -> (any OrbitDatabaseWriterBarrier)? {
    state.withLock { state in
      guard !state.activeWriterIDs.isEmpty else { return nil }
      let barrier = SQLitePoolWriterBarrier(writerCount: state.activeWriterIDs.count)
      for writerID in state.activeWriterIDs {
        state.writerBarriers[writerID, default: []].append(barrier)
      }
      return barrier
    }
  }

  // MARK: - Acquiring

  private func acquire(_ kind: Kind) async throws -> Lease {
    try Task.checkCancellation()
    let request = join(kind, blockingHolder: nil)
    for wakeup in request.wakeups { wakeup.deliver() }
    let grant = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { install($0, for: request.id) }
    } onCancel: {
      cancel(request.id)
    }
    // A slot granted to a task cancelled since goes back rather than opening a reader for it.
    if case .readerSlot(_, _, let blockingHolder) = grant, Task.isCancelled {
      giveBackReaderSlot(blockingHolder: blockingHolder)
      throw CancellationError()
    }
    return try lease(for: grant)
  }

  private func acquireBlocking(_ kind: Kind) throws -> Lease {
    let semaphore = PoolSemaphore(value: 0)
    let request = join(kind, blockingHolder: .current, semaphore: semaphore)
    for wakeup in request.wakeups { wakeup.deliver() }
    semaphore.wait()
    let grant = state.withLock { state in
      guard case .success(let grant) = state.settled.removeValue(forKey: request.id) else {
        preconditionFailure("A blocking pool request was not settled by a grant.")
      }
      return grant
    }
    return try lease(for: grant)
  }

  /// Returns the lease granted, opening the reader of a read granted a slot. A reader that fails
  /// to open gives its slot back.
  private func lease(for grant: Grant) throws -> Lease {
    switch grant {
    case .lease(let lease):
      return lease
    case .readerSlot(let id, let readerGeneration, let blockingHolder):
      // The slot already counts against the maximum, so opening needs no lock.
      do {
        return Lease(
          id: id,
          kind: .read,
          readerGeneration: readerGeneration,
          connection: try openReader(),
          blockingHolder: blockingHolder
        )
      } catch {
        giveBackReaderSlot(blockingHolder: blockingHolder)
        throw error
      }
    }
  }

  private func join(
    _ kind: Kind,
    blockingHolder: ThreadID?,
    semaphore: PoolSemaphore? = nil
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
        state.blockingHolders.append(blockingHolder)
      }

      let id = state.claimRequestID()
      let wake: Waiter.Wake = semaphore.map { .blocking($0) } ?? .asynchronous(nil)
      state.waiting.append(
        Waiter(id: id, kind: kind, blockingHolder: blockingHolder, wake: wake)
      )
      return (id, Self.grant(&state))
    }
  }

  // MARK: - Releasing

  // A reader of an older generation is not kept: the caller's lease drops the last reference to it
  // after this returns, outside the lock.
  private func release(_ lease: Lease) {
    let released = state.withLock {
      state -> (wakeups: [Wakeup], barriers: [SQLitePoolWriterBarrier]) in
      var barriers: [SQLitePoolWriterBarrier] = []
      switch lease.kind {
      case .read:
        if lease.readerGeneration == state.readerGeneration {
          state.idleReaders.append(lease.connection)
        } else {
          state.readerCount -= 1
        }
        state.activeOrdinaryAccesses -= 1
      case .concurrentWrite:
        state.idleWriters.append(lease.connection)
        state.activeOrdinaryAccesses -= 1
      case .barrierWrite:
        state.idleWriters.append(lease.connection)
        state.isBarrierWriteActive = false
      }
      if lease.kind != .read {
        precondition(state.activeWriterIDs.remove(lease.id) != nil)
        barriers = state.writerBarriers.removeValue(forKey: lease.id) ?? []
      }
      if let blockingHolder = lease.blockingHolder {
        state.blockingHolders.removeAll { $0 == blockingHolder }
      }
      return (Self.grant(&state), barriers)
    }
    // The borrowing closure has completed, including any commit publication it performs.
    for barrier in released.barriers { barrier.writerDidFinish() }
    for wakeup in released.wakeups { wakeup.deliver() }
  }

  /// Ends a read that never opened the reader it was granted a slot for.
  private func giveBackReaderSlot(blockingHolder: ThreadID?) {
    let wakeups = state.withLock { state -> [Wakeup] in
      state.readerCount -= 1
      state.activeOrdinaryAccesses -= 1
      if let blockingHolder {
        state.blockingHolders.removeAll { $0 == blockingHolder }
      }
      return Self.grant(&state)
    }
    for wakeup in wakeups { wakeup.deliver() }
  }

  // MARK: - Releasing memory

  /// Closes the idle readers now and the others when their reads end, and releases the memory of
  /// every writer once its current access, if any, ends.
  func releaseMemory() async {
    // The idle readers are returned so that they close outside the lock. A read that waits while
    // readers are idle is queued behind a barrier write, so the freed slots grant nothing.
    _ = state.withLock { state in
      defer { state.idleReaders.removeAll() }
      state.readerCount -= state.idleReaders.count
      state.readerGeneration &+= 1
      return state.idleReaders
    }
    await withTaskGroup(of: Void.self) { group in
      for writer in writers {
        group.addTask { await writer.releaseMemory() }
      }
    }
  }

  // MARK: - Granting

  private static func grant(_ state: inout State) -> [Wakeup] {
    guard !state.isBarrierWriteActive else { return [] }
    var wakeups: [Wakeup] = []

    while true {
      // A barrier write is a fairness boundary: accesses behind it cannot keep it waiting.
      let boundary =
        state.waiting.firstIndex { $0.kind == .barrierWrite }
        ?? state.waiting.endIndex
      let grantable = state.waiting.indices.first { index in
        guard index < boundary else { return false }
        switch state.waiting[index].kind {
        case .read:
          return !state.idleReaders.isEmpty || state.readerCount < state.maximumReaders
        case .concurrentWrite: return !state.idleWriters.isEmpty
        case .barrierWrite: return false
        }
      }

      if let index = grantable {
        let waiter = state.waiting.remove(at: index)
        state.activeOrdinaryAccesses += 1
        if waiter.kind == .concurrentWrite {
          state.activeWriterIDs.insert(waiter.id)
          wakeups.append(lend(state.idleWriters.removeLast(), to: waiter, in: &state))
        } else if let reader = state.idleReaders.popLast() {
          wakeups.append(lend(reader, to: waiter, in: &state))
        } else {
          state.readerCount += 1
          let slot = Grant.readerSlot(
            id: waiter.id,
            readerGeneration: state.readerGeneration,
            blockingHolder: waiter.blockingHolder
          )
          wakeups.append(settle(&state, waiter, with: .success(slot)))
        }
        continue
      }

      guard
        state.waiting.first?.kind == .barrierWrite,
        state.activeOrdinaryAccesses == 0,
        let connection = state.idleWriters.popLast()
      else { break }

      let waiter = state.waiting.removeFirst()
      state.isBarrierWriteActive = true
      state.activeWriterIDs.insert(waiter.id)
      wakeups.append(lend(connection, to: waiter, in: &state))
      break
    }

    return wakeups
  }

  private static func lend(
    _ connection: SQLiteSerialConnection,
    to waiter: Waiter,
    in state: inout State
  ) -> Wakeup {
    let lease = Lease(
      id: waiter.id,
      kind: waiter.kind,
      readerGeneration: state.readerGeneration,
      connection: connection,
      blockingHolder: waiter.blockingHolder
    )
    return settle(&state, waiter, with: .success(.lease(lease)))
  }

  private static func settle(
    _ state: inout State,
    _ waiter: Waiter,
    with outcome: Result<Grant, any Error>
  ) -> Wakeup {
    switch waiter.wake {
    case .asynchronous(.some): break
    case .blocking, .asynchronous(.none): state.settled[waiter.id] = outcome
    }
    return Wakeup(wake: waiter.wake, outcome: outcome)
  }

  private func install(
    _ continuation: CheckedContinuation<Grant, any Error>,
    for id: Int
  ) {
    let settled = state.withLock { state -> Result<Grant, any Error>? in
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
    for wakeup in wakeups { wakeup.deliver() }
  }
}
