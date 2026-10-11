/// Holds the handler a ``SQLiteBusyPolicy/handler(_:)`` policy installed on a connection, and
/// installs it.
///
/// The `@convention(c)` callback captures nothing, so it is handed this object as its user data.
/// The connection's settings keep it alive for as long as the connection is open, which is the
/// only window in which SQLite can call back, and replacing the handler only swaps what it holds.
final class SQLiteBusyHandlerInstallation {
  private var handler: (@Sendable (_ attempt: Int) -> Bool)?

  private static let callback: SQLiteBusyCallback = { userData, attempt in
    guard let userData else { return 0 }
    let installation = Unmanaged<SQLiteBusyHandlerInstallation>
      .fromOpaque(userData)
      .takeUnretainedValue()
    guard let handler = installation.handler else { return 0 }
    // SQLite counts from zero, while the handler is documented in terms of attempts made.
    return handler(Int(attempt) + 1) ? 1 : 0
  }

  /// Installs `handler` as the connection's busy handler, replacing its busy timeout.
  ///
  /// - Throws: A ``SQLiteFeatureUnavailableError`` when the library cannot install a busy
  ///   handler, or a ``SQLiteError`` when installing fails.
  func install(
    _ handler: @escaping @Sendable (_ attempt: Int) -> Bool,
    on connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>
  ) throws {
    guard let install = library.pointee.busyHandler?.install else {
      throw SQLiteFeatureUnavailableError(
        libraryName: library.pointee.name,
        feature: .busyHandler
      )
    }
    let previous = self.handler
    self.handler = handler
    let code = install(connection, Self.callback, Unmanaged.passUnretained(self).toOpaque())
    guard code == SQLiteResultCode.ok.rawValue else {
      self.handler = previous
      throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: nil)
    }
  }
}
