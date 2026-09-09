/// Creates a ``SQLiteLibrary`` from the SQLite functions visible at the expansion site.
///
/// With no module name, the macro refers to unqualified `sqlite3_*` functions:
///
/// ```swift
/// let library = #sqliteLibrary()
/// ```
///
/// Supply a module name when its functions need to be qualified. Set `encryption` when that build
/// provides SQLite's codec entry points too:
///
/// ```swift
/// let library = #sqliteLibrary(module: "SQLCipher", encryption: true)
/// ```
///
/// Both arguments must be literals. The macro supplies ``SQLiteLibrary/transientDestructor`` to
/// the text and blob functions whose buffers must be copied.
///
/// - Parameters:
///   - encryption: Whether to include `sqlite3_key_v2` and `sqlite3_rekey_v2`.
@freestanding(expression)
public macro sqliteLibrary(
  encryption: Bool = false
) -> SQLiteLibrary = #externalMacro(module: "SQLiteOrbitMacros", type: "SQLiteLibraryMacro")

/// Creates a ``SQLiteLibrary`` from the SQLite functions in a named Swift module.
///
/// - Parameters:
///   - module: The Swift module containing the SQLite functions.
///   - encryption: Whether to include `sqlite3_key_v2` and `sqlite3_rekey_v2`.
@freestanding(expression)
public macro sqliteLibrary(
  module: String,
  encryption: Bool = false
) -> SQLiteLibrary = #externalMacro(module: "SQLiteOrbitMacros", type: "SQLiteLibraryMacro")
