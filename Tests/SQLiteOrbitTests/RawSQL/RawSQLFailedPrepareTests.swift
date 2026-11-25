#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  // A statement that fails to prepare, reached through the inlinable generic fetch path. Swift
  // 6.3.3 has crashed tearing down the cursor such a statement never made, so these only pass
  // when the error propagates instead.
  @Suite
  struct RawSQLFailedPrepareTests {
    private static let failingSQL: [SQL] = [
      "SELEC 1",
      "SELECT * FROM missing_table",
      "SELECT missing_column FROM items"
    ]

    @Test(arguments: failingSQL)
    func concreteTransactionThrows(sql: SQL) throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      try owner.withReadConnection { connection in
        try connection.transaction { transaction in
          var errors = 0
          do {
            _ = try transaction.fetchAll(sql, as: FailedPrepareRecord.self)
          } catch is SQLiteError {
            errors += 1
          }
          do { _ = try transaction.fetchAll(sql) { try $0[0, as: Int.self] } } catch is SQLiteError
          {
            errors += 1
          }
          do { _ = try fetchGenerically(sql, in: transaction) } catch is SQLiteError { errors += 1 }
          #expect(errors == 3)
          // Still usable afterwards.
          let records = try transaction.fetchAll("SELECT 1", as: FailedPrepareRecord.self)
          #expect(records.count == 1)
        }
      }
    }

    private func fetchGenerically<Transaction>(
      _ sql: SQL,
      in transaction: borrowing Transaction
    ) throws -> [FailedPrepareRecord]
    where Transaction: OrbitDatabaseReadTransaction & ~Copyable & ~Escapable {
      try transaction.fetchAll(sql, as: FailedPrepareRecord.self)
    }
  }

  private struct FailedPrepareRecord: ConvertibleFromOrbitDatabaseRow {
    var id: Int

    init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(
      orbitDatabaseRow row: borrowing Row
    ) throws {
      id = try row[0, as: Int.self]
    }
  }
#endif
