// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/ColumnInfoTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class ColumnInfoTests: GRDBTestCase {
    

    
    func testGeneratedColumnInfo() throws {
        #if !GRDBCUSTOMSQLITE
        throw XCTSkip("Generated columns are not available")
        #else
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: """
                CREATE TABLE t (
                    a INT,
                    b ALWAYS GENERATED AS (a),
                    c ALWAYS GENERATED AS (a) VIRTUAL,
                    d ALWAYS GENERATED AS (a) STORED,
                    e INT ALWAYS GENERATED AS (a),
                    f TEXT ALWAYS GENERATED AS (a),
                    g ALWAYS GENERATED AS (a) NOT NULL
                )
                """)
            let columns = try db.columns(in: "t")
            XCTAssertEqual(columns.count, 7)
            
            XCTAssertEqual(columns[0].name, "a")
            XCTAssertEqual(columns[0].isNotNull, false)
            XCTAssertEqual(columns[0].type, "INT")
            XCTAssertEqual(columns[0].primaryKeyIndex, 0)
            XCTAssertNil(columns[0].defaultValueSQL)
            
            XCTAssertEqual(columns[1].name, "b")
            XCTAssertEqual(columns[1].isNotNull, false)
            XCTAssertEqual(columns[1].type, "ALWAYS GENERATED")
            XCTAssertEqual(columns[1].primaryKeyIndex, 0)
            XCTAssertNil(columns[1].defaultValueSQL)
            
            XCTAssertEqual(columns[2].name, "c")
            XCTAssertEqual(columns[2].isNotNull, false)
            XCTAssertEqual(columns[2].type, "ALWAYS GENERATED")
            XCTAssertEqual(columns[2].primaryKeyIndex, 0)
            XCTAssertNil(columns[2].defaultValueSQL)
            
            XCTAssertEqual(columns[3].name, "d")
            XCTAssertEqual(columns[3].isNotNull, false)
            XCTAssertEqual(columns[3].type, "ALWAYS GENERATED")
            XCTAssertEqual(columns[3].primaryKeyIndex, 0)
            XCTAssertNil(columns[3].defaultValueSQL)
            
            XCTAssertEqual(columns[4].name, "e")
            XCTAssertEqual(columns[4].isNotNull, false)
            XCTAssertEqual(columns[4].type, "INT ALWAYS GENERATED")
            XCTAssertEqual(columns[4].primaryKeyIndex, 0)
            XCTAssertNil(columns[4].defaultValueSQL)
            
            XCTAssertEqual(columns[5].name, "f")
            XCTAssertEqual(columns[5].isNotNull, false)
            XCTAssertEqual(columns[5].type, "TEXT ALWAYS GENERATED")
            XCTAssertEqual(columns[5].primaryKeyIndex, 0)
            XCTAssertNil(columns[5].defaultValueSQL)
            
            XCTAssertEqual(columns[6].name, "g")
            XCTAssertEqual(columns[6].isNotNull, true)
            XCTAssertEqual(columns[6].type, "ALWAYS GENERATED")
            XCTAssertEqual(columns[6].primaryKeyIndex, 0)
            XCTAssertNil(columns[6].defaultValueSQL)
        }
        #endif
    }
    



    
    func testUnknownSchema() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE t (id INTEGER)")
            do {
                _ = try db.columns(in: "t", in: "invalid")
                XCTFail("Expected Error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message, "no such schema: invalid")
                XCTAssertEqual(error.description, "SQLite error 1: no such schema: invalid")
            }
        }
    }
    
    func testSpecifiedMainSchema() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE t (id INTEGER)")
            let columns = try db.columns(in: "t")
            XCTAssertEqual(columns.count, 1)
            XCTAssertEqual(columns[0].name, "id")
            XCTAssertEqual(columns[0].type, "INTEGER")
        }
    }
    
    func testSpecifiedSchemaWithTableNameCollisions() throws {
        #if GRDBCIPHER_USE_ENCRYPTION
        // Avoid error due to key not being provided:
        // file is not a database - while executing `ATTACH DATABASE...`
        throw XCTSkip("This test does not support encrypted databases")
        #endif

        let attached = try makeDatabaseQueue(filename: "attached1")
        try attached.inDatabase { db in
            try db.execute(sql: "CREATE TABLE t (id2 TEXT)")
        }
        let main = try makeDatabaseQueue(filename: "main")
        try main.inDatabase { db in
            try db.execute(sql: "CREATE TABLE t (id1 INTEGER)")
            try db.execute(literal: "ATTACH DATABASE \(attached.path) AS attached")
            
            let columnsMain = try db.columns(in: "t", in: "main")
            XCTAssertEqual(columnsMain.count, 1)
            XCTAssertEqual(columnsMain[0].name, "id1")
            XCTAssertEqual(columnsMain[0].type, "INTEGER")
            
            let columnsAttached = try db.columns(in: "t", in: "attached")
            XCTAssertEqual(columnsAttached.count, 1)
            XCTAssertEqual(columnsAttached[0].name, "id2")
            XCTAssertEqual(columnsAttached[0].type, "TEXT")
        }
    }
    
    // The `t` table in the attached database should never
    // be found unless explicitly specified as it is after
    // `main.t` in resolution order.
    func testUnspecifiedSchemaWithTableNameCollisions() throws {
        #if GRDBCIPHER_USE_ENCRYPTION
        // Avoid error due to key not being provided:
        // file is not a database - while executing `ATTACH DATABASE...`
        throw XCTSkip("This test does not support encrypted databases")
        #endif
        
        let attached = try makeDatabaseQueue(filename: "attached1")
        try attached.inDatabase { db in
            try db.execute(sql: "CREATE TABLE t (id2 TEXT)")
        }
        let main = try makeDatabaseQueue(filename: "main")
        try main.inDatabase { db in
            try db.execute(sql: "CREATE TABLE t (id1 INTEGER)")
            try db.execute(literal: "ATTACH DATABASE \(attached.path) AS attached")
            
            let columnsMain = try db.columns(in: "t")
            XCTAssertEqual(columnsMain.count, 1)
            XCTAssertEqual(columnsMain[0].name, "id1")
            XCTAssertEqual(columnsMain[0].type, "INTEGER")
        }
    }
    
    func testUnspecifiedSchemaFindsAttachedDatabase() throws {
        #if GRDBCIPHER_USE_ENCRYPTION
        // Avoid error due to key not being provided:
        // file is not a database - while executing `ATTACH DATABASE...`
        throw XCTSkip("This test does not support encrypted databases")
        #endif
        
        let attached = try makeDatabaseQueue(filename: "attached1")
        try attached.inDatabase { db in
            try db.execute(sql: "CREATE TABLE t (id2 TEXT)")
        }
        let main = try makeDatabaseQueue(filename: "main")
        try main.inDatabase { db in
            try db.execute(literal: "ATTACH DATABASE \(attached.path) AS attached")
            
            let columnsMain = try db.columns(in: "t")
            XCTAssertEqual(columnsMain.count, 1)
            XCTAssertEqual(columnsMain[0].name, "id2")
            XCTAssertEqual(columnsMain[0].type, "TEXT")
        }
    }
}
