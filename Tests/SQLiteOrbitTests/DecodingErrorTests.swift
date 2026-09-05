#if SystemSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  @Test
  func typeMismatchesNameTheColumnAndWhatWasStored() async throws {
    let database = try inMemoryDatabase()

    let error = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
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
    let database = try inMemoryDatabase()

    let error = await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
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

  @Test
  func valueLevelFailuresAreReportedAsThemselves() async throws {
    let database = try inMemoryDatabase()

    // The column has the right storage class but the wrong contents. These are not the column
    // errors above, because the decoder already knows exactly what went wrong.
    let uuid = await #expect(throws: (any Error).self) {
      try await database.read { transaction in
        try transaction.fetchOne(#sql("SELECT 'not a uuid'", as: UUID.self))
      }
    }
    #expect(!(uuid is OrbitDatabaseColumnDecodingError))

    let date = await #expect(throws: (any Error).self) {
      try await database.read { transaction in
        try transaction.fetchOne(#sql("SELECT 'not a date'", as: Date.self))
      }
    }
    #expect(!(date is OrbitDatabaseColumnDecodingError))

    let negative = await #expect(throws: (any Error).self) {
      try await database.read { transaction in
        try transaction.fetchOne(#sql("SELECT -1", as: UInt64.self))
      }
    }
    #expect(!(negative is OrbitDatabaseColumnDecodingError))
  }
#endif
