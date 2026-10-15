import Benchmark
import BenchmarkSupport
import GRDB
import SQLiteOrbit

// No GRDB counterpart: 10,000 one-row reads, each a database access of its own, so what is
// measured is the cost of an access (the executor hop, the transaction begun and ended around it)
// rather than of reading. The synchronous `SQLiteConnection` is Orbit's floor, with no executor at
// all, and `SQLite` and `SQLiteWAL` are the floor beneath every library: the C API running each
// read as a deferred transaction around the lookup, with all three statements prepared once, in
// the rollback journal and in WAL.
//
// Every implementation prepares the lookup through its statement cache: Orbit's `fetchOne` always
// does, and GRDB's through `cachedStatement`.

func registerReadAccessOverhead() {
  registerAccessBenchmark(
    "ReadAccessOverhead/SQLite",
    opening: { try RawAccessConnection(path: $0) },
    measure: { connection in
      var sum = 0
      for access in 0..<accessCount {
        sum &+= try connection.read(rowID: rowID(forAccess: access))
      }
      try expectAccessLookups(sum: sum)
    }
  )

  registerAccessBenchmark(
    "ReadAccessOverhead/SQLiteWAL",
    opening: { try RawAccessConnection(path: $0, journalMode: "WAL") },
    measure: { connection in
      var sum = 0
      for access in 0..<accessCount {
        sum &+= try connection.read(rowID: rowID(forAccess: access))
      }
      try expectAccessLookups(sum: sum)
    }
  )

  registerAccessBenchmark(
    "ReadAccessOverhead/Orbit",
    opening: { try OrbitConnection(path: $0) },
    measure: { connection in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try connection.owner.withReadConnection { connection in
          try connection.transaction { transaction in
            try transaction.fetchOne("SELECT i0 FROM item WHERE rowid = \(id)", as: Int.self)
          }
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectAccessLookups(sum: sum)
    }
  )

  // GRDB's synchronous read, for reference: it blocks on the queue rather than suspending.
  registerAccessBenchmark(
    "ReadAccessOverhead/GRDBQueueSync",
    opening: { try DatabaseQueue(path: $0) },
    measure: { dbQueue in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try dbQueue.read { db in
          try Int.fetchOne(db.cachedStatement(sql: accessLookupSQL), arguments: [id])
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectAccessLookups(sum: sum)
    }
  )

  registerAccessBenchmark(
    "ReadAccessOverhead/GRDBQueue",
    opening: { try DatabaseQueue(path: $0) },
    measure: { dbQueue in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try await dbQueue.read { db in
          try Int.fetchOne(db.cachedStatement(sql: accessLookupSQL), arguments: [id])
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectAccessLookups(sum: sum)
    }
  )

  registerAccessBenchmark(
    "ReadAccessOverhead/OrbitQueue",
    opening: { try SQLiteQueue(path: OrbitDatabasePath($0), configuration: .default) },
    measure: { queue in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try await queue.read { transaction in
          try transaction.fetchOne("SELECT i0 FROM item WHERE rowid = \(id)", as: Int.self)
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectAccessLookups(sum: sum)
    }
  )

  // Both pools default to five readers.
  registerAccessBenchmark(
    "ReadAccessOverhead/GRDBPool",
    opening: { try DatabasePool(path: $0) },
    measure: { dbPool in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try await dbPool.read { db in
          try Int.fetchOne(db.cachedStatement(sql: accessLookupSQL), arguments: [id])
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectAccessLookups(sum: sum)
    }
  )

  registerAccessBenchmark(
    "ReadAccessOverhead/OrbitPool",
    opening: { try SQLitePool(path: OrbitDatabasePath($0), configuration: .default) },
    measure: { pool in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try await pool.read { transaction in
          try transaction.fetchOne("SELECT i0 FROM item WHERE rowid = \(id)", as: Int.self)
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectAccessLookups(sum: sum)
    }
  )
}
