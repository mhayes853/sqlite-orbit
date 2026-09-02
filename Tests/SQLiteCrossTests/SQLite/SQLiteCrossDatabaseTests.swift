#if SystemSQLite
  import Foundation
  import SQLiteCross
  import Testing

  /// Both drivers offer an `init(path:)`, so with the `GRDB` trait also enabled there is nothing
  /// for the compiler to infer the driver from. Naming the database type has to be enough.
  @Test
  func namedDatabaseTypeResolvesItsDriver() throws {
    let path = NSTemporaryDirectory() + "ambig-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let database = try SQLiteCrossDatabase(path: path)
    #expect(database.id.rawValue.hasSuffix(".sqlite"))
  }
#endif
