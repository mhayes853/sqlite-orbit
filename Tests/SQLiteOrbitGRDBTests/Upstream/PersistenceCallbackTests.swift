// Shared application fixture, run against both the overlay and GRDB 7.11.1.
import XCTest
import SQLiteOrbitGRDB

private final class CallbackRecord: MutablePersistableRecord {
  static let databaseTableName = "callback"
  var id: Int64?
  var name = "Arthur"
  var events: [String] = []
  func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id; container["name"] = name
  }
  func willSave(_ db: Database) throws { events.append("willSave") }
  func aroundSave(_ db: Database, save: () throws -> PersistenceSuccess) throws {
    events.append("aroundSave.before"); _ = try save(); events.append("aroundSave.after")
  }
  func didSave(_ saved: PersistenceSuccess) { events.append("didSave") }
  func willInsert(_ db: Database) throws { events.append("willInsert") }
  func aroundInsert(_ db: Database, insert: () throws -> InsertionSuccess) throws {
    events.append("aroundInsert.before"); _ = try insert(); events.append("aroundInsert.after")
  }
  func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID; events.append("didInsert") }
  func willUpdate(_ db: Database, columns: Set<String>) throws { events.append("willUpdate") }
  func aroundUpdate(_ db: Database, columns: Set<String>, update: () throws -> PersistenceSuccess) throws {
    events.append("aroundUpdate.before"); _ = try update(); events.append("aroundUpdate.after")
  }
  func didUpdate(_ updated: PersistenceSuccess) { events.append("didUpdate") }
}
class PersistenceCallbackTests: GRDBTestCase {
  func testInsertAndUpdateCallbacks() throws {
    let queue = try makeDatabaseQueue()
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE callback(id INTEGER PRIMARY KEY, name TEXT)")
      var record = CallbackRecord()
      try record.insert(db)
      XCTAssertEqual(record.id, 1)
      XCTAssertEqual(record.events, ["willSave", "aroundSave.before", "willInsert", "aroundInsert.before", "aroundInsert.after", "didInsert", "aroundSave.after", "didSave"])
      record.events = []
      try record.update(db)
      XCTAssertEqual(record.events, ["willSave", "aroundSave.before", "willUpdate", "aroundUpdate.before", "aroundUpdate.after", "didUpdate", "aroundSave.after", "didSave"])
    }
  }
  func testSaveFallbackDoesNotRepeatSaveCallbacks() throws {
    let queue = try makeDatabaseQueue()
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE callback(id INTEGER PRIMARY KEY, name TEXT)")
      var record = CallbackRecord(); record.id = 5
      try record.save(db)
      XCTAssertEqual(record.id, 5)
      XCTAssertEqual(record.events.filter { $0 == "willSave" }.count, 1)
      XCTAssertEqual(record.events.filter { $0 == "didSave" }.count, 1)
      XCTAssertEqual(record.events.filter { $0 == "aroundSave.before" }.count, 1)
    }
  }
}
