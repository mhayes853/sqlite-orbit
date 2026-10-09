/// A configuration step run on each opened connection.
///
/// SQL and callbacks share one ordered `SQLiteConfiguration.setups` collection. A setup runs
/// after standard connection settings and authorization, before the connection is lent to callers.
/// A thrown error stops setup and closes the connection.
///
/// Runtime-wide registration belongs on `SQLiteLibrary`, before opening connections.
///
/// - Important: SQLiteOrbit owns SQLite's single authorizer callback. A setup must not replace it.
public struct SQLiteSetup: Sendable {
  private let configure: @Sendable (borrowing SQLiteConnectionAccess) throws -> Void

  /// Creates a setup from a closure receiving the opened connection and its SQLite library.
  public init(
    _ configure: @escaping @Sendable (borrowing SQLiteConnectionAccess) throws -> Void
  ) {
    self.configure = configure
  }

  /// Runs the setup on an opened connection.
  /// Custom connection owners can use this to apply the same setup steps as the built-in drivers.
  public func callAsFunction(_ connection: borrowing SQLiteConnectionAccess) throws {
    try configure(connection)
  }

  /// Executes one SQL statement, preserving its parameter bindings and discarding any result rows.
  public static func sql(_ sql: SQL) -> Self {
    Self { try $0.execute(sql) }
  }

  /// Executes a script of one or more statements.
  /// A script takes no bindings; use text controlled by the program, or `sql(_:)` for bound values.
  public static func script(_ script: String) -> Self {
    Self { try $0.executeScript(script) }
  }
}
