/// Creates a ``SQLiteLibrary`` from the SQLite functions visible at the expansion site.
///
/// With no module name, the macro refers to unqualified `sqlite3_*` functions:
///
/// ```swift
/// let library = #sqliteLibrary()
/// ```
///
/// Supply a module name when its functions need to be qualified. Use `apis` to select the optional
/// entry-point groups the build implements faithfully:
///
/// ```swift
/// let library = #sqliteLibrary(module: "SQLCipher", apis: [.standard, .encryption])
/// ```
///
/// Arguments must be literals. The macro supplies ``SQLiteLibrary/transientDestructor`` to the
/// text and blob functions whose buffers must be copied.
///
/// - Parameters:
///   - apis: Optional API groups to include in the generated library.
@freestanding(expression)
public macro sqliteLibrary(
  apis: SQLiteLibrary.APIs = .standard
) -> SQLiteLibrary = #externalMacro(module: "SQLiteOrbitMacros", type: "SQLiteLibraryMacro")

/// Creates a ``SQLiteLibrary`` from the SQLite functions in a named Swift module.
///
/// - Parameters:
///   - module: The Swift module containing the SQLite functions.
///   - apis: Optional API groups to include in the generated library.
@freestanding(expression)
public macro sqliteLibrary(
  module: String,
  apis: SQLiteLibrary.APIs = .standard
) -> SQLiteLibrary = #externalMacro(module: "SQLiteOrbitMacros", type: "SQLiteLibraryMacro")
