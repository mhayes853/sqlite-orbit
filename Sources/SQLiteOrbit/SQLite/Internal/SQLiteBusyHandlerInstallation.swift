/// Installs a configuration's ``SQLiteConfiguration/busyHandler`` on a connection.
///
/// SQLite keeps one busy handler per connection and `sqlite3_busy_timeout` is implemented as one,
/// so the two replace each other. Installing is therefore not a thing done once at open: it is
/// redone whenever something has set the busy timeout since.
///
/// The `@convention(c)` callback captures nothing, so it is handed the handle's configuration
/// storage as its user data. That allocation outlives every statement the connection runs, which
/// is the only window in which SQLite can call back.
enum SQLiteBusyHandlerInstallation {
  private static let callback: SQLiteBusyCallback = { userData, attempt in
    guard let userData else { return 0 }
    let configuration = userData.assumingMemoryBound(to: SQLiteConfiguration.self)
    guard let handler = configuration.pointee.busyHandler else { return 0 }
    // SQLite counts from zero, while the handler is documented in terms of attempts made.
    return handler(Int(attempt) + 1) ? 1 : 0
  }

  /// Installs the handler the configuration carries, if it carries one.
  ///
  /// - Returns: The library's result code, and `SQLITE_OK` when there is nothing to install.
  static func install(
    on connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    configuration: UnsafeMutablePointer<SQLiteConfiguration>
  ) -> Int32 {
    guard configuration.pointee.busyHandler != nil,
      let install = library.pointee.busyHandler?.install
    else {
      return SQLiteResultCode.ok.rawValue
    }
    return install(connection, callback, UnsafeMutableRawPointer(configuration))
  }
}
