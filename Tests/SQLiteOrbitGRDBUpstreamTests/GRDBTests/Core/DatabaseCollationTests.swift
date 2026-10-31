// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseCollationTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabaseCollationTests: GRDBTestCase {
    


    func testCollation() throws {
        let dbQueue = try makeDatabaseQueue()
        let collation = DatabaseCollation("localized_standard") { (string1, string2) in
            let length1 = string1.utf8.count
            let length2 = string2.utf8.count
            if length1 == length2 {
                return (string1 as NSString).compare(string2)
            } else if length1 < length2 {
                return .orderedAscending
            } else {
                return .orderedDescending
            }
        }
        
        try dbQueue.inDatabase { db in
            db.add(collation: collation)
            try db.execute(sql: "CREATE TABLE strings (id INTEGER PRIMARY KEY, name TEXT COLLATE LOCALIZED_STANDARD)")
            try db.execute(sql: "INSERT INTO strings VALUES (1, 'a')")
            try db.execute(sql: "INSERT INTO strings VALUES (2, 'aa')")
            try db.execute(sql: "INSERT INTO strings VALUES (3, 'aaa')")
            try db.execute(sql: "INSERT INTO strings VALUES (4, 'b')")
            try db.execute(sql: "INSERT INTO strings VALUES (5, 'bb')")
            try db.execute(sql: "INSERT INTO strings VALUES (6, 'bbb')")
            try db.execute(sql: "INSERT INTO strings VALUES (7, 'c')")
            try db.execute(sql: "INSERT INTO strings VALUES (8, 'cc')")
            try db.execute(sql: "INSERT INTO strings VALUES (9, 'ccc')")
            
            let ids = try Int.fetchAll(db, sql: "SELECT id FROM strings ORDER BY NAME")
            XCTAssertEqual(ids, [1,4,7,2,5,8,3,6,9])
        }
    }
}
