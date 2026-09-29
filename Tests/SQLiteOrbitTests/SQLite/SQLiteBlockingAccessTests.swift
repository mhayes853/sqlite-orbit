#if BuiltInSQLite
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  // The blocking accesses every driver shares, and the ones that mix with its asynchronous
  // accesses, are in `SQLiteDriverTests`. These are about what a blocking access may not do.

  @Test func aBlockingReadNestedInsideABlockingWriteIsReported() async throws {
    await #expect(processExitsWith: .failure) {
      try withTestDatabaseFile { file in
        let driver = try file.pool()
        try driver.writeBlocking { _ in
          _ = try driver.readBlocking { _ in 1 }
        }
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

  @Test func aBlockingAccessInsideAnAsynchronousOneOnTheSameConnectionIsReported() async throws {
    await #expect(processExitsWith: .failure) {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.read { _ in
        _ = try driver.readBlocking { _ in 1 }
      }
    }
  }

  @Test func aBlockingAccessOnAnotherDatabaseIsNotReentrancy() async throws {
    try await withTestDatabaseFile { first in
      try await withTestDatabaseFile { second in
        let a = try first.pool()
        let b = try second.pool()
        try await a.execute(sql: "CREATE TABLE t (n INTEGER NOT NULL)")
        try await b.execute(sql: "CREATE TABLE t (n INTEGER NOT NULL)")

        let copied: Int? = try a.writeBlocking { transaction in
          try transaction.execute("INSERT INTO t (n) VALUES (5)")
          return try b.readBlocking {
            try $0.fetchOne("SELECT count(*) FROM t", as: Int.self)
          }
        }
        #expect(copied == 0)
      }
    }
  }
#endif
