/// The database that ``Fetch``, ``FetchAll``, and ``FetchOne`` read from when they are not given
/// one.
///
/// A fetch property takes its database from the first of three places that has one: the
/// `database:` argument it was declared with, the SwiftUI environment value a `.orbitDatabase(_:)`
/// modifier put above it, and this default. A property declared inside a view keeps looking until
/// it finds one, so a database that arrives after the property was created — from the environment,
/// or from a ``set(_:)`` the app had not reached yet — still starts it reading. A property that
/// named its own database is never re-sourced.
///
/// A property wrapper is created wherever the property it wraps lives — inside a view, a model, or
/// a controller — and those places rarely have a database to hand. Setting the default once, as
/// early as the process can, is what lets them be written without one:
///
/// ```swift
/// @main
/// struct RemindersApp: App {
///   init() {
///     OrbitDefaultDatabase.set(try! appDatabase())
///   }
///
///   var body: some Scene { WindowGroup { RemindersView() } }
/// }
/// ```
///
/// ``withValue(_:operation:)-1nrqd`` overrides it for the duration of an operation, which is what
/// a test that wants a database of its own uses:
///
/// ```swift
/// @Test func remindersAreObserved() async throws {
///   try await OrbitDefaultDatabase.withValue(try testDatabase()) {
///     @FetchAll(Reminder.all) var reminders
///     // ...
///   }
/// }
/// ```
public enum OrbitDefaultDatabase {
  /// The database property wrappers use when none is supplied.
  ///
  /// This is the innermost ``withValue(_:operation:)-1nrqd`` override in effect, or the database
  /// last given to ``set(_:)``, or `nil` when neither has happened.
  public static var current: (any OrbitObservableDatabase)? {
    scoped ?? storage.database
  }

  /// Sets the database property wrappers use when none is supplied.
  ///
  /// - Parameter database: The database to use, or `nil` to leave the process without a default.
  public static func set(_ database: (any OrbitObservableDatabase)?) {
    storage.database = database
  }

  /// Runs `operation` with `database` as the default.
  ///
  /// The override is task-local, so it reaches everything `operation` does, including the work of
  /// its child tasks, and nothing outside it.
  ///
  /// - Parameters:
  ///   - database: The database to use for the duration of `operation`.
  ///   - operation: The work to perform.
  /// - Returns: Whatever `operation` returns.
  /// - Throws: Whatever `operation` throws.
  public static func withValue<Result>(
    _ database: any OrbitObservableDatabase,
    operation: () throws -> Result
  ) rethrows -> Result {
    try $scoped.withValue(database, operation: operation)
  }

  /// Runs an asynchronous `operation` with `database` as the default.
  ///
  /// - Parameters:
  ///   - database: The database to use for the duration of `operation`.
  ///   - isolation: The actor the caller is isolated to. Defaults to the caller's isolation.
  ///   - operation: The work to perform.
  /// - Returns: Whatever `operation` returns.
  /// - Throws: Whatever `operation` throws.
  public static func withValue<Result>(
    _ database: any OrbitObservableDatabase,
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> Result
  ) async rethrows -> Result {
    try await $scoped.withValue(database, operation: operation, isolation: isolation)
  }

  @TaskLocal private static var scoped: (any OrbitObservableDatabase)?

  private static let storage = Storage()

  private final class Storage: Sendable {
    private let value = Lock<(any OrbitObservableDatabase)?>(nil)

    var database: (any OrbitObservableDatabase)? {
      get { value.withLock { $0 } }
      set { value.withLock { $0 = newValue } }
    }
  }
}

/// Thrown by a fetch property that was given no database and found no
/// ``OrbitDefaultDatabase/current`` one to fall back to.
///
/// The property keeps whatever value it was declared with and reports this as its `loadError`
/// rather than trapping, so a view built before its database exists still renders — and starts
/// reading by itself once one of the three sources of a database described by
/// ``OrbitDefaultDatabase`` supplies one.
///
/// ```swift
/// @FetchAll(Reminder.all) var reminders
/// if $reminders.loadError is OrbitMissingDefaultDatabaseError {
///   // `OrbitDefaultDatabase.set(_:)` has not been called.
/// }
/// ```
public struct OrbitMissingDefaultDatabaseError: Error, Sendable {
  /// Creates the error.
  public init() {}
}

extension OrbitMissingDefaultDatabaseError: CustomStringConvertible {
  /// A description naming the call that would have prevented the error.
  public var description: String {
    """
    A fetch property was created without a database, and no default database has been set. Call \
    'OrbitDefaultDatabase.set(_:)' before creating it, pass one as the property's 'database' \
    argument, or put a '.orbitDatabase(_:)' modifier above the view that declares it.
    """
  }
}
