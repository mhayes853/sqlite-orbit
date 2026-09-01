#if GRDB
  import GRDB
  import SQLiteCross
  import Testing

  @Test
  func typeMismatchesNameTheColumnAndWhatWasStored() async throws {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )

    let error = await #expect(throws: DatabaseColumnDecodingError.self) {
      try await database.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT 1 AS id, 'not a number' AS quantity", as: (Int, Int).self)
        )
      }
    }

    #expect(error?.columnIndex == 1)
    #expect(error?.columnName == "quantity")
    // `Int` reads through SQLite's 64-bit integer accessor, so that is the type asked for.
    #expect(error?.reason == "to decode Int64, but found TEXT")
    #expect(error?.sql.contains("not a number") == true)
  }

  @Test
  func missingRequiredColumnsNameTheColumnThatWasNull() async throws {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )

    let error = await #expect(throws: DatabaseColumnDecodingError.self) {
      try await database.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT 1 AS id, NULL AS title", as: (Int, String).self)
        )
      }
    }

    #expect(error?.columnIndex == 1)
    #expect(error?.columnName == "title")
    #expect(error?.reason == "to not be NULL")
  }
#endif
