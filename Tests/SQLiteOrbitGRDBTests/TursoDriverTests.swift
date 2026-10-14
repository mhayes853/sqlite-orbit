#if Turso
  import Foundation
  import SQLiteOrbit
  import SQLiteOrbitGRDB
  import Testing

  @Suite("GRDB Turso driver", .timeLimit(.minutes(1)))
  struct GRDBTursoDriverTests {
    @Test func directAccessRecordsMigrationsAndObservation() async throws {
      struct Item: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
        let id: Int64
        let name: String
      }
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"
      )
      defer { try? FileManager.default.removeItem(at: file) }
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
    }
  }
#endif
