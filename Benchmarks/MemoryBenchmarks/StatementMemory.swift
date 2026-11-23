import BenchmarkSupport
import GRDB
import SQLiteOrbit

// One connection or queue after running 64 or 500 distinct lookups in one read, each through the
// library's statement cache, and after 500 followed by releasing memory, which finalizes the
// cached statements. The `SQLite` rows prepare each statement once and keep it.

private func openRawConnection(path: String, statements: Int) throws -> RawStatementConnection {
  let connection = try RawStatementConnection(path: path)
  try connection.connection.execute("BEGIN")
  for k in 0..<statements {
    try expectLookup(try connection.lookUp(try connection.prepare(distinctLookupSQL(k))))
  }
  try connection.connection.execute("COMMIT")
  return connection
}

private func openGRDBQueue(path: String, statements: Int) throws -> DatabaseQueue {
  let queue = try DatabaseQueue(path: path)
  try queue.read { db in
    for k in 0..<statements {
      try expectLookup(
        try Int.fetchOne(db.cachedStatement(sql: distinctLookupSQL(k)), arguments: [1])
      )
    }
  }
  return queue
}

private func openOrbitConnection(path: String, statements: Int) throws -> OrbitConnection {
  let connection = try OrbitConnection(path: path)
  try connection.owner.withReadConnection {
    try $0.transaction { transaction in
      for k in 0..<statements {
        let sql = SQLiteOrbit.SQL(text: distinctLookupSQL(k), bindings: [.integer(1)])
        try expectLookup(try transaction.fetchOne(sql, as: Int.self))
      }
    }
  }
  return connection
}

func registerStatementMemory() {
  for count in [64, 500] {
    registerMemoryBenchmark("MemoryStatements\(count)/SQLite") {
      try openRawConnection(path: $0, statements: count)
    }
    registerMemoryBenchmark("MemoryStatements\(count)/GRDBQueue") {
      try openGRDBQueue(path: $0, statements: count)
    }
    registerMemoryBenchmark("MemoryStatements\(count)/Orbit") {
      try openOrbitConnection(path: $0, statements: count)
    }
  }

  registerMemoryBenchmark("MemoryStatementsReleased/SQLite") { path in
    let connection = try openRawConnection(path: path, statements: 500)
    connection.releaseMemory()
    return connection
  }
  registerMemoryBenchmark("MemoryStatementsReleased/GRDBQueue") { path in
    let queue = try openGRDBQueue(path: path, statements: 500)
    queue.releaseMemory()
    return queue
  }
  registerMemoryBenchmark("MemoryStatementsReleased/Orbit") { path in
    let connection = try openOrbitConnection(path: path, statements: 500)
    connection.owner.releaseMemory()
    return connection
  }
}
