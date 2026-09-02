#if SystemSQLite
  import Foundation
  import StructuredQueries
  import Synchronization
  import Testing

  @testable import SQLiteCross

  private struct TemporaryDatabase: ~Copyable {
    let path: String

    init() {
      self.path = NSTemporaryDirectory() + "sqlite-cross-pool-\(UUID().uuidString).sqlite"
    }

    deinit {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
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
    let crossProcess = CrossProcessDatabase(driver: driver)

    try await crossProcess.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "Blob's reminder") })
    }

    let items = try await crossProcess.read { transaction in
      try transaction.fetchAll(Item.all.order { $0.id })
    }
    #expect(items == [Item(id: 1, title: "Blob's reminder")])
  }

  @Test
  func poolDriverRejectsDatabasesItCannotPool() {
    #expect(throws: SQLitePoolUnavailableError.self) {
      _ = try SQLitePoolDriver(path: ":memory:")
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

  @Test
  func poolDriverReadsWithoutAnAsynchronousContext() async throws {
    let database = TemporaryDatabase()
    let driver = try SQLitePoolDriver(path: database.path)
    try await bootstrap(driver)
    try await driver.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "sync") })
    }

    let titles = try driver.readSynchronously { transaction in
      try transaction.fetchAll(Item.select(\.title))
    }
    #expect(titles == ["sync"])
  }

  @Test
  func readersKeepWorkingWhileAWriteIsInFlight() async throws {
    let database = TemporaryDatabase()
    let driver = try SQLitePoolDriver(path: database.path)
    try await bootstrap(driver)
    let writing = Mutex(false)
    let release = Mutex(false)

    let write = Task {
      try await driver.write { transaction in
        _ = try transaction.execute(Item.insert { Item(id: 1, title: "in flight") })
        writing.withLock { $0 = true }
        while !release.withLock({ $0 }) {}
      }
    }
    while !writing.withLock({ $0 }) {
      await Task.yield()
    }

    // WAL is what makes this possible: the reader sees the pre-write snapshot rather than waiting.
    let duringWrite = try await driver.read { transaction in
      try transaction.fetchAll(Item.all).count
    }
    #expect(duringWrite == 0)

    release.withLock { $0 = true }
    try await write.value

    let afterWrite = try await driver.read { transaction in
      try transaction.fetchAll(Item.all).count
    }
    #expect(afterWrite == 1)
  }

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    var title: String
  }
#endif
