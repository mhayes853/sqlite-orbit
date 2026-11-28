#if BuiltInSQLite
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SQLiteDatabaseMetadataTests {
    @Test
    func aQueueReportsItsPathAndConfigurationAndOneReader() throws {
      var configuration = SQLiteConfiguration.default
      configuration.setups = [.sql("PRAGMA cache_size = 100")]
      let queue = try SQLiteQueue(path: .memory, configuration: configuration)

      #expect(queue.metadata.path == .memory)
      #expect(queue.metadata.path == queue.path)
      #expect(queue.metadata.configuration.setups.count == 1)
      #expect(queue.metadata.readerCount == 1)
    }

    @Test
    func aPoolReportsTheConfigurationItWasGivenRatherThanTheWALModeItSwitchesTo() async throws {
      try await withTestDatabaseFile("metadata") { file in
        var configuration = SQLiteConfiguration.default
        configuration.setups = [.sql("PRAGMA cache_size = 100")]
        let pool = try file.pool(configuration: configuration, readerCount: 3)
        let mode = try await pool.readWithoutTransaction { connection in
          try connection.fetchOne("SELECT * FROM pragma_journal_mode") { $0[0].textValue ?? "" }
        }

        #expect(mode == "wal")
        #expect(pool.metadata.path == file.path)
        #expect(pool.metadata.path == pool.path)
        #expect(pool.metadata.configuration.journalMode == nil)
        #expect(pool.metadata.configuration.setups.count == 1)
        #expect(pool.metadata.readerCount == 3)
      }
    }

    @Test
    func anIPCDatabaseReportsItsNativeDriversMetadata() throws {
      let queue = try SQLiteQueue(path: .memory)
      let database = OrbitIPCDatabase(writer: queue, transport: InMemoryIPCTransport())

      let metadata = try #require(database.metadata)
      #expect(metadata.path == .memory)
      #expect(metadata.readerCount == 1)
    }

    #if canImport(Darwin) || os(Linux) || os(Android)
      @Test
      func anIPCDatabaseOpenedByPathReportsItsPoolsMetadata() throws {
        try withTestDatabaseFile("metadata") { file in
          let database = try file.ipcDatabase()

          let metadata = try #require(database.metadata)
          #expect(metadata.path == file.path)
          #expect(metadata.readerCount == 5)
        }
      }
    #endif

    @Test
    func anIPCDatabaseOverACustomWriterHasNoMetadata() throws {
      let writer = AnnouncingTestDatabase(try SQLiteQueue(path: .memory))
      let database = OrbitIPCDatabase(writer: writer, transport: InMemoryIPCTransport())

      #expect(database.metadata == nil)
    }
  }
#endif
