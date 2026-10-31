#if Turso
  import Foundation
  import SQLiteOrbit
  import SQLiteOrbitGRDB
  import Testing

  @Suite("GRDB Turso driver", .timeLimit(.minutes(1)))
  struct GRDBTursoDriverTests {
    @Test
    func directAccessRecordsMigrationsAndObservation() async throws {
      struct Item: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
        let id: Int64
        let name: String
      }

      let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"
      )
      defer {
        try? FileManager.default.removeItem(at: file)
      }
      let database = try TursoPool(path: OrbitDatabasePath(file.path))
      let metadata = try #require((database as any OrbitDatabaseReader).databaseMetadata)
      #expect(metadata.path == OrbitDatabasePath(file.path))
      #expect(metadata.readerCount == 5)
      var migrator = DatabaseMigrator()
      migrator.registerMigration("create", foreignKeyChecks: .immediate) {
        try $0.execute(sql: "CREATE TABLE item(id INTEGER PRIMARY KEY, name TEXT)")
      }
      try await migrator.migrate(database)
      var iterator = ValueObservation.tracking { try Item.fetchAll($0) }.values(in: database)
        .makeAsyncIterator()
      #expect(try await iterator.next() == [])
      try await database.write { try Item(id: 1, name: "Turso").insert($0) }
      #expect(try await iterator.next() == [Item(id: 1, name: "Turso")])
      #expect(database.path == file.path)
      let stored = try await database.write { db in
        try Item(id: 1, name: "Updated").upsertAndFetch(db)
      }
      #expect(stored == Item(id: 1, name: "Updated"))
      let names = try await database.read { db in
        try String.fetchSet(db, Table<Item>("item").select(Column("name")))
      }
      #expect(names == ["Updated"])
      let ids = try await database.read { db in
        try Table<SQLiteOrbitGRDB.Row>("item").all()
          .filterWhenConnected { _ in Column("name") == "Updated" }
          .orderByPrimaryKey().reversed().selectPrimaryKey(as: Int64.self).fetchAll(db)
      }
      #expect(ids == [1])
      let changed = try await database.write { db in
        try Item(id: 1, name: "Final").updateChanges(db, from: stored)
      }
      #expect(changed)
      let statementNames = try await database.read { db in
        try Set(String.fetchCursor(db.cachedStatement(literal: "SELECT name FROM item")))
      }
      #expect(statementNames == ["Final"])
    }
  }
#endif
