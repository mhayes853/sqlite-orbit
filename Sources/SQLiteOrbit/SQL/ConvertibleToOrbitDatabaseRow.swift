/// A value whose stored properties can be bound to named database columns.
///
/// The key-path mapping supports typed ``OrbitDatabaseRowValues``. Return `nil` for computed or
/// otherwise unsupported properties. ``OrbitRow(table:primaryKey:)`` synthesizes both requirements
/// when given a table name.
public protocol ConvertibleToOrbitDatabaseRow {
  /// The SQL column corresponding to a stored property, or `nil` for an unsupported property.
  static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String?

  /// Encodes this value, including its supplied primary key, into named column values.
  func encodeOrbitDatabaseRow(into values: inout OrbitDatabaseRowValues<Self>) throws
}

/// A value that can be both bound to columns and initialized from a database row.
public typealias OrbitDatabaseRowConvertible =
  ConvertibleFromOrbitDatabaseRow & ConvertibleToOrbitDatabaseRow

/// A complete record with a table and the column names identifying one stored row.
///
/// A keyless table may use an empty primary-key array for insertion. Updating and saving require
/// a nonempty key whose encoded values are present and non-NULL. Composite keys are supported.
public protocol PersistableOrbitDatabaseRow: OrbitDatabaseRowConvertible {
  /// The literal table name, quoted as one identifier rather than interpreted as SQL.
  static var orbitTableName: String { get }

  /// The SQL column names forming the complete primary key.
  static var orbitPrimaryKeyColumns: [String] { get }
}

/// A malformed column request or identity detected by the row persistence helpers.
public enum OrbitDatabaseRowPersistenceError: Error, Equatable, Sendable {
  /// A key path does not describe a supported stored property.
  case unknownColumn
  /// Multiple requested properties or key entries describe the same SQL column.
  case duplicateColumn(String)
  /// The operation needs a nonempty primary key or conflict target.
  case missingPrimaryKey
  /// A required identity or requested column was not encoded.
  case missingValue(String)
  /// A primary-key value is SQL NULL.
  case nullPrimaryKey(String)
  /// An explicit update assignment would change a primary key or conflict-target column.
  case identityUpdate(String)
  /// No columns were selected for an update.
  case emptyUpdate
  /// An insertion returned no record, for example because a trigger ignored it.
  case noInsertedRow
}
