import MacroTesting
import SQLiteOrbitMacros
import SwiftSyntaxMacroExpansion
import Testing

@Suite(
  .macros(
    [
      "OrbitRow": MacroSpec(
        type: OrbitRowMacro.self,
        conformances: [
          "ConvertibleFromOrbitDatabaseRow", "ConvertibleToOrbitDatabaseRow",
          "PersistableOrbitDatabaseRow"
        ]
      ),
      "OrbitColumn": MacroSpec(type: OrbitColumnMacro.self)
    ],
    indentationWidth: .spaces(2)
  )
)
struct OrbitRowPersistenceMacroTests {
  @Test
  func synthesizesPublicPersistenceAndInfersRenamedIdentity() {
    assertMacro {
      """
      @OrbitRow(table: "reminders")
      public struct Reminder {
        @OrbitColumn("record_id") let id: Int64
        var title: String
        var notes: String?
        var computed: String { title }
      }
      """
    } expansion: {
      #"""
      public struct Reminder {
        let id: Int64
        var title: String
        var notes: String?
        var computed: String { title }
      }

      extension Reminder: SQLiteOrbit.ConvertibleFromOrbitDatabaseRow, SQLiteOrbit.ConvertibleToOrbitDatabaseRow, SQLiteOrbit.PersistableOrbitDatabaseRow {
        public init<__macro_local_3RowfMu_: SQLiteOrbit.OrbitDatabaseRow & ~Copyable & ~Escapable>(
          orbitDatabaseRow row: borrowing __macro_local_3RowfMu_
        ) throws {
          self.id = try row[column: "record_id", as: Int64.self]
          self.title = try row[column: "title", as: String.self]
          self.notes = try row[column: "notes", as: String?.self]
        }
        public static var orbitTableName: String {
          "reminders"
        }
        public static var orbitPrimaryKeyColumns: [String] {
          ["record_id"]
        }

        public static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? {
          switch keyPath {
          case \Self.id:
          return "record_id"
        case \Self.title:
          return "title"
        case \Self.notes:
          return "notes"
          default:
          return nil
          }
        }

        public func encodeOrbitDatabaseRow(into values: inout SQLiteOrbit.OrbitDatabaseRowValues<Self>) throws {
          try values.set(\.id, to: self.id)
        try values.set(\.title, to: self.title)
        try values.set(\.notes, to: self.notes)
        }
      }
      """#
    }
  }

  @Test
  func acceptsCompositeKeysAndKeylessTables() {
    assertMacro {
      """
      @OrbitRow(table: "memberships", primaryKey: ["account_id", "user_id"])
      struct Membership {
        @OrbitColumn("account_id") let account: Int
        @OrbitColumn("user_id") let user: Int
      }
      @OrbitRow(table: "events", primaryKey: [])
      struct Event {
        let id: String
      }
      """
    } expansion: {
      #"""
      struct Membership {
        let account: Int
        let user: Int
      }
      struct Event {
        let id: String
      }

      extension Membership: SQLiteOrbit.ConvertibleFromOrbitDatabaseRow, SQLiteOrbit.ConvertibleToOrbitDatabaseRow, SQLiteOrbit.PersistableOrbitDatabaseRow {
        init<__macro_local_3RowfMu_: SQLiteOrbit.OrbitDatabaseRow & ~Copyable & ~Escapable>(
          orbitDatabaseRow row: borrowing __macro_local_3RowfMu_
        ) throws {
          self.account = try row[column: "account_id", as: Int.self]
          self.user = try row[column: "user_id", as: Int.self]
        }
        static var orbitTableName: String {
          "memberships"
        }
        static var orbitPrimaryKeyColumns: [String] {
          ["account_id", "user_id"]
        }

        static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? {
          switch keyPath {
          case \Self.account:
          return "account_id"
        case \Self.user:
          return "user_id"
          default:
          return nil
          }
        }

        func encodeOrbitDatabaseRow(into values: inout SQLiteOrbit.OrbitDatabaseRowValues<Self>) throws {
          try values.set(\.account, to: self.account)
        try values.set(\.user, to: self.user)
        }
      }

      extension Event: SQLiteOrbit.ConvertibleFromOrbitDatabaseRow, SQLiteOrbit.ConvertibleToOrbitDatabaseRow, SQLiteOrbit.PersistableOrbitDatabaseRow {
        init<__macro_local_3RowfMu0_: SQLiteOrbit.OrbitDatabaseRow & ~Copyable & ~Escapable>(
          orbitDatabaseRow row: borrowing __macro_local_3RowfMu0_
        ) throws {
          self.id = try row[column: "id", as: String.self]
        }
        static var orbitTableName: String {
          "events"
        }
        static var orbitPrimaryKeyColumns: [String] {
          []
        }

        static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? {
          switch keyPath {
          case \Self.id:
          return "id"
          default:
          return nil
          }
        }

        func encodeOrbitDatabaseRow(into values: inout SQLiteOrbit.OrbitDatabaseRowValues<Self>) throws {
          try values.set(\.id, to: self.id)
        }
      }
      """#
    }
  }

  @Test
  func rejectsNonliteralTableNames() {
    assertMacro {
      """
      @OrbitRow(table: tableName)
      struct Record { let id: Int }
      """
    } diagnostics: {
      """
      @OrbitRow(table: tableName)
      ┬──────────────────────────
      ╰─ 🛑 '@OrbitRow' requires a string literal table name
      struct Record { let id: Int }
      """
    }
  }

  @Test
  func rejectsNonliteralPrimaryKeys() {
    assertMacro {
      """
      @OrbitRow(table: "records", primaryKey: [key])
      struct Record { let id: Int }
      """
    } diagnostics: {
      """
      @OrbitRow(table: "records", primaryKey: [key])
                                               ┬──
                                               ╰─ 🛑 'primaryKey' requires string literal SQL column names
      struct Record { let id: Int }
      """
    }
  }

  @Test
  func rejectsMissingAndDuplicatePrimaryKeyColumns() {
    assertMacro {
      """
      @OrbitRow(table: "records", primaryKey: ["missing"])
      struct Missing { let id: Int }
      @OrbitRow(table: "records", primaryKey: ["id", "id"])
      struct Duplicate { let id: Int }
      """
    } diagnostics: {
      """
      @OrbitRow(table: "records", primaryKey: ["missing"])
      ┬───────────────────────────────────────────────────
      ╰─ 🛑 'primaryKey' must contain distinct stored SQL column names
      struct Missing { let id: Int }
      @OrbitRow(table: "records", primaryKey: ["id", "id"])
      ┬────────────────────────────────────────────────────
      ╰─ 🛑 'primaryKey' must contain distinct stored SQL column names
      struct Duplicate { let id: Int }
      """
    }
  }

  @Test
  func rejectsDuplicateStoredColumnMappings() {
    assertMacro {
      """
      @OrbitRow(table: "records")
      struct Record {
        let id: Int
        @OrbitColumn("id") let alias: Int
      }
      """
    } diagnostics: {
      """
      @OrbitRow(table: "records")
      struct Record {
        let id: Int
        @OrbitColumn("id") let alias: Int
        ┬────────────────────────────────
        ╰─ 🛑 persistent properties must use distinct SQL column names
      }
      """
    }
  }

  @Test
  func rejectsExistingPersistenceMembers() {
    assertMacro {
      """
      @OrbitRow(table: "records")
      struct Record {
        let id: Int
        static let orbitTableName = "records"
      }
      """
    } diagnostics: {
      """
      @OrbitRow(table: "records")
      struct Record {
        let id: Int
        static let orbitTableName = "records"
        ┬────────────────────────────────────
        ╰─ 🛑 '@OrbitRow' would duplicate this persistence member
      }
      """
    }
  }
}
