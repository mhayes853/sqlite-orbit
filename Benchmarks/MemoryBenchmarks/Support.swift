import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import Dispatch
import GRDB
import SQLiteOrbit
import Synchronization

/// Few iterations suffice: what an instance retains barely varies, and every iteration's instance
/// stays open until the benchmark ends.
private var memoryConfiguration: Benchmark.Configuration {
  Benchmark.Configuration(
    metrics: [.mallocCountTotal, .mallocBytesCount, .memoryLeakedBytes, .peakMemoryResidentDelta],
    warmupIterations: 1,
    maxDuration: .seconds(60),
    maxIterations: 7
  )
}

/// The instances iterations keep alive, released in teardown.
nonisolated(unsafe) private var retainedInstances: [AnyObject] = []

/// Registers a benchmark whose iterations each open an instance with `open`, given the path of a
/// scratch database, and keep it alive, so the bytes left allocated are what one instance holds.
///
/// The scratch database has 1,000 rows, where row `n` stores `n` in every column, and is already
/// in WAL mode, so that opening a pool does not count the switch.
func registerMemoryBenchmark(
  _ name: String,
  open: @escaping (String) async throws -> AnyObject
) {
  let path = Fixture.scratchDatabasePath(name.replacing("/", with: "-"))
  Benchmark(
    name,
    configuration: memoryConfiguration,
    closure: { benchmark in
      for _ in benchmark.scaledIterations {
        retainedInstances.append(try await open(path))
      }
    },
    setup: {
      Fixture.removeDatabase(at: path)
      let connection = try RawSQLiteConnection(path: path)
      try connection.execute(
        """
        \(Fixture.createItemTableSQL);
        WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM cnt LIMIT 1000)
        INSERT INTO item SELECT x, x, x, x, x, x, x, x, x, x FROM cnt;
        """
      )
      _ = try connection.integers("PRAGMA journal_mode = WAL")
    },
    teardown: {
      retainedInstances.removeAll()
      Fixture.removeDatabase(at: path)
    }
  )
}

// MARK: - Reads

let lookupSQL = "SELECT i0 FROM item WHERE rowid = ?"
let orbitLookup: SQLiteOrbit.SQL = "SELECT i0 FROM item WHERE rowid = \(1)"

/// A lookup distinct from every other `k`'s, so each takes a statement of its own.
func distinctLookupSQL(_ k: Int) -> String {
  "SELECT i0 FROM item WHERE rowid = ? AND \(k) = \(k)"
}

func expectLookup(_ value: Int?) throws {
  guard value == 1 else {
    throw BenchmarkError(message: "Looked up \(value.map(String.init) ?? "nil") instead of 1")
  }
}

/// Runs `count` reads at once, each calling its rendezvous from inside its access, which waits
/// until every read has reached it, so that a pool must lend `count` readers at the same time.
func concurrentReads(
  _ count: Int,
  _ read: @Sendable (_ rendezvous: @Sendable () -> Void) throws -> Void
) throws {
  let arrived = Atomic(0)
  let failures = Atomic(0)
  DispatchQueue.concurrentPerform(iterations: count) { _ in
    do {
      try read {
        arrived.add(1, ordering: .sequentiallyConsistent)
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while arrived.load(ordering: .sequentiallyConsistent) < count,
          DispatchTime.now().uptimeNanoseconds < deadline
        {}
      }
    } catch {
      failures.add(1, ordering: .relaxed)
    }
  }
  guard failures.load(ordering: .relaxed) == 0 else {
    throw BenchmarkError(message: "\(failures.load(ordering: .relaxed)) concurrent reads failed")
  }
}

// MARK: - Connections

/// A box for the noncopyable synchronous connection owner, so an iteration can keep it alive.
final class OrbitConnection {
  var owner: SQLiteOrbit.SQLiteConnection

  init(path: String) throws {
    owner = try SQLiteOrbit.SQLiteConnection(path: OrbitDatabasePath(path), configuration: .default)
  }
}

/// A raw C connection keeping prepared statements, as a library's statement cache does: the floor
/// each library's footprint is measured against.
final class RawStatementConnection {
  let connection: RawSQLiteConnection
  private(set) var statements: [OpaquePointer] = []

  init(path: String) throws {
    connection = try RawSQLiteConnection(path: path)
  }

  deinit {
    finalizeStatements()
  }

  /// Prepares `sql` and keeps the statement.
  func prepare(_ sql: String) throws -> OpaquePointer {
    let statement = try connection.prepare(sql)
    statements.append(statement)
    return statement
  }

  /// Runs a lookup of row 1 with `statement`, which `prepare` returned.
  func lookUp(_ statement: OpaquePointer) throws -> Int {
    defer { sqlite3_reset(statement) }
    sqlite3_bind_int64(statement, 1, 1)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.error }
    return Int(sqlite3_column_int64(statement, 0))
  }

  /// Reads row 1 in a deferred transaction, every statement prepared once.
  func read() throws -> Int {
    let begin = try prepare("BEGIN DEFERRED TRANSACTION")
    let commit = try prepare("COMMIT")
    let lookup = try prepare(lookupSQL)
    try connection.step(begin)
    sqlite3_reset(begin)
    let value = try lookUp(lookup)
    try connection.step(commit)
    sqlite3_reset(commit)
    return value
  }

  /// Finalizes every kept statement and frees what SQLite can.
  func releaseMemory() {
    finalizeStatements()
    sqlite3_db_release_memory(connection.handle)
  }

  private func finalizeStatements() {
    for statement in statements {
      sqlite3_finalize(statement)
    }
    statements.removeAll()
  }
}
