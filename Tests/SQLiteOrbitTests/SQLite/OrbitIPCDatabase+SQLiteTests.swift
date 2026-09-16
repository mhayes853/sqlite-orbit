#if BuiltInSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  @Test
  func openingByPathResolvesThePooledWriter() throws {
    let path = NSTemporaryDirectory() + "ambig-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let database = try OrbitIPCDatabase(path: OrbitDatabasePath(path))
    #expect(database.id.rawValue.hasSuffix(".sqlite"))
  }
#endif
