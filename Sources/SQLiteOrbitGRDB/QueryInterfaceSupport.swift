#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // MARK: - SQL helpers

  /// Comma-separated question marks: `databaseQuestionMarks(count: 3) // "?,?,?"`.
  public func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
  }

  extension SQLSpecificExpressible {
    /// Applies a collation.
    public func collating(_ collation: Database.CollationName) -> SQLExpression {
      .collated(sqlExpression, collation.rawValue)
    }

    /// Applies a custom collation.
    public func collating(_ collation: DatabaseCollation) -> SQLExpression {
      .collated(sqlExpression, collation.name)
    }
  }

  // MARK: - Records

  extension RecordError: CustomStringConvertible {
    public var description: String {
      switch self {
      case .recordNotFound(let table, let key):
        return "Key not found in table \(table): \(Row(key.map { ($0.key, $0.value) }).description)"
      }
    }
  }

  extension TableRecord {
    /// The number of columns selected by `databaseSelection`.
    public static func numberOfSelectedColumns(_ db: Database) throws -> Int {
      let alias = TableAliasBase(tableName: databaseTableName)
      let context = SQLGenerationContext(db)
      return try databaseSelection.reduce(0) { total, selection in
        guard let count = try selection.sqlSelection.qualified(with: alias).columnCount(context)
        else {
          throw DatabaseError(
            resultCode: .SQLITE_MISUSE,
            message:
              "Selection literals don't known how many columns they contain. To resolve this error, select one or several expressions instead."
          )
        }
        return total + count
      }
    }

    /// The error for a missing record with the given primary key.
    public static func recordNotFound(_ db: Database, key: some DatabaseValueConvertible)
      -> any Error
    {
      do {
        let column = try db.filteringPrimaryKeyColumn(databaseTableName)
        return RecordError.recordNotFound(
          databaseTableName: databaseTableName,
          key: [column: key.databaseValue]
        )
      } catch {
        return error
      }
    }

    /// The error for a missing record with the given unique key.
    public static func recordNotFound(key: [String: (any DatabaseValueConvertible)?])
      -> RecordError
    {
      .recordNotFound(
        databaseTableName: databaseTableName,
        key: key.mapValues { $0?.databaseValue ?? .null }
      )
    }
  }

  extension TableRecord where Self: EncodableRecord {
    /// The error for this missing record.
    public func recordNotFound(_ db: Database) -> any Error {
      do {
        let table = type(of: self).databaseTableName
        let container = try PersistenceContainer(self)
        let key = Dictionary(
          uniqueKeysWithValues: try db.primaryKey(table).columns
            .map {
              ($0, container[$0]?.databaseValue ?? .null)
            }
        )
        return RecordError.recordNotFound(databaseTableName: table, key: key)
      } catch {
        return error
      }
    }
  }

  extension TableRecord where Self: Identifiable, ID: DatabaseValueConvertible {
    /// The error for a missing record with the given identifier.
    public static func recordNotFound(_ db: Database, id: ID) -> any Error {
      recordNotFound(db, key: id)
    }
  }

  extension FetchableRecord where Self: TableRecord {
    /// Fetches the single record of the table (for single-row tables), or nil.
    public static func fetchOne(_ db: Database) throws -> Self? {
      try all().fetchOne(db)
    }
  }

  extension MutablePersistableRecord {
    /// Inserts the record and fetches the returned selection, given by a closure.
    public mutating func insertAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      fetch: (Statement) throws -> T,
      select: (DatabaseComponents) throws -> [any SQLSelectable]
    ) throws -> T {
      try insertAndFetch(
        db,
        onConflict: conflict,
        selection: select(Self.databaseComponents),
        fetch: fetch
      )
    }
  }

  extension PersistableRecord {
    /// Inserts the record and fetches the returned selection, given by a closure.
    public func insertAndFetch<T>(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      fetch: (Statement) throws -> T,
      select: (DatabaseComponents) throws -> [any SQLSelectable]
    ) throws -> T {
      try insertAndFetch(
        db,
        onConflict: conflict,
        selection: select(Self.databaseComponents),
        fetch: fetch
      )
    }
  }

  extension QueryInterfaceRequest where RowDecoder: FetchableRecord & TableRecord {
    public func updateAndFetchCursor(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      assignments: (RowDecoder.DatabaseComponents) throws -> [ColumnAssignment]
    ) throws -> RecordCursor<RowDecoder> {
      try updateAndFetchCursor(db, onConflict: conflict, assignments(RowDecoder.databaseComponents))
    }

    public func updateAndFetchAll(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      assignments: (RowDecoder.DatabaseComponents) throws -> [ColumnAssignment]
    ) throws -> [RowDecoder] {
      try updateAndFetchAll(db, onConflict: conflict, assignments(RowDecoder.databaseComponents))
    }
  }

  extension QueryInterfaceRequest where RowDecoder: FetchableRecord & TableRecord & Hashable {
    public func updateAndFetchSet(
      _ db: Database,
      onConflict conflict: Database.ConflictResolution? = nil,
      assignments: (RowDecoder.DatabaseComponents) throws -> [ColumnAssignment]
    ) throws -> Set<RowDecoder> {
      try updateAndFetchSet(db, onConflict: conflict, assignments(RowDecoder.databaseComponents))
    }
  }

  // MARK: - Legacy schema API

  extension Database {
    /// Creates a table (legacy options).
    public func create(
      table name: String,
      temporary: Bool = false,
      ifNotExists: Bool = false,
      withoutRowID: Bool = false,
      body: (TableDefinition) throws -> Void
    ) throws {
      var options: TableOptions = []
      if temporary { options.insert(.temporary) }
      if ifNotExists { options.insert(.ifNotExists) }
      if withoutRowID { options.insert(.withoutRowID) }
      try create(table: name, options: options, body: body)
    }
  }

  // MARK: - Regions

  extension FetchRequest {
    /// The database region read by the request.
    public func databaseRegion(_ db: Database) throws -> DatabaseRegion {
      try makePreparedRequest(db, forSingleResult: false).statement.databaseRegion
    }
  }

  extension Table: DatabaseRegionConvertible {
    public func databaseRegion(_ db: Database) throws -> DatabaseRegion {
      DatabaseRegion(table: tableName)
    }
  }

  // MARK: - AnyFetchRequest

  /// A type-erased fetch request.
  public struct AnyFetchRequest<RowDecoder>: FetchRequest, @unchecked Sendable {
    private let makeSQL: (Database) throws -> SQL
    private let subquery: SQLSubquery
    private let prepare: (Database, Bool) throws -> PreparedRequest
    private let count: (Database) throws -> Int

    private init(
      makeSQL: @escaping (Database) throws -> SQL,
      subquery: SQLSubquery,
      prepare: @escaping (Database, Bool) throws -> PreparedRequest,
      count: @escaping (Database) throws -> Int
    ) {
      self.makeSQL = makeSQL
      self.subquery = subquery
      self.prepare = prepare
      self.count = count
    }

    public init<Request: FetchRequest>(_ request: Request) where Request.RowDecoder == RowDecoder {
      self.init(
        makeSQL: request.sql(in:),
        subquery: request.sqlSubquery,
        prepare: { try request.makePreparedRequest($0, forSingleResult: $1) },
        count: request.fetchCount
      )
    }

    public func asRequest<T>(of type: T.Type) -> AnyFetchRequest<T> {
      AnyFetchRequest<T>(makeSQL: makeSQL, subquery: subquery, prepare: prepare, count: count)
    }

    public var sqlSubquery: SQLSubquery { subquery }

    public func sql(in db: Database) throws -> SQL { try makeSQL(db) }

    public func makePreparedRequest(_ db: Database, forSingleResult singleResult: Bool = false)
      throws -> PreparedRequest
    {
      try prepare(db, singleResult)
    }

    public func fetchCount(_ db: Database) throws -> Int { try count(db) }
  }
#endif
