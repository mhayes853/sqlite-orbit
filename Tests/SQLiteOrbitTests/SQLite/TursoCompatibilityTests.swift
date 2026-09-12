#if Turso
  import Dispatch
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @DatabaseCollation
  private func tursoTestCollation(_ lhs: String, _ rhs: String) -> CollationOrder {
    CollationOrder(lhs, rhs)
  }

  private struct TemporaryTursoDatabase: ~Copyable {
    let path: OrbitDatabasePath

    init(_ name: String = "turso-pool") {
      self.path = OrbitDatabasePath(temporaryDatabasePath(name))
    }

    deinit {
      for suffix in ["", "-wal", "-shm", "-log"] {
        try? FileManager.default.removeItem(atPath: path.sqlitePath + suffix)
      }
    }
  }

  private final class TursoGate: Sendable {
    private let state = Lock((entered: 0, isOpen: false))

    var enteredCount: Int { state.withLock { $0.entered } }

    func hold() {
      state.withLock { $0.entered += 1 }
      while !state.withLock({ $0.isOpen }) {}
    }

    func waitUntilEntered(_ count: Int) async {
      while state.withLock({ $0.entered }) < count {
        await Task.yield()
      }
    }

    func open() {
      state.withLock { $0.isOpen = true }
    }
  }

  private final class TursoEntryOrder: Sendable {
    private let entries = Lock<[String]>([])

    var isEmpty: Bool { entries.withLock { $0.isEmpty } }

    func append(_ entry: String) {
      entries.withLock { $0.append(entry) }
    }

    func matches(_ expected: [String]) -> Bool {
      entries.withLock { $0 == expected }
    }
  }

  private final class TursoCommitRecorder: OrbitDatabaseTransactionObserver, Sendable {
    private let recordedCommits = Lock<[OrbitDatabaseCommit]>([])

    var commits: [OrbitDatabaseCommit] { recordedCommits.withLock { $0 } }

    func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
      recordedCommits.withLock { $0.append(commit) }
    }
  }

  private final class TursoValueRecorder<Value: Sendable>: Sendable {
    private let recordedValues = Lock<[Value]>([])

    var values: [Value] { recordedValues.withLock { $0 } }

    func record(_ change: OrbitValueObservationChange<Value>) {
      recordedValues.withLock { $0.append(change.value) }
    }

    func waitForCount(_ count: Int) async throws {
      try await waitUntil(timeout: .seconds(5)) { self.values.count >= count }
    }
  }

  @Test
  func tursoRunsBasicQueueTransactions() async throws {
    #expect(SQLiteConfiguration.default.library.name == "Turso")
    #expect(SQLiteConfiguration.default.isTrustedSchemaEnabled)

    let database = try inMemoryDatabase()
    try await database.write { transaction in
      try transaction.execute(
        #sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
      )
      try transaction.execute(
        #sql("INSERT INTO notes (id, title) VALUES (1, 'hello')", as: Void.self)
      )
    }

    let titles = try await database.read { transaction in
      try transaction.fetchAll(#sql("SELECT title FROM notes", as: String.self))
    }
    #expect(titles == ["hello"])
  }

  @Test
  func tursoRunsAPoolConfinedToOneProcess() async throws {
    let path = OrbitDatabasePath(temporaryDatabasePath("turso-local"))
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path.sqlitePath + suffix)
      }
    }

    let database = try OrbitDatabase<SQLitePool>(localPath: path)
    try await database.write { transaction in
      try transaction.execute(
        #sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
      )
      try transaction.execute(
        #sql("INSERT INTO notes (id, title) VALUES (1, 'pooled')", as: Void.self)
      )
    }
    let titles = try await database.read { transaction in
      try transaction.fetchAll(#sql("SELECT title FROM notes", as: String.self))
    }
    #expect(titles == ["pooled"])
  }

  @Test
  func tursoPoolRunsInMVCCMode() async throws {
    let database = TemporaryTursoDatabase("turso-mvcc")
    let driver = try TursoPool(path: database.path)

    let mode = try await driver.readWithoutTransaction { connection in
      try connection.fetchOne(#sql("PRAGMA journal_mode", as: String.self))
    }

    #expect(mode?.lowercased() == "mvcc")
  }

  @Test
  func tursoPoolSupportsWritesOutsideATransaction() async throws {
    let database = TemporaryTursoDatabase("turso-without-transaction")
    let driver = try TursoPool(path: database.path)
    try await driver.exclusiveWrite { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }

    try await driver.writeWithoutTransaction { connection in
      try connection.execute("INSERT INTO items (id) VALUES (1)")
      try connection.execute("INSERT INTO items (id) VALUES (2)")
    }

    let count = try await driver.readWithoutTransaction { connection in
      try connection.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
    }
    #expect(count == 2)
  }

  @Test
  func tursoPoolRunsConcurrentWritesOnDistinctConnections() async throws {
    let database = TemporaryTursoDatabase("turso-writers")
    let driver = try TursoPool(path: database.path, writerCount: 2)
    try await driver.exclusiveWrite { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    let gate = TursoGate()

    let writes = (1...2)
      .map { id in
        Task {
          try await driver.write { transaction in
            try transaction.execute("INSERT INTO items (id) VALUES (\(id))")
            gate.hold()
          }
        }
      }

    await gate.waitUntilEntered(2)
    gate.open()
    for write in writes { try await write.value }

    let count = try await driver.read { transaction in
      try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
    }
    #expect(count == 2)
  }

  @Test
  func tursoPoolPublishesEachConcurrentCommitWithItsActiveWriterCohort() async throws {
    let database = TemporaryTursoDatabase("turso-observation")
    let driver = try TursoPool(path: database.path, writerCount: 2)
    try await driver.exclusiveWrite { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    let observer = TursoCommitRecorder()
    let subscription = try driver.subscribe(transactionObserver: observer)
    let firstGate = TursoGate()
    let secondGate = TursoGate()

    let first = Task {
      try await driver.write { transaction in
        try transaction.execute("INSERT INTO items VALUES (1)")
        firstGate.hold()
      }
    }
    let second = Task {
      try await driver.write { transaction in
        try transaction.execute("INSERT INTO items VALUES (2)")
        secondGate.hold()
      }
    }
    await firstGate.waitUntilEntered(1)
    await secondGate.waitUntilEntered(1)

    firstGate.open()
    try await first.value
    let firstCommit = try #require(observer.commits.first)
    #expect(firstCommit.origin == .local)
    #expect(firstCommit.region.isFullDatabase)
    let barrier = try #require(firstCommit.activeWriterBarrier)
    #expect(barrier.hasActiveWriters)

    let barrierFinished = Lock(false)
    let wait = Task {
      await barrier.wait()
      barrierFinished.withLock { $0 = true }
    }
    for _ in 0..<100 { await Task.yield() }
    #expect(!barrierFinished.withLock { $0 })

    secondGate.open()
    try await second.value
    await wait.value
    #expect(barrierFinished.withLock { $0 })
    #expect(observer.commits.count == 2)
    _ = subscription
  }

  @Test
  func coalescedObservationWaitsForTheConcurrentTursoWriterCohort() async throws {
    let database = TemporaryTursoDatabase("turso-coalesced-observation")
    let driver = try TursoPool(path: database.path, writerCount: 2)
    try await driver.exclusiveWrite { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    let fetchCount = Lock(0)
    let observation = OrbitValueObservation<Int>
      .tracking { transaction in
        fetchCount.withLock { $0 += 1 }
        return try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self)) ?? 0
      }
      .refetching(.coalesced)
    let recorder = TursoValueRecorder<Int>()
    let subscription = try observation.subscribe(
      to: driver,
      onError: { Issue.record("Unexpected observation error: \($0)") },
      onChange: recorder.record
    )
    try await recorder.waitForCount(1)
    let firstGate = TursoGate()
    let secondGate = TursoGate()

    let first = Task {
      try await driver.write { transaction in
        try transaction.execute("INSERT INTO items VALUES (1)")
        firstGate.hold()
      }
    }
    let second = Task {
      try await driver.write { transaction in
        try transaction.execute("INSERT INTO items VALUES (2)")
        secondGate.hold()
      }
    }
    await firstGate.waitUntilEntered(1)
    await secondGate.waitUntilEntered(1)

    firstGate.open()
    try await first.value
    for _ in 0..<100 { await Task.yield() }
    #expect(recorder.values == [0])

    secondGate.open()
    try await second.value
    try await recorder.waitForCount(2)
    #expect(recorder.values == [0, 2])
    #expect(fetchCount.withLock { $0 } == 2)
    _ = subscription
  }

  @Test
  func tursoPoolDoesNotPublishFailedConcurrentWrites() async throws {
    struct Abort: Error {}

    let database = TemporaryTursoDatabase("turso-observation-rollback")
    let driver = try TursoPool(path: database.path, writerCount: 1)
    let observer = TursoCommitRecorder()
    let subscription = try driver.subscribe(transactionObserver: observer)

    await #expect(throws: Abort.self) {
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE discarded (id INTEGER)")
        throw Abort()
      }
    }

    #expect(observer.commits.isEmpty)
    _ = subscription
  }

  @Test
  func tursoPoolSurfacesAConcurrentWriteConflict() async throws {
    let database = TemporaryTursoDatabase("turso-conflict")
    let driver = try TursoPool(path: database.path, writerCount: 2)
    try await driver.exclusiveWrite { transaction in
      try transaction.execute(
        "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL);"
          + " INSERT INTO counter VALUES (1, 0)"
      )
    }
    let gate = TursoGate()

    let writes = (1...2)
      .map { value in
        Task { () -> SQLiteError? in
          do {
            try await driver.write { transaction in
              _ = try transaction.fetchOne(
                #sql("SELECT value FROM counter WHERE id = 1", as: Int.self)
              )
              gate.hold()
              try transaction.execute("UPDATE counter SET value = \(value) WHERE id = 1")
            }
            return nil
          } catch let error as SQLiteError {
            return error
          } catch {
            Issue.record("Unexpected conflict error: \(error)")
            return nil
          }
        }
      }

    await gate.waitUntilEntered(2)
    gate.open()
    var errors: [SQLiteError] = []
    for write in writes {
      if let error = await write.value { errors.append(error) }
    }

    #expect(errors.count == 1)
    let conflict = try #require(errors.first)
    #expect(
      conflict.primaryCode == .busy
        || conflict.message?.localizedCaseInsensitiveContains("conflict") == true
    )
    // The connection whose transaction lost the conflict was rolled back and remains usable.
    try await driver.write { transaction in
      try transaction.execute("INSERT INTO counter VALUES (2, 3)")
    }
  }

  @Test
  func tursoPoolRunsAReadAlongsideAWrite() async throws {
    let database = TemporaryTursoDatabase("turso-read-write")
    var configuration = SQLiteConfiguration.turso
    configuration.readerCount = 1
    let driver = try TursoPool(path: database.path, configuration: configuration, writerCount: 1)
    try await driver.exclusiveWrite { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    let gate = TursoGate()

    let read = Task { try await driver.read { _ in gate.hold() } }
    let write = Task {
      try await driver.write { transaction in
        try transaction.execute("INSERT INTO items (id) VALUES (1)")
        gate.hold()
      }
    }

    await gate.waitUntilEntered(2)
    gate.open()
    try await read.value
    try await write.value
  }

  @Test
  func tursoPoolExclusiveWriteWaitsForOrdinaryAccesses() async throws {
    let database = TemporaryTursoDatabase("turso-exclusive")
    let driver = try TursoPool(path: database.path, writerCount: 1)
    let gate = TursoGate()
    let entryOrder = TursoEntryOrder()

    let read = Task { try await driver.read { _ in gate.hold() } }
    await gate.waitUntilEntered(1)
    let exclusive = Task {
      try await driver.exclusiveWrite { transaction in
        entryOrder.append("exclusive")
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
    }
    for _ in 0..<100 { await Task.yield() }
    let trailingWrite = Task {
      try await driver.write { _ in
        entryOrder.append("trailing write")
      }
    }
    for _ in 0..<100 { await Task.yield() }
    #expect(entryOrder.isEmpty)

    gate.open()
    try await read.value
    try await exclusive.value
    try await trailingWrite.value
    #expect(entryOrder.matches(["exclusive", "trailing write"]))
  }

  @Test
  func cancellingAQueuedTursoWriteReturnsTheCapacity() async throws {
    let database = TemporaryTursoDatabase("turso-cancel")
    let driver = try TursoPool(path: database.path, writerCount: 1)
    try await driver.exclusiveWrite { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    let gate = TursoGate()

    let holding = Task { try await driver.write { _ in gate.hold() } }
    await gate.waitUntilEntered(1)
    let cancelled = Task {
      try await driver.write { transaction in
        try transaction.execute("INSERT INTO items (id) VALUES (1)")
      }
    }
    for _ in 0..<100 { await Task.yield() }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }

    gate.open()
    try await holding.value
    try await driver.write { transaction in
      try transaction.execute("INSERT INTO items (id) VALUES (2)")
    }
  }

  @Test
  func tursoPoolBlockingAccessesUseTheSameConnections() throws {
    let database = TemporaryTursoDatabase("turso-blocking")
    let driver = try TursoPool(path: database.path, writerCount: 2)

    try driver.exclusiveWriteBlocking { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    try driver.writeWithoutTransactionBlocking { connection in
      try connection.execute("INSERT INTO items (id) VALUES (1)")
    }
    let count = try driver.readWithoutTransactionBlocking { connection in
      try connection.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
    }

    #expect(count == 1)
  }

  @Test
  func tursoPoolBlockingWritesCanRunConcurrently() throws {
    let database = TemporaryTursoDatabase("turso-blocking-writers")
    let driver = try TursoPool(path: database.path, writerCount: 2)
    try driver.exclusiveWriteBlocking { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    let gate = TursoGate()
    let done = DispatchSemaphore(value: 0)

    for id in 1...2 {
      Thread.detachNewThread {
        try! driver.writeBlocking { transaction in
          try transaction.execute("INSERT INTO items (id) VALUES (\(id))")
          gate.hold()
        }
        done.signal()
      }
    }

    while gate.enteredCount < 2 { Thread.sleep(forTimeInterval: 0.001) }
    gate.open()
    done.blockingWait()
    done.blockingWait()

    let count = try driver.readBlocking { transaction in
      try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
    }
    #expect(count == 2)
  }

  @Test(arguments: [OrbitDatabasePath.memory, .temporary, ":memory:", ""])
  func tursoPoolRejectsDatabasesPrivateToAConnection(path: OrbitDatabasePath) {
    #expect(throws: SQLitePoolUnavailableError.self) {
      _ = try TursoPool(path: path)
    }
  }

  @Test
  func tursoUsesWholeDatabaseRegionsWithoutAnAuthorizer() throws {
    let handle = try SQLiteHandle.open(
      path: .memory,
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: .turso
    )
    try handle.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")

    let read = try handle.statements.prepare("SELECT title FROM notes")
    defer { _ = handle.library.pointee.statements.execution.finalize(read.pointer) }
    #expect(read.readRegion.isFullDatabase)

    let write = try handle.statements.prepare("INSERT INTO notes (title) VALUES ('hello')")
    defer { _ = handle.library.pointee.statements.execution.finalize(write.pointer) }
    #expect(write.changedRegion.isFullDatabase)
    #expect(write.invalidatesStatementCache)
  }

  @Test
  func tursoRefusesWritesPassedThroughAReadTransaction() throws {
    let handle = try SQLiteHandle.open(
      path: .memory,
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: .turso
    )
    try handle.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY)")

    #expect(throws: SQLiteError.self) {
      try handle.read { transaction in
        try transaction.fetchAll(
          #sql("INSERT INTO notes DEFAULT VALUES RETURNING id", as: Int.self)
        )
      }
    }
  }

  @Test
  func tursoReportsFeaturesItCannotProvide() {
    var hardened = SQLiteConfiguration.turso
    hardened.isTrustedSchemaEnabled = false
    #expect(throws: SQLiteFeatureUnavailableError.self) {
      _ = try SQLiteQueue(path: .memory, configuration: hardened)
    }

    var withCollation = SQLiteConfiguration.turso
    withCollation.register(collation: $tursoTestCollation)
    #expect(throws: SQLiteFeatureUnavailableError.self) {
      _ = try SQLiteQueue(path: .memory, configuration: withCollation)
    }

    #if canImport(Darwin) || canImport(Glibc)
      #expect(throws: SQLiteFeatureUnavailableError.self) {
        _ = try OrbitDatabase<SQLitePool>(path: "/tmp/turso-multiprocess.sqlite")
      }
    #endif
  }

  @Test
  func tursoRefusesToCheckForeignKeysRatherThanReportNoViolations() async throws {
    #expect(!SQLiteLibrary.turso.isForeignKeyCheckAvailable)
    let expected = SQLiteFeatureUnavailableError(libraryName: "Turso", feature: .foreignKeyCheck)
    #expect(expected.description == "Turso does not support SQLite's foreign key checks.")

    // Turso answers `PRAGMA foreign_key_check` with no rows, even for a row that refers to
    // nothing, which is what an empty result would wrongly vouch for.
    let driver = try SQLiteQueue(path: .memory)
    try await driver.writeWithoutTransaction { connection in
      connection.isForeignKeysEnabled = false
      try connection.execute(
        """
        CREATE TABLE lists (id INTEGER PRIMARY KEY);
        CREATE TABLE reminders (id INTEGER PRIMARY KEY, listID INTEGER REFERENCES lists (id));
        INSERT INTO reminders VALUES (1, 7);
        """
      )
    }

    let fromTransaction = await #expect(throws: SQLiteFeatureUnavailableError.self) {
      try await driver.read { try $0.foreignKeyViolations() }
    }
    let fromWrite = await #expect(throws: SQLiteFeatureUnavailableError.self) {
      try await driver.write { try $0.foreignKeyViolations() }
    }
    let fromConnection = await #expect(throws: SQLiteFeatureUnavailableError.self) {
      try await driver.readWithoutTransaction { try $0.foreignKeyViolations() }
    }
    let fromWriteConnection = await #expect(throws: SQLiteFeatureUnavailableError.self) {
      try await driver.writeWithoutTransaction { try $0.foreignKeyViolations() }
    }
    #expect(fromTransaction == expected)
    #expect(fromWrite == expected)
    #expect(fromConnection == expected)
    #expect(fromWriteConnection == expected)
  }
#endif
