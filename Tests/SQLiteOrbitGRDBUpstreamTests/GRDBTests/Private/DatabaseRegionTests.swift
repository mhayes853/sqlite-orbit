// Generated from GRDB 7.11.1 Tests/GRDBTests/Private/DatabaseRegionTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabaseRegionTests : GRDBTestCase {
    

    

    

    

    

    
    func testSelectStatement_rowid() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT)")
            
            do {
                // Select the rowid
                let statement = try db.makeStatement(sql: "SELECT id FROM foo")
                let expectedRegion = DatabaseRegion(table: "foo")
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "foo(*)")
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT ID FROM FOO")
                let expectedRegion = DatabaseRegion(table: "foo")
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "foo(*)")
            }
        }
    }
    
    func testSelectStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT)")
            try db.execute(sql: "CREATE TABLE bar (id INTEGER PRIMARY KEY, fooId INTEGER)")
            
            do {
                let statement = try db.makeStatement(sql: "SELECT name FROM foo")
                let expectedRegion = DatabaseRegion(table: "foo", columns: ["name"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "foo(name)")
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT NAME FROM FOO")
                let expectedRegion = DatabaseRegion(table: "foo", columns: ["name"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "foo(name)")
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT foo.name FROM foo JOIN bar ON fooId = foo.id")
                let expectedRegion = DatabaseRegion(table: "foo", columns: ["name", "id"])
                    .union(DatabaseRegion(table: "bar", columns: ["fooId"]))
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "bar(fooId),foo(id,name)")
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT FOO.NAME FROM FOO JOIN BAR ON FOOID = FOO.ID")
                let expectedRegion = DatabaseRegion(table: "foo", columns: ["name", "id"])
                    .union(DatabaseRegion(table: "bar", columns: ["fooId"]))
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "bar(fooId),foo(id,name)")
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT COUNT(*) FROM foo")
                let expectedRegion = DatabaseRegion(table: "foo")
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "foo(*)")
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT COUNT(*) FROM FOO")
                let expectedRegion = DatabaseRegion(table: "foo")
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "FOO(*)")
            }
        }
    }
    
    func testRegionRowIds() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE foo (id INTEGER PRIMARY KEY, a TEXT)")
            struct Record: TableRecord {
                static let databaseTableName = "foo"
            }
            
            // Undefined rowIds
            
            do {
                let request = Record.all()
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)")
            }
            do {
                let request = Record.filter(Column("a") == 1)
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)")
            }
            do {
                let request = Record.filter(Column("id") >= 1)
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)")
            }
            do {
                let request = Record.filter((Column("id") == 1) || (Column("a") == "foo"))
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)")
            }

            // No rowId
            
            do {
                let request = Record.none()
                try XCTAssertEqual(request.databaseRegion(db).description, "empty")
            }
            do {
                let request = Record.filter([Int]().contains(Column("id")))
                try XCTAssertEqual(request.databaseRegion(db).description, "empty")
            }
            do {
                let request = Record.filter([String]().contains(Column("a")))
                try XCTAssertEqual(request.databaseRegion(db).description, "empty")
            }
            do {
                let request = Record.filter(Column("id") == nil)
                try XCTAssertEqual(request.databaseRegion(db).description, "empty")
            }
            do {
                let request = Record.filter(Column("id") === nil)
                try XCTAssertEqual(request.databaseRegion(db).description, "empty")
            }
            do {
                let request = Record.filter(nil == Column("id"))
                try XCTAssertEqual(request.databaseRegion(db).description, "empty")
            }
            do {
                let request = Record.filter(nil === Column("id"))
                try XCTAssertEqual(request.databaseRegion(db).description, "empty")
            }
            do {
                let request = Record.filter((Column("id") == 1) && (Column("id") == 2))
                try XCTAssertEqual(request.databaseRegion(db).description, "empty")
            }
            do {
                let request = Record.filter(key: 1).filter(key: 2)
                try XCTAssertEqual(request.databaseRegion(db).description, "empty")
            }

            // Single rowId
            
            do {
                let request = Record.filter(Column("id") == 1)
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1]")
            }
            do {
                let request = Record.filter(Column("id") === 1)
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1]")
            }
            do {
                let request = Record.filter(Column("id") == 1 && Column("a") == "foo")
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1]")
            }
            do {
                let request = Record.filter(Column.rowID == 1)
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1]")
            }
            do {
                let request = Record.filter(1 == Column("id"))
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1]")
            }
            do {
                let request = Record.filter(1 === Column("id"))
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1]")
            }
            do {
                let request = Record.filter(1 === Column.rowID)
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1]")
            }
            do {
                let request = Record.filter(key: 1)
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1]")
            }
            do {
                let request = Record.filter(key: 1).filter(key: 1)
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1]")
            }
            do {
                let request = Record.filter(key: 1).filter(Column("a") == "foo")
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1]")
            }

            // Multiple rowIds
            
            do {
                let request = Record.filter(Column("id") == 1 || Column.rowID == 2)
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1,2]")
            }
            do {
                let request = Record.filter((Column("id") == 1 && Column("a") == "foo") || Column.rowID == 2)
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1,2]")
            }
            do {
                let request = Record.filter([1, 2, 3].contains(Column("id")))
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1,2,3]")
            }
            do {
                let request = Record.filter([1, 2, 3].contains(Column.rowID))
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1,2,3]")
            }
            do {
                let request = Record.filter([1, 2, 3].contains(Column("id")) || [2, 3, 4].contains(Column.rowID))
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1,2,3,4]")
            }
            do {
                let request = Record.filter([1, 2, 3].contains(Column("id")) && [2, 3, 4].contains(Column.rowID))
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[2,3]")
            }
            do {
                let request = Record.filter(keys: [1, 2, 3])
                try XCTAssertEqual(request.databaseRegion(db).description, "foo(a,id)[1,2,3]")
            }
        }
    }
    
    func testDatabaseRegionOfJoinedRequests() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT)")
            try db.execute(sql: "CREATE TABLE b (id INTEGER PRIMARY KEY, name TEXT, aid INTEGER REFERENCES a(id))")
            try db.execute(sql: "CREATE TABLE c (id INTEGER PRIMARY KEY, name TEXT, aid INTEGER REFERENCES a(id))")
            struct A: TableRecord {
                static let databaseTableName = "a"
                static let b = hasOne(B.self)
                static let c = hasMany(C.self)
            }
            struct B: TableRecord {
                static let databaseTableName = "b"
                static let a = belongsTo(A.self)
            }
            struct C: TableRecord {
                static let databaseTableName = "c"
            }
            do {
                let request = A.filter(key: 1)
                    .including(optional: A.b.filter(key: 2))
                    .including(optional: A.c.filter(keys: [1, 2, 3]))
                // This test will fail when we are able to improve regions of joined requestt
                try XCTAssertEqual(request.databaseRegion(db).description, "a(id,name)[1],b(aid,id,name),c(aid,id,name)")
            }
            do {
                let request = B.filter(key: 1)
                    .including(optional: B.a.filter(key: 2)
                        .including(optional: A.c.filter(keys: [1, 2, 3])))
                // This test will fail when we are able to improve regions of joined requestt
                try XCTAssertEqual(request.databaseRegion(db).description, "a(id,name),b(aid,id,name)[1],c(aid,id,name)")
            }
        }
    }
    

    

    
    func testRowIdNameInSelectStatement() throws {
        // Here we test that sqlite authorizer gives the "ROWID" name to
        // the rowid column, regardless of its name in the request (rowid, oid, _rowid_)
        //
        // See also testRowIdNameInUpdateStatement
        
        guard Database.sqliteLibVersionNumber < 3019003 else {
            // This test fails on SQLite 3.19.3 (iOS 11.2) and SQLite 3.21.0 (custom build),
            // but succeeds on SQLite 3.16.0 (iOS 10.3.1).
            // TODO: evaluate the consequences
            return
        }
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE foo (name TEXT)")
            do {
                let statement = try db.makeStatement(sql: "SELECT rowid FROM FOO")
                let expectedRegion = DatabaseRegion(table: "foo", columns: ["ROWID"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "foo(ROWID)")
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT _ROWID_ FROM FOO")
                let expectedRegion = DatabaseRegion(table: "foo", columns: ["ROWID"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "foo(ROWID)")
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT oID FROM FOO")
                let expectedRegion = DatabaseRegion(table: "foo", columns: ["ROWID"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
                XCTAssertEqual(statement.databaseRegion.description, "foo(ROWID)")
            }
        }
    }








    

    
    // Regression test for https://github.com/groue/GRDB.swift/issues/514
    func testIssue514() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT);
                CREATE TABLE b (id TEXT, name TEXT);
                """)
            
            // INTEGER PRIMARY KEY
            do {
                // TODO: contact SQLite and ask if this test is expected to fail
//                let statement = try db.makeStatement(sql: "SELECT id FROM a")
//                let expectedRegion = DatabaseRegion(table: "a", columns: ["id"])
//                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT name FROM a")
                let expectedRegion = DatabaseRegion(table: "a", columns: ["name"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT id, name FROM a")
                let expectedRegion = DatabaseRegion(table: "a", columns: ["id", "name"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
            
            // TEXT primary key
            do {
                let statement = try db.makeStatement(sql: "SELECT id FROM b")
                let expectedRegion = DatabaseRegion(table: "b", columns: ["id"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT name FROM b")
                let expectedRegion = DatabaseRegion(table: "b", columns: ["name"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT id, name FROM b")
                let expectedRegion = DatabaseRegion(table: "b", columns: ["id", "name"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
        }
    }
}
