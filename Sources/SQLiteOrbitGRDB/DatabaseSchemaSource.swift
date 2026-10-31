#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// Customizes schema introspection, such as the primary keys of views.
  public protocol DatabaseSchemaSource: Sendable {
    /// The primary key columns of a view, or nil if the source does not customize it.
    func columnsForPrimaryKey(_ db: Database, inView view: DatabaseObjectID) throws -> [String]?
  }

  extension DatabaseSchemaSource {
    public func columnsForPrimaryKey(_ db: Database, inView view: DatabaseObjectID) throws
      -> [String]?
    {
      nil
    }

    /// A schema source that asks `other` when this source does not customize a view.
    public func then(_ other: some DatabaseSchemaSource) -> some DatabaseSchemaSource {
      ChainedSchemaSource(first: self, second: other)
    }
  }

  private struct ChainedSchemaSource<First: DatabaseSchemaSource, Second: DatabaseSchemaSource>:
    DatabaseSchemaSource
  {
    var first: First
    var second: Second

    func columnsForPrimaryKey(_ db: Database, inView view: DatabaseObjectID) throws -> [String]? {
      try first.columnsForPrimaryKey(db, inView: view)
        ?? second.columnsForPrimaryKey(db, inView: view)
    }
  }

  /// The schema source of each connection, keyed by the connection state, which is unique to
  /// an open connection.
  enum SchemaSourceStore {
    struct Entry {
      weak var state: DatabaseConnectionState?
      var source: (any DatabaseSchemaSource)?
    }

    static let lock = NSLock()
    nonisolated(unsafe) static var entries: [ObjectIdentifier: Entry] = [:]

    static func source(for state: DatabaseConnectionState) -> (any DatabaseSchemaSource)? {
      lock.withLock {
        guard let entry = entries[ObjectIdentifier(state)], entry.state === state else {
          return nil
        }
        return entry.source
      }
    }

    static func setSource(_ source: (any DatabaseSchemaSource)?, for state: DatabaseConnectionState)
    {
      lock.withLock {
        entries = entries.filter { $0.value.state != nil }
        entries[ObjectIdentifier(state)] = Entry(state: state, source: source)
      }
    }
  }

  extension Database {
    /// The schema source of the connection.
    public var schemaSource: (any DatabaseSchemaSource)? {
      SchemaSourceStore.source(for: connectionState)
    }

    /// Runs `execute` with another schema source.
    public func withSchemaSource<T>(
      _ schemaSource: (any DatabaseSchemaSource)?,
      execute: () throws -> T
    ) rethrows -> T {
      let state = connectionState
      let previous = SchemaSourceStore.source(for: state)
      SchemaSourceStore.setSource(schemaSource, for: state)
      defer { SchemaSourceStore.setSource(previous, for: state) }
      return try execute()
    }
  }

  extension ColumnInfo {
    /// The declared type of the column, or nil when it has no declared type.
    public var columnType: Database.ColumnType? {
      type.isEmpty ? nil : Database.ColumnType(rawValue: type)
    }
  }
#endif
