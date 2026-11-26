#if BuiltInSQLite
  import Foundation
  import Testing

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

  @Test
  func aTemporaryDatabaseIsUsableAndPrivateToItsConnection() async throws {
    let driver = try SQLiteQueue(path: .temporary)
    try await driver.execute(
      sql: """
        CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
        INSERT INTO items VALUES (1, 'scratch');
        """
    )
    let titles = try await driver.fetchAll(sql: "SELECT title FROM items", as: String.self)
    #expect(titles == ["scratch"])

    // No file names it, so a second driver opens a different, empty database of its own.
    #expect(OrbitDatabasePath.temporary.filePath == nil)
    let other = try SQLiteQueue(path: .temporary)
    await #expect(throws: SQLiteError.self) {
      try await other.rowCount(of: "items")
    }
  }
#endif
