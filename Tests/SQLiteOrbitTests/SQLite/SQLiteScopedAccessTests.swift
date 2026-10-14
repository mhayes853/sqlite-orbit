#if BuiltInSQLite
  import Dispatch
  import Foundation
  import SQLiteOrbit
  import Testing

  @Suite(.timeLimit(.minutes(1)))
  struct SQLiteScopedAccessTests {
    @Test func ownedRowsAndStatementMetadata() throws {
      let database = try SQLiteQueue(path: .memory)
      try database.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)")
        try transaction.execute("INSERT INTO items VALUES (1, 'a'), (2, 'b')")
      }
      try database.readBlocking { transaction in
        try transaction.withScopedAccess { (access: SQLiteScopedAccess) throws in
          let info = try access.statementInfo("SELECT id, name FROM items WHERE id > ?3")
          #expect(info.columnNames == ["id", "name"])
          #expect(info.parameterCount == 3)
          #expect(info.isReadOnly)
          #expect(info.changedRegion.isEmpty)
          #expect(info.readRegion == (try access.region(for: "SELECT id, name FROM items")))
          let cursor = try access.statementCursor(
            "SELECT id, name FROM items ORDER BY id",
            cached: true
          )
          let first = try #require(try cursor.next())
          #expect(first.map(\.name) == ["id", "name"])
          #expect(try cursor.next()?[0].value == .integer(2))
          #expect(first[0].value == .integer(1))
          try cursor.close()
          #expect(try cursor.next() == nil)
          let error = #expect(throws: SQLiteError.self) {
            _ = try access.statementCursor("DELETE FROM items")
          }
          #expect(error?.code == .readOnly)
          try access.withConnectionAccess { raw in
            try raw.withScopedAccess { nested in
              let error = #expect(throws: SQLiteError.self) {
                try nested.notifyChanges(in: .fullDatabase)
              }
              #expect(error?.code == .readOnly)
            }
          }
        }
      }
    }

    @Test func expiredViewsAndCursorsRefuseAccess() throws {
      var owner = try SQLiteConnection(path: .memory, configuration: .default)
      let (access, cursor) = try owner.withReadConnection { connection in
        try connection.withScopedAccess { access in
          (access, try access.statementCursor("SELECT 1"))
        }
      }
      #expect(throws: SQLiteError.self) { try access.checkAccess() }
      #expect(throws: SQLiteError.self) { try access.sqliteConnection }
      #expect(throws: SQLiteError.self) { try access.configuration }
      #expect(throws: SQLiteError.self) { try access.changesCount }
      #expect(throws: SQLiteError.self) { try access.lastInsertedRowID }
      #expect(throws: SQLiteError.self) { try access.isInsideTransaction }
      #expect(throws: SQLiteError.self) { try access.statementInfo("SELECT 1") }
      #expect(throws: SQLiteError.self) { try access.region(for: "SELECT 1") }
      #expect(throws: SQLiteError.self) { try access.notifyReads(in: .fullDatabase) }
      #expect(throws: SQLiteError.self) { try access.notifyChanges(in: .fullDatabase) }
      #expect(throws: SQLiteError.self) { try access.firstStatement("SELECT 1") }
      #expect(throws: SQLiteError.self) { try access.withConnectionAccess { _ in } }
      #expect(throws: SQLiteError.self) { try access.transaction { _ in } }
      #expect(throws: SQLiteError.self) { try cursor.next() }
      #expect(throws: SQLiteError.self) { try cursor.close() }
      #expect(try owner.withReadConnection { try $0.fetchOne("SELECT 2", as: Int.self) } == 2)
    }

    @Test(arguments: [SQLiteWriteTransactionMode.deferred, .immediate, .exclusive])
    func managedTransactionsCommitAndRollBack(mode: SQLiteWriteTransactionMode) throws {
      enum Rollback: Error { case requested }
      let database = try SQLiteQueue(path: .memory)
      try database.writeWithoutTransactionBlocking { connection in
        try connection.withScopedAccess { access in
          let create = try access.statementCursor("CREATE TABLE items(id INTEGER PRIMARY KEY)")
          _ = try create.next()
          let result = try access.transaction(mode: mode) { transaction in
            let insert = try transaction.statementCursor("INSERT INTO items VALUES (1)")
            _ = try insert.next()
            #expect(try transaction.isInsideTransaction)
            return try transaction.lastInsertedRowID
          }
          #expect(result == 1)
          #expect(throws: Rollback.requested) {
            try access.transaction(mode: mode) { transaction in
              _ = try transaction.statementCursor("INSERT INTO items VALUES (2)").next()
              throw Rollback.requested
            }
          }
          #expect(!(try access.isInsideTransaction))
        }
      }
      #expect(
        try database.readBlocking { try $0.fetchAll("SELECT id FROM items", as: Int.self) } == [1]
      )
    }

    @Test func anotherThreadCannotUseTheView() throws {
      let database = try SQLiteQueue(path: .memory)
      try database.readBlocking { transaction in
        try transaction.withScopedAccess { (access: SQLiteScopedAccess) throws in
          let transfer = AccessTransfer(access: access)
          let completed = DispatchSemaphore(value: 0)
          Thread {
            defer { completed.signal() }
            do { _ = try transfer.access.statementCursor("SELECT 1") } catch let error
              as SQLiteError
            { transfer.error = error } catch {}
          }
          .start()
          completed.wait()
          #expect(transfer.error?.code == .misuse)
          #expect(try access.statementCursor("SELECT 1").next()?[0].value == .integer(1))
        }
      }
    }

    @Test func explicitRegionsResolveOncePerRuntime() async throws {
      let database = try SQLiteQueue(path: .memory)
      try await database.write { transaction in
        try transaction.executeScript("CREATE TABLE items(id); INSERT INTO items VALUES (1)")
      }
      let resolutions = ResolutionCounter()
      func makeObservation() -> OrbitValueObservation<Int> {
        OrbitValueObservation.tracking(
          region: { transaction in
            resolutions.increment()
            return try OrbitDatabaseRegion("SELECT id FROM items", in: transaction)
          },
          { try $0.fetchOne("SELECT count(*) FROM items", as: Int.self)! }
        )
      }
      let observation = makeObservation()
      let values = observation.values(in: database)
      #expect(resolutions.value == 0)
      var first = values.makeAsyncIterator()
      #expect(try await first.next() == 1)
      try await database.write { try $0.execute("INSERT INTO items VALUES (2)") }
      #expect(try await first.next() == 2)
      #expect(resolutions.value == 1)
      var second = values.makeAsyncIterator()
      #expect(try await second.next() == 2)
      #expect(resolutions.value == 1)
      let separate = makeObservation()
      #expect(separate.identity != observation.identity)
      var third = separate.values(in: database).makeAsyncIterator()
      #expect(try await third.next() == 2)
      #expect(resolutions.value == 2)
    }

    @Test func driverMetadataIsAvailableWithoutBorrowingAConnection() throws {
      let queue = try SQLiteQueue(path: .memory)
      let metadata = try #require((queue as any OrbitDatabaseReader).databaseMetadata)
      #expect(metadata.path == .memory)
      #expect(metadata.readerCount == 1)
      #expect(metadata.configuration.isForeignKeysEnabled)
      var configurationCopy = metadata.configuration
      configurationCopy.isForeignKeysEnabled = false
      #expect(queue.databaseMetadata?.configuration.isForeignKeysEnabled == true)
      #expect(queue.readerCount == 1)
      let customSnapshot = SQLiteDatabaseMetadata(path: .memory, configuration: configurationCopy)
      #expect(customSnapshot.readerCount == 1)
      #expect(!customSnapshot.configuration.isForeignKeysEnabled)
      try withTemporaryDirectory("metadata") { directory in
        var configuration = SQLiteConfiguration.default
        configuration.isForeignKeysEnabled = false
        let pool = try SQLitePool(
          path: .file(directory.appendingPathComponent("db.sqlite")),
          configuration: configuration,
          readerCount: 2
        )
        let database = OrbitIPCDatabase(
          writer: pool,
          transport: InMemoryIPCTransport(network: .init())
        )
        let forwarded = try #require((database as any OrbitDatabaseReader).databaseMetadata)
        let poolMetadata = try #require((pool as any OrbitDatabaseReader).databaseMetadata)
        #expect(poolMetadata.path == forwarded.path)
        #expect(poolMetadata.readerCount == forwarded.readerCount)
        #expect(forwarded.path == pool.path)
        #expect(forwarded.readerCount == 2)
        #expect(!forwarded.configuration.isForeignKeysEnabled)
      }
    }

    @Test func nestedViewsAndRawChangesUseTheParentObservation() throws {
      let database = try SQLiteQueue(path: .memory)
      try database.writeBlocking { try $0.execute("CREATE TABLE items(id)") }
      let recorder = OrbitDatabaseRegionRecorder()
      try database.writeWithoutTransactionBlocking { connection in
        try connection.withObservation(recorder) {
          try connection.withScopedAccess { access in
            try access.withConnectionAccess { raw in
              try raw.withScopedAccess { nested in
                _ = try nested.statementCursor("INSERT INTO items VALUES (1)").next()
                _ = try nested.statementCursor("SELECT id FROM items").next()
              }
              try raw.execute("INSERT INTO items VALUES (2)")
            }
            try access.notifyChanges(in: OrbitDatabaseRegion(table: "items"))
          }
        }
      }
      #expect(!recorder.readRegion.isEmpty)
      #expect(!recorder.changedRegion.isEmpty)
      #expect(recorder.hasCommitted)
      #expect(!recorder.committedRegion.isEmpty)
      #expect(
        try database.readBlocking { try $0.fetchAll("SELECT id FROM items", as: Int.self) } == [
          1, 2
        ]
      )
    }
  }

  // The background thread writes the error before signalling, and the caller reads it only after
  // the semaphore wait. The transferred access deliberately checks and rejects that thread.
  private final class AccessTransfer: @unchecked Sendable {
    let access: SQLiteScopedAccess
    var error: SQLiteError?
    init(access: SQLiteScopedAccess) { self.access = access }
  }

  private final class ResolutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
      lock.lock()
      defer { lock.unlock() }
      count += 1
    }
    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
  }
#endif
