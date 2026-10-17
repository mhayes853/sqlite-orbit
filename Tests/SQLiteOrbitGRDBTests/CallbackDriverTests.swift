import Foundation
import SQLiteOrbit
import SQLiteOrbitGRDB
import Testing

private func exerciseCallbacks(_ database: any DatabaseWriter) async throws {
  let count: Int = try await withCheckedThrowingContinuation { continuation in
    database.asyncWrite { db in
      #expect(db.isInsideTransaction)
      try db.execute(
        sql: "CREATE TABLE IF NOT EXISTS item(n); DELETE FROM item; INSERT INTO item VALUES (1)"
      )
      return 1
    } completion: { db, result in
      #expect(!db.isInsideTransaction)
      do {
        #expect(try result.get() == 1)
        continuation.resume(returning: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item")!)
      } catch { continuation.resume(throwing: error) }
    }
  }
  #expect(count == 1)
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    database.asyncWriteWithoutTransaction { db in
      #expect(!db.isInsideTransaction)
      do {
        try db.execute(sql: "INSERT INTO item VALUES (2)")
        continuation.resume()
      } catch { continuation.resume(throwing: error) }
    }
  }
  #expect(
    try await database.read { try Int.fetchAll($0, sql: "SELECT n FROM item ORDER BY n") } == [1, 2]
  )
}

@Suite("GRDB callback drivers", .timeLimit(.minutes(1)))
struct CallbackDriverTests {
  @Test
  func nativeDriversAndTypeErasure() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: file.path + suffix)
      }
    }
    let queue = try SQLiteOrbit.SQLiteQueue(path: .memory)
    try await exerciseCallbacks(queue)
    try await exerciseCallbacks(AnyDatabaseWriter(queue))
    let pool = try SQLiteOrbit.SQLitePool(path: OrbitDatabasePath(file.path))
    try await exerciseCallbacks(pool)
    try await exerciseCallbacks(AnyDatabaseWriter(pool))
    #if Turso
      let turso = try TursoPool(path: OrbitDatabasePath(file.path + ".turso"))
      defer { try? FileManager.default.removeItem(atPath: file.path + ".turso") }
      try await exerciseCallbacks(turso)
    #endif
  }

  @Test
  func callbackWritesNotifyIPCPeers() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: file.path + suffix)
      }
    }
    let network = SQLiteOrbit.InMemoryIPCTransport.Network()
    let first = OrbitIPCDatabase(
      writer: try SQLiteOrbit.SQLitePool(path: OrbitDatabasePath(file.path)),
      transport: InMemoryIPCTransport(network: network)
    )
    let second = OrbitIPCDatabase(
      writer: try SQLiteOrbit.SQLitePool(path: OrbitDatabasePath(file.path)),
      transport: InMemoryIPCTransport(network: network)
    )
    try await first.write { (db: SQLiteOrbitGRDB.Database) in
      try db.execute(sql: "CREATE TABLE item(n)")
    }
    var iterator = SQLiteOrbitGRDB.ValueObservation
      .tracking { db in
        try Int.fetchAll(db, sql: "SELECT n FROM item ORDER BY n")
      }
      .values(in: second).makeAsyncIterator()
    #expect(try await iterator.next() == [])
    try await exerciseCallbacks(first)
    // Observation can coalesce the two commits; the last value must reach the peer.
    while let value = try await iterator.next() {
      if value == [1, 2] { return }
    }
    Issue.record("Observation ended before receiving callback writes")
  }
}
