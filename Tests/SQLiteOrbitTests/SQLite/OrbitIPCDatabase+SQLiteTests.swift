#if BuiltInSQLite && (canImport(Darwin) || os(Linux) || os(Android))
  import Foundation
  import SQLiteOrbit
  import Testing

  // A test file that imports SQLiteOrbit without `@testable` sees only the public initializers,
  // which is where opening by path alone was once ambiguous.
  @Test
  func openingByPathResolvesThePooledWriter() throws {
    try withTestDatabaseFile { file in
      let database = try OrbitIPCDatabase(path: file.path, coordination: file.coordination)
      #expect(database.id == .forDatabase(path: file.path))
    }
  }
#endif
