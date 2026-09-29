#if BuiltInSQLite && !Turso
  import Foundation
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
          try transaction.execute("INSERT INTO items (id) VALUES (1), (2)")
        }
        #expect(try fileSize(walURL) > 0)

        let full = try await pool.writeWithoutTransaction { connection in
          try connection.checkpoint(.full, schema: .main)
        }
        // With nothing reading, every frame in the log reaches the database file.
        #expect(full.logFrameCount > 0)
        #expect(full.checkpointedFrameCount == full.logFrameCount)

        let truncate = try await pool.writeWithoutTransaction { connection in
          try connection.execute("INSERT INTO items (id) VALUES (3)")
          return try connection.checkpoint(.truncate)
        }
        // The log is emptied, so what it held is counted as it stands afterwards: nothing.
        #expect(truncate == SQLiteWALCheckpointResult(logFrameCount: 0, checkpointedFrameCount: 0))
        #expect(try fileSize(walURL) == 0)
        let count = try await pool.read { transaction in
          try transaction.fetchOne("SELECT count(*) FROM items", as: Int.self)
        }
        #expect(count == 3)
      }
    }

    @Test
    func aPassiveCheckpointIsTheDefault() async throws {
      try await withTestDatabaseFile("ckpt") { file in
        let calls = TestRecorder<(String?, Int32)>()
        let base = builtInTestLibrary
        var configuration = SQLiteConfiguration.default
        configuration.library.connections.walCheckpoint = { connection, schema, mode, log, moved in
          calls.append((schema.map { String(cString: $0) }, mode))
          return base.connections.walCheckpoint(connection, schema, mode, log, moved)
        }
        let pool = try file.pool(configuration: configuration)
        try await pool.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }

        let result = try await pool.writeWithoutTransaction { connection in
          try connection.checkpoint()
        }

        let call = try #require(calls.values.first)
        #expect(calls.count == 1)
        #expect(call.0 == nil)
        #expect(call.1 == 0)  // SQLITE_CHECKPOINT_PASSIVE
        #expect(result.logFrameCount > 0)
        #expect(result.checkpointedFrameCount == result.logFrameCount)
        for (mode, rawValue) in [
          (SQLiteWALCheckpointMode.passive, Int32(0)), (.full, 1), (.restart, 2), (.truncate, 3)
        ] {
          calls.removeAll()
          _ = try await pool.writeWithoutTransaction { try $0.checkpoint(mode, schema: .main) }
          let forwarded = try #require(calls.values.first)
          #expect(calls.count == 1)
          #expect(forwarded.0 == "main")
          #expect(forwarded.1 == rawValue)
        }
      }
    }

    @Test(arguments: [SQLiteWALCheckpointMode.full, .restart, .truncate])
    func aHeldSnapshotAllowsPartialPassiveProgressButMakesBlockingCheckpointsBusy(
      mode: SQLiteWALCheckpointMode
    ) async throws {
      try await withTestDatabaseFile("checkpoint-reader") { file in
        var configuration = SQLiteConfiguration.default
        configuration.busyTimeout = .limit(.zero)
        let writer = try file.pool(configuration: configuration)
        let reader = try file.queue(configuration: configuration)
        try await writer.write {
          try $0.executeScript(
            "CREATE TABLE items (id INTEGER PRIMARY KEY); INSERT INTO items VALUES (1)"
          )
        }
        let gate = TestGate()
        defer { gate.open() }
        let snapshot = Task {
          try await reader.read { transaction in
            #expect(try transaction.fetchOne("SELECT count(*) FROM items", as: Int.self) == 1)
            try gate.enter()
            #expect(try transaction.fetchOne("SELECT count(*) FROM items", as: Int.self) == 1)
          }
        }
        defer { snapshot.cancel() }
        try await gate.waitUntilEntered()
        try await writer.write { try $0.execute("INSERT INTO items VALUES (2)") }
        let passive = try await writer.writeWithoutTransaction { try $0.checkpoint() }
        #expect(passive.logFrameCount > passive.checkpointedFrameCount)
        #expect(passive.checkpointedFrameCount >= 0)
        let error = await #expect(throws: SQLiteError.self) {
          try await writer.writeWithoutTransaction { try $0.checkpoint(mode, schema: .main) }
        }
        #expect(error?.isBusy == true)
        gate.open()
        try await snapshot.value
        let completed = try await writer.writeWithoutTransaction {
          try $0.checkpoint(mode, schema: .main)
        }
        #expect(completed.logFrameCount == completed.checkpointedFrameCount)
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
