/// The metadata SQLite reports when compiling a statement, without executing it.
public struct SQLiteStatementInfo: Hashable, Sendable {
  /// Result column names, in their result order, including duplicate names.
  public let columnNames: [String]

  /// The region the statement reads, including reads made by triggers and views.
  public let readRegion: OrbitDatabaseRegion

  /// The region the statement may change.
  public let changedRegion: OrbitDatabaseRegion

  /// Whether SQLite reports that the statement only reads.
  public let isReadOnly: Bool

  /// The highest parameter slot used, including gaps introduced by numbered parameters.
  public let parameterCount: Int
}
