// Generated from GRDB 7.11.1 Tests/GRDBTests/Private/DatabaseQueueSchemaCacheTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest/ and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabaseQueueSchemaCacheTests : GRDBTestCase {
    

    

    

    

    
    func testMainShadowedByAttachedDatabase() throws {
        #if GRDBCIPHER_USE_ENCRYPTION
        // Avoid error due to key not being provided:
        // file is not a database - while executing `ATTACH DATABASE...`
        throw XCTSkip("This test does not support encrypted databases")
        #endif
        
        let attached1 = try makeDatabaseQueue(filename: "attached1")
        try attached1.write { db in
            try db.execute(sql: """
                CREATE TABLE item (attached1Column TEXT);
                INSERT INTO item VALUES('attached1');
                """)
            try XCTAssertEqual(String.fetchOne(db, sql: "SELECT * FROM item"), "attached1")
            try XCTAssertEqual(db.columns(in: "item").first?.name, "attached1Column")
        }
        
        let attached2 = try makeDatabaseQueue(filename: "attached2")
        try attached2.write { db in
            try db.execute(sql: """
                CREATE TABLE item (attached2Column TEXT);
                INSERT INTO item VALUES('attached2');
                """)
            try XCTAssertEqual(String.fetchOne(db, sql: "SELECT * FROM item"), "attached2")
            try XCTAssertEqual(db.columns(in: "item").first?.name, "attached2Column")
        }
        
        let main = try makeDatabaseQueue(filename: "main")
        try main.writeWithoutTransaction { db in
            try XCTAssertFalse(db.tableExists("item"))
            
            try db.execute(literal: "ATTACH DATABASE \(attached1.path) AS attached1")
            try XCTAssertEqual(String.fetchOne(db, sql: "SELECT * FROM item"), "attached1")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA table_info(item)")?["name"], "attached1Column")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA attached1.table_info(item)")?["name"], "attached1Column")
            try XCTAssertTrue(db.tableExists("item"))
            try XCTAssertEqual(db.columns(in: "item").first?.name, "attached1Column")
            
            // Main shadows attached1
            try db.execute(sql: """
                CREATE TABLE item (mainColumn TEXT);
                INSERT INTO item VALUES('main');
                """)
            try XCTAssertEqual(String.fetchOne(db, sql: "SELECT * FROM item"), "main")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA main.table_info(item)")?["name"], "mainColumn")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA attached1.table_info(item)")?["name"], "attached1Column")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA table_info(item)")?["name"], "mainColumn")
            try XCTAssertTrue(db.tableExists("item"))
            try XCTAssertEqual(db.columns(in: "item").first?.name, "mainColumn")
            
            // Main no longer shadows attached1
            try db.execute(sql: "DROP TABLE item")
            try XCTAssertEqual(String.fetchOne(db, sql: "SELECT * FROM item"), "attached1")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA attached1.table_info(item)")?["name"], "attached1Column")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA table_info(item)")?["name"], "attached1Column")
            try XCTAssertTrue(db.tableExists("item"))
            try XCTAssertEqual(db.columns(in: "item").first?.name, "attached1Column")
            
            // Attached1 shadows attached2
            try db.execute(literal: "ATTACH DATABASE \(attached2.path) AS attached2")
            try XCTAssertEqual(String.fetchOne(db, sql: "SELECT * FROM item"), "attached1")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA attached1.table_info(item)")?["name"], "attached1Column")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA attached2.table_info(item)")?["name"], "attached2Column")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA table_info(item)")?["name"], "attached1Column")
            try XCTAssertTrue(db.tableExists("item"))
            try XCTAssertEqual(db.columns(in: "item").first?.name, "attached1Column")
            
            // Attached1 no longer shadows attached2
            try db.execute(sql: "DETACH DATABASE attached1")
            try XCTAssertEqual(String.fetchOne(db, sql: "SELECT * FROM item"), "attached2")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA attached2.table_info(item)")?["name"], "attached2Column")
            try XCTAssertEqual(Row.fetchOne(db, sql: "PRAGMA table_info(item)")?["name"], "attached2Column")
            try XCTAssertTrue(db.tableExists("item"))
            try XCTAssertEqual(db.columns(in: "item").first?.name, "attached2Column")
            
            // Attached2 no longer shadows main
            try db.execute(sql: "DETACH DATABASE attached2")
            try XCTAssertFalse(db.tableExists("item"))
        }
    }
    
    func testTableExistsThrowsWhenUnknownSchema() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: """
               CREATE TABLE t (id INTEGER);
               CREATE VIEW v AS SELECT * FROM t;
               CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END;
               """)
            do {
                _ = try db.tableExists("t", in: "invalid")
                XCTFail("Expected Error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message, "no such schema: invalid")
                XCTAssertEqual(error.description, "SQLite error 1: no such schema: invalid")
            }
            do {
                _ = try db.viewExists("v", in: "invalid")
                XCTFail("Expected Error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message, "no such schema: invalid")
                XCTAssertEqual(error.description, "SQLite error 1: no such schema: invalid")
            }
            do {
                _ = try db.triggerExists("tr", in: "invalid")
                XCTFail("Expected Error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message, "no such schema: invalid")
                XCTAssertEqual(error.description, "SQLite error 1: no such schema: invalid")
            }
        }
    }
    
    func testExistsWithSpecifiedMainSchema() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: """
               CREATE TABLE t (id INTEGER);
               CREATE VIEW v AS SELECT * FROM t;
               CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END;
               """)
            let tableExists = try db.tableExists("t", in: "main")
            let viewExists = try db.viewExists("v", in: "main")
            let triggerExists = try db.triggerExists("tr", in: "main")
            XCTAssertTrue(tableExists)
            XCTAssertTrue(viewExists)
            XCTAssertTrue(triggerExists)
        }
    }
    
    func testNotExistsWithSpecifiedMainSchema() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let tableExists = try db.tableExists("t", in: "main")
            let viewExists = try db.viewExists("v", in: "main")
            let triggerExists = try db.triggerExists("tr", in: "main")
            XCTAssertFalse(tableExists)
            XCTAssertFalse(viewExists)
            XCTAssertFalse(triggerExists)
        }
    }
    
    func testExistsWithSpecifiedSchemaWithEntityNameCollisions() throws {
        #if GRDBCIPHER_USE_ENCRYPTION
        // Avoid error due to key not being provided:
        // file is not a database - while executing `ATTACH DATABASE...`
        throw XCTSkip("This test does not support encrypted databases")
        #endif
        
        let attached = try makeDatabaseQueue(filename: "attached")
        try attached.inDatabase { db in
            try db.execute(sql: """
               CREATE TABLE t (id INTEGER);
               CREATE VIEW v AS SELECT * FROM t;
               CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END;
               """)
        }
        let main = try makeDatabaseQueue(filename: "main")
        try main.inDatabase { db in
            try db.execute(sql: """
               CREATE TABLE t (id INTEGER);
               CREATE VIEW v AS SELECT * FROM t;
               CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END;
               """)
            try db.execute(literal: "ATTACH DATABASE \(attached.path) AS attached")
            
            let tableExistsInMain = try db.tableExists("t", in: "main")
            let viewExistsInMain = try db.viewExists("v", in: "main")
            let triggerExistsInMain = try db.triggerExists("tr", in: "main")
            XCTAssertTrue(tableExistsInMain)
            XCTAssertTrue(viewExistsInMain)
            XCTAssertTrue(triggerExistsInMain)
            
            let tableExistsInAttached = try db.tableExists("t", in: "attached")
            let viewExistsInAttached = try db.viewExists("v", in: "attached")
            let triggerExistsInAttached = try db.triggerExists("tr", in: "attached")
            XCTAssertTrue(tableExistsInAttached)
            XCTAssertTrue(viewExistsInAttached)
            XCTAssertTrue(triggerExistsInAttached)
        }
    }
    
    func testExistsWithUnspecifiedSchemaWithEntityNameCollisions() throws {
        #if GRDBCIPHER_USE_ENCRYPTION
        // Avoid error due to key not being provided:
        // file is not a database - while executing `ATTACH DATABASE...`
        throw XCTSkip("This test does not support encrypted databases")
        #endif
        
        let attached = try makeDatabaseQueue(filename: "attached")
        try attached.inDatabase { db in
            try db.execute(sql: """
               CREATE TABLE t (id INTEGER);
               CREATE VIEW v AS SELECT * FROM t;
               CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END;
               """)
        }
        let main = try makeDatabaseQueue(filename: "main")
        try main.inDatabase { db in
            try db.execute(sql: """
               CREATE TABLE t (id INTEGER);
               CREATE VIEW v AS SELECT * FROM t;
               CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END;
               """)
            try db.execute(literal: "ATTACH DATABASE \(attached.path) AS attached")
            
            // Some entity with the name exists, but we can't prove from this information which one
            // it's getting. `true` is still the correct result.
            let tableExists = try db.tableExists("t")
            let viewExists = try db.viewExists("v")
            let triggerExists = try db.triggerExists("tr")
            XCTAssertTrue(tableExists)
            XCTAssertTrue(viewExists)
            XCTAssertTrue(triggerExists)
        }
    }
    
    func testExistsWithUnspecifiedSchemaFindsAttachedDatabase() throws {
        #if GRDBCIPHER_USE_ENCRYPTION
        // Avoid error due to key not being provided:
        // file is not a database - while executing `ATTACH DATABASE...`
        throw XCTSkip("This test does not support encrypted databases")
        #endif
        
        let attached = try makeDatabaseQueue(filename: "attached")
        try attached.inDatabase { db in
            try db.execute(sql: """
               CREATE TABLE t (id INTEGER);
               CREATE VIEW v AS SELECT * FROM t;
               CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END;
               """)
        }
        let main = try makeDatabaseQueue(filename: "main")
        try main.inDatabase { db in
            try db.execute(literal: "ATTACH DATABASE \(attached.path) AS attached")
            
            try XCTAssertTrue(db.tableExists("t"))
            try XCTAssertTrue(db.viewExists("v"))
            try XCTAssertTrue(db.triggerExists("tr"))

            try XCTAssertFalse(db.tableExists("t", in: "main"))
            try XCTAssertFalse(db.viewExists("v", in: "main"))
            try XCTAssertFalse(db.triggerExists("tr", in: "main"))

            try XCTAssertTrue(db.tableExists("t", in: "attached"))
            try XCTAssertTrue(db.viewExists("v", in: "attached"))
            try XCTAssertTrue(db.triggerExists("tr", in: "attached"))
        }
    }
    
    func testExistsWithUnspecifiedSchemaFindsTempSchema() throws {
        try makeDatabaseQueue().inDatabase { db in
            try db.execute(sql: """
               CREATE TEMPORARY TABLE t (id INTEGER);
               CREATE TEMPORARY VIEW v AS SELECT * FROM t;
               """)
            
            try XCTAssertTrue(db.tableExists("t"))
            try XCTAssertTrue(db.viewExists("v"))
            
            try XCTAssertTrue(db.tableExists("t", in: "temp"))
            try XCTAssertTrue(db.viewExists("v", in: "temp"))
            
            try XCTAssertFalse(db.tableExists("t", in: "main"))
            try XCTAssertFalse(db.viewExists("v", in: "main"))
        }
    }
}
