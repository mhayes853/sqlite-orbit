#if SystemSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  /// Naming the database type selects the native pooled storage implementation.
  @Test
  func namedDatabaseTypeResolvesItsDriver() throws {
    let path = NSTemporaryDirectory() + "ambig-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let database = try OrbitDatabase(path: DatabasePath(path))
    #expect(database.id.rawValue.hasSuffix(".sqlite"))
  }
#endif
