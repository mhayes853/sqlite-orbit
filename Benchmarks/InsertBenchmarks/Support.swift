import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import SQLiteOrbit

extension Benchmark.Configuration {
  /// The configuration of the `Arguments` groups: a million statements make an iteration take
  /// seconds, so these run 10 iterations rather than the suite's 50.
  static var arguments: Self {
    var configuration = Self.comparison
    configuration.maxIterations = 10
    return configuration
  }
}

/// Runs one iteration of an insert benchmark against a database of its own.
///
/// The database and its table are created, and `open` connects the implementation under test,
/// before measurement starts. Only `insert` is measured. The connection is closed, `verify` checks
/// what was written, and the files are removed after measurement stops.
func measureInsert<Database: ~Copyable>(
  _ benchmark: Benchmark,
  schema: String = Fixture.createItemTableSQL,
  verify: (String) throws -> Void = { try verifyItems(at: $0, count: Fixture.insertedRowCount) },
  open: (String) throws -> Database,
  insert: (inout Database) throws -> Void
) throws {
  let path = Fixture.scratchDatabasePath("insert")
  defer { Fixture.removeDatabase(at: path) }
  try RawSQLiteConnection(path: path).execute(schema)
  do {
    var database = try open(path)
    benchmark.startMeasurement()
    try insert(&database)
    benchmark.stopMeasurement()
    _ = consume database
  }
  try verify(path)
}

/// The asynchronous counterpart of `measureInsert(_:schema:verify:open:insert:)`.
func measureInsert<Database>(
  _ benchmark: Benchmark,
  schema: String = Fixture.createItemTableSQL,
  verify: (String) throws -> Void = { try verifyItems(at: $0, count: Fixture.insertedRowCount) },
  open: (String) async throws -> Database,
  insert: (inout Database) async throws -> Void
) async throws {
  let path = Fixture.scratchDatabasePath("insert")
  defer { Fixture.removeDatabase(at: path) }
  try RawSQLiteConnection(path: path).execute(schema)
  do {
    var database = try await open(path)
    benchmark.startMeasurement()
    try await insert(&database)
    benchmark.stopMeasurement()
    _ = consume database
  }
  try verify(path)
}

/// Checks the item table holds rows `0..<count`, as GRDB's tests do.
func verifyItems(at path: String, count: Int) throws {
  let found = try RawSQLiteConnection(path: path)
    .integers("SELECT COUNT(*), MIN(i0), MAX(i9) FROM item")
  let expected = [Int64(count), 0, Int64(count - 1)]
  guard found == expected else {
    throw BenchmarkError(message: "Expected [COUNT, MIN, MAX] \(expected), got \(found)")
  }
}

// MARK: - Orbit

func openOrbitConnection(_ path: String) throws -> SQLiteConnection {
  try SQLiteConnection(path: OrbitDatabasePath(path), configuration: .default)
}

/// `Fixture.insertItemSQL` with every column bound to `i`.
func insertItemSQL(_ i: Int) -> SQL {
  """
  INSERT INTO item (i0, i1, i2, i3, i4, i5, i6, i7, i8, i9) \
  VALUES (\(i), \(i), \(i), \(i), \(i), \(i), \(i), \(i), \(i), \(i))
  """
}

// MARK: - SQLite

// SQLITE_TRANSIENT is a macro Swift cannot import.
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
