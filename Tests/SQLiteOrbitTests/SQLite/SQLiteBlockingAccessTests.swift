#if SystemSQLite
  import Dispatch
  import Foundation
  import StructuredQueries
  import Synchronization
  import Testing

  @testable import SQLiteOrbit

  private struct BlockingTestDatabase: ~Copyable {
    let path: OrbitDatabasePath
    init() {
      self.path = OrbitDatabasePath(
        temporaryDatabasePath("blocking")
      )
    }
    deinit {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path.sqlitePath + suffix)
      }
    }
  }

  @Test
  func blockingAccessOnThePoolReadsItsOwnWrite() async throws {
    let database = BlockingTestDatabase()
    let driver = try SQLitePool(path: database.path)
    try await driver.write { try $0.execute("CREATE TABLE counter (n INTEGER NOT NULL)") }

    try driver.writeBlocking { try $0.execute("INSERT INTO counter (n) VALUES (41)") }
    let n: Int? = try driver.readBlocking { transaction in
      try transaction.fetchOne(#sql("SELECT n FROM counter", as: Int.self))
    }
    #expect(n == 41)
  }

  /// Blocking writers on their own threads and asynchronous writers in tasks, all at once.
  @Test
  func blockingAndAsynchronousWritersShareOneLine() async throws {
    let database = BlockingTestDatabase()
    let driver = try SQLitePool(path: database.path)
    try await driver.write { try $0.execute("CREATE TABLE counter (n INTEGER NOT NULL)") }
    try await driver.write { try $0.execute("INSERT INTO counter (n) VALUES (0)") }

    let writeBlockingrs = 8
    let asyncWriters = 8
    let bumpsEach = 20

    let done = DispatchSemaphore(value: 0)
    for _ in 0..<writeBlockingrs {
      Thread.detachNewThread {
        for _ in 0..<bumpsEach {
          try! driver.writeBlocking { try $0.execute("UPDATE counter SET n = n + 1") }
          _ = try! driver.readBlocking { try $0.execute("SELECT n FROM counter") }
        }
        done.signal()
      }
    }

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<asyncWriters {
        group.addTask {
          for _ in 0..<bumpsEach {
            try! await driver.write { try $0.execute("UPDATE counter SET n = n + 1") }
            try! await driver.read { try $0.execute("SELECT n FROM counter") }
          }
        }
      }
    }
    for _ in 0..<writeBlockingrs { done.wait() }

    let total: Int? = try driver.readBlocking { transaction in
      try transaction.fetchOne(#sql("SELECT n FROM counter", as: Int.self))
    }
    #expect(total == (writeBlockingrs + asyncWriters) * bumpsEach)
  }

  /// A blocking read issued after an asynchronous write must observe that write.
  @Test
  func aBlockingReadIssuedAfterAnAsynchronousWriteObservesIt() async throws {
    let database = BlockingTestDatabase()
    let driver = try SQLitePool(path: database.path)
    try await driver.write { try $0.execute("CREATE TABLE counter (n INTEGER NOT NULL)") }
    for round in 1...50 {
      try await driver.write {
        try $0.execute("DELETE FROM counter; INSERT INTO counter (n) VALUES (\(round))")
      }
      let n: Int? = try driver.readBlocking { transaction in
        try transaction.fetchOne(#sql("SELECT n FROM counter", as: Int.self))
      }
      #expect(n == round)
    }
  }

  @Test
  func theQueueDriverAlsoBlocks() async throws {
    let driver = try SQLiteQueue(path: .memory)
    try await driver.write { try $0.execute("CREATE TABLE counter (n INTEGER NOT NULL)") }
    try driver.writeBlocking { try $0.execute("INSERT INTO counter (n) VALUES (7)") }
    let n: Int? = try driver.readBlocking { transaction in
      try transaction.fetchOne(#sql("SELECT n FROM counter", as: Int.self))
    }
    #expect(n == 7)
  }

  /// The case that used to hang: the inner read wants a reader while the outer write holds the
  /// writer, so neither can finish. The two are on different connections, so only the scheduler
  /// is in a position to notice.
  @Test func aBlockingReadNestedInsideABlockingWriteIsReported() async throws {
    await #expect(processExitsWith: .failure) {
      let database = BlockingTestDatabase()
      let driver = try SQLitePool(path: database.path)
      try driver.writeBlocking { _ in
        _ = try driver.readBlocking { _ in 1 }
      }
    }
  }

  @Test func aBlockingAccessNestedOnOneConnectionIsReported() async throws {
    await #expect(processExitsWith: .failure) {
      let driver = try SQLiteQueue(path: .memory)
      try driver.readBlocking { _ in
        _ = try driver.readBlocking { _ in 1 }
      }
    }
  }

  /// Nesting across two different databases is not reentrancy: neither access waits on the other.
  @Test func aBlockingAccessOnAnotherDatabaseIsNotReentrancy() async throws {
    let first = BlockingTestDatabase()
    let second = BlockingTestDatabase()
    let a = try SQLitePool(path: first.path)
    let b = try SQLitePool(path: second.path)
    try await a.write { try $0.execute("CREATE TABLE t (n INTEGER NOT NULL)") }
    try await b.write { try $0.execute("CREATE TABLE t (n INTEGER NOT NULL)") }

    let copied: Int? = try a.writeBlocking { transaction in
      try transaction.execute("INSERT INTO t (n) VALUES (5)")
      return try b.readBlocking { try $0.fetchOne(#sql("SELECT count(*) FROM t", as: Int.self)) }
    }
    #expect(copied == 0)
  }

  /// A blocking writer releases its reentrancy marker, so the same thread may write again.
  @Test func aThreadMayTakeAnotherBlockingAccessAfterItsFirstOneEnds() async throws {
    let database = BlockingTestDatabase()
    let driver = try SQLitePool(path: database.path)
    try driver.writeBlocking { try $0.execute("CREATE TABLE t (n INTEGER NOT NULL)") }
    for _ in 0..<10 {
      try driver.writeBlocking { try $0.execute("INSERT INTO t (n) VALUES (1)") }
      _ = try driver.readBlocking { try $0.fetchOne(#sql("SELECT count(*) FROM t", as: Int.self)) }
    }
    let total: Int? = try driver.readBlocking {
      try $0.fetchOne(#sql("SELECT count(*) FROM t", as: Int.self))
    }
    #expect(total == 10)
  }
#endif
