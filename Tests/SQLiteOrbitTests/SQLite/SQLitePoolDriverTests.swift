#if SystemSQLite
  import Foundation
  import StructuredQueries
  import Synchronization
  import Testing

  @testable import SQLiteOrbit

  private struct TemporaryDatabase: ~Copyable {
    let path: DatabasePath

    init() {
      self.path = DatabasePath(
        temporaryDatabasePath("pool")
      )
    }

    deinit {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path.sqlitePath + suffix)
      }
    }
  }

  private func bootstrap(_ driver: SQLitePoolDriver) async throws {
    try await driver.write { transaction in
      try transaction.execute(
        "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
      )
    }
  }

  @Test
  func poolDriverWritesAndReadsThroughTheDriverProtocol() async throws {
    let database = TemporaryDatabase()
    let driver = try SQLitePoolDriver(path: database.path)
    try await bootstrap(driver)
    let interprocess = InterprocessDatabase(writer: driver)

    try await interprocess.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "Blob's reminder") })
    }

    let items = try await interprocess.read { transaction in
      try transaction.fetchAll(Item.all.order { $0.id })
    }
    #expect(items == [Item(id: 1, title: "Blob's reminder")])
  }

  @Test(arguments: [DatabasePath.memory, .temporary, ":memory:", ""])
  func poolDriverRejectsDatabasesItCannotPool(path: DatabasePath) {
    #expect(throws: SQLitePoolUnavailableError.self) {
      _ = try SQLitePoolDriver(path: path)
    }
  }

  @Test
  func poolDriverRunsInWALMode() async throws {
    let database = TemporaryDatabase()
    let driver = try SQLitePoolDriver(path: database.path)

    let mode = try await driver.read { transaction in
      try transaction.fetchAll(#sql("PRAGMA journal_mode", as: String.self))
    }
    #expect(mode == ["wal"])
  }

  @Test
  func poolReadersRefuseToWriteThroughTheRawConnection() async throws {
    let database = TemporaryDatabase()
    let driver = try SQLitePoolDriver(path: database.path)
    try await bootstrap(driver)

    let isReadOnly = try await driver.read { transaction in
      try transaction.fetchAll(#sql("PRAGMA query_only", as: Bool.self))
    }
    #expect(isReadOnly == [true])

    await #expect(throws: SQLiteError.self) {
      try await driver.read { transaction in
        try transaction.execute("INSERT INTO items (title) VALUES ('nope')")
      }
    }
  }

  @Test
  func poolDriverRollsBackAWriteThatThrows() async throws {
    let database = TemporaryDatabase()
    let driver = try SQLitePoolDriver(path: database.path)
    try await bootstrap(driver)

    struct Abort: Error {}
    await #expect(throws: Abort.self) {
      try await driver.write { transaction in
        try transaction.execute(Item.insert { Item(id: 1, title: "doomed") })
        throw Abort()
      }
    }

    let items = try await driver.read { transaction in
      try transaction.fetchAll(Item.all)
    }
    #expect(items.isEmpty)
  }

  @Test
  func poolDriverSurvivesHighContentionFromManyTasks() async throws {
    let database = TemporaryDatabase()
    var configuration = SQLiteConfiguration.default
    configuration.readerCount = 4
    let driver = try SQLitePoolDriver(path: database.path, configuration: configuration)
    try await bootstrap(driver)
    let count = 500

    try await withThrowingTaskGroup(of: Void.self) { group in
      for id in 1...count {
        group.addTask {
          try await driver.write { transaction in
            _ = try transaction.execute(Item.insert { Item(id: id, title: "contended") })
          }
        }
        group.addTask {
          _ = try await driver.read { transaction in
            try transaction.fetchAll(Item.all).count
          }
        }
      }
      try await group.waitForAll()
    }

    let written = try await driver.read { transaction in
      try transaction.fetchAll(Item.all).count
    }
    #expect(written == count)
  }

  @Test
  func poolDriverReturnsEveryReaderItLends() async throws {
    let database = TemporaryDatabase()
    var configuration = SQLiteConfiguration.default
    configuration.readerCount = 2
    let driver = try SQLitePoolDriver(path: database.path, configuration: configuration)
    try await bootstrap(driver)

    // Far more concurrent readers than the pool holds, so most of them have to wait for one.
    try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<50 {
        group.addTask {
          try await driver.read { transaction in
            try transaction.fetchAll(Item.all).count
          }
        }
      }
      for try await value in group {
        #expect(value == 0)
      }
    }

    // A reader that was never given back would leave this waiting forever.
    let count = try await driver.read { transaction in
      try transaction.fetchAll(Item.all).count
    }
    #expect(count == 0)
  }

  @Test
  func aFailedPooledReadStillGivesItsReaderBack() async throws {
    let database = TemporaryDatabase()
    var configuration = SQLiteConfiguration.default
    configuration.readerCount = 1
    let driver = try SQLitePoolDriver(path: database.path, configuration: configuration)
    try await bootstrap(driver)

    struct Abort: Error {}
    for _ in 0..<5 {
      await #expect(throws: Abort.self) {
        try await driver.read { _ in throw Abort() }
      }
    }

    // The one reader in the pool survived five failures.
    let count = try await driver.read { transaction in
      try transaction.fetchAll(Item.all).count
    }
    #expect(count == 0)
  }

  /// Holds an access open until released, so a test can arrange overlaps deliberately.
  private final class Gate: Sendable {
    private let entered = Mutex(0)
    private let released = Mutex(false)

    var enteredCount: Int { entered.withLock { $0 } }

    func hold() {
      entered.withLock { $0 += 1 }
      while !released.withLock({ $0 }) {}
    }

    func waitUntilEntered(_ count: Int) async {
      while enteredCount < count {
        await Task.yield()
      }
    }

    func release() {
      released.withLock { $0 = true }
    }
  }

  private final class RequestCounter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func increment() {
      count.withLock { $0 += 1 }
    }
  }

  @Test
  func readsRunAlongsideOneAnother() async throws {
    let database = TemporaryDatabase()
    var configuration = SQLiteConfiguration.default
    configuration.readerCount = 2
    let driver = try SQLitePoolDriver(path: database.path, configuration: configuration)
    let gate = Gate()

    let reads = (0..<2)
      .map { _ in
        Task { try await driver.read { _ in gate.hold() } }
      }
    // Both reads are inside the database at once; a serialized pool would never get here.
    await gate.waitUntilEntered(2)
    gate.release()
    for read in reads {
      try await read.value
    }
  }

  @Test
  func readsIssuedDuringAWriteWaitForItToCommit() async throws {
    let database = TemporaryDatabase()
    let driver = try SQLitePoolDriver(path: database.path)
    try await bootstrap(driver)
    let gate = Gate()

    let write = Task {
      try await driver.write { transaction in
        _ = try transaction.execute(Item.insert { Item(id: 1, title: "in flight") })
        gate.hold()
      }
    }
    await gate.waitUntilEntered(1)

    let read = Task {
      try await driver.read { transaction in
        try transaction.fetchAll(Item.all).count
      }
    }
    // The read is queued behind the write, so it cannot have run yet.
    await Task.yield()
    gate.release()
    try await write.value

    // And when it does run, it sees what the write committed.
    #expect(try await read.value == 1)
  }

  @Test
  func aWriteWaitsForTheReadsInFlight() async throws {
    let database = TemporaryDatabase()
    let driver = try SQLitePoolDriver(path: database.path)
    try await bootstrap(driver)
    let gate = Gate()
    let wrote = Mutex(false)

    let read = Task { try await driver.read { _ in gate.hold() } }
    await gate.waitUntilEntered(1)

    let write = Task {
      try await driver.write { transaction in
        wrote.withLock { $0 = true }
        _ = try transaction.execute(Item.insert { Item(id: 1, title: "after read") })
      }
    }
    for _ in 0..<100 {
      await Task.yield()
    }
    #expect(wrote.withLock { $0 } == false)

    gate.release()
    try await read.value
    try await write.value
    #expect(wrote.withLock { $0 })
  }

  @Test
  func aQueuedWriterRunsBeforeLaterReadersUnderReadPressure() async throws {
    let database = TemporaryDatabase()
    var configuration = SQLiteConfiguration.default
    configuration.readerCount = 2
    let driver = try SQLitePoolDriver(path: database.path, configuration: configuration)
    try await bootstrap(driver)
    let gate = Gate()

    let blockingReads = (0..<2)
      .map { _ in
        Task { try await driver.read { _ in gate.hold() } }
      }
    await gate.waitUntilEntered(2)

    let writerRequested = Mutex(false)
    let writer = Task {
      writerRequested.withLock { $0 = true }
      try await driver.write { transaction in
        try transaction.execute(Item.insert { Item(id: 1, title: "writer") })
      }
    }
    while !writerRequested.withLock({ $0 }) { await Task.yield() }
    for _ in 0..<100 { await Task.yield() }

    // Keep read pressure behind the writer. Every one of these must observe its commit; granting
    // any of them first would allow a steady read stream to starve the writer indefinitely.
    let trailingRequested = RequestCounter()
    let trailingReads = (0..<32)
      .map { _ in
        Task {
          trailingRequested.increment()
          return try await driver.read { transaction in
            try transaction.fetchAll(Item.all).count
          }
        }
      }
    while trailingRequested.value < trailingReads.count { await Task.yield() }
    for _ in 0..<100 { await Task.yield() }

    gate.release()
    for read in blockingReads { try await read.value }
    _ = try await writer.value
    for read in trailingReads {
      #expect(try await read.value == 1)
    }
  }

  @Test
  func cancellingAQueuedWriteLetsTheRequestsBehindItRun() async throws {
    let database = TemporaryDatabase()
    let driver = try SQLitePoolDriver(path: database.path)
    try await bootstrap(driver)
    let gate = Gate()

    let read = Task { try await driver.read { _ in gate.hold() } }
    await gate.waitUntilEntered(1)

    let write = Task {
      try await driver.write { transaction in
        _ = try transaction.execute(Item.insert { Item(id: 1, title: "never") })
      }
    }
    let trailingRead = Task {
      try await driver.read { transaction in
        try transaction.fetchAll(Item.all).count
      }
    }
    for _ in 0..<100 {
      await Task.yield()
    }
    write.cancel()
    await #expect(throws: CancellationError.self) {
      try await write.value
    }

    // The trailing read was queued behind the write and is released by its cancellation, rather
    // than waiting on a write that will never run.
    gate.release()
    try await read.value
    #expect(try await trailingRead.value == 0)
  }

  @Test
  @MainActor
  func poolAccessesRunOffTheCallersThread() async throws {
    let database = TemporaryDatabase()
    let driver = try SQLitePoolDriver(path: database.path)

    let readOnMain = try await driver.read { _ in Thread.isMainThread }
    let wroteOnMain = try await driver.write { _ in Thread.isMainThread }
    #expect(readOnMain == false)
    #expect(wroteOnMain == false)
  }

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    var title: String
  }
#endif
