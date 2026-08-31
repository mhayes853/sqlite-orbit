#if GRDB
  import GRDB
  import SQLiteCross
  import StructuredQueries
  import Testing

  @Test
  func grdbDriverExecutesStructuredQueriesAndDecodesTables() async throws {
    let queue = try DatabaseQueue()
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: queue)
    )
    let title = "Blob's reminder"

    try await database.write { transaction in
      _ = try transaction.execute(
        #sql(
          "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)",
          as: Void.self
        )
      )
      _ = try transaction.execute(Item.insert { Item(id: 1, title: title) })
    }

    let items = try await database.read { transaction in
      try transaction.fetchAll(Item.all.order { $0.id })
    }

    #expect(items == [Item(id: 1, title: title)])

    let projections = try await database.read { transaction in
      try transaction.fetchAll(Item.select { ($0.id, $0.title) })
    }
    #expect(projections.count == 1)
    #expect(projections[0].0 == 1)
    #expect(projections[0].1 == title)
  }

  @Test
  func grdbDriverRollsBackThrownWrites() async throws {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )
    _ = try await database.write { transaction in
      try transaction.execute(
        #sql("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
      )
    }

    do {
      try await database.write { transaction in
        _ = try transaction.execute(
          Item.insert { Item(id: 1, title: "rolled back") }
        )
        throw ExpectedFailure()
      }
      Issue.record("Expected the write to throw")
    } catch is ExpectedFailure {
      // Expected.
    }

    let count = try await database.read { transaction in
      try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
    }
    #expect(count == 0)
  }

  @Test
  func grdbDriverRejectsWritesInReadTransactions() async throws {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )

    await #expect(throws: (any Error).self) {
      try await database.read { transaction in
        try transaction.execute(
          #sql("CREATE TABLE forbidden (id INTEGER)", as: Void.self)
        )
      }
    }
  }

  @Test
  func inMemoryGRDBDriversReceiveUniqueDefaultIdentifiers() throws {
    let first = GRDBDatabaseDriver(writer: try DatabaseQueue())
    let second = GRDBDatabaseDriver(writer: try DatabaseQueue())

    #expect(first.defaultIdentifier != second.defaultIdentifier)
    #expect(CrossProcessDatabase(driver: first).id == first.defaultIdentifier)
  }

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    var title: String
  }

  private struct ExpectedFailure: Error {}
#endif
