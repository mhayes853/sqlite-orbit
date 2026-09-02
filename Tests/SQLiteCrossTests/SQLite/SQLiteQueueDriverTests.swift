#if SystemSQLite
  import Foundation
  import StructuredQueries
  import Synchronization
  import Testing

  @testable import SQLiteCross

  private func makeQueueDriver() throws -> SQLiteQueueDriver {
    let driver = try SQLiteQueueDriver(path: ":memory:")
    try driver.readSynchronously { _ in }
    return driver
  }

  private func bootstrap(_ driver: SQLiteQueueDriver) async throws {
    try await driver.write { transaction in
      try transaction.execute(
        "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
      )
    }
  }

  @Test
  func queueDriverWritesAndReadsThroughTheDriverProtocol() async throws {
    let driver = try makeQueueDriver()
    try await bootstrap(driver)
    let database = CrossProcessDatabase(driver: driver)

    try await database.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "Blob's reminder") })
    }

    let items = try await database.read { transaction in
      try transaction.fetchAll(Item.all.order { $0.id })
    }
    #expect(items == [Item(id: 1, title: "Blob's reminder")])
  }

  @Test
  func queueDriverCommitsAcrossSeparateWrites() async throws {
    let driver = try makeQueueDriver()
    try await bootstrap(driver)

    for id in 1...3 {
      try await driver.write { transaction in
        try transaction.execute(Item.insert { Item(id: id, title: "item \(id)") })
      }
    }

    let count = try await driver.read { transaction in
      try transaction.fetchAll(Item.all).count
    }
    #expect(count == 3)
  }

  @Test
  func queueDriverRollsBackAWriteThatThrows() async throws {
    let driver = try makeQueueDriver()
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

    // The rolled-back transaction did not leave one open behind it.
    try await driver.write { transaction in
      try transaction.execute(Item.insert { Item(id: 2, title: "after") })
    }
    let recovered = try await driver.read { transaction in
      try transaction.fetchAll(Item.all)
    }
    #expect(recovered == [Item(id: 2, title: "after")])
  }

  @Test
  func queueDriverSerializesConcurrentWrites() async throws {
    let driver = try makeQueueDriver()
    try await bootstrap(driver)
    let count = 200

    try await withThrowingTaskGroup(of: Void.self) { group in
      for id in 1...count {
        group.addTask {
          try await driver.write { transaction in
            _ = try transaction.execute(Item.insert { Item(id: id, title: "concurrent") })
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
  func queueDriverInterleavesConcurrentReadsAndWrites() async throws {
    let driver = try makeQueueDriver()
    try await bootstrap(driver)
    let count = 100

    try await withThrowingTaskGroup(of: Void.self) { group in
      for id in 1...count {
        group.addTask {
          try await driver.write { transaction in
            _ = try transaction.execute(Item.insert { Item(id: id, title: "row") })
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
  func queueDriverReadsWithoutAnAsynchronousContext() async throws {
    let driver = try makeQueueDriver()
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
  func queueDriverDerivesItsIdentifierFromThePath() throws {
    let path = NSTemporaryDirectory() + "sqlite-cross-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let driver = try SQLiteQueueDriver(path: path)
    #expect(driver.defaultIdentifier.rawValue.hasSuffix(".sqlite"))

    // An in-memory database is private to its connection, so no two of them are the same database.
    let first = try SQLiteQueueDriver(path: ":memory:")
    let second = try SQLiteQueueDriver(path: ":memory:")
    #expect(first.defaultIdentifier != second.defaultIdentifier)
  }

  @Test
  func queueDriverPersistsToAFileAcrossDrivers() async throws {
    let path = NSTemporaryDirectory() + "sqlite-cross-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
      let driver = try SQLiteQueueDriver(path: path)
      try await bootstrap(driver)
      try await driver.write { transaction in
        try transaction.execute(Item.insert { Item(id: 1, title: "persisted") })
      }
    }

    let reopened = try SQLiteQueueDriver(path: path)
    let items = try await reopened.read { transaction in
      try transaction.fetchAll(Item.all)
    }
    #expect(items == [Item(id: 1, title: "persisted")])
  }

  @Test
  func cancellingAReadInterruptsTheQueryItIsRunning() async throws {
    // Cancelling before the query starts stepping would be a no-op in SQLite, so the test waits
    // for the step itself rather than for the task, which would race.
    let steps = Mutex(0)
    let base = SQLiteLibrary.system
    var configuration = SQLiteConfiguration.default
    configuration.library.step = { statement in
      steps.withLock { $0 += 1 }
      return base.step(statement)
    }

    let driver = try SQLiteQueueDriver(path: ":memory:", configuration: configuration)
    try await bootstrap(driver)
    let stepsBefore = steps.withLock { $0 }

    let task = Task {
      try await driver.read { transaction in
        try transaction.fetchAll(
          #sql(
            """
            WITH RECURSIVE counter(x) AS (
              SELECT 1 UNION ALL SELECT x + 1 FROM counter WHERE x < 200000000
            )
            SELECT count(*) FROM counter
            """,
            as: Int.self
          )
        )
      }
    }

    // One step opens the transaction; the next is the query, and it does not return on its own.
    while steps.withLock({ $0 }) < stepsBefore + 2 {
      await Task.yield()
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }

    // The interrupted read left the connection usable.
    let count = try await driver.read { transaction in
      try transaction.fetchAll(Item.all).count
    }
    #expect(count == 0)
  }

  @Test
  func cancellingBeforeTheConnectionIsFreeStillCancels() async throws {
    let driver = try makeQueueDriver()
    try await bootstrap(driver)
    let holding = Mutex(false)
    let release = Mutex(false)

    // Occupy the connection so the next reader has to wait its turn.
    let blocker = Task {
      try await driver.write { _ in
        holding.withLock { $0 = true }
        while !release.withLock({ $0 }) {}
      }
    }
    while !holding.withLock({ $0 }) {
      await Task.yield()
    }

    let waiter = Task {
      try await driver.read { transaction in
        try transaction.fetchAll(Item.all).count
      }
    }
    waiter.cancel()
    release.withLock { $0 = true }
    _ = try await blocker.value

    await #expect(throws: CancellationError.self) {
      _ = try await waiter.value
    }
  }

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    var title: String
  }
#endif
