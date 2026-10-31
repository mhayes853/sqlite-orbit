// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/TransactionObserver/TruncateOptimizationTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class TruncateOptimizationTests: GRDBTestCase {
    // https://www.sqlite.org/c3ref/update_hook.html
    //
    // > In the current implementation, the update hook is not invoked [...]
    // > when rows are deleted using the truncate optimization.
    //
    // https://www.sqlite.org/lang_delete.html#truncateopt
    //
    // > When the WHERE is omitted from a DELETE statement and the table
    // > being deleted has no triggers, SQLite uses an optimization to erase
    // > the entire table content without having to visit each row of the
    // > table individually.
    //
    // We  will thus test that the truncate optimization does not prevent
    // transaction observers from observing individual deletions.
    //
    // But that's not enough: preventing the truncate optimization requires GRDB
    // to fiddle with sqlite3_set_authorizer. When badly done, this can prevent
    // DROP TABLE statements from dropping tables. SQLite3 authorizers are
    // invoked during both compilation and execution of SQL statements. We will
    // thus test that DROP TABLE statements perform as expected when compilation
    // and execution are grouped, and when they are performed separately.


    

    

    

    

    

    
    func testDropTable() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            try XCTAssertTrue(db.tableExists("t"))
            try db.execute(sql: "DROP TABLE t") // compile + execute
            try XCTAssertFalse(db.tableExists("t"))
        }
    }
    


    func testDropTableWithPreparedStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            try XCTAssertTrue(db.tableExists("t"))
            let dropStatement = try db.makeStatement(sql: "DROP TABLE t") // compile...
            try dropStatement.execute() // ... then execute
            try XCTAssertFalse(db.tableExists("t"))
        }
    }



    func testDropTemporaryTable() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TEMPORARY TABLE t(a)")
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            try XCTAssertTrue(db.tableExists("t"))
            try db.execute(sql: "DROP TABLE t") // compile + execute
            try XCTAssertFalse(db.tableExists("t"))
        }
    }
    

    
    func testDropTemporaryTableWithPreparedStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TEMPORARY TABLE t(a)")
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            try XCTAssertTrue(db.tableExists("t"))
            let dropStatement = try db.makeStatement(sql: "DROP TABLE t") // compile...
            try dropStatement.execute() // ... then execute
            try XCTAssertFalse(db.tableExists("t"))
        }
    }
    

    
    func testDropVirtualTable() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE t USING fts3(a)")
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            try XCTAssertTrue(db.tableExists("t"))
            try db.execute(sql: "DROP TABLE t") // compile + execute
            try XCTAssertFalse(db.tableExists("t"))
        }
    }
    

    
    func testDropVirtualTableWithPreparedStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE t USING fts3(a)")
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            try XCTAssertTrue(db.tableExists("t"))
            let dropStatement = try db.makeStatement(sql: "DROP TABLE t") // compile...
            try dropStatement.execute() // ... then execute
            try XCTAssertFalse(db.tableExists("t"))
        }
    }
    

    
    func testDropView() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "CREATE VIEW v AS SELECT * FROM t")
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            try XCTAssertTrue(db.viewExists("v"))
            try db.execute(sql: "DROP VIEW v") // compile + execute
            try XCTAssertFalse(db.viewExists("v"))
        }
    }
    

    
    func testDropViewWithPreparedStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "CREATE VIEW v AS SELECT * FROM t")
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            try XCTAssertTrue(db.viewExists("v"))
            let dropStatement = try db.makeStatement(sql: "DROP VIEW v") // compile...
            try dropStatement.execute() // ... then execute
            try XCTAssertFalse(db.viewExists("v"))
        }
    }
    

    
    func testDropTemporaryView() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "CREATE TEMPORARY VIEW v AS SELECT * FROM t")
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            try XCTAssertTrue(db.viewExists("v"))
            try db.execute(sql: "DROP VIEW v") // compile + execute
            try XCTAssertFalse(db.viewExists("v"))
        }
    }
    

    
    func testDropTemporaryViewWithPreparedStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "CREATE TEMPORARY VIEW v AS SELECT * FROM t")
            try db.execute(sql: "INSERT INTO t VALUES (NULL)")
            try XCTAssertTrue(db.viewExists("v"))
            let dropStatement = try db.makeStatement(sql: "DROP VIEW v") // compile...
            try dropStatement.execute() // ... then execute
            try XCTAssertFalse(db.viewExists("v"))
        }
    }
    

    
    func testDropIndex() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "CREATE INDEX i ON t(a)")
            try XCTAssertFalse(db.indexes(on: "t").isEmpty)
            try db.execute(sql: "DROP INDEX i") // compile + execute
            try XCTAssertTrue(db.indexes(on: "t").isEmpty)
        }
    }
    

    
    func testDropIndexViewWithPreparedStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "CREATE INDEX i ON t(a)")
            try db.execute(sql: "INSERT INTO t VALUES (1)")
            try XCTAssertFalse(db.indexes(on: "t").isEmpty)
            let dropStatement = try db.makeStatement(sql: "DROP INDEX i") // compile...
            try dropStatement.execute() // ... then execute
            try XCTAssertTrue(db.indexes(on: "t").isEmpty)
        }
    }
    

    
    func testDropTemporaryIndex() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TEMPORARY TABLE t(a)")
            try db.execute(sql: "CREATE INDEX i ON t(a)")
            try XCTAssertFalse(db.indexes(on: "t").isEmpty)
            try db.execute(sql: "DROP INDEX i") // compile + execute
            try XCTAssertTrue(db.indexes(on: "t").isEmpty)
        }
    }
    

    
    func testDropTemporaryIndexViewWithPreparedStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TEMPORARY TABLE t(a)")
            try db.execute(sql: "CREATE INDEX i ON t(a)")
            try db.execute(sql: "INSERT INTO t VALUES (1)")
            try XCTAssertFalse(db.indexes(on: "t").isEmpty)
            let dropStatement = try db.makeStatement(sql: "DROP INDEX i") // compile...
            try dropStatement.execute() // ... then execute
            try XCTAssertTrue(db.indexes(on: "t").isEmpty)
        }
    }
    

    
    func testDropTrigger() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "CREATE TRIGGER r INSERT ON t BEGIN DELETE FROM t; END")
            try XCTAssertTrue(db.triggerExists("r"))
            try db.execute(sql: "DROP TRIGGER r") // compile + execute
            try XCTAssertFalse(db.triggerExists("r"))
        }
    }
    

    
    func testDropTriggerWithPreparedStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "CREATE TRIGGER r INSERT ON t BEGIN DELETE FROM t; END")
            try XCTAssertTrue(db.triggerExists("r"))
            let dropStatement = try db.makeStatement(sql: "DROP TRIGGER r") // compile...
            try dropStatement.execute() // ... then execute
            try XCTAssertFalse(db.triggerExists("r"))
        }
    }
    

    
    func testDropTemporaryTrigger() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "CREATE TEMPORARY TRIGGER r INSERT ON t BEGIN DELETE FROM t; END")
            try XCTAssertTrue(db.triggerExists("r"))
            try db.execute(sql: "DROP TRIGGER r") // compile + execute
            try XCTAssertFalse(db.triggerExists("r"))
        }
    }
    

    
    func testDropTemporaryTriggerWithPreparedStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE t(a)")
            try db.execute(sql: "CREATE TEMPORARY TRIGGER r INSERT ON t BEGIN DELETE FROM t; END")
            try XCTAssertTrue(db.triggerExists("r"))
            let dropStatement = try db.makeStatement(sql: "DROP TRIGGER r") // compile...
            try dropStatement.execute() // ... then execute
            try XCTAssertFalse(db.triggerExists("r"))
        }
    }
    

}
