#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  /// A read-only view of a database pool, frozen at the state of its creation.
  ///
  /// A snapshot owns a dedicated connection, outside of the pool, that keeps a read transaction
  /// open in write-ahead logging mode. The pool keeps writing meanwhile. Accesses run on a thread
  /// owned by the snapshot.
  public final class DatabaseSnapshot: DatabaseReader, @unchecked Sendable {
    public let path: String
    public let configuration: Configuration
    public let orbitDatabase: any OrbitObservableDatabaseWriter
    private let worker: SnapshotWorker

    init(pool: DatabasePool, description: String) throws {
      path = pool.path
      configuration = pool.configuration
      let queue = try translate {
        try SQLiteQueue(
          path: OrbitDatabasePath(pool.path),
          configuration: pool.configuration.resolvedNative(registry: nil)
        )
      }
      orbitDatabase = queue
      worker = try SnapshotWorker(queue: queue, description: description)
    }

    deinit {
      worker.stop()
    }

    /// Closes the snapshot. Later accesses fail with `SQLITE_MISUSE`. Closing again does nothing.
    public func close() throws {
      worker.stop()
    }

    public func read<T>(_ value: (Database) throws -> T) throws -> T {
      try worker.sync(value)
    }

    public func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
      try await worker.async(value)
    }

    public func unsafeRead<T>(_ value: (Database) throws -> T) throws -> T {
      try worker.sync(value)
    }

    public func unsafeRead<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T
    {
      try await worker.async(value)
    }

    /// Runs `value` on the snapshot connection, reentrantly if already on it.
    public func unsafeReentrantRead<T>(_ value: (Database) throws -> T) throws -> T {
      try worker.sync(value)
    }

    public func asyncRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
      worker.enqueue(value)
    }

    public func asyncUnsafeRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
      worker.enqueue(value)
    }
  }

  extension DatabasePool {
    /// Returns a snapshot of the current state of the database.
    public func makeSnapshot() throws -> DatabaseSnapshot {
      let number = snapshotCounter.next()
      let base = configuration.label ?? "GRDB.DatabasePool"
      return try DatabaseSnapshot(pool: self, description: "\(base).snapshot.\(number)")
    }
  }

  final class SnapshotCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
      lock.withLock {
        count += 1
        return count
      }
    }
  }

  // Runs closures on a thread that keeps a native read transaction open.
  final class SnapshotWorker: @unchecked Sendable {
    private struct BodyError: Error {
      let base: any Error
    }

    // Holds a non-escaping closure while it runs on the snapshot thread, then releases it
    // before the caller resumes.
    private final class Transfer<Value>: @unchecked Sendable {
      var value: Value?

      init(value: Value) {
        self.value = value
      }
    }

    private let condition = NSCondition()
    private var jobs: [(Database?) -> Void] = []
    private var stopped = false
    private var started: Result<Void, Error>?
    private var thread: Thread?

    init(queue: SQLiteQueue, description: String) throws {
      let thread = Thread { [unowned self] in self.run(queue: queue, description: description) }
      thread.name = description
      self.thread = thread
      thread.start()
      condition.lock()
      while started == nil { condition.wait() }
      let result = started!
      condition.unlock()
      try result.get()
    }

    private func run(queue: SQLiteQueue, description: String) {
      do {
        try queue.readBlocking { transaction in
          try transaction.withScopedAccess { access in
            let db = Database(access)
            db.connectionState.databaseDescription = description
            // Reading starts the snapshot: later commits are not visible.
            _ = try Row.fetchAll(db, sql: "SELECT 1 FROM sqlite_master LIMIT 1")
            condition.withLock {
              started = .success(())
              condition.broadcast()
            }
            while let job = nextJob() {
              db.enableRawStatements()
              job(db)
              db.finalizeRawStatements()
            }
          }
        }
      } catch {
        condition.withLock {
          if started == nil { started = .failure(error) }
          condition.broadcast()
        }
      }
      // Fail the jobs submitted after the end of the transaction.
      let pending = condition.withLock {
        stopped = true
        let pending = jobs
        jobs = []
        condition.broadcast()
        return pending
      }
      for job in pending { job(nil) }
    }

    private func nextJob() -> ((Database?) -> Void)? {
      condition.lock()
      defer { condition.unlock() }
      while jobs.isEmpty && !stopped { condition.wait() }
      if stopped { return nil }
      return jobs.removeFirst()
    }

    private static var closedError: DatabaseError {
      DatabaseError(resultCode: .SQLITE_MISUSE, message: "Connection is closed")
    }

    func stop() {
      condition.withLock {
        stopped = true
        condition.broadcast()
      }
    }

    private func submit(_ job: @escaping (Database?) -> Void) -> Bool {
      condition.withLock {
        guard !stopped else { return false }
        jobs.append(job)
        condition.broadcast()
        return true
      }
    }

    // Runs a closure synchronously on the snapshot thread.
    func sync<T>(_ body: (Database) throws -> T) throws -> T {
      if Thread.current === thread {
        preconditionFailure("Database methods are not reentrant.")
      }
      return try withoutActuallyEscaping(body) { body in
        let box = Transfer(value: body)
        var result: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        let accepted = submit { db in
          if let db {
            result = Result { try box.value!(db) }.mapError { BodyError(base: $0) }
          } else {
            result = .failure(Self.closedError)
          }
          box.value = nil
          done.signal()
        }
        guard accepted else {
          box.value = nil
          throw Self.closedError
        }
        done.wait()
        do {
          return try result!.get()
        } catch let error as BodyError {
          throw error.base
        }
      }
    }

    private func asyncEscaping<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T)
      async throws -> T
    {
      try await withCheckedThrowingContinuation { continuation in
        let accepted = submit { db in
          guard let db else { return continuation.resume(throwing: Self.closedError) }
          continuation.resume(with: Result { try body(db) })
        }
        if !accepted { continuation.resume(throwing: Self.closedError) }
      }
    }

    func async<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws -> T {
      try await withoutActuallyEscaping(body) { body in
        let box = Transfer(value: body)
        defer { box.value = nil }
        return try await asyncEscaping { try box.value!($0) }
      }
    }

    func enqueue(_ body: @escaping @Sendable (Result<Database, Error>) -> Void) {
      let accepted = submit { db in
        body(db.map { .success($0) } ?? .failure(Self.closedError))
      }
      if !accepted { body(.failure(Self.closedError)) }
    }
  }
#endif
