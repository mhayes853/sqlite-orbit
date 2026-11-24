/// Synthesizes ``ConvertibleFromOrbitDatabaseRow`` and ``OrbitDatabaseRowColumns`` for a struct
/// using named result columns.
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
///
/// A property marked with ``OrbitColumns(prefix:)`` is itself a row, read from a group of this
/// row's columns, which is how a join decodes into the row types of its tables:
///
/// ```swift
/// @OrbitRow
/// struct ReminderWithList {
///   @OrbitColumns let reminder: Reminder
///   @OrbitColumns(prefix: "list_") let list: RemindersList?
/// }
/// ```
///
/// The generated `orbitColumnName(for:)` maps stored-property key paths to result-column names,
/// allowing typed reads such as `try row[column: \ReminderSummary.title]`. Unmapped properties
/// and nested rows return `nil`.
@attached(
  extension,
  conformances: ConvertibleFromOrbitDatabaseRow,
  OrbitDatabaseRowColumns,
  names: named(init),
  named(orbitColumnName)
)
public macro OrbitRow() = #externalMacro(module: "SQLiteOrbitMacros", type: "OrbitRowMacro")

/// Overrides the SQL result-column name of a stored property in an ``OrbitRow()`` struct.
///
/// The name must be a string literal. Names match byte for byte, including case; a missing column
/// throws even if the property's type is optional. SQL `NULL` can be read into an optional.
@attached(peer)
public macro OrbitColumn(_ name: String) =
  #externalMacro(module: "SQLiteOrbitMacros", type: "OrbitColumnMacro")

/// Reads a stored property of an ``OrbitRow()`` struct as a nested row, from the result columns
/// whose names start with a prefix.
///
/// ```swift
/// @OrbitRow
/// struct ReminderWithList {
///   @OrbitColumns let reminder: Reminder
///   @OrbitColumns(prefix: "list_") let list: RemindersList?
/// }
///
/// let rows = try transaction.fetchAll(
///   """
///   SELECT r.id, r.title, l.id AS list_id, l.name AS list_name
///   FROM reminders r LEFT JOIN lists l ON l.id = r.list_id
///   """,
///   as: ReminderWithList.self
/// )
/// ```
///
/// The property's type must conform to ``ConvertibleFromOrbitDatabaseRow``. It reads the prefixed
/// columns under their names with the prefix removed, so `list_id` is `id` to `RemindersList`.
/// Without a prefix, the property reads the same columns as the enclosing struct. Nested rows may
/// nest further, and their prefixes add up.
///
/// An optional property is `nil` when every column with the prefix is `NULL`, as in a `LEFT JOIN`
/// that matched nothing. The prefix must be a string literal and match byte for byte, including
/// case; a prefix no column has throws even if the property's type is optional.
@attached(peer)
public macro OrbitColumns(prefix: String = "") =
  #externalMacro(module: "SQLiteOrbitMacros", type: "OrbitColumnsMacro")
