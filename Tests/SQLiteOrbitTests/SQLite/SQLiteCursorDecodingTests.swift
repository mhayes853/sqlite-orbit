#if SystemSQLite
  import Foundation
  import SQLiteOrbit
  import StructuredQueriesSQLite
  import Testing

  /// Tuple projections flow through the tuple cursor, including its lazy adapters and the eager
  /// `collect` the compiler cannot see through when `Element` is a pack expansion.
  @Test
  func tupleProjectionsDecodeThroughCursorsAndCollect() async throws {
    let database = try inMemoryDatabase()
    let title = "Blob's reminder"

    try await database.write { transaction in
      try transaction.execute(
        #sql("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
      )
      try transaction.execute(Item.insert { Item(id: 1, title: title) })
    }

    let uppercased = try await database.read { transaction in
      let cursor = try transaction.fetchCursor(Item.select { ($0.id, $0.title) })
      var uppercased = cursor.filter { $0.0 == 1 }.map { $0.1.uppercased() }
      return try uppercased.collect()
    }
    #expect(uppercased == [title.uppercased()])

    let tupleValues: [(Int, String)] = try await database.read { transaction in
      var cursor = try transaction.fetchCursor(Item.select { ($0.id, $0.title) })
      return try cursor.collect()
    }
    #expect(tupleValues.count == 1)
    #expect(tupleValues[0] == (1, title))
  }

  @Test
  func nativeDriverExposesTransactionScopedCursors() async throws {
    let database = try inMemoryDatabase()

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
  func nativeDriverRoundTripsDateAndUUIDBindings() async throws {
    let database = try inMemoryDatabase()
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
  func nativeDriverDecodesDatesWithoutFractionsAndUppercaseUUIDs() async throws {
    let database = try inMemoryDatabase()
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
  func nativeRowDecodesColumnsSequentiallyAndRestartsOnEachRow() async throws {
    let database = try inMemoryDatabase()

    let decoded: [(Int, String)] = try await database.read { transaction in
      var cursor = try transaction.rowCursor(
        #sql("SELECT 1, 'one' UNION ALL SELECT 2, 'two'", as: Void.self)
      )
      var decoded: [(Int, String)] = []
      while var row = try cursor.next() {
        // Two separate decodes on one row must advance through its columns rather than
        // both reading column 0.
        let id = try row.decode(Int.self)
        let title = try row.decode(String.self)
        decoded.append((id, title))
      }
      return decoded
    }

    #expect(decoded.count == 2)
    #expect(decoded[0].0 == 1)
    #expect(decoded[0].1 == "one")
    #expect(decoded[1].0 == 2)
    #expect(decoded[1].1 == "two")
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

#endif
