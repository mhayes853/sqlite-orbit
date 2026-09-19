#if BuiltInSQLite
  import SQLiteOrbit
  import SQLiteOrbitTestSupport
  import Testing

  #if Dependencies
    import Dependencies
  #endif

  private let sharedTraitDatabase = try! SQLiteQueue(path: .memory)

  @Test(.orbitDatabase(sharedTraitDatabase))
  func databaseTestTraitAcceptsAnExistingDatabase() {
    #expect(OrbitDefaultDatabase.current === sharedTraitDatabase)
  }

  @Test(.orbitDatabase { try await makeAsyncTraitDatabase() })
  func databaseTestTraitAcceptsAnAsyncFactory() {
    _ = OrbitDefaultDatabase.current
  }

  #if Dependencies
    @Test(.orbitDatabase(try SQLiteQueue(path: .memory)))
    func databaseTestTraitAlsoScopesTheDependency() {
      @Dependency(\.orbitDefaultDatabase) var database
      #expect(database === OrbitDefaultDatabase.current)
    }
  #endif

  @Suite(.orbitDatabase(try SQLiteQueue(path: .memory)))
  struct OrbitDatabaseTestTraitScopeTests {
    @Test(arguments: [1, 2])
    func databaseExpressionIsEvaluatedForEveryTestCase(_ argument: Int) async throws {
      let database = OrbitDefaultDatabase.current
      try await database.write { transaction in
        try transaction.execute("CREATE TABLE marker_\(argument) (value)")
        // Every case also creates this table. It would fail if the suite shared one database.
        try transaction.execute("CREATE TABLE case_local_marker (value)")
      }
    }
  }

  private func makeAsyncTraitDatabase() async throws -> any OrbitObservableDatabase {
    try SQLiteQueue(path: .memory)
  }
#endif
