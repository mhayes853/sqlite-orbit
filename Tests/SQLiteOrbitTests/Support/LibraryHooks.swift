#if BuiltInSQLite
  import Testing

  @testable import SQLiteOrbit

  /// Entry points that call closures the running test supplies.
  ///
  /// A library's entry points are C function pointers, which capture nothing, so one cannot close
  /// over a test's counters or flags. Each function here keeps the closure it is given in the
  /// running test's ``Scope`` and returns an entry point that looks it up there. Outside any test
  /// that hooked it, the entry point calls the built-in library's instead.
  ///
  /// The scope is a task local, bound by the ``Trait/libraryHooks`` trait. Swift Testing runs each
  /// test, and each argument of a parameterized test, in a task of its own, and a task local
  /// reaches only that task, the tasks it creates, and the actors it calls, which is where its
  /// connections run. So tests running in parallel never call one another's closures, and none of
  /// them has to be serialized.
  ///
  /// ```swift
  /// @Test(.libraryHooks)
  /// func countsSteps() async throws {
  ///   let steps = TestCounter()
  ///   var configuration = SQLiteConfiguration.default
  ///   configuration.library.statements.execution.step = LibraryHooks.step { statement in
  ///     steps.increment()
  ///     return builtInTestLibrary.statements.execution.step(statement)
  ///   }
  ///   ...
  /// }
  /// ```
  enum LibraryHooks {
    /// The closures one test has hooked entry points with.
    final class Scope: Sendable {
      fileprivate let hooks = Lock(Hooks())
    }

    @TaskLocal static var scope: Scope?

    fileprivate struct Hooks {
      var open:
        (
          @Sendable (
            UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32,
            UnsafePointer<CChar>?
          ) -> Int32
        )?
      var close: (@Sendable (OpaquePointer?) -> Int32)?
      var interrupt: (@Sendable (OpaquePointer?) -> Void)?
      var setBusyTimeout: (@Sendable (OpaquePointer?, Int32) -> Int32)?
      var setExtendedResultCodes: (@Sendable (OpaquePointer?, Int32) -> Int32)?
      var walCheckpoint:
        (
          @Sendable (
            OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<Int32>?,
            UnsafeMutablePointer<Int32>?
          ) -> Int32
        )?
      var versionNumber: (@Sendable () -> Int32)?
      var prepare:
        (
          @Sendable (
            OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
            UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
          ) -> Int32
        )?
      var step: (@Sendable (OpaquePointer?) -> Int32)?
      var finalize: (@Sendable (OpaquePointer?) -> Int32)?
      var columnName: (@Sendable (OpaquePointer?, Int32) -> UnsafePointer<CChar>?)?
      var installAuthorizer:
        (@Sendable (OpaquePointer?, SQLiteAuthorizerCallback?, UnsafeMutableRawPointer?) -> Int32)?
      var createCollation:
        (
          @Sendable (
            OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?,
            SQLiteComparator?, SQLiteDestructor?
          ) -> Int32
        )?
      var key:
        (@Sendable (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32) -> Int32)?
      var rekey:
        (@Sendable (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32) -> Int32)?
      var userData: (@Sendable (OpaquePointer?) -> UnsafeMutableRawPointer?)?
      var argumentText: (@Sendable (OpaquePointer?) -> UnsafePointer<UInt8>?)?
      var resultText: (@Sendable (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Void)?
      var aggregateContext: (@Sendable (OpaquePointer?, Int32) -> UnsafeMutableRawPointer?)?
      var registerAutoExtension: (@Sendable (@convention(c) () -> Void) -> Int32)?
      var cancelAutoExtension: (@Sendable (@convention(c) () -> Void) -> Int32)?
    }

    private static func install<Hook>(_ hook: WritableKeyPath<Hooks, Hook?>, _ body: Hook) {
      guard let scope else {
        preconditionFailure("Hooking a library entry point needs the test to have .libraryHooks.")
      }
      scope.hooks.withLock { $0[keyPath: hook] = body }
    }

    // Copied out of the lock before a hook is called, since a hook can run SQL of its own.
    private static var current: Hooks? {
      scope?.hooks.withLock { $0 }
    }

    // MARK: - Connections

    static func open(
      _ body:
        @escaping @Sendable (
          UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?
        ) -> Int32
    )
      -> @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?
      ) -> Int32
    {
      install(\.open, body)
      return { path, connection, flags, vfs in
        guard let open = LibraryHooks.current?.open else {
          return builtInTestLibrary.connections.open(path, connection, flags, vfs)
        }
        return open(path, connection, flags, vfs)
      }
    }

    static func close(
      _ body: @escaping @Sendable (OpaquePointer?) -> Int32
    ) -> @convention(c) (OpaquePointer?) -> Int32 {
      install(\.close, body)
      return { connection in
        guard let close = LibraryHooks.current?.close else {
          return builtInTestLibrary.connections.close(connection)
        }
        return close(connection)
      }
    }

    static func interrupt(
      _ body: @escaping @Sendable (OpaquePointer?) -> Void
    ) -> @convention(c) (OpaquePointer?) -> Void {
      install(\.interrupt, body)
      return { connection in
        guard let interrupt = LibraryHooks.current?.interrupt else {
          return builtInTestLibrary.connections.interrupt(connection)
        }
        interrupt(connection)
      }
    }

    static func setBusyTimeout(
      _ body: @escaping @Sendable (OpaquePointer?, Int32) -> Int32
    ) -> @convention(c) (OpaquePointer?, Int32) -> Int32 {
      install(\.setBusyTimeout, body)
      return { connection, milliseconds in
        guard let setBusyTimeout = LibraryHooks.current?.setBusyTimeout else {
          return builtInTestLibrary.connections.setBusyTimeout(connection, milliseconds)
        }
        return setBusyTimeout(connection, milliseconds)
      }
    }

    static func setExtendedResultCodes(
      _ body: @escaping @Sendable (OpaquePointer?, Int32) -> Int32
    ) -> @convention(c) (OpaquePointer?, Int32) -> Int32 {
      install(\.setExtendedResultCodes, body)
      return { connection, isOn in
        guard let setExtendedResultCodes = LibraryHooks.current?.setExtendedResultCodes else {
          return builtInTestLibrary.connections.setExtendedResultCodes(connection, isOn)
        }
        return setExtendedResultCodes(connection, isOn)
      }
    }

    static func walCheckpoint(
      _ body:
        @escaping @Sendable (
          OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<Int32>?,
          UnsafeMutablePointer<Int32>?
        ) -> Int32
    )
      -> @convention(c) (
        OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<Int32>?,
        UnsafeMutablePointer<Int32>?
      ) -> Int32
    {
      install(\.walCheckpoint, body)
      return { connection, schema, mode, log, moved in
        guard let walCheckpoint = LibraryHooks.current?.walCheckpoint else {
          return builtInTestLibrary.connections.walCheckpoint(connection, schema, mode, log, moved)
        }
        return walCheckpoint(connection, schema, mode, log, moved)
      }
    }

    static func versionNumber(
      _ body: @escaping @Sendable () -> Int32
    ) -> @convention(c) () -> Int32 {
      install(\.versionNumber, body)
      return {
        guard let versionNumber = LibraryHooks.current?.versionNumber else {
          return builtInTestLibrary.runtime.versionNumber()
        }
        return versionNumber()
      }
    }

    // MARK: - Statements

    static func prepare(
      _ body:
        @escaping @Sendable (
          OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
          UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
        ) -> Int32
    )
      -> @convention(c) (
        OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt32,
        UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?
      ) -> Int32
    {
      install(\.prepare, body)
      return { connection, sql, byteCount, flags, statement, tail in
        guard let prepare = LibraryHooks.current?.prepare else {
          return builtInTestLibrary.statements.preparation
            .prepare(connection, sql, byteCount, flags, statement, tail)
        }
        return prepare(connection, sql, byteCount, flags, statement, tail)
      }
    }

    static func step(
      _ body: @escaping @Sendable (OpaquePointer?) -> Int32
    ) -> @convention(c) (OpaquePointer?) -> Int32 {
      install(\.step, body)
      return { statement in
        guard let step = LibraryHooks.current?.step else {
          return builtInTestLibrary.statements.execution.step(statement)
        }
        return step(statement)
      }
    }

    static func finalize(
      _ body: @escaping @Sendable (OpaquePointer?) -> Int32
    ) -> @convention(c) (OpaquePointer?) -> Int32 {
      install(\.finalize, body)
      return { statement in
        guard let finalize = LibraryHooks.current?.finalize else {
          return builtInTestLibrary.statements.execution.finalize(statement)
        }
        return finalize(statement)
      }
    }

    static func columnName(
      _ body: @escaping @Sendable (OpaquePointer?, Int32) -> UnsafePointer<CChar>?
    ) -> @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>? {
      install(\.columnName, body)
      return { statement, index in
        guard let columnName = LibraryHooks.current?.columnName else {
          return builtInTestLibrary.columns.name(statement, index)
        }
        return columnName(statement, index)
      }
    }

    // MARK: - Optional groups

    static func installAuthorizer(
      _ body:
        @escaping @Sendable (
          OpaquePointer?, SQLiteAuthorizerCallback?, UnsafeMutableRawPointer?
        ) -> Int32
    )
      -> @convention(c) (OpaquePointer?, SQLiteAuthorizerCallback?, UnsafeMutableRawPointer?) ->
      Int32
    {
      install(\.installAuthorizer, body)
      return { connection, callback, context in
        guard let installAuthorizer = LibraryHooks.current?.installAuthorizer else {
          return builtInTestLibrary.authorizer!.install(connection, callback, context)
        }
        return installAuthorizer(connection, callback, context)
      }
    }

    static func createCollation(
      _ body:
        @escaping @Sendable (
          OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?,
          SQLiteComparator?, SQLiteDestructor?
        ) -> Int32
    )
      -> @convention(c) (
        OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?, SQLiteComparator?,
        SQLiteDestructor?
      ) -> Int32
    {
      install(\.createCollation, body)
      return { connection, name, flags, context, compare, destroy in
        guard let createCollation = LibraryHooks.current?.createCollation else {
          return builtInTestLibrary.collations!
            .create(connection, name, flags, context, compare, destroy)
        }
        return createCollation(connection, name, flags, context, compare, destroy)
      }
    }

    static func key(
      _ body:
        @escaping @Sendable (
          OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32
        ) -> Int32
    ) -> @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32) -> Int32 {
      install(\.key, body)
      return { connection, schema, bytes, count in
        guard let key = LibraryHooks.current?.key else {
          fatalError("A key was applied outside the test that hooked it.")
        }
        return key(connection, schema, bytes, count)
      }
    }

    static func rekey(
      _ body:
        @escaping @Sendable (
          OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32
        ) -> Int32
    ) -> @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int32) -> Int32 {
      install(\.rekey, body)
      return { connection, schema, bytes, count in
        guard let rekey = LibraryHooks.current?.rekey else {
          fatalError("A key was changed outside the test that hooked it.")
        }
        return rekey(connection, schema, bytes, count)
      }
    }

    static func userData(
      _ body: @escaping @Sendable (OpaquePointer?) -> UnsafeMutableRawPointer?
    ) -> @convention(c) (OpaquePointer?) -> UnsafeMutableRawPointer? {
      install(\.userData, body)
      return { context in
        guard let userData = LibraryHooks.current?.userData else {
          return builtInTestLibrary.scalarFunctions!.callbacks.context.userData(context)
        }
        return userData(context)
      }
    }

    static func argumentText(
      _ body: @escaping @Sendable (OpaquePointer?) -> UnsafePointer<UInt8>?
    ) -> @convention(c) (OpaquePointer?) -> UnsafePointer<UInt8>? {
      install(\.argumentText, body)
      return { value in
        guard let argumentText = LibraryHooks.current?.argumentText else {
          return builtInTestLibrary.scalarFunctions!.callbacks.argument.text(value)
        }
        return argumentText(value)
      }
    }

    static func resultText(
      _ body: @escaping @Sendable (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Void
    ) -> @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Void {
      install(\.resultText, body)
      return { context, text, count in
        guard let resultText = LibraryHooks.current?.resultText else {
          return builtInTestLibrary.scalarFunctions!.callbacks.result.text(context, text, count)
        }
        resultText(context, text, count)
      }
    }

    static func aggregateContext(
      _ body: @escaping @Sendable (OpaquePointer?, Int32) -> UnsafeMutableRawPointer?
    ) -> @convention(c) (OpaquePointer?, Int32) -> UnsafeMutableRawPointer? {
      install(\.aggregateContext, body)
      return { context, size in
        guard let aggregateContext = LibraryHooks.current?.aggregateContext else {
          return builtInTestLibrary.aggregateFunctions!.context(context, size)
        }
        return aggregateContext(context, size)
      }
    }

    static func registerAutoExtension(
      _ body: @escaping @Sendable (@convention(c) () -> Void) -> Int32
    ) -> @convention(c) (@convention(c) () -> Void) -> Int32 {
      install(\.registerAutoExtension, body)
      return { initializer in
        guard let registerAutoExtension = LibraryHooks.current?.registerAutoExtension else {
          fatalError("An extension was registered outside the test that hooked it.")
        }
        return registerAutoExtension(initializer)
      }
    }

    static func cancelAutoExtension(
      _ body: @escaping @Sendable (@convention(c) () -> Void) -> Int32
    ) -> @convention(c) (@convention(c) () -> Void) -> Int32 {
      install(\.cancelAutoExtension, body)
      return { initializer in
        guard let cancelAutoExtension = LibraryHooks.current?.cancelAutoExtension else {
          fatalError("An extension was cancelled outside the test that hooked it.")
        }
        return cancelAutoExtension(initializer)
      }
    }
  }

  /// Gives a test a ``LibraryHooks/Scope`` of its own.
  struct LibraryHooksTrait: TestTrait, SuiteTrait, TestScoping {
    // Applied to a suite, every test in it gets a scope of its own.
    var isRecursive: Bool { true }

    func provideScope(
      for test: Test,
      testCase: Test.Case?,
      performing function: @Sendable () async throws -> Void
    ) async throws {
      try await LibraryHooks.$scope.withValue(LibraryHooks.Scope()) {
        try await function()
      }
    }
  }

  extension Trait where Self == LibraryHooksTrait {
    /// Lets the test hook library entry points through ``LibraryHooks``.
    static var libraryHooks: Self { Self() }
  }
#endif
