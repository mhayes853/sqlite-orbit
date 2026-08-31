#if GRDB
  import Foundation
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
  func grdbDriverExposesTransactionScopedCursors() async throws {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )

    let readValues = try await database.read { transaction in
      var cursor = try transaction.fetchCursor(
        #sql("SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3", as: Int.self)
      )
      var values: [Int] = []
      while let value = try cursor.next() {
        values.append(value)
      }
      return values
    }

    let writeValues = try await database.write { transaction in
      var cursor = try transaction.executeCursor(
        #sql("SELECT 4 UNION ALL SELECT 5", as: Int.self)
      )
      var values: [Int] = []
      while let value = try cursor.next() {
        values.append(value)
      }
      return values
    }

    #expect(readValues == [1, 2, 3])
    #expect(writeValues == [4, 5])
  }

  @Test
  func grdbDriverRoundTripsDateAndUUIDBindings() async throws {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )
    let value = SpecialValue(
      id: 1,
      occurredAt: Date(timeIntervalSince1970: 1_725_000_000.125),
      token: UUID(uuidString: "deadbeef-cafe-babe-0123-456789abcdef")!
    )

    try await database.write { transaction in
      try transaction.execute(
        #sql(
          """
          CREATE TABLE special_values (
            id INTEGER PRIMARY KEY,
            occurredAt TEXT NOT NULL,
            token TEXT NOT NULL
          )
          """,
          as: Void.self
        )
      )
      try transaction.execute(SpecialValue.insert { value })
    }

    let decoded = try await database.read { transaction in
      try transaction.fetchOne(SpecialValue.all)
    }
    #expect(decoded == value)
  }

  @Test
  func grdbDriverDecodesDatesWithoutFractionsAndUppercaseUUIDs() async throws {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )
    let timestamp = "2024-01-02 03:04:05"
    let uuid = "DEADBEEF-CAFE-BABE-0123-456789ABCDEF"

    let decoded: (Date, UUID)? = try await database.read { transaction in
      try transaction.fetchOne(
        #sql(
          "SELECT \(timestamp, as: String.self), \(uuid, as: String.self)",
          as: (Date, UUID).self
        )
      )
    }

    #expect(decoded?.0.timeIntervalSince1970 == 1_704_164_645)
    #expect(decoded?.1 == UUID(uuidString: uuid))
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

  @Table("special_values")
  private struct SpecialValue: Equatable, Sendable {
    let id: Int
    var occurredAt: Date
    var token: UUID
  }

  private struct ExpectedFailure: Error {}
#endif
