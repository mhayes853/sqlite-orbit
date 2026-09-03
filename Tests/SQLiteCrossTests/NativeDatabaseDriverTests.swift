#if SystemSQLite
  import Foundation
  import SQLiteCross
  import StructuredQueriesSQLite
  import Testing

  @Test
  func nativeDriverExecutesStructuredQueriesAndDecodesTables() async throws {
    let queue = try SQLiteQueueDriver(path: ":memory:")
    let database = CrossProcessDatabase(
      driver: queue
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

    let transformedTitles = try await database.read { transaction in
      let cursor = try transaction.fetchCursor(Item.select { ($0.id, $0.title) })
      var transformedCursor =
        cursor
        .filter { $0.0 == 1 }
        .map { $0.1.uppercased() }
      var transformedTitles: [String] = []
      try transformedCursor.forEach { title in
        transformedTitles.append(title)
      }
      return transformedTitles
    }
    #expect(transformedTitles == [title.uppercased()])

    let tupleValues: [(Int, String)] = try await database.read { transaction in
      let cursor = try transaction.fetchCursor(Item.select { ($0.id, $0.title) })
      return try cursor.collect()
    }
    #expect(tupleValues.count == 1)
    #expect(tupleValues[0].0 == 1)
    #expect(tupleValues[0].1 == title)
  }

  @Test
  func nativeDriverExposesTransactionScopedCursors() async throws {
    let database = CrossProcessDatabase(
      driver: try SQLiteQueueDriver(path: ":memory:")
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
  func nativeDriverRoundTripsDateAndUUIDBindings() async throws {
    let database = CrossProcessDatabase(
      driver: try SQLiteQueueDriver(path: ":memory:")
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
  func nativeDriverDecodesDatesWithoutFractionsAndUppercaseUUIDs() async throws {
    let database = CrossProcessDatabase(
      driver: try SQLiteQueueDriver(path: ":memory:")
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
  func nativeDriverRollsBackThrownWrites() async throws {
    let database = CrossProcessDatabase(
      driver: try SQLiteQueueDriver(path: ":memory:")
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
  func inMemoryNativeDriversReceiveUniqueDefaultIdentifiers() throws {
    let first = try SQLiteQueueDriver(path: ":memory:")
    let second = try SQLiteQueueDriver(path: ":memory:")

    #expect(first.defaultIdentifier != second.defaultIdentifier)
    #expect(CrossProcessDatabase(driver: first).id == first.defaultIdentifier)
  }

  @Test
  func fileNativeDriversUseTheirStandardizedPathAsTheDefaultIdentifier() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .path
    defer { try? FileManager.default.removeItem(atPath: path) }

    let driver = try SQLiteQueueDriver(path: DatabasePath(path))

    #expect(
      driver.defaultIdentifier.rawValue
        == URL(fileURLWithPath: path).standardizedFileURL.path
    )
  }

  @Test
  func nativeRowDecodesColumnsSequentiallyAndRestartsOnEachRow() async throws {
    let database = CrossProcessDatabase(
      driver: try SQLiteQueueDriver(path: ":memory:")
    )

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

  @Test
  func crossProcessDatabaseCanBeConstructedFromNativeWriter() throws {
    let writer = try SQLiteQueueDriver(path: ":memory:")
    let database = CrossProcessDatabase(driver: writer)
    let override = DatabaseIdentifier(rawValue: "override")
    let overriddenDatabase = CrossProcessDatabase(driver: writer, id: override)

    #expect(database.id == database.driver.defaultIdentifier)
    #expect(overriddenDatabase.id == override)
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
