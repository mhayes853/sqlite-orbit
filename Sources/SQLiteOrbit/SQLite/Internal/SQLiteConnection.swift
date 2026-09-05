import Dispatch

actor SQLiteConnection {
  private let handle: SQLiteHandle
  private let executor: SQLiteConnectionExecutor
  private let interrupt: @Sendable () -> Void

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }

  init(path: OrbitDatabasePath, flags: SQLiteOpenFlags, configuration: SQLiteConfiguration) throws {
    let handle = try SQLiteHandle.open(path: path, flags: flags, configuration: configuration)
    // The connection is captured as an address rather than a pointer, which is what lets this
    // closure be shared without an unchecked conformance on `OpaquePointer`. It stays valid
    // because the closure and the handle are released together.
    let address = UInt(bitPattern: handle.pointer)
    let entryPoint = handle.library.pointee.interrupt
    self.interrupt = { entryPoint(OpaquePointer(bitPattern: address)) }
    self.executor = SQLiteConnectionExecutor(path: path)
    self.handle = handle
  }

  func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    try await perform { handle in try handle.read(body) }
  }

  func write<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    try await perform { handle in try handle.write(observers: observers, body) }
  }

  nonisolated func readBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try performBlocking { handle in try handle.read(body) }
  }

  nonisolated func writeBlocking<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try performBlocking { handle in try handle.write(observers: observers, body) }
  }

  private nonisolated func performBlocking<Result: Sendable>(
    _ work: sending (borrowing SQLiteHandle) throws -> Result
  ) throws -> Result {
    nonisolated(unsafe) let work = work
    return try executor.sync {
      try self.assumeIsolated { connection in
        try work(connection.handle)
      }
    }
  }

  private func perform<Result: Sendable>(
    _ work: sending (borrowing SQLiteHandle) throws -> Result
  ) async throws -> Result {
    let token = SQLiteInterruptToken()
    do {
      return try await withTaskCancellationHandler {
        token.arm(interrupt)
        defer { token.disarm() }
        // A task may have been cancelled while waiting to enter the actor.
        try Task.checkCancellation()
        return try work(handle)
      } onCancel: {
        token.fire()
      }
    } catch let error as SQLiteError where error.primaryCode == .interrupt {
      throw CancellationError()
    }
  }
}

final class SQLiteConnectionExecutor: SerialExecutor {
  private let queue: DispatchQueue

  private static let owner = DispatchSpecificKey<ObjectIdentifier>()

  init(path: OrbitDatabasePath) {
    // The queue is labelled with the database it serves, because a stack of blocked threads is
    // most of what a hang report of this package will show.
    self.queue = DispatchQueue(
      label: "SQLiteOrbit.connection(\(path))",
      autoreleaseFrequency: .workItem
    )
    queue.setSpecific(key: Self.owner, value: ObjectIdentifier(self))
  }

  func sync<Result>(_ body: () throws -> Result) rethrows -> Result {
    precondition(
      DispatchQueue.getSpecific(key: Self.owner) != ObjectIdentifier(self),
      """
      A blocking database access cannot be nested inside another one on the same connection: \
      the inner access would wait for the outer one to release a connection it still holds. \
      Use the transaction already in hand rather than opening a second one.
      """
    )
    return try queue.sync(execute: body)
  }

  func enqueue(_ job: consuming ExecutorJob) {
    // The job's priority is handed to dispatch rather than dropped. Without it every query would
    // run at the queue's own QoS, so a read a user is waiting on would be served no sooner than a
    // background one, and the thread running it would not be raised to match. Dispatch also
    // resolves the inversion this leaves behind: a high-priority block enqueued behind a
    // low-priority one raises the queue until it drains.
    let qos = Self.dispatchQoS(for: job.priority)
    let job = UnownedJob(job)
    queue.async(qos: qos) {
      job.runSynchronously(on: self.asUnownedSerialExecutor())
    }
  }

  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }

  func checkIsolated() {
    dispatchPrecondition(condition: .onQueue(queue))
  }

  private static func dispatchQoS(for priority: JobPriority) -> DispatchQoS {
    guard let priority = TaskPriority(priority) else { return .unspecified }
    if priority >= .high { return .userInitiated }
    if priority >= .medium { return .default }
    if priority >= .low { return .utility }
    return .background
  }
}

#if os(Linux) || os(Android) || os(Windows)
  extension SQLiteConnectionExecutor: @unchecked Sendable {}
#endif

private final class SQLiteInterruptToken: Sendable {
  private let interrupt = Lock<(@Sendable () -> Void)?>(nil)

  func arm(_ interrupt: @escaping @Sendable () -> Void) {
    self.interrupt.withLock { $0 = interrupt }
  }

  func disarm() {
    interrupt.withLock { $0 = nil }
  }

  func fire() {
    // Invoke while holding the lock so `disarm` cannot let the next access begin first.
    interrupt.withLock { $0?() }
  }
}
