#if SystemSQLite
  import Foundation
  import StructuredQueries
  import Synchronization
  import Testing

  @testable import SQLiteOrbit

  private func makeQueueDriver() throws -> SQLiteQueue {
    try SQLiteQueue(path: ":memory:")
  }

  private func bootstrap(_ driver: SQLiteQueue) async throws {
    try await driver.write { transaction in
      try transaction.execute(
        "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
      )
    }
  }

  @Test
  func queueWritesAndReadsThroughTheDriverProtocol() async throws {
    let driver = try makeQueueDriver()
    try await bootstrap(driver)
    let database = OrbitDatabase(writer: driver)

    try await database.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "Blob's reminder") })
    }

    let items = try await database.read { transaction in
      try transaction.fetchAll(Item.all.order { $0.id })
    }
    #expect(items == [Item(id: 1, title: "Blob's reminder")])
  }

  @Test
  func accessClosuresNeedNotBeSendable() async throws {
    final class Capture {
      var value = 0
    }

    let driver = try makeQueueDriver()
    let capture = Capture()
    let value = try await driver.write { transaction in
      capture.value = 42
      try transaction.execute("CREATE TABLE marker (value INTEGER)")
      return capture.value
    }

    #expect(value == 42)
  }

  @Test
  func queueCommitsAcrossSeparateWrites() async throws {
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
  func queueRollsBackAWriteThatThrows() async throws {
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
  func queueSerializesConcurrentWrites() async throws {
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
  func queueInterleavesConcurrentReadsAndWrites() async throws {
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
  @MainActor
  func accessesRunOffTheCallersThread() async throws {
    let driver = try makeQueueDriver()

    // The driver method runs on the caller's isolation, here the main actor, but the query itself
    // hops to the connection's own queue rather than running the main thread.
    let ranOnMainThread = try await driver.read { _ in Thread.isMainThread }
    #expect(ranOnMainThread == false)
  }

  @Test
  func writesAndReadsSeeEachOtherInOrder() async throws {
    let driver = try makeQueueDriver()
    try await bootstrap(driver)

    for id in 1...20 {
      try await driver.write { transaction in
        try transaction.execute(Item.insert { Item(id: id, title: "ordered") })
      }
      let count = try await driver.read { transaction in
        try transaction.fetchAll(Item.all).count
      }
      #expect(count == id)
    }
  }

  @Test
  func queueDerivesItsIdentifierFromThePath() throws {
    let path = temporaryDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let driver = try SQLiteQueue(path: OrbitDatabasePath(path))
    #expect(driver.defaultIdentifier.rawValue.hasSuffix(".sqlite"))

    // An in-memory database is private to its connection, so no two of them are the same database.
    let first = try SQLiteQueue(path: ":memory:")
    let second = try SQLiteQueue(path: ":memory:")
    #expect(first.defaultIdentifier != second.defaultIdentifier)
  }

  @Test
  func queuePersistsToAFileAcrossDrivers() async throws {
    let path = temporaryDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
      let driver = try SQLiteQueue(path: OrbitDatabasePath(path))
      try await bootstrap(driver)
      try await driver.write { transaction in
        try transaction.execute(Item.insert { Item(id: 1, title: "persisted") })
      }
    }

    let reopened = try SQLiteQueue(path: OrbitDatabasePath(path))
    let items = try await reopened.read { transaction in
      try transaction.fetchAll(Item.all)
    }
    #expect(items == [Item(id: 1, title: "persisted")])
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

  /// SQLite reads the empty path as a database it creates for one connection and deletes when that
  /// connection closes, which is what ``OrbitDatabasePath/temporary`` names. It is a real mode, and
  /// the third thing SQLite does with a path string, so `OrbitDatabasePath("")` has somewhere to
  /// land.
  @Test
  func aTemporaryDatabaseIsUsableAndPrivateToItsConnection() async throws {
    let driver = try SQLiteQueue(path: .temporary)
    try await bootstrap(driver)
    try await driver.write { transaction in
      try transaction.execute(Item.insert { Item(id: 1, title: "scratch") })
    }
    let items = try await driver.read { transaction in
      try transaction.fetchAll(Item.all)
    }
    #expect(items == [Item(id: 1, title: "scratch")])

    // No file names it, so a second driver opens a different, empty database of its own.
    #expect(OrbitDatabasePath.temporary.fileURL == nil)
    let other = try SQLiteQueue(path: .temporary)
    #expect(other.defaultIdentifier != driver.defaultIdentifier)
    await #expect(throws: SQLiteError.self) {
      try await other.read { try $0.fetchCount(Item.all) }
    }
  }

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    var title: String
  }
#endif
