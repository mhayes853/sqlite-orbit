import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import SQLiteOrbit

// GRDB's fetch tests open their database once, before `measure`, and reuse it in every iteration.
// These helpers do the same: a benchmark's resource is opened in its setup and released in its
// teardown, so neither is measured.

/// Registers a benchmark that measures `body` against a resource opened before its iterations.
///
/// - Parameters:
///   - name: The benchmark's name, as `<GRDB test>/<implementation>`.
///   - configuration: The benchmark's configuration, the suite's default unless given.
///   - open: Opens the resource, outside the measured region.
///   - cleanUp: Runs after the resource is released, to remove anything `open` created.
///   - body: The measured work.
func registerBenchmark<Resource>(
  _ name: String,
  configuration: Benchmark.Configuration = Benchmark.defaultConfiguration,
  opening open: @escaping () async throws -> Resource,
  cleanUp: @escaping () -> Void = {},
  measure body: @escaping (Resource) throws -> Void
) {
  let holder = ResourceHolder<Resource>()
  Benchmark(
    name,
    configuration: configuration,
    closure: { benchmark in
      let resource = try holder.resource(for: name)
      for _ in benchmark.scaledIterations {
        try body(resource)
      }
    },
    setup: { holder.value = try await open() },
    teardown: {
      holder.value = nil
      cleanUp()
    }
  )
}

/// Registers a benchmark that measures asynchronous `body` against a resource opened before its
/// iterations.
func registerBenchmark<Resource>(
  _ name: String,
  configuration: Benchmark.Configuration = Benchmark.defaultConfiguration,
  opening open: @escaping () async throws -> Resource,
  cleanUp: @escaping () -> Void = {},
  measure body: @escaping (Resource) async throws -> Void
) {
  let holder = ResourceHolder<Resource>()
  Benchmark(
    name,
    configuration: configuration,
    closure: { benchmark in
      let resource = try holder.resource(for: name)
      for _ in benchmark.scaledIterations {
        try await body(resource)
      }
    },
    setup: { holder.value = try await open() },
    teardown: {
      holder.value = nil
      cleanUp()
    }
  )
}

private final class ResourceHolder<Value> {
  var value: Value?

  func resource(for name: String) throws -> Value {
    guard let value else {
      throw BenchmarkError(message: "\(name) ran without its setup")
    }
    return value
  }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
  guard condition else { throw BenchmarkError(message: message()) }
}

// MARK: - Fixture expectations

/// The sum of every column of every fixture row, where row `n` stores `n` in all ten columns.
///
/// Value benchmarks add up what they read rather than discarding it, which keeps the optimizer
/// from dropping the reads and checks every value with one comparison.
let expectedFetchedValueSum = 10 * (Fixture.fetchedRowCount - 1) * Fixture.fetchedRowCount / 2

func expectFetchedValues(count: Int, sum: Int) throws {
  try expect(
    count == Fixture.fetchedRowCount,
    "Read \(count) rows instead of \(Fixture.fetchedRowCount)"
  )
  try expect(sum == expectedFetchedValueSum, "Read values summing to \(sum)")
  blackHole(sum)
}

/// Checks fetched records the way GRDB's tests do: their count, and three spot values.
func expectFetchedRecords<Record>(
  _ records: [Record],
  i0: (Record) -> Int,
  i1: (Record) -> Int,
  i9: (Record) -> Int
) throws {
  let last = Fixture.fetchedRowCount - 1
  try expect(
    records.count == Fixture.fetchedRowCount,
    "Fetched \(records.count) records instead of \(Fixture.fetchedRowCount)"
  )
  try expect(i0(records[0]) == 0, "records[0].i0 is \(i0(records[0]))")
  try expect(i1(records[1]) == 1, "records[1].i1 is \(i1(records[1]))")
  try expect(i9(records[last]) == last, "records[\(last)].i9 is \(i9(records[last]))")
  blackHole(records)
}

// MARK: - Connections

/// A box for the noncopyable synchronous connection owner, so a benchmark can hold it across
/// iterations.
final class OrbitConnection {
  var owner: SQLiteConnection

  init(path: String) throws {
    owner = try SQLiteConnection(path: OrbitDatabasePath(path), configuration: .default)
  }

  init(path: OrbitDatabasePath) throws {
    owner = try SQLiteConnection(path: path, configuration: .default)
  }
}

// MARK: - Access benchmarks

// The access groups run 10,000 one-row lookups, each in an access of its own, against a scratch
// database of 1,000 rows, where row `n` stores `n` in i0 and access `i` reads row `i % 1,000 + 1`.

let accessCount = 10_000
private let accessTableRowCount = 1_000

let accessLookupSQL = "SELECT i0 FROM item WHERE rowid = ?"

/// The sum of the values `accessCount` lookups read.
let expectedAccessLookupSum =
  accessCount / accessTableRowCount
  * (accessTableRowCount * (accessTableRowCount + 1) / 2)

func rowID(forAccess access: Int) -> Int {
  access % accessTableRowCount + 1
}

private func makeAccessDatabase(at path: String) throws {
  let connection = try RawSQLiteConnection(path: path)
  try connection.execute(
    """
    \(Fixture.createItemTableSQL);
    WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM cnt LIMIT \(accessTableRowCount))
    INSERT INTO item SELECT x, x, x, x, x, x, x, x, x, x FROM cnt;
    """
  )
}

func expectAccessLookups(sum: Int, accessesPerLookup: Int = 1) throws {
  let expected = expectedAccessLookupSum * accessesPerLookup
  try expect(sum == expected, "Looked up values summing to \(sum)")
  blackHole(sum)
}

struct MissingRowError: Error {}

/// Registers an access benchmark against a scratch database it creates in setup and removes in
/// teardown.
///
/// Every benchmark reads a scratch database of its own, because the pools switch theirs to WAL for
/// good, and the shared fetch fixture must stay as the C API wrote it.
func registerAccessBenchmark<Database>(
  _ name: String,
  opening open: @escaping (String) throws -> Database,
  measure body: @escaping (Database) async throws -> Void
) {
  let path = Fixture.scratchDatabasePath(name.replacing("/", with: "-"))
  registerBenchmark(
    name,
    opening: {
      Fixture.removeDatabase(at: path)
      try makeAccessDatabase(at: path)
      return try open(path)
    },
    cleanUp: { Fixture.removeDatabase(at: path) },
    measure: body
  )
}

/// A raw C connection with every statement an access runs prepared once, so that an access costs
/// no more than the transaction around its lookup: the floor every library's access is measured
/// against.
final class RawAccessConnection {
  private let connection: RawSQLiteConnection
  private let beginDeferred: OpaquePointer
  private let beginImmediate: OpaquePointer
  private let commit: OpaquePointer
  private let lookup: OpaquePointer

  /// Opens the database at `path`, switching it to `journalMode` when one is given.
  init(path: String, journalMode: String? = nil) throws {
    let connection = try RawSQLiteConnection(path: path)
    if let journalMode {
      _ = try connection.integers("PRAGMA journal_mode = \(journalMode)")
    }
    self.connection = connection
    beginDeferred = try connection.prepare("BEGIN DEFERRED TRANSACTION")
    beginImmediate = try connection.prepare("BEGIN IMMEDIATE TRANSACTION")
    commit = try connection.prepare("COMMIT")
    lookup = try connection.prepare(accessLookupSQL)
  }

  deinit {
    for statement in [beginDeferred, beginImmediate, commit, lookup] {
      sqlite3_finalize(statement)
    }
  }

  /// Looks a row up in a deferred transaction, as a read access does.
  func read(rowID: Int) throws -> Int {
    try lookUp(rowID: rowID, beginningWith: beginDeferred)
  }

  /// Looks a row up in an immediate transaction, as a write access that only reads does.
  func write(rowID: Int) throws -> Int {
    try lookUp(rowID: rowID, beginningWith: beginImmediate)
  }

  private func lookUp(rowID: Int, beginningWith begin: OpaquePointer) throws -> Int {
    try run(begin)
    sqlite3_bind_int64(lookup, 1, Int64(rowID))
    guard sqlite3_step(lookup) == SQLITE_ROW else {
      sqlite3_reset(lookup)
      throw connection.error
    }
    let value = Int(sqlite3_column_int64(lookup, 0))
    sqlite3_reset(lookup)
    try run(commit)
    return value
  }

  private func run(_ statement: OpaquePointer) throws {
    defer { sqlite3_reset(statement) }
    try connection.step(statement)
  }
}
