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
    defer { _ = handle.library.pointee.statement.finalize(read.pointer) }
    #expect(read.readRegion.isFullDatabase)

    let write = try handle.statements.prepare("INSERT INTO notes (title) VALUES ('hello')")
    defer { _ = handle.library.pointee.statement.finalize(write.pointer) }
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
#endif
