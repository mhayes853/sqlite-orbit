import BenchmarkSupport
import GRDB
import SQLiteOrbit

// One connection or queue, after one read.

func registerOpenMemory() {
  registerMemoryBenchmark("MemoryOpenRead/SQLite") { path in
    let connection = try RawStatementConnection(path: path)
    try expectLookup(try connection.read())
    return connection
  }

  registerMemoryBenchmark("MemoryOpenRead/GRDBQueue") { path in
    let queue = try DatabaseQueue(path: path)
    try expectLookup(
      try queue.read { try Int.fetchOne($0.cachedStatement(sql: lookupSQL), arguments: [1]) }
    )
    return queue
  }

  registerMemoryBenchmark("MemoryOpenRead/Orbit") { path in
    let connection = try OrbitConnection(path: path)
    try expectLookup(
      try connection.owner.withReadConnection {
        try $0.transaction { try $0.fetchOne(orbitLookup, as: Int.self) }
      }
    )
    return connection
  }

  registerMemoryBenchmark("MemoryOpenRead/OrbitQueue") { path in
    let queue = try SQLiteQueue(path: OrbitDatabasePath(path), configuration: .default)
    try expectLookup(try queue.readBlocking { try $0.fetchOne(orbitLookup, as: Int.self) })
    return queue
  }
}
