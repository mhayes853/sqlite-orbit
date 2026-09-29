#if BuiltInSQLite && !Turso
  import Foundation
  import StructuredQueriesSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SQLiteWALCheckpointTests {
    @Test
    func aCheckpointReportsTheFramesItMovedAndATruncateEmptiesTheLog() async throws {
      try await withTestDatabaseFile("ckpt") { file in
        let walURL = file.directory.appending(component: "database.sqlite-wal")
        let pool = try file.pool()

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
        #expect(truncate == SQLiteWALCheckpointResult(logFrameCount: 0, checkpointedFrameCount: 0))
        #expect(try fileSize(walURL) == 0)
        let count = try await pool.read { transaction in
          try transaction.fetchOne(#sql("SELECT count(*) FROM items", as: Int.self))
        }
        #expect(count == 3)
      }
    }

    @Test
    func aPassiveCheckpointIsTheDefault() async throws {
      try await withTestDatabaseFile("ckpt") { file in
        let pool = try file.pool()
        try await pool.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }

        let result = try await pool.writeWithoutTransaction { connection in
          try connection.checkpoint()
        }

        #expect(result.logFrameCount > 0)
        #expect(result.checkpointedFrameCount == result.logFrameCount)
      }
    }

    @Test(arguments: [SQLiteWALCheckpointMode.passive, .full, .restart, .truncate])
    func aDatabaseNotInWALModeHasNoLogToCheckpoint(_ mode: SQLiteWALCheckpointMode) async throws {
      let queue = try SQLiteQueue(path: .memory)

      let result = try await queue.writeWithoutTransaction { connection in
        try connection.checkpoint(mode, schema: .main)
      }

      #expect(result == SQLiteWALCheckpointResult(logFrameCount: -1, checkpointedFrameCount: -1))
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
