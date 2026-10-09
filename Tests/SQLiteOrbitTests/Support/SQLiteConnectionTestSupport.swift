import SQLiteOrbit

// Keep the established transaction-test vocabulary while building each access from the public
// connection lenders. Raw statement/cache inspections in those tests remain separate.
extension SQLiteConnection {
  static func open(
    path: OrbitDatabasePath,
    flags: SQLiteOpenFlags,
    configuration: SQLiteConfiguration
  ) throws -> SQLiteConnection {
    try SQLiteConnection(path: path, configuration: configuration, flags: flags)
  }

  mutating func read<Result: ~Copyable>(
    _ body: (borrowing SQLiteReadTransaction) throws -> Result
  ) throws -> Result {
    try withReadConnection { try $0.transaction(body) }
  }

  mutating func write<Result: ~Copyable>(
    _ body: (borrowing SQLiteWriteTransaction) throws -> Result
  ) throws -> Result {
    try withWriteConnection { try $0.transaction(body) }
  }

  mutating func readWithoutTransaction<Result: ~Copyable>(
    _ body: (borrowing SQLiteReadConnection) throws -> Result
  ) throws -> Result {
    try withReadConnection(body)
  }

  mutating func writeWithoutTransaction<Result: ~Copyable>(
    _ body: (borrowing SQLiteWriteConnection) throws -> Result
  ) throws -> Result {
    try withWriteConnection(body)
  }
}
