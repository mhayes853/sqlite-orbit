#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// A base class for records that track changes since they were fetched or saved.
  ///
  /// Subclasses override `databaseTableName`, `init(row:)`, and `encode(to:)`.
  open class Record {
    // The values last fetched or saved; nil when every column counts as changed.
    var referenceRow: Row?

    /// Creates a record whose columns all count as changed.
    public init() {}

    /// Creates a record from a row. Fetched rows become the reference for change tracking.
    public required init(row: Row) throws {
      if row.isFetched {
        referenceRow = row.copy()
      }
    }

    /// The name of the database table. Subclasses must override this property.
    open class var databaseTableName: String {
      fatalError("subclass must override")
    }

    /// The conflict policy of insertions and updates.
    open class var persistenceConflictPolicy: PersistenceConflictPolicy {
      PersistenceConflictPolicy(insert: .abort, update: .abort)
    }

    /// The columns selected when fetching records.
    open class var databaseSelection: [any SQLSelectable] {
      [AllColumns()]
    }

    /// Encodes the record into the container. Subclasses override this method.
    open func encode(to container: inout PersistenceContainer) throws {}

    // MARK: - Changes

    /// Whether the record has columns that differ from the values last fetched or saved.
    public var hasDatabaseChanges: Bool {
      do {
        return try databaseChangesIterator().next() != nil
      } catch {
        // A record that cannot be encoded cannot be saved either.
        return true
      }
    }

    /// The changed columns, with their values as last fetched or saved, or nil when unknown.
    public var databaseChanges: [String: DatabaseValue?] {
      get throws {
        try Dictionary(uniqueKeysWithValues: databaseChangesIterator())
      }
    }

    private func databaseChangesIterator() throws -> AnyIterator<(String, DatabaseValue?)> {
      let reference = referenceRow
      var values = try PersistenceContainer(self).fields.makeIterator()
      return AnyIterator {
        while let (column, value) = values.next() {
          guard let reference, let index = reference.index(ofColumn: column) else {
            return (column, nil)
          }
          let old = reference.databaseValues[index]
          if value != old {
            return (column, old)
          }
        }
        return nil
      }
    }

    private func resetDatabaseChanges(with container: PersistenceContainer) {
      referenceRow = Row(container.fields)
    }

    // MARK: - Persistence callbacks

    open func willInsert(_ db: Database) throws {}

    open func aroundInsert(_ db: Database, insert: () throws -> InsertionSuccess) throws {
      let inserted = try insert()
      resetDatabaseChanges(with: inserted.persistenceContainer)
    }

    open func didInsert(_ inserted: InsertionSuccess) {}

    open func willUpdate(_ db: Database, columns: Set<String>) throws {}

    open func aroundUpdate(
      _ db: Database,
      columns: Set<String>,
      update: () throws -> PersistenceSuccess
    ) throws {
      let updated = try update()
      resetDatabaseChanges(with: updated.persistenceContainer)
    }

    open func didUpdate(_ updated: PersistenceSuccess) {}

    open func willSave(_ db: Database) throws {}

    open func aroundSave(_ db: Database, save: () throws -> PersistenceSuccess) throws {
      _ = try save()
    }

    open func didSave(_ saved: PersistenceSuccess) {}

    open func willDelete(_ db: Database) throws {}

    open func aroundDelete(_ db: Database, delete: () throws -> Bool) throws {
      _ = try delete()
      referenceRow = nil
    }

    open func didDelete(deleted: Bool) {}

    // MARK: - CRUD

    /// Updates the changed columns, and returns whether there were any.
    @discardableResult
    public final func updateChanges(_ db: Database) throws -> Bool {
      let columns = try Set(databaseChanges.keys)
      guard !columns.isEmpty else { return false }
      // Opening the existential binds the persistence methods to the dynamic subclass, whose
      // table name and policies apply.
      let type: any PersistableRecord.Type = Swift.type(of: self)
      try updateDynamicRecord(type, self, db, columns: columns)
      return true
    }
  }

  private func updateDynamicRecord<R: PersistableRecord>(
    _ type: R.Type,
    _ record: Record,
    _ db: Database,
    columns: Set<String>
  ) throws {
    try (record as! R).update(db, columns: columns)
  }

  extension Record: TableRecord {}
  extension Record: PersistableRecord {}
  extension Record: FetchableRecord {}

  // Persistence methods mutate the reference row of the instance.
  @available(*, unavailable)
  extension Record: Sendable {}
#endif
