#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import Dispatch
    import Foundation
    import StructuredQueries
    import Testing

    @testable import SQLiteOrbit

    /// What every SQLite driver promises, whether it has one connection or a pool of them.
    @Suite
    struct SQLiteDriverTests {
      @Test(arguments: SQLiteTestDriver.allCases)
      func aWriteThatThrowsIsRolledBackAndLeavesNoTransactionOpen(
        _ driver: SQLiteTestDriver
      ) async throws {
        try await driver.withDatabase(schema: itemsSchema) { database in
          await #expect(throws: TestError()) {
            try await database.write { transaction in
              try transaction.execute(Item.insert { Item(id: 1, title: "doomed") })
              throw TestError()
            }
          }
          #expect(try await database.read { try $0.fetchAll(Item.all) }.isEmpty)

          // The rolled-back transaction did not leave one open behind it.
          try await database.write { transaction in
            try transaction.execute(Item.insert { Item(id: 2, title: "after") })
          }
          #expect(
            try await database.read { try $0.fetchAll(Item.all) } == [Item(id: 2, title: "after")]
          )
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      @MainActor
      func accessesRunOffTheCallersThread(_ driver: SQLiteTestDriver) async throws {
        try await driver.withDatabase { database in
          // The driver method runs on the caller's isolation, here the main actor, but the query
          // itself hops to a connection's own thread rather than running on the main thread.
          let readOnMain = try await database.read { _ in Thread.isMainThread }
          let wroteOnMain = try await database.write { _ in Thread.isMainThread }
          #expect(!readOnMain)
          #expect(!wroteOnMain)
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func concurrentWritesAndReadsFromManyTasksAllCommit(_ driver: SQLiteTestDriver) async throws {
        try await driver.withDatabase(readerCount: 4, schema: itemsSchema) {
          database in
          let count = 300
          _ = try await concurrently(2 * count) { index in
            if index.isMultiple(of: 2) {
              try await database.write { transaction in
                try transaction.execute(Item.insert { Item(id: index, title: "contended") })
              }
            } else {
              _ = try await database.read { try $0.fetchAll(Item.all).count }
            }
          }
          #expect(try await database.rowCount(of: "items") == count)
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func eachReadSeesEveryWriteCommittedBeforeIt(_ driver: SQLiteTestDriver) async throws {
        try await driver.withDatabase(schema: itemsSchema) { database in
          for id in 1...20 {
            try await database.write { transaction in
              try transaction.execute(Item.insert { Item(id: id, title: "ordered") })
            }
            #expect(try await database.rowCount(of: "items") == id)
            // A blocking read, on whichever connection it is lent, sees the write too.
            let blocking = try database.readBlocking { try $0.fetchAll(Item.all).count }
            #expect(blocking == id)
          }
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func aDatabaseFileKeepsItsIdentityAndContentsAcrossReopening(
        _ driver: SQLiteTestDriver
      ) async throws {
        try await withTestDatabaseFile { file in
          do {
            let database = try file.open(driver)
            #expect(database.defaultIdentifier == .forDatabase(path: file.path))
            try await database.execute(sql: itemsSchema)
            try await database.write { transaction in
              try transaction.execute(Item.insert { Item(id: 1, title: "persisted") })
            }
          }

          let reopened = try file.open(driver)
          #expect(reopened.defaultIdentifier == .forDatabase(path: file.path))
          let items = try await reopened.read { try $0.fetchAll(Item.all) }
          #expect(items == [Item(id: 1, title: "persisted")])
        }
      }

      @Test(arguments: SQLiteTestDriver.allCases)
      func blockingAndAsynchronousWritersShareOneLine(_ driver: SQLiteTestDriver) async throws {
        try await driver.withDatabase(
          schema: "CREATE TABLE counter (n INTEGER NOT NULL); INSERT INTO counter (n) VALUES (0)"
        ) { database in
          let writers = 8
          let bumpsEach = 20
          let bump = "UPDATE counter SET n = n + 1"
          let read = #sql("SELECT n FROM counter", as: Int.self)

          async let blocking = concurrentlyOnThreads(writers) { _ in
            for _ in 0..<bumpsEach {
              try database.writeBlocking { try $0.executeScript(bump) }
              _ = try database.readBlocking { try $0.fetchOne(read) }
            }
          }
          _ = try await concurrently(writers) { _ in
            for _ in 0..<bumpsEach {
              try await database.write { try $0.executeScript(bump) }
              _ = try await database.read { try $0.fetchOne(read) }
            }
          }
          _ = try await blocking

          let total = try database.readBlocking { try $0.fetchOne(read) }
          #expect(total == 2 * writers * bumpsEach)
        }
      }
    }

    private let itemsSchema = "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"

    @Table
    private struct Item: Equatable, Sendable {
      let id: Int
      var title: String
    }
  #endif
#endif
