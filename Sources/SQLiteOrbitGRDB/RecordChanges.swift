#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  extension PersistenceContainer {
    func changes(from previous: Self) -> [String: DatabaseValue] {
      Dictionary(
        uniqueKeysWithValues: fields.compactMap { column, value in
          let oldValue = previous[column]?.databaseValue ?? .null
          return value == oldValue ? nil : (column, oldValue)
        }
      )
    }
  }

  extension EncodableRecord {
    public mutating func databaseChanges(modify: (inout Self) throws -> Void) throws
      -> [String: DatabaseValue]
    {
      let previous = try PersistenceContainer(self)
      try modify(&self)
      return try PersistenceContainer(self).changes(from: previous)
    }
  }

  extension MutablePersistableRecord {
    @discardableResult
    public func updateChanges<R: MutablePersistableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      from record: R
    ) throws -> Bool {
      let columns = Set(
        try PersistenceContainer(self).changes(from: PersistenceContainer(record)).keys
      )
      guard !columns.isEmpty else {
        return false
      }
      try update(db, columns: columns, onConflict: conflict)
      return true
    }

    public mutating func updateChangesAndFetch(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      modify: (inout Self) throws -> Void
    ) throws -> Self? where Self: FetchableRecord {
      try updateChangesAndFetch(db, onConflict: conflict, as: Self.self, modify: modify)
    }

    public mutating func updateChangesAndFetch<T: FetchableRecord & TableRecord>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      as type: T.Type,
      modify: (inout Self) throws -> Void
    ) throws -> T? {
      let source = self
      return try updateChangesAndFetch(
        db,
        onConflict: conflict,
        selection: T.databaseSelection,
        fetch: { statement in
          guard let record = try T.fetchOne(statement) else {
            throw try source.missingRecord(db)
          }
          return record
        },
        modify: modify
      )
    }

    public mutating func updateChangesAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      selection: [any SQLSelectable],
      fetch: (Statement) throws -> T,
      modify: (inout Self) throws -> Void
    ) throws -> T? {
      let previous = try PersistenceContainer(self)
      try modify(&self)
      let columns = Set(try PersistenceContainer(self).changes(from: previous).keys)
      guard !columns.isEmpty else {
        return nil
      }
      return try updateAndFetch(
        db,
        onConflict: conflict,
        columns: columns,
        selection: selection,
        fetch: fetch
      )
    }
  }
#endif
