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
/// The generated `orbitColumnName(for:)` maps stored-property key paths to result-column names,
/// allowing typed reads such as `try row[column: \ReminderSummary.title]`. Unmapped properties
/// return `nil`.
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
