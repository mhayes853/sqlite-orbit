// Generated from GRDB 7.11.1 Tests/GRDBTests/Support/Foundation/FoundationNSDateTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class FoundationNSDateTests : GRDBTestCase {
    
    override func setup(_ dbWriter: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createDates") { db in
            try db.execute(sql: """
                CREATE TABLE dates (
                    ID INTEGER PRIMARY KEY,
                    creationDate DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP)
                """)
        }
        try migrator.migrate(dbWriter)
    }



    func testNSDateIsLexicallyComparableToCURRENT_TIMESTAMP() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(
                sql: "INSERT INTO dates (id, creationDate) VALUES (?,?)",
                arguments: [1, NSDate().addingTimeInterval(-1)])
            
            try db.execute(
                sql: "INSERT INTO dates (id) VALUES (?)",
                arguments: [2])
            
            try db.execute(
                sql: "INSERT INTO dates (id, creationDate) VALUES (?,?)",
                arguments: [3, NSDate().addingTimeInterval(1)])
            
            let ids = try Int.fetchAll(db, sql: "SELECT id FROM dates ORDER BY creationDate")
            XCTAssertEqual(ids, [1,2,3])
        }
    }


    

    

    

    









    





}
