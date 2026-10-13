import MacroTesting
import SQLiteOrbitMacros
import SwiftSyntaxMacroExpansion
import Testing

@Suite(
  .macros(
    [
      "OrbitRow": MacroSpec(
        type: OrbitRowMacro.self,
        conformances: ["ConvertibleFromOrbitDatabaseRow", "OrbitDatabaseRowColumns"]
      ),
      "OrbitColumn": MacroSpec(type: OrbitColumnMacro.self)
    ],
    indentationWidth: .spaces(2)
  )
)
struct OrbitRowMacroTests {
  @Test
  func rejectsExistingColumnMappings() {
    assertMacro {
      """
      @OrbitRow
      struct Summary {
        let id: Int
        static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? { nil }
      }
      """
    } diagnostics: {
      """
      @OrbitRow
      struct Summary {
        let id: Int
        static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? { nil }
        ┬────────────────────────────────────────────────────────────────────────────────
        ╰─ 🛑 '@OrbitRow' would duplicate this column mapping; use a handwritten conformance instead
      }
      """
    }
  }

  @Test
  func rejectsConditionalMembers() {
    assertMacro {
      """
      @OrbitRow
      struct Summary {
        #if FEATURE
        let id: Int
        #endif
      }
      """
    } diagnostics: {
      """
      @OrbitRow
      struct Summary {
        #if FEATURE
        ╰─ 🛑 '@OrbitRow' does not support conditional members; use a handwritten conformance
        let id: Int
        #endif
      }
      """
    }
  }

  @Test
  func synthesizesNamedReadsAndIgnoresComputedAndStaticProperties() {
    assertMacro {
      """
      @OrbitRow
      public struct Summary {
        let id: Int
        @OrbitColumn("display_title") var title: String = ""
        var priority: Int?
        static let table = "reminders"
        var isImportant: Bool { priority != nil }
      }
      """
    } expansion: {
      """
      public struct Summary {
        let id: Int
        var title: String = ""
        var priority: Int?
        static let table = "reminders"
        var isImportant: Bool { priority != nil }
      }

      extension Summary: SQLiteOrbit.ConvertibleFromOrbitDatabaseRow, SQLiteOrbit.OrbitDatabaseRowColumns {
        public init<__macro_local_3RowfMu_: SQLiteOrbit.OrbitDatabaseRow & ~Copyable & ~Escapable>(
          orbitDatabaseRow row: borrowing __macro_local_3RowfMu_
        ) throws {
          self.id = try row[column: "id", as: Int.self]
          self.title = try row[column: "display_title", as: String.self]
          self.priority = try row[column: "priority", as: Int?.self]
        }

        public static func orbitColumnName(for keyPath: Swift.PartialKeyPath<Self>) -> Swift.String? {
          switch keyPath {
          case \\Self.id:
            return "id"
          case \\Self.title:
            return "display_title"
          case \\Self.priority:
            return "priority"
          default:
            return nil
          }
        }
      }
      """
    }
  }

  @Test
  func handlesEscapedIdentifiersColumnNamesAndGenericParameterShadowing() {
    assertMacro {
      #"""
      @OrbitRow
      struct Box<Row: ConvertibleFromOrbitDatabaseValue> {
        @OrbitColumn("a \"quoted\" column") let `class`: Row
      }
      """#
    } expansion: {
      """
      struct Box<Row: ConvertibleFromOrbitDatabaseValue> {
        let `class`: Row
      }

      extension Box: SQLiteOrbit.ConvertibleFromOrbitDatabaseRow, SQLiteOrbit.OrbitDatabaseRowColumns {
        init<__macro_local_3RowfMu_: SQLiteOrbit.OrbitDatabaseRow & ~Copyable & ~Escapable>(
          orbitDatabaseRow row: borrowing __macro_local_3RowfMu_
        ) throws {
          self.`class` = try row[column: #"a "quoted" column"#, as: Row.self]
        }

        static func orbitColumnName(for keyPath: Swift.PartialKeyPath<Self>) -> Swift.String? {
          switch keyPath {
          case \\Self.`class`:
            return #"a "quoted" column"#
          default:
            return nil
          }
        }
      }
      """
    }
  }

  @Test
  func rejectsClasses() {
    assertMacro {
      """
      @OrbitRow
      class Summary {
        let id: Int
      }
      """
    } diagnostics: {
      """
      @OrbitRow
      ┬────────
      ╰─ 🛑 '@OrbitRow' can only be applied to structs
      class Summary {
        let id: Int
      }
      """
    }
  }

  @Test
  func requiresExplicitStoredPropertyTypes() {
    assertMacro {
      """
      @OrbitRow
      struct Summary {
        var id = 0
      }
      """
    } diagnostics: {
      """
      @OrbitRow
      struct Summary {
        var id = 0
            ┬─
            ╰─ 🛑 '@OrbitRow' requires an explicit type for stored property 'id'
      }
      """
    }
  }

  @Test
  func rejectsInitializedLetProperties() {
    assertMacro {
      """
      @OrbitRow
      struct Summary {
        let id: Int = 0
      }
      """
    } diagnostics: {
      """
      @OrbitRow
      struct Summary {
        let id: Int = 0
                    ┬──
                    ╰─ 🛑 '@OrbitRow' cannot decode a 'let' property with an initializer; remove the initializer or use a handwritten conformance
      }
      """
    }
  }

  @Test
  func rejectsPropertyWrappers() {
    assertMacro {
      """
      @OrbitRow
      struct Summary {
        @Wrapped var id: Int
      }
      """
    } diagnostics: {
      """
      @OrbitRow
      struct Summary {
        @Wrapped var id: Int
        ┬───────
        ╰─ 🛑 '@OrbitRow' does not support property wrappers or other property attributes; use a handwritten conformance
      }
      """
    }
  }

  @Test
  func rejectsDuplicateInitializers() {
    assertMacro {
      """
      @OrbitRow
      struct Summary {
        let id: Int
        init(orbitDatabaseRow row: Int) { id = row }
      }
      """
    } diagnostics: {
      """
      @OrbitRow
      struct Summary {
        let id: Int
        init(orbitDatabaseRow row: Int) { id = row }
        ┬───────────────────────────────────────────
        ╰─ 🛑 '@OrbitRow' would duplicate this row initializer; use a handwritten conformance instead
      }
      """
    }
  }

  @Test
  func rejectsInterpolatedColumnNames() {
    assertMacro {
      #"""
      @OrbitRow
      struct Summary {
        @OrbitColumn("column_\(suffix)") let id: Int
      }
      """#
    } diagnostics: {
      #"""
      @OrbitRow
      struct Summary {
        @OrbitColumn("column_\(suffix)") let id: Int
        ┬───────────────────────────────
        ╰─ 🛑 '@OrbitColumn' requires one string literal column name
      }
      """#
    }
  }

  @Test
  func requiresColumnMarkersToBeInsideAnOrbitRow() {
    assertMacro {
      """
      struct Summary {
        @OrbitColumn("identifier") let id: Int
      }
      """
    } diagnostics: {
      """
      struct Summary {
        @OrbitColumn("identifier") let id: Int
        ┬─────────────────────────
        ╰─ 🛑 '@OrbitColumn' requires a stored instance property inside an '@OrbitRow' struct
      }
      """
    }
  }

  @Test
  func rejectsColumnMarkersOnComputedProperties() {
    assertMacro {
      """
      @OrbitRow
      struct Summary {
        @OrbitColumn("identifier") var id: Int { 1 }
      }
      """
    } diagnostics: {
      """
      @OrbitRow
      struct Summary {
        @OrbitColumn("identifier") var id: Int { 1 }
        ┬─────────────────────────
        ╰─ 🛑 '@OrbitColumn' requires a stored instance property inside an '@OrbitRow' struct
      }
      """
    }
  }

  @Test
  func rejectsMultipleBindingsAndLazyProperties() {
    assertMacro {
      """
      @OrbitRow
      struct Summary {
        let id: Int, other: Int
      }
      @OrbitRow
      struct LazySummary {
        lazy var id: Int = 0
      }
      """
    } diagnostics: {
      """
      @OrbitRow
      struct Summary {
        let id: Int, other: Int
        ┬──────────────────────
        ╰─ 🛑 '@OrbitRow' requires one named property per declaration
      }
      @OrbitRow
      struct LazySummary {
        lazy var id: Int = 0
        ┬───────────────────
        ╰─ 🛑 '@OrbitRow' does not support lazy properties; use a handwritten conformance
      }
      """
    }
  }
}
