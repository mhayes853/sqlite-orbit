import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import GRDB
import SQLiteOrbit

private let insertCount = 1_000_000
private let shortString = "foo"
private let longString = """
  Lorem ipsum dolor sit amet, consectetur adipiscing elit. Phasellus consectetur felis eget nibh \
  aliquet ullamcorper. Nam sodales, tellus a cursus tincidunt, arcu purus suscipit elit, nec \
  congue erat ipsum a purus.
  """

// A million single-string inserts in one transaction, isolating the cost of binding an argument.
// GRDB's tests share one transaction and one table across every iteration; here each iteration
// writes a fresh table in a transaction of its own, which it commits, and runs the `.arguments`
// configuration of 10 iterations, since one takes seconds.
func argumentsBenchmarks() {
  argumentsBenchmarks(named: "ArgumentsShortString", value: shortString)
  argumentsBenchmarks(named: "ArgumentsLongString", value: longString)
}

private func argumentsBenchmarks(named name: String, value: String) {
  func measure(
    _ benchmark: Benchmark,
    open: (String) throws -> RawSQLiteConnection,
    insert: (inout RawSQLiteConnection) throws -> Void
  ) throws {
    try measureInsert(
      benchmark,
      schema: "CREATE TABLE t(a)",
      verify: { try verifyStrings(at: $0, value: value) },
      open: open,
      insert: insert
    )
  }

  // The two ways C binds text: SQLITE_STATIC borrows the caller's buffer, which must outlive the
  // step, and SQLITE_TRANSIENT copies it. Both rebind every row.
  let destructors: [(String, sqlite3_destructor_type?)] = [
    ("SQLiteStatic", nil), ("SQLiteTransient", sqliteTransient)
  ]
  for (implementation, destructor) in destructors {
    Benchmark("\(name)/\(implementation)", configuration: .arguments) { benchmark in
      try measure(benchmark, open: RawSQLiteConnection.init(path:)) { connection in
        try connection.execute("BEGIN TRANSACTION")
        let statement = try connection.prepare("INSERT INTO t(a) VALUES (?)")
        var text = value
        try text.withUTF8 { buffer in
          for _ in 0..<insertCount {
            sqlite3_reset(statement)
            buffer.withMemoryRebound(to: CChar.self) {
              _ = sqlite3_bind_text(statement, 1, $0.baseAddress, Int32($0.count), destructor)
            }
            try connection.step(statement)
          }
        }
        sqlite3_finalize(statement)
        try connection.execute("COMMIT")
      }
    }
  }

  // GRDB's three tests. Legacy binds with `setArguments` and then executes, as
  // `execute(arguments:)` once did; SQLITE_STATIC is today's `execute(arguments:)`;
  // SQLITE_TRANSIENT binds once and re-executes without rebinding.
  Benchmark("\(name)/GRDBLegacy", configuration: .arguments) { benchmark in
    try measureGRDB(benchmark, value: value) { statement, arguments in
      for _ in 0..<insertCount {
        try statement.setArguments(arguments)
        try statement.execute()
      }
    }
  }

  Benchmark("\(name)/GRDBStatic", configuration: .arguments) { benchmark in
    try measureGRDB(benchmark, value: value) { statement, arguments in
      for _ in 0..<insertCount {
        try statement.execute(arguments: arguments)
      }
    }
  }

  Benchmark("\(name)/GRDBTransient", configuration: .arguments) { benchmark in
    try measureGRDB(benchmark, value: value) { statement, arguments in
      try statement.setArguments(arguments)
      for _ in 0..<insertCount {
        try statement.execute()
      }
    }
  }

  // Orbit binds interpolated values every time a statement runs. `Orbit` prepares each statement
  // anew; `OrbitCached` reuses the cached one.
  Benchmark("\(name)/Orbit", configuration: .arguments) { benchmark in
    try measureOrbit(benchmark, value: value) { transaction in
      for _ in 0..<insertCount {
        try transaction.execute("INSERT INTO t(a) VALUES (\(value))")
      }
    }
  }

  Benchmark("\(name)/OrbitCached", configuration: .arguments) { benchmark in
    try measureOrbit(benchmark, value: value) { transaction in
      for _ in 0..<insertCount {
        try transaction.executeCached("INSERT INTO t(a) VALUES (\(value))")
      }
    }
  }
}

private func measureGRDB(
  _ benchmark: Benchmark,
  value: String,
  insert: (GRDB.Statement, StatementArguments) throws -> Void
) throws {
  try measureInsert(
    benchmark,
    schema: "CREATE TABLE t(a)",
    verify: { try verifyStrings(at: $0, value: value) },
    open: { try DatabaseQueue(path: $0) },
    insert: { dbQueue in
      try dbQueue.write { db in
        let statement = try db.makeStatement(sql: "INSERT INTO t(a) VALUES (?)")
        try insert(statement, [value])
      }
    }
  )
}

private func measureOrbit(
  _ benchmark: Benchmark,
  value: String,
  insert: (borrowing SQLiteWriteTransaction) throws -> Void
) throws {
  try measureInsert(
    benchmark,
    schema: "CREATE TABLE t(a)",
    verify: { try verifyStrings(at: $0, value: value) },
    open: openOrbitConnection,
    insert: { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction(insert)
      }
    }
  )
}

/// Checks `t` holds `insertCount` rows, each `value`.
private func verifyStrings(at path: String, value: String) throws {
  // Neither string holds a quote, so it can be spliced in as a literal.
  let found = try RawSQLiteConnection(path: path)
    .integers("SELECT COUNT(*), COUNT(*) FILTER (WHERE a = '\(value)') FROM t")
  guard found == [Int64(insertCount), Int64(insertCount)] else {
    throw BenchmarkError(message: "Expected \(insertCount) matching rows, got \(found)")
  }
}
