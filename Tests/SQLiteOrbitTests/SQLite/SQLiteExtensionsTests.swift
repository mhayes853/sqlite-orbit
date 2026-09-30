#if BuiltInSQLite
  import Testing
  @testable import SQLiteOrbit

  @Suite
  struct SQLiteExtensionsTests {
    private static let initializer: SQLiteExtensionInitializer = { _, _, _ in
      SQLiteResultCode.constraint.rawValue
    }

    @Test
    func automaticRegistrationPreservesTheInitializerAndReportsCancellation() throws {
      let registrations = TestCounter()
      let cancellations = TestCounter()
      var library = builtInTestLibrary
      library.extensions = SQLiteLibrary.Extensions(
        autoExtensions: SQLiteLibrary.AutoExtensions(
          register: { initializer in
            let callback = unsafeBitCast(initializer, to: SQLiteExtensionInitializer.self)
            #expect(callback(nil, nil, nil) == SQLiteResultCode.constraint.rawValue)
            registrations.increment()
            return SQLiteResultCode.ok.rawValue
          },
          cancel: { _ in
            cancellations.increment()
            return cancellations.value == 1 ? 1 : 0
          }
        )
      )

      try library.registerAutoExtension(Self.initializer)
      #expect(registrations.value == 1)
      #expect(try library.cancelAutoExtension(Self.initializer))
      #expect(try !library.cancelAutoExtension(Self.initializer))
    }

    @Test
    func unsupportedAndFailedRegistrationAreTypedErrors() throws {
      var library = builtInTestLibrary
      library.extensions = nil
      let unavailable = SQLiteFeatureUnavailableError(
        libraryName: library.name,
        feature: .autoExtensions
      )
      #expect(throws: unavailable) { try library.registerAutoExtension(Self.initializer) }
      #expect(throws: unavailable) { try library.cancelAutoExtension(Self.initializer) }

      library.extensions = SQLiteLibrary.Extensions(
        autoExtensions: SQLiteLibrary.AutoExtensions(
          register: { _ in SQLiteResultCode.busy.rawValue },
          cancel: { _ in 0 }
        )
      )
      let error = #expect(throws: SQLiteError.self) {
        try library.registerAutoExtension(Self.initializer)
      }
      #expect(error?.code == .busy)
    }

    @Test
    func preparationUsesTheCurrentLibraryAndPrecedesOpening() throws {
      let opens = TestCounter()
      let preparations = TestCounter()
      let base = builtInTestLibrary
      var configuration = SQLiteConfiguration(library: base)
      configuration.connectionSetups = [
        SQLiteConnectionSetup(
          prepare: { library in
            #expect(library.name == "changed after setup")
            #expect(opens.value == preparations.value)
            preparations.increment()
          },
          install: { _ in SQLiteResultCode.ok.rawValue }
        )
      ]
      configuration.library.name = "changed after setup"
      configuration.library.connections.open = { path, connection, flags, vfs in
        #expect(preparations.value == opens.value + 1)
        opens.increment()
        return base.connections.open(path, connection, flags, vfs)
      }

      for _ in 0..<2 {
        _ = try SQLiteHandle.open(
          path: ":memory:",
          flags: [.readWrite, .create, .memory, .noMutex],
          configuration: configuration
        )
      }
      #expect(opens.value == 2)
      #expect(preparations.value == 2)

      configuration.connectionSetups.insert(
        SQLiteConnectionSetup(
          prepare: { _ in throw TestError() },
          install: { _ in SQLiteResultCode.ok.rawValue }
        ),
        at: 0
      )
      #expect(throws: TestError()) {
        _ = try SQLiteHandle.open(
          path: ":memory:",
          flags: [.readWrite, .create, .memory, .noMutex],
          configuration: configuration
        )
      }
      #expect(opens.value == 2)
    }
  }
#endif

#if SystemSQLite && !canImport(Darwin)
  import CSQLite3

  @Test
  func macroBindsAutomaticExtensionsToTheSelectedRuntime() throws {
    let library = #sqliteLibrary(module: "CSQLite3", apis: [.standard, .autoExtensions])
    let initializer: SQLiteExtensionInitializer = { connection, _, _ in
      sqlite3_create_function_v2(
        connection,
        "orbit_extension_test_marker",
        0,
        SQLITE_UTF8,
        nil,
        { context, _, _ in sqlite3_result_int(context, 42) },
        nil,
        nil,
        nil
      )
    }
    try library.registerAutoExtension(initializer)
    defer { _ = try? library.cancelAutoExtension(initializer) }

    var configuration = SQLiteConfiguration(library: library)
    // Exercise registration itself independently of the Vec integration.
    configuration.connectionSetups = []
    let database = try SQLiteQueue(path: ":memory:", configuration: configuration)
    let value = try database.readBlocking {
      try $0.fetchOne("SELECT orbit_extension_test_marker()", as: Int64.self)
    }
    #expect(value == 42)
    #expect(try library.cancelAutoExtension(initializer))
    #expect(try !library.cancelAutoExtension(initializer))

    // Cancellation affects future connections, but leaves an initialized connection working.
    #expect(
      try database.readBlocking {
        try $0.fetchOne("SELECT orbit_extension_test_marker()", as: Int64.self)
      } == 42
    )
    let later = try SQLiteQueue(path: ":memory:", configuration: configuration)
    #expect(throws: SQLiteError.self) {
      try later.readBlocking {
        try $0.fetchOne("SELECT orbit_extension_test_marker()", as: Int64.self)
      }
    }
  }
#endif
