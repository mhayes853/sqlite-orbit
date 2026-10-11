/// One native SQLite connection that serializes every access to it on an executor of its own.
///
/// This is the building block the package's drivers are made of: ``SQLiteQueue`` is one of these,
/// and ``SQLiteConnectionPool`` lends several. It owns a ``SQLiteConnection`` for its whole
/// lifetime and lends it one access at a time, asynchronously or by blocking the calling thread,
/// in the order the accesses arrive. An access is synchronous and runs on the connection's
/// executor, so it never suspends while it holds the connection.
///
/// A driver of your own adds the transactions and the observation on top. Combined with an
/// ``OrbitCompositeDatabaseTransactionObserver``, a serial connection makes an observable database:
///
/// ```swift
/// final class LoggingQueue: OrbitDatabaseReader {
///   private let connection: SQLiteSerialConnection
///   private let observers = OrbitCompositeDatabaseTransactionObserver()
///
///   init(path: OrbitDatabasePath) throws {
///     connection = try SQLiteSerialConnection(path: path, configuration: .default)
///   }
///
///   func read<Result: Sendable>(
///     _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
///   ) async throws -> Result {
///     try await connection.withReadConnection { connection in
///       try connection.transaction(observer: observers, body)
///     }
///   }
///
///   // ...
/// }
/// ```
///
/// Cancelling the task awaiting an access interrupts the statement it is running, and the access
/// throws `CancellationError` rather than the `SQLITE_INTERRUPT` SQLite reports.
public final class SQLiteSerialConnection: Sendable {
  private let connection: SQLiteSerialConnectionActor

  /// Opens and configures a connection to the database at `path`.
  ///
  /// ```swift
  /// let connection = try SQLiteSerialConnection(
  ///   path: .file(url),
  ///   configuration: .default,
  ///   setups: [.sql("PRAGMA cache_size = -16000")]
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - path: Where the database lives. Every path is usable, including `.memory`.
  ///   - configuration: The settings applied to the connection.
  ///   - flags: How the database is opened. Defaults to reading and writing, creating the
  ///     database when it does not exist, without SQLite's own mutex, since the connection is
  ///     never used by two threads at once.
  ///   - setups: The driver's own setups, run in order after `configuration`'s setups. They run
  ///     with the driver's privilege, so `configuration`'s authorization does not apply to them,
  ///     and are not part of the configuration the lent connections report.
  /// - Throws: A ``SQLiteError`` when the database cannot be opened or configured, or whatever a
  ///   setup throws.
  public convenience init(
    path: OrbitDatabasePath,
    configuration: SQLiteConfiguration,
    flags: SQLiteOpenFlags = [.readWrite, .create, .noMutex],
    setups: [SQLiteSetup] = []
  ) throws {
    try self.init(
      path: path,
      configuration: configuration,
      flags: flags,
      setups: setups,
      suspension: nil
    )
  }

  init(
    path: OrbitDatabasePath,
    configuration: SQLiteConfiguration,
    flags: SQLiteOpenFlags = [.readWrite, .create, .noMutex],
    setups: [SQLiteSetup] = [],
    idleTimeout: Duration? = nil,
    suspension: SQLiteWriteSuspension?
  ) throws {
    self.connection = try SQLiteSerialConnectionActor(
      path: path,
      flags: flags,
      configuration: configuration,
      driverSetups: setups,
      idleTimeout: idleTimeout,
      suspension: suspension
    )
  }

  /// Lends the connection for reading, once every access that arrived before this one is done.
  ///
  /// ```swift
  /// let count = try await connection.withReadConnection { connection in
  ///   try connection.fetchOne("SELECT count(*) FROM reminders") { $0[0].integerValue }
  /// }
  /// ```
  ///
  /// A connection that can write enforces `PRAGMA query_only` for the duration, so a read that
  /// attempts a write fails.
  ///
  /// - Parameter body: Receives the connection. Each statement runs in its own implicit
  ///   transaction unless `body` opens one.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled while waiting or running.
  public nonisolated(nonsending) func withReadConnection<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) async throws -> Result {
    try await connection.withReadConnection(body)
  }

  /// Lends the connection for writing, once every access that arrived before this one is done.
  ///
  /// ```swift
  /// try await connection.withWriteConnection { connection in
  ///   try connection.transaction { transaction in
  ///     try transaction.execute("INSERT INTO reminders (title) VALUES (\("Get milk"))")
  ///   }
  /// }
  /// ```
  ///
  /// - Parameter body: Receives the connection. Each statement commits on its own unless `body`
  ///   opens a transaction.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, a ``SQLiteError``, or `CancellationError` when the task was
  ///   cancelled while waiting or running. A connection opened read-only throws `SQLITE_READONLY`
  ///   without calling `body`.
  public nonisolated(nonsending) func withWriteConnection<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) async throws -> Result {
    try await connection.withWriteConnection(body)
  }

  /// Lends the connection for reading, blocking the calling thread until the access is done.
  ///
  /// - Important: Never call this from a task, and never from inside another access on this
  ///   connection: the nested access would wait for the connection the outer one still holds.
  ///
  /// - Parameter body: Receives the connection.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``.
  public func withReadConnectionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try connection.withReadConnectionBlocking(body)
  }

  /// Lends the connection for writing, blocking the calling thread until the access is done.
  ///
  /// - Important: Never call this from a task, and never from inside another access on this
  ///   connection: the nested access would wait for the connection the outer one still holds.
  ///
  /// - Parameter body: Receives the connection.
  /// - Returns: Whatever `body` returned.
  /// - Throws: Whatever `body` threw, or a ``SQLiteError``. A connection opened read-only throws
  ///   `SQLITE_READONLY` without calling `body`.
  public func withWriteConnectionBlocking<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try connection.withWriteConnectionBlocking(body)
  }
}

/// The actor a ``SQLiteSerialConnection`` runs its accesses on, isolated to the connection's own
/// executor.
actor SQLiteSerialConnectionActor {
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
    driverSetups: [SQLiteSetup],
    idleTimeout: Duration?,
    suspension: SQLiteWriteSuspension?
  ) throws {
    var handle = try SQLiteConnection(path: path, configuration: configuration, flags: flags)
    // Role-specific setup is driver policy, performed through the same public lending API but
    // with the driver's privilege rather than the application's authorization. The interrupt
    // callback remains valid because this driver owns the connection for its lifetime.
    let authorizer = handle.authorizer
    self.interrupt = try handle.withConnectionAccess { connection in
      try authorizer.withoutUserAuthorization {
        try authorizer.requiringExecution {
          for setup in driverSetups { try setup(connection) }
        }
      }
      let address = UInt(bitPattern: connection.sqliteConnection)
      let entryPoint = connection.sqlite.connections.interrupt
      return { @Sendable in entryPoint(OpaquePointer(bitPattern: address)) }
    }
    self.suspension = suspension
    #if _runtime(_multithreaded)
      self.executor = SQLiteConnectionExecutor(path: path, idleTimeout: idleTimeout)
    #else
      _ = idleTimeout
    #endif
    self.handle = handle
  }

  func withReadConnection<Result: Sendable>(
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

  func withWriteConnection<Result: Sendable>(
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

  nonisolated func withReadConnectionBlocking<Result: Sendable>(
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

  nonisolated func withWriteConnectionBlocking<Result: Sendable>(
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
      return try withStatementStepInterceptor(
        suspension.interceptor(of: sqlite, on: sqliteConnection),
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
      return try withStatementStepInterceptor(
        suspension.interceptor(of: sqlite, on: sqliteConnection),
        perform: body
      )
    }
    return try body()
  }
}
