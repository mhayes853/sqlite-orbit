import Benchmark
import BenchmarkSupport
import GRDB
import SQLiteOrbit

// No GRDB counterpart: 10,000 pairs of accesses, a write access followed by a read access, each
// looking up one row, so what is measured is what switching between the two kinds of access costs
// on top of what ReadAccessOverhead measures for reads alone. A connection that can write has to
// be kept from writing during a read and allowed to write again afterwards, and work it keeps
// between accesses, such as its compiled statements, may not survive the switch.
//
// The write access only reads, the same lookup as the read, so its transaction changes nothing:
// nothing reaches the disk and its commit does not sync, which leaves the access itself as all
// there is to measure. `SQLite` is the floor: the C API running the write as an immediate
// transaction and the read as a deferred one, with every statement prepared once. The synchronous
// `SQLiteConnection` is Orbit's floor, with no executor at all.
//
// Every implementation prepares the lookup through its statement cache: Orbit's `fetchOne` always
// does, and GRDB's through `cachedStatement`.

func registerAlternatingAccessOverhead() {
  registerAccessBenchmark(
    "AlternatingAccessOverhead/SQLite",
    opening: { try RawAccessConnection(path: $0) },
    measure: { connection in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        sum &+= try connection.write(rowID: id)
        sum &+= try connection.read(rowID: id)
      }
      try expectAccessLookups(sum: sum, accessesPerLookup: 2)
    }
  )

  registerAccessBenchmark(
    "AlternatingAccessOverhead/Orbit",
    opening: { try OrbitConnection(path: $0) },
    measure: { connection in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let written = try connection.owner.withWriteConnection { connection in
          try connection.transaction { transaction in
            try transaction.fetchOne("SELECT i0 FROM item WHERE rowid = \(id)", as: Int.self)
          }
        }
        let read = try connection.owner.withReadConnection { connection in
          try connection.transaction { transaction in
            try transaction.fetchOne("SELECT i0 FROM item WHERE rowid = \(id)", as: Int.self)
          }
        }
        guard let written, let read else { throw MissingRowError() }
        sum &+= written &+ read
      }
      try expectAccessLookups(sum: sum, accessesPerLookup: 2)
    }
  )

  // GRDB's synchronous accesses, for reference: they block on the queue rather than suspending.
  registerAccessBenchmark(
    "AlternatingAccessOverhead/GRDBQueueSync",
    opening: { try DatabaseQueue(path: $0) },
    measure: { dbQueue in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let written = try dbQueue.write { db in
          try Int.fetchOne(db.cachedStatement(sql: accessLookupSQL), arguments: [id])
        }
        let read = try dbQueue.read { db in
          try Int.fetchOne(db.cachedStatement(sql: accessLookupSQL), arguments: [id])
        }
        guard let written, let read else { throw MissingRowError() }
        sum &+= written &+ read
      }
      try expectAccessLookups(sum: sum, accessesPerLookup: 2)
    }
  )

  registerAccessBenchmark(
    "AlternatingAccessOverhead/GRDBQueue",
    opening: { try DatabaseQueue(path: $0) },
    measure: { dbQueue in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let written = try await dbQueue.write { db in
          try Int.fetchOne(db.cachedStatement(sql: accessLookupSQL), arguments: [id])
        }
        let read = try await dbQueue.read { db in
          try Int.fetchOne(db.cachedStatement(sql: accessLookupSQL), arguments: [id])
        }
        guard let written, let read else { throw MissingRowError() }
        sum &+= written &+ read
      }
      try expectAccessLookups(sum: sum, accessesPerLookup: 2)
    }
  )

  registerAccessBenchmark(
    "AlternatingAccessOverhead/OrbitQueue",
    opening: { try SQLiteQueue(path: OrbitDatabasePath($0), configuration: .default) },
    measure: { queue in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let written = try await queue.write { transaction in
          try transaction.fetchOne("SELECT i0 FROM item WHERE rowid = \(id)", as: Int.self)
        }
        let read = try await queue.read { transaction in
          try transaction.fetchOne("SELECT i0 FROM item WHERE rowid = \(id)", as: Int.self)
        }
        guard let written, let read else { throw MissingRowError() }
        sum &+= written &+ read
      }
      try expectAccessLookups(sum: sum, accessesPerLookup: 2)
    }
  )
}
