#if Dependencies
  import Dependencies
  #if canImport(SwiftUI)
    import protocol SwiftUI.DynamicProperty
  #endif
#endif

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
  /// in `DependencyValues.orbitDefaultDatabase` when the `Dependencies` trait is enabled, or the
  /// database last given to ``set(_:)``, in that order.
  ///
  /// Accessing this property without first configuring a database is a programmer error and
  /// terminates the process with setup instructions.
  public static var current: any OrbitObservableDatabase {
    OrbitDefaultDatabaseSource().current
  }

  /// Sets the process-wide fallback database property wrappers use when none is supplied.
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

  static var currentIfConfigured: (any OrbitObservableDatabase)? {
    OrbitDefaultDatabaseSource().currentIfConfigured
  }

  fileprivate static func resolve(
    dependency: (any OrbitObservableDatabase)?
  ) -> (any OrbitObservableDatabase)? {
    scoped ?? dependency ?? storage.database
  }

  fileprivate static func require(
    dependency: (any OrbitObservableDatabase)?
  ) -> any OrbitObservableDatabase {
    guard let database = resolve(dependency: dependency) else {
      fatalError(missingDatabaseMessage)
    }
    return database
  }

  static let missingDatabaseMessage = """
    A default database has not been configured for 'SQLiteOrbit'.

    Configure one as early as possible in your application's lifetime:

      OrbitDefaultDatabase.set(try! appDatabase())

    When using the 'Dependencies' package trait, prepare the dependency instead:

      prepareDependencies {
        $0.orbitDefaultDatabase = try! appDatabase()
      }

    In tests, import 'SQLiteOrbitTestSupport' and apply its database trait:

      @Test(.orbitDatabase(try testDatabase()))

    A SwiftUI view can instead provide a database to its fetch properties:

      ContentView()
        .orbitDatabase(try! previewDatabase())
    """

  private final class Storage: Sendable {
    private let value = Lock<(any OrbitObservableDatabase)?>(nil)

    var database: (any OrbitObservableDatabase)? {
      get { value.withLock { $0 } }
      set { value.withLock { $0 = newValue } }
    }
  }
}

/// A default-database lookup that retains the dependency values present when it is created.
///
/// Fetch storage owns one of these so that a model created inside `withDependencies` keeps that
/// database after the operation returns. Reading it still observes any more-local dependency or
/// ``OrbitDefaultDatabase/withValue(_:operation:)-1nrqd`` scope.
struct OrbitDefaultDatabaseSource: Sendable {
  #if Dependencies
    @Dependency(OrbitDefaultDatabaseKey.self) private var dependency
  #else
    private let dependency: (any OrbitObservableDatabase)? = nil
  #endif

  var currentIfConfigured: (any OrbitObservableDatabase)? {
    OrbitDefaultDatabase.resolve(dependency: dependency)
  }

  var current: any OrbitObservableDatabase {
    OrbitDefaultDatabase.require(dependency: dependency)
  }
}

#if Dependencies
  #if canImport(SwiftUI)
    extension OrbitDefaultDatabaseSource: DynamicProperty {}
  #endif

  private enum OrbitDefaultDatabaseKey: DependencyKey {
    static let liveValue: (any OrbitObservableDatabase)? = nil
    static let testValue: (any OrbitObservableDatabase)? = nil
  }

  extension DependencyValues {
    /// The database Orbit fetch properties use when no nearer source supplies one.
    ///
    /// This value interoperates with ``OrbitDefaultDatabase`` in both directions. An
    /// ``OrbitDefaultDatabase/withValue(_:operation:)-1nrqd`` scope takes precedence over a
    /// dependency override, while the process default set by ``OrbitDefaultDatabase/set(_:)`` is
    /// used when the dependency has not been overridden. Accessing this value without configuring
    /// any of those sources terminates the process with setup instructions.
    public var orbitDefaultDatabase: any OrbitObservableDatabase {
      get {
        OrbitDefaultDatabase.require(dependency: self[OrbitDefaultDatabaseKey.self])
      }
      set {
        self[OrbitDefaultDatabaseKey.self] = newValue
      }
    }
  }
#endif
