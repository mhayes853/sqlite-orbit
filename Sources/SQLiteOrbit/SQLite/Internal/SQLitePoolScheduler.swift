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
/// Writers are opened by the pool before the scheduler exists. Readers are opened on demand, up to
/// a maximum: a read that finds no idle reader while fewer than the maximum are open is granted a
/// slot rather than a connection, and opens its reader itself, outside the lock, so that opening
/// one never holds up the accesses that can proceed meanwhile.
///
/// Every reader belongs to a generation. ``closeReaders()`` closes the idle ones and starts a new
/// generation, and a reader of an older generation, lent out or still opening at the time, is
/// closed rather than kept when its read ends.
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
    // `nil` for a read granted a reader slot rather than a reader: the read opens its reader.
    let connection: SQLiteSerialConnection?
    let blockingHolder: ThreadID?
  }

  private struct State {
    let maximumReaders: Int
    var idleReaders: [SQLiteSerialConnection] = []
    // Every reader that is idle, lent out, or being opened, including those of older generations
    // that have yet to be returned, so that no more than `maximumReaders` are ever open.
    var readerCount = 0
    var readerGeneration: UInt32 = 0
    var idleWriters: [SQLiteSerialConnection]
    var activeOrdinaryAccesses = 0
    var isBarrierWriteActive = false
    var waiting: [Waiter] = []
    var settled: [Int: Result<Lease, any Error>] = [:]
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
  private let openReader: @Sendable () throws -> SQLiteSerialConnection
  /// Every writer, whether idle or lent out.
  let writers: [SQLiteSerialConnection]

  /// - Parameters:
  ///   - maximumReaders: The most readers open at once.
  ///   - openReader: Opens and configures one reader. It is called without the scheduler's lock,
  ///     on the task or thread of the read that needs the reader.
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

  /// How many readers are open, counting those being opened and those of older generations still
  /// lent out, and how many of them are idle.
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
    return try await lease.connection.unsafelyUnwrapped.withReadConnection(body)
  }

  func writeWithoutTransaction<Result: Sendable>(
    concurrent: Bool = false,
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    let lease = try await acquire(concurrent ? .concurrentWrite : .barrierWrite)
    defer { release(lease) }
    return try await lease.connection.unsafelyUnwrapped.withWriteConnection(body)
  }

  func readWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    let lease = try acquireBlocking(.read)
    defer { release(lease) }
    return try lease.connection.unsafelyUnwrapped.withReadConnectionBlocking(body)
  }

  func writeWithoutTransactionBlocking<Result: Sendable>(
    concurrent: Bool = false,
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    let lease = try acquireBlocking(concurrent ? .concurrentWrite : .barrierWrite)
    defer { release(lease) }
    return try lease.connection.unsafelyUnwrapped.withWriteConnectionBlocking(body)
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
    let lease = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { install($0, for: request.id) }
    } onCancel: {
      cancel(request.id)
    }
    guard lease.connection != nil else {
      // A slot granted to a task cancelled since goes back rather than opening a reader for it.
      if Task.isCancelled {
        abandon(lease)
        throw CancellationError()
      }
      return try fillSlot(lease)
    }
    return lease
  }

  private func acquireBlocking(_ kind: Kind) throws -> Lease {
    let semaphore = PoolSemaphore(value: 0)
    let request = join(kind, blockingHolder: .current, semaphore: semaphore)
    for wakeup in request.wakeups { wakeup.deliver() }
    semaphore.wait()
    let lease = state.withLock { state in
      guard case .success(let lease) = state.settled.removeValue(forKey: request.id) else {
        preconditionFailure("A blocking pool request was not settled by a grant.")
      }
      return lease
    }
    return lease.connection == nil ? try fillSlot(lease) : lease
  }

  /// Opens the reader for a read granted a slot, or gives the slot back and throws why it could
  /// not be opened.
  ///
  /// The slot already counts against the maximum, so opening needs no lock. A reader opened for a
  /// generation that has since been closed serves this read and is closed when it ends.
  private func fillSlot(_ slot: Lease) throws -> Lease {
    let reader: SQLiteSerialConnection
    do {
      reader = try openReader()
    } catch {
      abandon(slot)
      throw error
    }
    return Lease(
      id: slot.id,
      kind: slot.kind,
      readerGeneration: slot.readerGeneration,
      connection: reader,
      blockingHolder: slot.blockingHolder
    )
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

  // A reader of an older generation is not kept, and the last reference to it goes with the
  // caller's lease, after this returns and so outside the lock and off the reader's own executor.
  private func release(_ lease: Lease) {
    let released = state.withLock {
      state -> (wakeups: [Wakeup], barriers: [SQLitePoolWriterBarrier]) in
      var barriers: [SQLitePoolWriterBarrier] = []
      switch lease.kind {
      case .read:
        if lease.readerGeneration == state.readerGeneration {
          state.idleReaders.append(lease.connection.unsafelyUnwrapped)
        } else {
          state.readerCount -= 1
        }
        state.activeOrdinaryAccesses -= 1
      case .concurrentWrite:
        state.idleWriters.append(lease.connection.unsafelyUnwrapped)
        state.activeOrdinaryAccesses -= 1
      case .barrierWrite:
        state.idleWriters.append(lease.connection.unsafelyUnwrapped)
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

  /// Gives back the slot of a read that never opened its reader, ending the read.
  private func abandon(_ slot: Lease) {
    let wakeups = state.withLock { state -> [Wakeup] in
      state.readerCount -= 1
      state.activeOrdinaryAccesses -= 1
      if let blockingHolder = slot.blockingHolder {
        state.blockingHolders.removeAll { $0 == blockingHolder }
      }
      return Self.grant(&state)
    }
    for wakeup in wakeups { wakeup.deliver() }
  }

  // MARK: - Closing readers

  /// Closes the idle readers, and every reader lent out or being opened now once its read ends.
  ///
  /// Reads after this open readers again as they need them. The idle readers close on the calling
  /// thread, after the lock is released.
  func closeReaders() {
    let (closed, wakeups) = state.withLock { state in
      let closed = state.idleReaders
      state.idleReaders.removeAll()
      state.readerCount -= closed.count
      state.readerGeneration &+= 1
      // Nothing waits on an idle reader, but the freed slots are offered all the same.
      return (closed, Self.grant(&state))
    }
    for wakeup in wakeups { wakeup.deliver() }
    withExtendedLifetime(closed) {}
  }

  /// Closes the readers as ``closeReaders()`` does, and releases the memory of every writer once
  /// its current access, if any, ends.
  func releaseMemory() async {
    closeReaders()
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
        let connection: SQLiteSerialConnection?
        if waiter.kind == .read {
          connection = state.idleReaders.popLast()
          // No idle reader: the read is granted a slot and opens a reader in it.
          if connection == nil { state.readerCount += 1 }
        } else {
          connection = state.idleWriters.removeLast()
        }
        state.activeOrdinaryAccesses += 1
        if waiter.kind == .concurrentWrite {
          state.activeWriterIDs.insert(waiter.id)
        }
        wakeups.append(lend(connection, to: waiter, in: &state))
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
    _ connection: SQLiteSerialConnection?,
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
    return settle(&state, waiter, with: .success(lease))
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
    for wakeup in wakeups { wakeup.deliver() }
  }
}
