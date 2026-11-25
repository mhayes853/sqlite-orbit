import BenchmarkSupport
import GRDB
import SQLiteOrbit

// A pool after one read, after five concurrent reads (so five readers are open), and after five
// concurrent reads followed by releasing memory. Both pools default to five readers, opened as
// reads need them.

private func openGRDBPool(path: String, reads: Int) throws -> DatabasePool {
  let pool = try DatabasePool(path: path)
  try concurrentReads(reads) { rendezvous in
    try expectLookup(
      try pool.read { db in
        rendezvous()
        return try Int.fetchOne(db.cachedStatement(sql: lookupSQL), arguments: [1])
      }
    )
  }
  return pool
}

private func openOrbitPool(path: String, reads: Int) throws -> SQLitePool {
  let pool = try SQLitePool(path: OrbitDatabasePath(path), configuration: .default)
  try concurrentReads(reads) { rendezvous in
    try expectLookup(
      try pool.readBlocking { transaction in
        rendezvous()
        return try transaction.fetchOne(orbitLookup, as: Int.self)
      }
    )
  }
  return pool
}

func registerPoolMemory() {
  registerMemoryBenchmark("MemoryPoolOneRead/GRDBPool") { try openGRDBPool(path: $0, reads: 1) }
  registerMemoryBenchmark("MemoryPoolOneRead/OrbitPool") { try openOrbitPool(path: $0, reads: 1) }

  registerMemoryBenchmark("MemoryPoolFiveReads/GRDBPool") { try openGRDBPool(path: $0, reads: 5) }
  registerMemoryBenchmark("MemoryPoolFiveReads/OrbitPool") { try openOrbitPool(path: $0, reads: 5) }

  registerMemoryBenchmark("MemoryPoolReleased/GRDBPool") { path in
    let pool = try openGRDBPool(path: path, reads: 5)
    pool.releaseMemory()
    return pool
  }
  registerMemoryBenchmark("MemoryPoolReleased/OrbitPool") { path in
    let pool = try openOrbitPool(path: path, reads: 5)
    await pool.releaseMemory()
    return pool
  }
}
