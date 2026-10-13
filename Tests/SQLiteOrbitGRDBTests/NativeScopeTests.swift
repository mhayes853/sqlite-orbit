import Foundation
@_spi(GRDB) import SQLiteOrbit
import Testing

@testable import SQLiteOrbitGRDB

@Suite("GRDB native scopes")
struct NativeScopeTests {
  @Test func cachedTransactionControlUsesTheCurrentScope() throws {
    let queue = try DatabaseQueue()
    try queue.writeWithoutTransaction { db in
      try db.inTransaction {
        try db.cachedStatement(sql: "SAVEPOINT test").execute()
        try db.execute(sql: "RELEASE test")
        return .commit
      }
      let error = #expect(throws: DatabaseError.self) {
        try db.cachedStatement(sql: "SAVEPOINT test").execute()
      }
      #expect(error?.resultCode == .SQLITE_AUTH)
      #expect(!db.isInsideTransaction)
    }
  }

  @Test func overlayCursorsParticipateInNativeAuthorizationScopes() throws {
    let queue = try SQLiteOrbit.SQLiteQueue(path: .memory)
    try queue.readBlocking { transaction in
      try transaction.withGRDBAccess { access in
        let db = SQLiteOrbitGRDB.Database(access)
        func holdCursor() throws {
          let cursor = try SQLiteOrbitGRDB.Row.fetchCursor(db, sql: "SELECT 1")
          #expect(try cursor.next() != nil)
          #expect(throws: SQLiteError.self) {
            try access.withConnectionAccess { connection in
              try connection.withAuthorization({ _ in .allow }) {
                Issue.record("Authorization changed with an outstanding overlay cursor")
              }
            }
          }
        }
        try holdCursor()
        try access.withConnectionAccess { connection in
          try connection.withAuthorization({ event in
            if case .select = event.action { return .deny }
            return .allow
          }) {
            let error = #expect(throws: DatabaseError.self) {
              _ = try Int.fetchOne(db, sql: "SELECT 1")
            }
            #expect(error?.resultCode == .SQLITE_AUTH)
          }
        }
        #expect(try Int.fetchOne(db, sql: "SELECT 1") == 1)
      }
    }
  }
}
