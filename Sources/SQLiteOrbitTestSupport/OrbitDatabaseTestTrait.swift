import SQLiteOrbit
import Testing

/// A test trait that gives fetch properties a database for the duration of each test case.
///
/// Apply it to one test or recursively to a suite. A database expression or factory is evaluated
/// once per test case, so a suite can give every test an independent database:
///
/// ```swift
/// @Suite(.orbitDatabase(try testDatabase()))
/// struct RemindersTests {
///   @Test func loadsReminders() {
///     let model = RemindersModel()
///     #expect(model.reminders.count == 2)
///   }
/// }
/// ```
public struct OrbitDatabaseTestTrait: TestTrait, SuiteTrait, TestScoping {
  private let makeDatabase: @Sendable () async throws -> any OrbitObservableDatabase

  /// Makes a suite apply this trait to each test it contains.
  public var isRecursive: Bool { true }

  fileprivate init(
    makeDatabase:
      @escaping @Sendable () async throws -> any OrbitObservableDatabase
  ) {
    self.makeDatabase = makeDatabase
  }

  /// Creates the database, installs it as the task-local default, and runs one test case.
  public func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    let database = try await makeDatabase()
    try await OrbitDefaultDatabase.withValue(database) {
      try await function()
    }
  }
}

extension Trait where Self == OrbitDatabaseTestTrait {
  /// Gives each test case the database produced by `database`.
  ///
  /// The expression is evaluated inside the test's scope. Passing a construction expression such
  /// as `try testDatabase()` creates a fresh database for every case; passing an existing database
  /// intentionally shares that instance.
  public static func orbitDatabase(
    _ database: @autoclosure @escaping @Sendable () throws -> any OrbitObservableDatabase
  ) -> Self {
    Self { try database() }
  }

  /// Gives each test case the database returned by an asynchronous factory.
  public static func orbitDatabase(
    _ makeDatabase:
      @escaping @Sendable () async throws -> any OrbitObservableDatabase
  ) -> Self {
    Self(makeDatabase: makeDatabase)
  }
}
