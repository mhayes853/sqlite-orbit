actor SQLiteSerialConnection {
  // Reached from `performBlocking` without hopping onto the actor: what serializes access to the
  // handle is the connection's executor, which is also this actor's executor.
  private nonisolated(unsafe) let handle: SQLiteHandle
  private let executor: SQLiteConnectionExecutor
  private let interrupt: @Sendable () -> Void

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }

  init(
    path: OrbitDatabasePath,
    flags: SQLiteOpenFlags,
    configuration: SQLiteConfiguration,
    driverSetupSQL: [String] = [],
    idleTimeout: Duration? = nil
  ) throws {
    let handle = try SQLiteHandle.open(
      path: path,
      flags: flags,
      configuration: configuration,
      driverSetupSQL: driverSetupSQL
    )
    // The connection is captured as an address rather than a pointer, which is what lets this
    // closure be shared without an unchecked conformance on `OpaquePointer`. It stays valid
    // because the closure and the handle are released together.
    let address = UInt(bitPattern: handle.pointer)
    let entryPoint = handle.library.pointee.connections.interrupt
    self.interrupt = { entryPoint(OpaquePointer(bitPattern: address)) }
    self.executor = SQLiteConnectionExecutor(path: path, idleTimeout: idleTimeout)
    self.handle = handle
  }

  func read<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    try await perform { handle in try handle.read(observers: observers, body) }
  }

  func write<Result: Sendable>(
    mode: SQLiteWriteTransactionMode = .immediate,
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    try await perform { handle in try handle.write(mode: mode, observers: observers, body) }
  }

  nonisolated func readBlocking<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try performBlocking { handle in try handle.read(observers: observers, body) }
  }

  nonisolated func writeBlocking<Result: Sendable>(
    mode: SQLiteWriteTransactionMode = .immediate,
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try performBlocking {
      handle in try handle.write(mode: mode, observers: observers, body)
    }
  }

  func readWithoutTransaction<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    try await perform { handle in try handle.readWithoutTransaction(observers: observers, body) }
  }

  func writeWithoutTransaction<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    try await perform { handle in try handle.writeWithoutTransaction(observers: observers, body) }
  }

  nonisolated func readWithoutTransactionBlocking<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try performBlocking { handle in try handle.readWithoutTransaction(observers: observers, body) }
  }

  nonisolated func writeWithoutTransactionBlocking<Result: Sendable>(
    observers: OrbitDatabaseTransactionObservers? = nil,
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try performBlocking { handle in try handle.writeWithoutTransaction(observers: observers, body) }
  }

  private nonisolated func performBlocking<Result: Sendable>(
    _ work: sending (borrowing SQLiteHandle) throws -> Result
  ) throws -> Result {
    // `sync` runs the work as this actor's executor, so no isolated use of the handle can be
    // running while it does. Hopping onto the actor to say so is what a closure the caller only
    // lent us cannot do.
    return try executor.sync { try work(handle) }
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
    } catch let error as SQLiteError where error.isInterruption {
      throw CancellationError()
    }
  }
}

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
