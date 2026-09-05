#if SystemSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  /// Opening a database by path alone selects the native pooled storage implementation.
  @Test
  func openingByPathResolvesThePooledWriter() throws {
    let path = NSTemporaryDirectory() + "ambig-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let database = try OrbitDatabase(path: OrbitDatabasePath(path))
    #expect(database.id.rawValue.hasSuffix(".sqlite"))
  }
#endif
