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
      try willSave(db)
      var saved: PersistenceSuccess?
      try aroundSave(db) {
        let inserted = try insertWithCallbacks(db, conflict: conflictResolution)
        let result = PersistenceSuccess(persistenceContainer: inserted.persistenceContainer)
        saved = result
        return result
      }
      guard let saved else {
        throw callbackMisuse("aroundSave")
      }
      didSave(saved)
    }

    private mutating func insertWithCallbacks(
      _ db: Database,
      conflict: Database.ConflictResolution?
    )
      throws -> InsertionSuccess
    {
      try willInsert(db)
      let container = try PersistenceContainer(self)
      var inserted: InsertionSuccess?
      try aroundInsert(db) {
        guard inserted == nil else {
          throw callbackMisuse("aroundInsert")
        }
        let result = try performInsert(
          db,
          table: Self.databaseTableName,
          container: container,
          conflict: conflict ?? Self.persistenceConflictPolicy.conflictResolutionForInsert
        )
        inserted = result
        return result
      }
      guard let inserted else {
        throw callbackMisuse("aroundInsert")
      }
      didInsert(inserted)
      return inserted
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
      columns: Set<String>,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws {
      try willSave(db)
      var saved: PersistenceSuccess?
      try aroundSave(db) {
        let result = try updateWithCallbacks(db, columns: columns, conflict: conflictResolution)
        saved = result
        return result
      }
      guard let saved else {
        throw callbackMisuse("aroundSave")
      }
      didSave(saved)
    }

    private func updateWithCallbacks(
      _ db: Database,
      columns: Set<String>,
      conflict: Database.ConflictResolution?
    ) throws -> PersistenceSuccess {
      try willUpdate(db, columns: columns)
      let container = try PersistenceContainer(self)
      var updated: PersistenceSuccess?
      try aroundUpdate(db, columns: columns) {
        guard updated == nil else {
          throw callbackMisuse("aroundUpdate")
        }
        try performUpdate(
          db,
          table: Self.databaseTableName,
          container: container,
          columns: columns,
          conflict: conflict ?? Self.persistenceConflictPolicy.conflictResolutionForUpdate
        )
        let result = PersistenceSuccess(persistenceContainer: container)
        updated = result
        return result
      }
      guard let updated else {
        throw callbackMisuse("aroundUpdate")
      }
      didUpdate(updated)
      return updated
    }

    public mutating func save(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws {
      try willSave(db)
      var saved: PersistenceSuccess?
      try aroundSave(db) {
        let container = try PersistenceContainer(self)
        let pk = try db.primaryKey(Self.databaseTableName)
        if pk.columns.allSatisfy({ container[$0]?.databaseValue.isNull == false }) {
          do {
            let result = try updateWithCallbacks(
              db,
              columns: Set(container.fields.map(\.0)),
              conflict: conflictResolution
            )
            saved = result
            return result
          } catch RecordError.recordNotFound {}
        }
        let inserted = try insertWithCallbacks(db, conflict: conflictResolution)
        let result = PersistenceSuccess(persistenceContainer: inserted.persistenceContainer)
        saved = result
        return result
      }
      guard let saved else {
        throw callbackMisuse("aroundSave")
      }
      didSave(saved)
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
      let container = try PersistenceContainer(self)
      let key = try primaryKeyValues(db, table: Self.databaseTableName, container: container)
      var deleted: Bool?
      try aroundDelete(db) {
        let request = QueryInterfaceRequest<Row>(table: Self.databaseTableName)
          .filter(key: key.mapValues { $0 as (any DatabaseValueConvertible)? })
        let result = try request.deleteAll(db) > 0
        deleted = result
        return result
      }
      guard let deleted else {
        throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "aroundDelete did not delete")
      }
      didDelete(deleted: deleted)
      return deleted
    }

    public func exists(_ db: Database) throws -> Bool {
      let key = try primaryKeyValues(
        db,
        table: Self.databaseTableName,
        container: PersistenceContainer(self)
      )
      guard key.values.allSatisfy({ !$0.isNull }) else {
        return false
      }
      return try QueryInterfaceRequest<Row>(table: Self.databaseTableName)
        .filter(key: key.mapValues { $0 as (any DatabaseValueConvertible)? }).fetchCount(db) > 0
    }

    public mutating func updateChanges(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil,
      modify: (inout Self) throws -> Void
    ) throws -> Bool {
      let before = try PersistenceContainer(self)
      try modify(&self)
      let after = try PersistenceContainer(self)
      let columns = Set(after.fields.filter { before[$0.0]?.databaseValue != $0.1 }.map(\.0))
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
      try copy.insertMutable(db, onConflict: conflictResolution)
    }

    public func save(
      _ db: Database,
      onConflict conflictResolution: Database.ConflictResolution? = nil
    ) throws {
      var copy = self
      try copy.saveMutable(db, onConflict: conflictResolution)
    }
  }

  // Explicitly select the mutable implementations rather than recursing through overloads.
  extension MutablePersistableRecord {
    fileprivate mutating func insertMutable(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution?
    ) throws {
      try insert(db, onConflict: conflict)
    }

    fileprivate mutating func saveMutable(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution?
    ) throws {
      try save(db, onConflict: conflict)
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

  func performInsert(
    _ db: Database,
    table: String,
    container: PersistenceContainer,
    conflict: Database.ConflictResolution
  ) throws -> InsertionSuccess {
    let prefix = "INSERT OR \(conflict.rawValue.uppercased()) INTO \(quoted(table))"
    if container.isEmpty {
      try db.execute(sql: prefix + " DEFAULT VALUES")
    } else {
      let columns = container.fields.map { quoted($0.0) }.joined(separator: ", ")
      let placeholders = Array(repeating: "?", count: container.count).joined(separator: ", ")
      try db.execute(
        sql: prefix + " (\(columns)) VALUES (\(placeholders))",
        arguments: StatementArguments(container.fields.map(\.1))
      )
    }
    let rowID = db.lastInsertedRowID
    let column = try db.primaryKey(table).rowIDColumn
    var saved = container
    if let column {
      saved[column] = rowID
    }
    return InsertionSuccess(rowID: rowID, rowIDColumn: column, persistenceContainer: saved)
  }

  func performUpdate(
    _ db: Database,
    table: String,
    container: PersistenceContainer,
    columns: Set<String>,
    conflict: Database.ConflictResolution
  ) throws {
    let key = try primaryKeyValues(db, table: table, container: container)
    guard key.values.allSatisfy({ !$0.isNull }) else {
      throw RecordError.recordNotFound(databaseTableName: table, key: key)
    }
    let fields = container.fields.filter { field in
      columns.contains { $0.caseInsensitiveCompare(field.0) == .orderedSame }
        && !key.keys.contains { $0.caseInsensitiveCompare(field.0) == .orderedSame }
    }
    // An update of a record with only a primary key still checks that the row exists.
    let assignments =
      fields.isEmpty
      ? [quoted(key.keys.sorted()[0]) + " = " + quoted(key.keys.sorted()[0])]
      : fields.map { quoted($0.0) + " = ?" }
    let orderedKey = key.sorted { $0.key < $1.key }
    let whereSQL = orderedKey.map { quoted($0.key) + " = ?" }.joined(separator: " AND ")
    try db.execute(
      sql:
        "UPDATE OR \(conflict.rawValue.uppercased()) \(quoted(table)) SET \(assignments.joined(separator: ", ")) WHERE \(whereSQL)",
      arguments: StatementArguments(fields.map(\.1) + orderedKey.map(\.value))
    )
    if db.changesCount == 0 {
      let exists =
        try QueryInterfaceRequest<Row>(table: table)
        .filter(key: key.mapValues { $0 as (any DatabaseValueConvertible)? }).fetchCount(db) > 0
      if !exists {
        throw RecordError.recordNotFound(databaseTableName: table, key: key)
      }
    }
  }

  private func callbackMisuse(_ name: String) -> DatabaseError {
    DatabaseError(
      resultCode: .SQLITE_MISUSE,
      message: "\(name) must invoke its persistence closure exactly once"
    )
  }

#endif
