#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  public enum RecordError: Error, Sendable {
    case recordNotFound(databaseTableName: String, key: [String: DatabaseValue])
  }

  public struct PersistenceConflictPolicy: Sendable {
    public let conflictResolutionForInsert: Database.ConflictResolution
    public let conflictResolutionForUpdate: Database.ConflictResolution

    public init(
      insert: Database.ConflictResolution = .abort,
      update: Database.ConflictResolution = .abort
    ) {
      conflictResolutionForInsert = insert
      conflictResolutionForUpdate = update
    }
  }

  public struct InsertionSuccess: Sendable {
    public var rowID: Int64
    public var rowIDColumn: String?
    public var persistenceContainer: PersistenceContainer
  }

  public struct PersistenceSuccess: Sendable {
    public var persistenceContainer: PersistenceContainer
  }

  public protocol MutablePersistableRecord: EncodableRecord, TableRecord {
    static var persistenceConflictPolicy: PersistenceConflictPolicy { get }

    mutating func willInsert(_ db: Database) throws

    func aroundInsert(_ db: Database, insert: () throws -> InsertionSuccess) throws

    mutating func didInsert(_ inserted: InsertionSuccess)

    func willUpdate(_ db: Database, columns: Set<String>) throws

    func aroundUpdate(_ db: Database, columns: Set<String>, update: () throws -> PersistenceSuccess)
      throws

    func didUpdate(_ updated: PersistenceSuccess)

    func willSave(_ db: Database) throws

    func aroundSave(_ db: Database, save: () throws -> PersistenceSuccess) throws

    func didSave(_ saved: PersistenceSuccess)

    func willDelete(_ db: Database) throws

    func aroundDelete(_ db: Database, delete: () throws -> Bool) throws

    func didDelete(deleted: Bool)
  }

  public protocol PersistableRecord: MutablePersistableRecord {
    func willInsert(_ db: Database) throws

    func didInsert(_ inserted: InsertionSuccess)

    func willSave(_ db: Database) throws

    func didSave(_ saved: PersistenceSuccess)
  }

  extension MutablePersistableRecord {
    public static var persistenceConflictPolicy: PersistenceConflictPolicy {
      .init()
    }

    public mutating func willInsert(_ db: Database) throws {}

    public func aroundInsert(_ db: Database, insert: () throws -> InsertionSuccess) throws {
      _ = try insert()
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {}

    public func willUpdate(_ db: Database, columns: Set<String>) throws {}

    public func aroundUpdate(
      _ db: Database,
      columns: Set<String>,
      update: () throws -> PersistenceSuccess
    ) throws {
      _ = try update()
    }

    public func didUpdate(_ updated: PersistenceSuccess) {}

    public func willSave(_ db: Database) throws {}

    public func aroundSave(_ db: Database, save: () throws -> PersistenceSuccess) throws {
      _ = try save()
    }

    public func didSave(_ saved: PersistenceSuccess) {}

    public func willDelete(_ db: Database) throws {}

    public func aroundDelete(_ db: Database, delete: () throws -> Bool) throws {
      _ = try delete()
    }

    public func didDelete(deleted: Bool) {}

    public mutating func insert(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws {
      try insertRecord(
        db,
        conflict: conflictResolution,
        selection: [],
        fetch: { try $0.execute() }
      )
    }

    public func update(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws {
      try update(
        db,
        columns: Set(try PersistenceContainer(self).fields.map(\.0)),
        onConflict: conflictResolution
      )
    }

    public func update(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil,
      columns: some Collection<String>
    ) throws {
      try update(db, columns: Set(columns), onConflict: conflictResolution)
    }

    public func update(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      columns: some Collection<some ColumnExpression>
    ) throws {
      try update(db, onConflict: conflict, columns: columns.map(\.name))
    }

    public func update(
      _ db: Database,
      columns: Set<String>,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws {
      try updateRecord(
        db,
        conflict: conflictResolution,
        columns: columns,
        selection: [],
        fetch: { try $0.execute() }
      )
    }

    public mutating func save(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws {
      try saveRecord(
        db,
        conflict: conflictResolution,
        selection: [],
        fetch: { try $0.execute() }
      )
    }

    public func inserted(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws -> Self {
      var result = self
      try result.insert(db, onConflict: conflictResolution)
      return result
    }

    public func saved(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws -> Self {
      var result = self
      try result.save(db, onConflict: conflictResolution)
      return result
    }

    @discardableResult
    public func delete(_ db: Database) throws -> Bool {
      try willDelete(db)
      var deleted: Bool?
      try aroundDelete(db) {
        guard deleted == nil else { throw callbackMisuse("aroundDelete") }
        let result = try deleteWithoutCallbacks(db)
        deleted = result
        return result
      }
      guard let deleted else {
        throw callbackMisuse("aroundDelete")
      }
      didDelete(deleted: deleted)
      return deleted
    }

    private func deleteWithoutCallbacks(_ db: Database) throws -> Bool {
      guard
        let statement = try primaryKeyStatement(
          db,
          prefix: "DELETE FROM \(quoted(type(of: self).databaseTableName)) WHERE ",
          suffix: ""
        )
      else {
        return false
      }
      let (_, changes) = try db.countChanges(forTable: type(of: self).databaseTableName) {
        try statement.execute()
      }
      return changes > 0
    }

    public func exists(_ db: Database) throws -> Bool {
      guard
        let statement = try primaryKeyStatement(
          db,
          prefix: "SELECT EXISTS (SELECT 1 FROM \(quoted(type(of: self).databaseTableName)) WHERE ",
          suffix: ")"
        )
      else {
        return false
      }
      return try Bool.fetchOne(statement) ?? false
    }

    /// A statement filtered on the record's primary key, or nil when the key is NULL.
    private func primaryKeyStatement(_ db: Database, prefix: String, suffix: String) throws
      -> Statement?
    {
      let container = try PersistenceContainer(self)
      let columns = try db.primaryKey(type(of: self).databaseTableName).columns
      let values = columns.map { container[$0]?.databaseValue ?? .null }
      if values.allSatisfy(\.isNull) { return nil }
      let predicate = columns.map { quoted($0) + "=?" }.joined(separator: " AND ")
      let statement = try db.makeStatement(sql: prefix + predicate + suffix)
      statement.setUncheckedArguments(StatementArguments(values))
      return statement
    }

    public mutating func updateChanges(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil,
      modify: (inout Self) throws -> Void
    ) throws -> Bool {
      let before = try PersistenceContainer(self)
      try modify(&self)
      let after = try PersistenceContainer(self)
      let columns = Set(after.changes(from: before).keys)
      guard !columns.isEmpty else {
        return false
      }
      try update(db, columns: columns, onConflict: conflictResolution)
      return true
    }
  }

  extension PersistableRecord {
    public func willInsert(_ db: Database) throws {}

    public func didInsert(_ inserted: InsertionSuccess) {}

    public func willSave(_ db: Database) throws {}

    public func didSave(_ saved: PersistenceSuccess) {}

    public func insert(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws {
      var copy = self
      try copy.insertRecord(
        db,
        conflict: conflictResolution,
        selection: [],
        fetch: { try $0.execute() }
      )
    }

    public func save(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws {
      var copy = self
      try copy.saveRecord(
        db,
        conflict: conflictResolution,
        selection: [],
        fetch: { try $0.execute() }
      )
    }
  }

  func primaryKeyValues(_ db: Database, table: String, container: PersistenceContainer) throws
    -> [String: DatabaseValue]
  {
    let primaryKey = try db.primaryKey(table)
    return Dictionary(
      uniqueKeysWithValues: primaryKey.columns.map { ($0, container[$0]?.databaseValue ?? .null) }
    )
  }

  func callbackMisuse(_ name: String) -> DatabaseError {
    DatabaseError(
      resultCode: .SQLITE_MISUSE,
      message: "\(name) must invoke its persistence closure exactly once"
    )
  }

#endif
