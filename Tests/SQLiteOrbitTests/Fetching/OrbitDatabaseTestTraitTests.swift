#if BuiltInSQLite
  import SQLiteOrbit
  import SQLiteOrbitTestSupport
  import Testing

  private let sharedTraitDatabase = try! SQLiteQueue(path: .memory)

  @Test(.orbitDatabase(sharedTraitDatabase))
  func databaseTestTraitAcceptsAnExistingDatabase() {
    #expect(OrbitDefaultDatabase.current === sharedTraitDatabase)
  }

  @Test(.orbitDatabase { try await makeAsyncTraitDatabase() })
  func databaseTestTraitAcceptsAnAsyncFactory() {
    #expect(OrbitDefaultDatabase.current != nil)
  }

  @Suite(.orbitDatabase(try SQLiteQueue(path: .memory)))
  struct OrbitDatabaseTestTraitScopeTests {
    @Test(arguments: [1, 2])
    func databaseExpressionIsEvaluatedForEveryTestCase(_ argument: Int) async throws {
      let database = try #require(OrbitDefaultDatabase.current)
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
