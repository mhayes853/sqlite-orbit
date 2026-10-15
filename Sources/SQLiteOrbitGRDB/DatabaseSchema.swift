#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  public struct IndexInfo: Sendable {
    public struct Origin: RawRepresentable, Equatable, DatabaseValueConvertible, Sendable {
      public var rawValue: String

      public init(rawValue: String) {
        self.rawValue = rawValue
      }

      public static let createIndex = Self(rawValue: "c")
      public static let uniqueConstraint = Self(rawValue: "u")
      public static let primaryKeyConstraint = Self(rawValue: "pk")

      public var databaseValue: DatabaseValue {
        rawValue.databaseValue
      }

      public static func fromDatabaseValue(_ value: DatabaseValue) -> Self? {
        String.fromDatabaseValue(value).map(Self.init(rawValue:))
      }
    }

    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let origin: Origin
  }

  public struct ForeignKeyInfo: Sendable {
    public var id: Int
    public let destinationTable: String
    public let mapping: [(origin: String, destination: String)]

    public var originColumns: [String] {
      mapping.map(\.origin)
    }

    public var destinationColumns: [String] {
      mapping.map(\.destination)
    }
  }

  extension Database {
    public func schemaVersion() throws -> Int32 {
      try Int32.fetchOne(self, sql: "PRAGMA schema_version")!
    }

    public func tableExists(_ name: String, in schemaName: String? = nil) throws -> Bool {
      try objectSchema(name, types: ["table"], in: schemaName) != nil
    }

    public func viewExists(_ name: String, in schemaName: String? = nil) throws -> Bool {
      try objectSchema(name, types: ["view"], in: schemaName) != nil
    }

    public func triggerExists(_ name: String, in schemaName: String? = nil) throws -> Bool {
      try objectSchema(name, types: ["trigger"], in: schemaName) != nil
    }

    public func columns(in table: String, in schemaName: String? = nil) throws -> [ColumnInfo] {
      let schema = try requireObjectSchema(table, types: ["table", "view"], in: schemaName)
      var rows: [Row]
      do {
        rows = try Row.fetchAll(self, sql: "PRAGMA \(quoted(schema)).table_xinfo(\(quoted(table)))")
      } catch let error as DatabaseError where error.resultCode == .SQLITE_ERROR {
        rows = try Row.fetchAll(self, sql: "PRAGMA \(quoted(schema)).table_info(\(quoted(table)))")
      }
      if rows.isEmpty {
        rows = try Row.fetchAll(self, sql: "PRAGMA \(quoted(schema)).table_info(\(quoted(table)))")
      }
      return rows.filter { !$0.hasColumn("hidden") || ($0["hidden"] as Int) != 1 }
        .map {
          ColumnInfo(
            cid: $0["cid"],
            name: $0["name"],
            type: $0["type"],
            notNull: $0["notnull"],
            defaultValueSQL: $0["dflt_value"],
            primaryKeyIndex: $0["pk"]
          )
        }
    }

    public func primaryKey(_ table: String, in schemaName: String? = nil) throws -> PrimaryKeyInfo {
      let schema = try requireObjectSchema(table, types: ["table"], in: schemaName)
      let tableColumns = try columns(in: table, in: schema)
      let columns = tableColumns.filter { $0.primaryKeyIndex > 0 }
        .sorted { $0.primaryKeyIndex < $1.primaryKeyIndex }
      let hasPrimaryKeyIndex = try indexes(on: table, in: schema)
        .contains { $0.origin == .primaryKeyConstraint }
      let integer =
        columns.count == 1 && columns[0].type.uppercased() == "INTEGER"
          && !hasPrimaryKeyIndex ? columns[0].name : nil
      let keyColumns: [String]
      if columns.isEmpty {
        let names = Set(tableColumns.map { $0.name.lowercased() })
        guard let alias = ["rowid", "_rowid_", "oid"].first(where: { !names.contains($0) }) else {
          throw DatabaseError(message: "table has no accessible primary key: \(table)")
        }
        keyColumns = [alias]
      } else {
        keyColumns = columns.map(\.name)
      }
      return PrimaryKeyInfo(columns: keyColumns, rowIDColumn: integer, hiddenRowID: columns.isEmpty)
    }

    public func indexes(on table: String, in schemaName: String? = nil) throws -> [IndexInfo] {
      let schema = try requireObjectSchema(table, types: ["table"], in: schemaName)
      return try Row.fetchAll(self, sql: "PRAGMA \(quoted(schema)).index_list(\(quoted(table)))")
        .compactMap { row in
          let name: String = row["name"]
          let parts =
            try Row.fetchAll(self, sql: "PRAGMA \(quoted(schema)).index_info(\(quoted(name)))")
            .sorted { ($0["seqno"] as Int) < ($1["seqno"] as Int) }
          // GRDB's IndexInfo cannot represent expression or rowid indexes and excludes them.
          let columns: [String?] = parts.map { $0["name"] }
          guard columns.allSatisfy({ $0 != nil }) else {
            return nil
          }
          return IndexInfo(
            name: name,
            columns: columns.compactMap { $0 },
            isUnique: row["unique"],
            origin: row["origin"]
          )
        }
    }

    public func foreignKeys(on table: String, in schemaName: String? = nil) throws
      -> [ForeignKeyInfo]
    {
      let schema = try requireObjectSchema(table, types: ["table"], in: schemaName)
      let rows = try Row.fetchAll(
        self,
        sql: "PRAGMA \(quoted(schema)).foreign_key_list(\(quoted(table)))"
      )
      let groups = Dictionary(grouping: rows) { $0["id"] as Int }
      return try groups.keys.sorted()
        .map { id in
          let parts = groups[id]!.sorted { ($0["seq"] as Int) < ($1["seq"] as Int) }
          let destinationTable: String = parts[0]["table"]
          let implicit = parts.contains { ($0["to"] as String?) == nil }
          let primaryKey = implicit ? try primaryKey(destinationTable, in: schema).columns : []
          guard !implicit || primaryKey.count == parts.count else {
            throw DatabaseError(
              message: "foreign key mismatch: \(table) referencing \(destinationTable)"
            )
          }
          let mapping = parts.enumerated()
            .map { index, row in
              (
                origin: row["from"] as String,
                destination: (row["to"] as String?) ?? primaryKey[index]
              )
            }
          return ForeignKeyInfo(id: id, destinationTable: destinationTable, mapping: mapping)
        }
    }

    public func table(_ table: String, hasUniqueKey columns: some Sequence<String>) throws -> Bool {
      let columns = Set(columns.map { $0.lowercased() })
      if columns.isEmpty {
        return false
      }
      guard try tableExists(table) else {
        return false
      }
      if columns.contains("rowid"),
        (try? access.statementInfo("SELECT rowid FROM \(quoted(table)) LIMIT 0")) != nil
      {
        return true
      }
      let key = Set(try primaryKey(table).columns.map { $0.lowercased() })
      if key.isSubset(of: columns) {
        return true
      }
      return try indexes(on: table)
        .contains {
          $0.isUnique && Set($0.columns.map { $0.lowercased() }).isSubset(of: columns)
        }
    }

    private func objectSchema(_ name: String, types: [String], in schemaName: String?) throws
      -> String?
    {
      var schemas = try Row.fetchAll(self, sql: "PRAGMA database_list").map { $0["name"] as String }
      if let temp = schemas.firstIndex(where: { $0.lowercased() == "temp" }) {
        schemas.insert(schemas.remove(at: temp), at: 0)
      }
      if let schemaName {
        guard
          let schema = schemas.first(where: {
            $0.caseInsensitiveCompare(schemaName) == .orderedSame
          })
        else {
          throw DatabaseError(message: "no such schema: \(schemaName)")
        }
        schemas = [schema]
      }
      for schema in schemas {
        if try Bool.fetchOne(
          self,
          sql:
            "SELECT EXISTS(SELECT 1 FROM \(quoted(schema)).sqlite_schema WHERE name = ? COLLATE NOCASE AND type IN (\(Array(repeating: "?", count: types.count).joined(separator: ","))))",
          arguments: StatementArguments([name] + types)
        ) == true {
          return schema
        }
      }
      return nil
    }

    private func requireObjectSchema(_ name: String, types: [String], in schemaName: String?) throws
      -> String
    {
      guard let schema = try objectSchema(name, types: types, in: schemaName) else {
        throw DatabaseError(message: "no such table: \(name)")
      }
      return schema
    }
  }
#endif
