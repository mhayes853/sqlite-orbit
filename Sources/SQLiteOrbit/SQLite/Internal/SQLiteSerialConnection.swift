actor SQLiteSerialConnection {
  // Reached from `performBlocking` without hopping onto the actor. The custom executor serializes
  // this access on threaded runtimes; on a single-threaded runtime no other job can run during it.
  private nonisolated(unsafe) var handle: SQLiteConnection
  private let interrupt: @Sendable () -> Void
  private let suspension: SQLiteWriteSuspension?

  #if _runtime(_multithreaded)
    private let executor: SQLiteConnectionExecutor

    nonisolated var unownedExecutor: UnownedSerialExecutor {
      executor.asUnownedSerialExecutor()
    }
  #else
    private let isAccessing = Lock(false)
  #endif

  init(
    path: OrbitDatabasePath,
    flags: SQLiteOpenFlags,
    configuration: SQLiteConfiguration,
    driverSetupSQL: [String] = [],
    idleTimeout: Duration? = nil,
    suspension: SQLiteWriteSuspension? = nil
  ) throws {
    var handle = try SQLiteConnection(path: path, configuration: configuration, flags: flags)
    // Role-specific setup is driver policy, performed through the same public lending API.
    // The interrupt callback remains valid because this driver owns the connection for its lifetime.
    if handle.isReadOnly {
      self.interrupt = try handle.withReadConnection { connection in
        for sql in driverSetupSQL {
          var cursor = try connection.rowCursor(SQL(text: sql))
          while try cursor.next() != nil {}
        }
        let address = UInt(bitPattern: connection.sqliteConnection)
        let entryPoint = connection.sqlite.connections.interrupt
        return { @Sendable in entryPoint(OpaquePointer(bitPattern: address)) }
      }
    } else {
      self.interrupt = try handle.withWriteConnection { connection in
        for sql in driverSetupSQL { try connection.executeScript(sql) }
        let address = UInt(bitPattern: connection.sqliteConnection)
        let entryPoint = connection.sqlite.connections.interrupt
        return { @Sendable in entryPoint(OpaquePointer(bitPattern: address)) }
      }
    }
    self.suspension = suspension
    #if _runtime(_multithreaded)
      self.executor = SQLiteConnectionExecutor(path: path, idleTimeout: idleTimeout)
    #else
      _ = idleTimeout
    #endif
    self.handle = handle
  }

  func readWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    try await perform { handle, cancellation in
      try handle.withReadConnection(cancellation: cancellation) { connection in
        try connection.withSuspension(self.suspension) {
          try body(connection)
        }
      }
    }
  }

  func writeWithoutTransaction<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    try await perform { handle, cancellation in
      try handle.withWriteConnection(cancellation: cancellation) { connection in
        try connection.withSuspension(self.suspension) {
          try body(connection)
        }
      }
    }
  }

  nonisolated func readWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try performBlocking { handle, cancellation in
      try handle.withReadConnection(cancellation: cancellation) { connection in
        try connection.withSuspension(self.suspension) {
          try body(connection)
        }
      }
    }
  }

  nonisolated func writeWithoutTransactionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try performBlocking { handle, cancellation in
      try handle.withWriteConnection(cancellation: cancellation) { connection in
        try connection.withSuspension(self.suspension) {
          try body(connection)
        }
      }
    }
  }

  private nonisolated func performBlocking<Result: Sendable>(
    _ work: sending (inout SQLiteConnection, SQLiteConnectionCancellation?) throws -> Result
  ) throws -> Result {
    #if _runtime(_multithreaded)
      // `sync` runs the work as this actor's executor. Hopping onto the actor is impossible for
      // a closure the caller only lent us.
      return try executor.sync { try trackingSuspension { try work(&handle, nil) } }
    #else
      return try withConnectionAccess { try trackingSuspension { try work(&handle, nil) } }
    #endif
  }

  private nonisolated func trackingSuspension<Result>(
    _ work: () throws -> Result
  ) throws -> Result {
    guard let suspension else { return try work() }
    return try suspension.trackingAccess(interrupt: interrupt, work)
  }

  #if !_runtime(_multithreaded)
    private nonisolated func withConnectionAccess<Result>(
      _ work: () throws -> Result
    ) rethrows -> Result {
      isAccessing.withLock { isAccessing in
        precondition(
          !isAccessing,
          "A blocking database access cannot be nested inside another access on the same connection."
        )
        isAccessing = true
      }
      defer { isAccessing.withLock { $0 = false } }
      return try work()
    }
  #endif

  private func perform<Result: Sendable>(
    _ work: sending (inout SQLiteConnection, SQLiteConnectionCancellation?) throws -> Result
  ) async throws -> Result {
    let token = SQLiteConnectionCancellation()
    do {
      return try await withTaskCancellationHandler {
        // A task may have been cancelled while waiting to enter the actor.
        try Task.checkCancellation()
        #if _runtime(_multithreaded)
          return try trackingSuspension { try work(&handle, token) }
        #else
          return try withConnectionAccess { try trackingSuspension { try work(&handle, token) } }
        #endif
      } onCancel: {
        token.cancel()
      }
    } catch let error as SQLiteError where error.isInterruption {
      throw CancellationError()
    }
  }
}

// Driver policy composes only public connection capabilities.
extension SQLiteReadConnection {
  fileprivate borrowing func withSuspension<Result: ~Copyable>(
    _ suspension: SQLiteWriteSuspension?,
    _ body: () throws -> Result
  ) rethrows -> Result {
    if let suspension {
      return try withStatementExecution(
        suspension.step(of: sqlite, on: sqliteConnection),
        perform: body
      )
    }
    return try body()
  }
}

// Driver policy composes only public connection capabilities.
extension SQLiteWriteConnection {
  fileprivate borrowing func withSuspension<Result: ~Copyable>(
    _ suspension: SQLiteWriteSuspension?,
    _ body: () throws -> Result
  ) rethrows -> Result {
    if let suspension {
      return try withStatementExecution(
        suspension.step(of: sqlite, on: sqliteConnection),
        perform: body
      )
    }
    return try body()
  }
}
