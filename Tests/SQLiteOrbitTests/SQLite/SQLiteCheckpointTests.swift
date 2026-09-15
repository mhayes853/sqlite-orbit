#if BuiltInSQLite && !Turso
  import Foundation
  import StructuredQueriesSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SQLiteCheckpointTests {
    @Test
    func aCheckpointReportsTheFramesItMovedAndATruncateEmptiesTheLog() async throws {
      let directory = try makeShortTemporaryDirectory("ckpt")
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appending(component: "database.sqlite")
      let walURL = directory.appending(component: "database.sqlite-wal")
      let pool = try SQLitePool(path: .file(url))

      try await pool.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1), (2)", as: Void.self))
      }
      #expect(try fileSize(walURL) > 0)

      let full = try await pool.writeWithoutTransaction { connection in
        try connection.checkpoint(.full, schema: .main)
      }
      // With nothing reading, every frame in the log reaches the database file.
      #expect(full.logFrameCount > 0)
      #expect(full.checkpointedFrameCount == full.logFrameCount)

      let truncate = try await pool.writeWithoutTransaction { connection in
        try connection.execute(#sql("INSERT INTO items (id) VALUES (3)", as: Void.self))
        return try connection.checkpoint(.truncate)
      }
      // The log is emptied, so what it held is counted as it stands afterwards: nothing.
      #expect(truncate == SQLiteCheckpointResult(logFrameCount: 0, checkpointedFrameCount: 0))
      #expect(try fileSize(walURL) == 0)
      let count = try await pool.read { transaction in
        try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
      }
      #expect(count == 3)
    }

    @Test
    func aPassiveCheckpointIsTheDefault() async throws {
      let directory = try makeShortTemporaryDirectory("ckpt")
      defer { try? FileManager.default.removeItem(at: directory) }
      let pool = try SQLitePool(path: .file(directory.appending(component: "database.sqlite")))
      try await pool.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }

      let result = try await pool.writeWithoutTransaction { connection in
        try connection.checkpoint()
      }

      #expect(result.logFrameCount > 0)
      #expect(result.checkpointedFrameCount == result.logFrameCount)
    }

    @Test(arguments: [SQLiteCheckpointMode.passive, .full, .restart, .truncate])
    func aDatabaseNotInWALModeHasNoLogToCheckpoint(_ mode: SQLiteCheckpointMode) async throws {
      let queue = try SQLiteQueue(path: .memory)

      let result = try await queue.writeWithoutTransaction { connection in
        try connection.checkpoint(mode, schema: .main)
      }

      #expect(result == SQLiteCheckpointResult(logFrameCount: -1, checkpointedFrameCount: -1))
    }

    @Test
    func checkpointingASchemaThatIsNotAttachedFails() async throws {
      let queue = try SQLiteQueue(path: .memory)

      await #expect(throws: SQLiteError.self) {
        try await queue.writeWithoutTransaction { connection in
          try connection.checkpoint(schema: "missing")
        }
      }
    }
  }

  private func fileSize(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.size] as? Int)
  }
#endif
