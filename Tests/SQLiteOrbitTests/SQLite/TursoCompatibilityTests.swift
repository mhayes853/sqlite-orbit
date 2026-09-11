#if Turso
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @DatabaseCollation
  private func tursoTestCollation(_ lhs: String, _ rhs: String) -> CollationOrder {
    CollationOrder(lhs, rhs)
  }

  @Test
  func tursoRunsBasicQueueTransactions() async throws {
    #expect(SQLiteConfiguration.default.library.name == "Turso")
    #expect(SQLiteConfiguration.default.isTrustedSchemaEnabled)

    let database = try inMemoryDatabase()
    try await database.write { transaction in
      try transaction.execute(
        #sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
      )
      try transaction.execute(
        #sql("INSERT INTO notes (id, title) VALUES (1, 'hello')", as: Void.self)
      )
    }

    let titles = try await database.read { transaction in
      try transaction.fetchAll(#sql("SELECT title FROM notes", as: String.self))
    }
    #expect(titles == ["hello"])
  }

  @Test
  func tursoRunsAPoolConfinedToOneProcess() async throws {
    let path = OrbitDatabasePath(temporaryDatabasePath("turso-local"))
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path.sqlitePath + suffix)
      }
    }

    let database = try OrbitDatabase<SQLitePool>(localPath: path)
    try await database.write { transaction in
      try transaction.execute(
        #sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
      )
      try transaction.execute(
        #sql("INSERT INTO notes (id, title) VALUES (1, 'pooled')", as: Void.self)
      )
    }
    let titles = try await database.read { transaction in
      try transaction.fetchAll(#sql("SELECT title FROM notes", as: String.self))
    }
    #expect(titles == ["pooled"])
  }

  @Test
  func tursoUsesWholeDatabaseRegionsWithoutAnAuthorizer() throws {
    let handle = try SQLiteHandle.open(
      path: .memory,
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: .turso
    )
    try handle.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")

    let read = try handle.statements.prepare("SELECT title FROM notes")
    defer { _ = handle.library.pointee.statements.execution.finalize(read.pointer) }
    #expect(read.readRegion.isFullDatabase)

    let write = try handle.statements.prepare("INSERT INTO notes (title) VALUES ('hello')")
    defer { _ = handle.library.pointee.statements.execution.finalize(write.pointer) }
    #expect(write.changedRegion.isFullDatabase)
    #expect(write.invalidatesStatementCache)
  }

  @Test
  func tursoRefusesWritesPassedThroughAReadTransaction() throws {
    let handle = try SQLiteHandle.open(
      path: .memory,
      flags: [.readWrite, .create, .memory, .noMutex],
      configuration: .turso
    )
    try handle.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY)")

    #expect(throws: SQLiteError.self) {
      try handle.read { transaction in
        try transaction.fetchAll(
          #sql("INSERT INTO notes DEFAULT VALUES RETURNING id", as: Int.self)
        )
      }
    }
  }

  @Test
  func tursoReportsFeaturesItCannotProvide() {
    var hardened = SQLiteConfiguration.turso
    hardened.isTrustedSchemaEnabled = false
    #expect(throws: SQLiteFeatureUnavailableError.self) {
      _ = try SQLiteQueue(path: .memory, configuration: hardened)
    }

    var withCollation = SQLiteConfiguration.turso
    withCollation.register(collation: $tursoTestCollation)
    #expect(throws: SQLiteFeatureUnavailableError.self) {
      _ = try SQLiteQueue(path: .memory, configuration: withCollation)
    }

    #if canImport(Darwin) || canImport(Glibc)
      #expect(throws: SQLiteFeatureUnavailableError.self) {
        _ = try OrbitDatabase<SQLitePool>(path: "/tmp/turso-multiprocess.sqlite")
      }
    #endif
  }

  @Test
  func tursoRefusesToCheckForeignKeysRatherThanReportNoViolations() async throws {
    #expect(!SQLiteLibrary.turso.isForeignKeyCheckAvailable)
    let expected = SQLiteFeatureUnavailableError(libraryName: "Turso", feature: .foreignKeyCheck)
    #expect(expected.description == "Turso does not support SQLite's foreign key checks.")

    // Turso answers `PRAGMA foreign_key_check` with no rows, even for a row that refers to
    // nothing, which is what an empty result would wrongly vouch for.
    let driver = try SQLiteQueue(path: .memory)
    try await driver.writeWithoutTransaction { connection in
      connection.isForeignKeysEnabled = false
      try connection.execute(
        """
        CREATE TABLE lists (id INTEGER PRIMARY KEY);
        CREATE TABLE reminders (id INTEGER PRIMARY KEY, listID INTEGER REFERENCES lists (id));
        INSERT INTO reminders VALUES (1, 7);
        """
      )
    }

    let fromTransaction = await #expect(throws: SQLiteFeatureUnavailableError.self) {
      try await driver.read { try $0.foreignKeyViolations() }
    }
    let fromWrite = await #expect(throws: SQLiteFeatureUnavailableError.self) {
      try await driver.write { try $0.foreignKeyViolations() }
    }
    let fromConnection = await #expect(throws: SQLiteFeatureUnavailableError.self) {
      try await driver.readWithoutTransaction { try $0.foreignKeyViolations() }
    }
    let fromWriteConnection = await #expect(throws: SQLiteFeatureUnavailableError.self) {
      try await driver.writeWithoutTransaction { try $0.foreignKeyViolations() }
    }
    #expect(fromTransaction == expected)
    #expect(fromWrite == expected)
    #expect(fromConnection == expected)
    #expect(fromWriteConnection == expected)
  }
#endif
