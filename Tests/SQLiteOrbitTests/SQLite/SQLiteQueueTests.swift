#if BuiltInSQLite
  import Foundation
  import Testing

  #if StructuredQueries
    import StructuredQueriesSQLite
  #endif

  @testable import SQLiteOrbit

  @Test
  func accessClosuresNeedNotBeSendable() async throws {
    final class Capture {
      var value = 0
    }

    let driver = try SQLiteQueue(path: .memory)
    let capture = Capture()
    let value = try await driver.write { transaction in
      capture.value = 42
      try transaction.execute("CREATE TABLE marker (value INTEGER)")
      return capture.value
    }

    #expect(value == 42)
  }

  #if StructuredQueries
    @Test
    func aTemporaryDatabaseIsUsableAndPrivateToItsConnection() async throws {
      let driver = try SQLiteQueue(path: .temporary)
      try await driver.execute(
        sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
      )
      try await driver.write { transaction in
        try Item.insert { Item(id: 1, title: "scratch") }.execute(transaction)
      }
      let items = try await driver.read { transaction in
        try Item.all.fetchAll(transaction)
      }
      #expect(items == [Item(id: 1, title: "scratch")])

      // No file names it, so a second driver opens a different, empty database of its own.
      #expect(OrbitDatabasePath.temporary.fileURL == nil)
      let other = try SQLiteQueue(path: .temporary)
      await #expect(throws: SQLiteError.self) {
        try await other.read { try Item.all.fetchCount($0) }
      }
    }

    @Table
    private struct Item: Equatable, Sendable {
      let id: Int
      var title: String
    }
  #endif
#endif
