/// A decoding failure, reported against the column it happened on.
///
/// SQLite is untyped enough that a schema change or a hand-written `SELECT` can quietly hand a
/// column back in the wrong storage class. This names which column it was.
///
/// ```swift
/// do {
///   _ = try await database.read { transaction in
///     try transaction.fetchAll("SELECT id, title FROM reminders") { row in
///       (try row[0, as: Int.self], try row[1, as: Int.self])
///     }
///   }
/// } catch let error as OrbitDatabaseColumnDecodingError {
///   print(error.columnIndex, error.columnName, error.reason)
/// }
/// ```
public struct OrbitDatabaseColumnDecodingError: Error, CustomStringConvertible {
  /// The zero-based position of the column in the result row, or `nil` when the row has no column
  /// with the name it was read by.
  public let columnIndex: Int?

  /// The column's name, or `"?"` when SQLite had none for it.
  public let columnName: String

  /// What the decoder expected, phrased to follow "Expected column N (name) ".
  public let reason: String

  /// The SQL of the statement that produced the row, when the row knows it.
  ///
  /// A row read through ``OrbitDatabaseRow`` alone does not know its statement, so this is `nil`
  /// for the errors its typed subscripts throw.
  public let sql: String?

  /// The error that made the column fail to decode, such as an
  /// ``OrbitDatabaseValueConversionError``, when there was one.
  public let underlyingError: (any Error)?

  init(
    columnIndex: Int?,
    columnName: String,
    reason: String,
    sql: String? = nil,
    underlyingError: (any Error)? = nil
  ) {
    self.columnIndex = columnIndex
    self.columnName = columnName
    self.reason = reason
    self.sql = sql
    self.underlyingError = underlyingError
  }

  /// The column, its name, what was expected of it, and the SQL that produced it when known.
  public var description: String {
    let column =
      if let columnIndex {
        "column \(columnIndex) (\(columnName.debugDescription))"
      } else {
        "a column named \(columnName.debugDescription)"
      }
    let expectation = "Expected \(column) \(reason)."
    guard let sql else { return expectation }
    return """
      \(expectation)

      \(sql)
      """
  }
}
