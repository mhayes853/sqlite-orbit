/// Synthesizes ``ConvertibleFromOrbitDatabaseRow`` for a struct using named result columns.
///
/// ```swift
/// @OrbitRow
/// struct ReminderSummary {
///   let id: Int
///   let title: String
///   @OrbitColumn("due_date") let dueDate: String?
/// }
/// ```
///
/// Stored instance properties must have explicit types conforming to
/// ``ConvertibleFromOrbitDatabaseValue``. Computed and static properties are ignored. Mutable
/// properties may have defaults, but missing columns still throw; `let` properties with defaults,
/// lazy properties, property wrappers, conditional members, and an existing row initializer require
/// a handwritten conformance. The initializer is generated in an extension, preserving memberwise
/// initialization.
@attached(
  extension,
  conformances: ConvertibleFromOrbitDatabaseRow,
  names: named(init)
)
public macro OrbitRow() = #externalMacro(module: "SQLiteOrbitMacros", type: "OrbitRowMacro")

/// Synthesizes row decoding, encoding, and ``PersistableOrbitDatabaseRow`` for a table record.
///
/// Stored properties must support conversion in both directions. The table and primary-key names
/// must be string literals. By default the stored property named `id` supplies the primary key,
/// respecting an ``OrbitColumn(_:)`` rename. An explicit array overrides inference and uses SQL
/// column names; `[]` marks a keyless table, which supports insertion but not primary-key updates.
///
/// ```swift
/// @OrbitRow(table: "reminders")
/// struct Reminder: Identifiable {
///   let id: Int64
///   var title: String
/// }
/// ```
///
/// Use ``OrbitDatabaseRowValues`` to omit a generated ID during insertion. The returned record
/// keeps its nonoptional identity. Generation and defaults are determined by the database schema.
@attached(
  extension,
  conformances: ConvertibleFromOrbitDatabaseRow,
  ConvertibleToOrbitDatabaseRow,
  PersistableOrbitDatabaseRow,
  names: named(init),
  named(orbitColumnName),
  named(encodeOrbitDatabaseRow),
  named(orbitTableName),
  named(orbitPrimaryKeyColumns)
)
public macro OrbitRow(table: String, primaryKey: [String]? = nil) =
  #externalMacro(module: "SQLiteOrbitMacros", type: "OrbitRowMacro")

/// Overrides the SQL result-column name of a stored property in an ``OrbitRow()`` struct.
///
/// The name must be a string literal. Names match byte for byte, including case; a missing column
/// throws even if the property's type is optional. SQL `NULL` can be read into an optional.
@attached(peer)
public macro OrbitColumn(_ name: String) =
  #externalMacro(module: "SQLiteOrbitMacros", type: "OrbitColumnMacro")
