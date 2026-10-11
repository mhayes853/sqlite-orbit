import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import GRDB
import SQLiteOrbit

private let accessCount = 10_000

// Orbit-specific, with no GRDB counterpart: 10,000 write accesses of one single-row `INSERT` each,
// measuring what one access costs: the hop to the connection's executor, beginning and committing
// the transaction, and observation bookkeeping. Drivers are paired by journal mode: the queues
// with a DELETE journal, the pools with WAL. `SQLite` and `OrbitConnection` run synchronously on
// the calling thread, as floors.
//
// Every implementation runs `synchronous = OFF`, set on each connection and checked before
// measurement starts, so that 10,000 commits are not 10,000 fsyncs drowning the overhead under
// test. NORMAL would do that for WAL but not for the DELETE journal, and one setting for every
// implementation keeps the queue and pool numbers comparable too. GRDB's pool sets NORMAL on its
// writer after `prepareDatabase` runs, so OFF is set on it again once it is open.
//
// Each insert runs through its implementation's cached prepared statement, so preparation does
// not dominate either.
private let synchronousOff = "PRAGMA synchronous = OFF"

func accessOverheadBenchmarks() {
  func verify(_ path: String) throws {
    try verifyItems(at: path, count: accessCount)
  }

  Benchmark("AccessOverheadWrite/SQLite") { benchmark in
    try measureInsert(benchmark, verify: verify, open: openRawConnection) { connection in
      let statement = try connection.prepare(Fixture.insertItemSQL)
      for i in Int64(0)..<Int64(accessCount) {
        try connection.execute("BEGIN IMMEDIATE")
        sqlite3_reset(statement)
        for column in Int32(1)...10 {
          sqlite3_bind_int64(statement, column, i)
        }
        try connection.step(statement)
        try connection.execute("COMMIT")
      }
      sqlite3_finalize(statement)
    }
  }

  Benchmark("AccessOverheadWrite/OrbitConnection") { benchmark in
    try measureInsert(
      benchmark,
      verify: verify,
      open: { path in
        var owner = try SQLiteConnection(path: OrbitDatabasePath(path), configuration: orbit)
        try owner.withWriteConnection { connection in
          try connection.transaction { try requireSynchronousOff($0) }
        }
        return owner
      }
    ) { owner in
      for i in 0..<accessCount {
        try owner.withWriteConnection { connection in
          try connection.transaction { try $0.execute(insertItemSQL(i)) }
        }
      }
    }
  }

  Benchmark("AccessOverheadWrite/GRDBQueue") { benchmark in
    try await measureInsert(
      benchmark,
      verify: verify,
      open: { path in
        let dbQueue = try DatabaseQueue(path: path, configuration: grdb)
        try await dbQueue.write { try requireSynchronousOff($0) }
        return dbQueue
      }
    ) { dbQueue in
      for i in 0..<accessCount {
        try await dbQueue.write { try insertItem(i, into: $0) }
      }
    }
  }

  Benchmark("AccessOverheadWrite/OrbitQueue") { benchmark in
    try await measureInsert(
      benchmark,
      verify: verify,
      open: { path in
        let queue = try SQLiteQueue(path: OrbitDatabasePath(path), configuration: orbit)
        try await queue.write { try requireSynchronousOff($0) }
        return queue
      }
    ) { queue in
      for i in 0..<accessCount {
        try await queue.write { try $0.execute(insertItemSQL(i)) }
      }
    }
  }

  Benchmark("AccessOverheadWrite/GRDBPool") { benchmark in
    try await measureInsert(
      benchmark,
      verify: verify,
      open: { path in
        let dbPool = try DatabasePool(path: path, configuration: grdb)
        try await dbPool.writeWithoutTransaction { try $0.execute(sql: synchronousOff) }
        try await dbPool.write { try requireSynchronousOff($0) }
        return dbPool
      }
    ) { dbPool in
      for i in 0..<accessCount {
        try await dbPool.write { try insertItem(i, into: $0) }
      }
    }
  }

  Benchmark("AccessOverheadWrite/OrbitPool") { benchmark in
    try await measureInsert(
      benchmark,
      verify: verify,
      open: { path in
        let pool = try SQLitePool(path: OrbitDatabasePath(path), configuration: orbit)
        try await pool.write { try requireSynchronousOff($0) }
        return pool
      }
    ) { pool in
      for i in 0..<accessCount {
        try await pool.write { try $0.execute(insertItemSQL(i)) }
      }
    }
  }

  // An `SQLitePool` that also announces every commit to its peers, of which there are none.
  Benchmark("AccessOverheadWrite/OrbitIPC") { benchmark in
    try await measureInsert(
      benchmark,
      verify: verify,
      open: { path in
        let database = try OrbitIPCDatabase(path: OrbitDatabasePath(path), configuration: orbit)
        try await database.write { try requireSynchronousOff($0) }
        return database
      }
    ) { database in
      for i in 0..<accessCount {
        try await database.write { try $0.execute(insertItemSQL(i)) }
      }
    }
  }
}

private var orbit: SQLiteConfiguration {
  var configuration = SQLiteConfiguration.default
  configuration.setups.append(.script(synchronousOff))
  return configuration
}

private var grdb: Configuration {
  var configuration = Configuration()
  configuration.prepareDatabase { try $0.execute(sql: synchronousOff) }
  return configuration
}

private func openRawConnection(_ path: String) throws -> RawSQLiteConnection {
  let connection = try RawSQLiteConnection(path: path)
  try connection.execute(synchronousOff)
  guard try connection.integers("PRAGMA synchronous") == [0] else {
    throw BenchmarkError(message: "synchronous is not OFF")
  }
  return connection
}

private func insertItem(_ i: Int, into db: Database) throws {
  try db.cachedStatement(sql: Fixture.insertItemSQL)
    .execute(arguments: [i, i, i, i, i, i, i, i, i, i])
}

private func requireSynchronousOff(_ db: Database) throws {
  guard try Int.fetchOne(db, sql: "PRAGMA synchronous") == 0 else {
    throw BenchmarkError(message: "synchronous is not OFF")
  }
}

private func requireSynchronousOff(_ transaction: borrowing SQLiteWriteTransaction) throws {
  guard try transaction.fetchOne("PRAGMA synchronous", as: Int.self) == 0 else {
    throw BenchmarkError(message: "synchronous is not OFF")
  }
}
