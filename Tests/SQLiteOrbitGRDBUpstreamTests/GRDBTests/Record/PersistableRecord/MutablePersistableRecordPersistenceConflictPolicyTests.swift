// Generated from GRDB 7.11.1 Tests/GRDBTests/Record/PersistableRecord/MutablePersistableRecordPersistenceConflictPolicyTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

private struct DefaultPolicy: MutablePersistableRecord {
    var id: Int64?
    
    static let databaseTableName = "records"
    
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
    }
    
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct MixedPolicy: MutablePersistableRecord {
    var id: Int64?
    
    static let databaseTableName = "records"
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .fail, update: .rollback)
    
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
    }
    
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct ReplacePolicy: MutablePersistableRecord {
    var id: Int64?
    var email: String
    
    static let databaseTableName = "records"
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .replace, update: .replace)
    
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["email"] = email
    }
    
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct IgnorePolicy: MutablePersistableRecord {
    var id: Int64?
    
    static let databaseTableName = "records"
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .ignore, update: .ignore)
    
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
    }
    
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct FailPolicy: MutablePersistableRecord {
    var id: Int64?
    
    static let databaseTableName = "records"
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .fail, update: .fail)
    
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
    }
    
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct AbortPolicy: MutablePersistableRecord {
    var id: Int64?
    
    static let databaseTableName = "records"
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .abort, update: .abort)
    
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
    }
    
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

private struct RollbackPolicy: MutablePersistableRecord {
    var id: Int64?
    
    static let databaseTableName = "records"
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .rollback, update: .rollback)
    
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
    }
    
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

class MutablePersistableRecordPersistenceConflictPolicyTests: GRDBTestCase {
    
    func testPolicyDefaultArguments() {
        let policy = PersistenceConflictPolicy()
        XCTAssertEqual(policy.conflictResolutionForInsert, .abort)
        XCTAssertEqual(policy.conflictResolutionForUpdate, .abort)
    }
    
    func testDefaultPolicy() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "records") { t in
                t.primaryKey("id", .integer)
            }
            
            // Insert
            var record = DefaultPolicy(id: nil)
            try record.insert(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("INSERT INTO \"records\""))
            XCTAssertEqual(record.id, 1)
            
            // Update
            record = DefaultPolicy(id: 1)
            try record.update(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("UPDATE \"records\""))
        }
    }
    
    func testPolicyOverride() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "records") { t in
                t.primaryKey("id", .integer)
            }
            
            // Insert
            var record = DefaultPolicy(id: nil)
            try record.insert(db, onConflict: .ignore)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("INSERT OR IGNORE INTO \"records\""))
            
            // Update
            record = DefaultPolicy(id: 1)
            try record.update(db, onConflict: .ignore)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("UPDATE OR IGNORE \"records\""))
        }
    }

    func testMixedPolicy() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "records") { t in
                t.primaryKey("id", .integer)
            }
            
            // Insert
            var record = MixedPolicy(id: nil)
            try record.insert(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("INSERT OR FAIL INTO \"records\""))
            XCTAssertEqual(record.id, 1)
            
            // Update
            record = MixedPolicy(id: 1)
            try record.update(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("UPDATE OR ROLLBACK \"records\""))
        }
    }



    func testIgnorePolicy() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "records") { t in
                t.primaryKey("id", .integer)
            }
            
            // Insert
            var record = IgnorePolicy(id: nil)
            try record.insert(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("INSERT OR IGNORE INTO \"records\""))
            XCTAssertEqual(record.id, 1)
            
            // Update
            record = IgnorePolicy(id: 1)
            try record.update(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("UPDATE OR IGNORE \"records\""))
        }
    }

    func testFailPolicy() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "records") { t in
                t.primaryKey("id", .integer)
            }
            
            // Insert
            var record = FailPolicy(id: nil)
            try record.insert(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("INSERT OR FAIL INTO \"records\""))
            XCTAssertEqual(record.id, 1)
            
            // Update
            record = FailPolicy(id: 1)
            try record.update(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("UPDATE OR FAIL \"records\""))
        }
    }

    func testAbortPolicy() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "records") { t in
                t.primaryKey("id", .integer)
            }
            
            // Insert
            var record = AbortPolicy(id: nil)
            try record.insert(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("INSERT INTO \"records\""))
            XCTAssertEqual(record.id, 1)
            
            // Update
            record = AbortPolicy(id: 1)
            try record.update(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("UPDATE \"records\""))
        }
    }

    func testRollbackPolicy() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "records") { t in
                t.primaryKey("id", .integer)
            }
            
            // Insert
            var record = RollbackPolicy(id: nil)
            try record.insert(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("INSERT OR ROLLBACK INTO \"records\""))
            XCTAssertEqual(record.id, 1)
            
            // Update
            record = RollbackPolicy(id: 1)
            try record.update(db)
            XCTAssertTrue(self.lastSQLQuery!.hasPrefix("UPDATE OR ROLLBACK \"records\""))
        }
    }
}
