// Generated from GRDB 7.11.1 Tests/GRDBTests/QueryInterface/TableTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class TableTests: GRDBTestCase {
    func test_Table_nameRoundTrip() {
        let table = Table("Player")
        XCTAssertEqual(table.tableName, "Player")
    }
    
    func test_Table_defaults_to_Row() {
        // This test passes if it compiles
        func f(_: Table<Row>) { }
        let table = Table("Player")
        f(table)
    }
    
    func test_Table_accepts_any_type() {
        // This test passes if it compiles
        struct S { }
        class C { }
        _ = Table<S>("ignored")
        _ = Table<C>("ignored")
    }
    

    
    func test_fetchCount() throws {
        try makeDatabaseQueue().write { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
            }
            let t = Table("player")
            try XCTAssertEqual(t.fetchCount(db), 0)
            try db.execute(sql: "INSERT INTO player VALUES (1, 'Alice')")
            try XCTAssertEqual(t.fetchCount(db), 1)
        }
    }

    func test_fetch_FetchableRecord() throws {
        struct Player: FetchableRecord, Decodable, Hashable {
            var id: Int64
            var name: String
        }
        
        try makeDatabaseQueue().write { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
            }
            try db.execute(sql: "INSERT INTO player VALUES (1, 'Alice')")
            
            let t = Table<Player>("player")
            try XCTAssertEqual(t.fetchCursor(db).next(), Player(id: 1, name: "Alice"))
            try XCTAssertEqual(t.fetchAll(db), [Player(id: 1, name: "Alice")])
            try XCTAssertEqual(t.fetchSet(db), [Player(id: 1, name: "Alice")])
            try XCTAssertEqual(t.fetchOne(db), Player(id: 1, name: "Alice"))
        }
    }
    
    func test_fetch_Row() throws {
        try makeDatabaseQueue().write { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
            }
            try db.execute(sql: "INSERT INTO player VALUES (1, 'Alice')")
            
            let t = Table("player")
            try XCTAssertEqual(t.fetchCursor(db).map { $0.copy() }.next(), ["id": 1, "name": "Alice"])
            try XCTAssertEqual(t.fetchAll(db), [["id": 1, "name": "Alice"]])
            try XCTAssertEqual(t.fetchSet(db), [["id": 1, "name": "Alice"]])
            try XCTAssertEqual(t.fetchOne(db), ["id": 1, "name": "Alice"])
        }
    }
    
    func test_fetch_DatabaseValueConvertible() throws {
        struct Value: DatabaseValueConvertible, Hashable {
            var rawValue: Int64
            var databaseValue: DatabaseValue { rawValue.databaseValue }
            static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Value? {
                Int64.fromDatabaseValue(dbValue).map(Value.init)
            }
        }
        
        try makeDatabaseQueue().write { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
            }
            try db.execute(sql: "INSERT INTO player VALUES (1, 'Alice')")
            
            let t = Table<Value>("player")
            try XCTAssertEqual(t.fetchCursor(db).next(), Value(rawValue: 1))
            try XCTAssertEqual(t.fetchAll(db), [Value(rawValue: 1)])
            try XCTAssertEqual(t.fetchSet(db), [Value(rawValue: 1)])
            
            do {
                try db.execute(sql: "DELETE FROM player")
                try XCTAssertEqual(t.fetchOne(db), nil)
            }
            
            do {
                try db.execute(sql: "DELETE FROM player")
                try db.execute(sql: "INSERT INTO player VALUES (1, 'Alice')")
                try XCTAssertEqual(t.fetchOne(db), Value(rawValue: 1))
            }
        }
    }
    
    func test_fetch_optional_DatabaseValueConvertible() throws {
        struct Value: DatabaseValueConvertible, Hashable {
            var rawValue: String
            var databaseValue: DatabaseValue { rawValue.databaseValue }
            static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Value? {
                String.fromDatabaseValue(dbValue).map(Value.init)
            }
        }
        
        try makeDatabaseQueue().write { db in
            try db.create(table: "player") { t in
                t.column("name", .text)
            }
            try db.execute(sql: "INSERT INTO player VALUES ('Alice')")
            try db.execute(sql: "INSERT INTO player VALUES (NULL)")
            
            let t = Table<Value?>("player")
            try XCTAssertEqual(t.fetchCursor(db).next(), Value(rawValue: "Alice"))
            try XCTAssertEqual(t.fetchAll(db), [Value(rawValue: "Alice"), nil])
            try XCTAssertEqual(t.fetchSet(db), [Value(rawValue: "Alice"), nil])
            
            do {
                try db.execute(sql: "DELETE FROM player")
                try XCTAssertEqual(t.fetchOne(db), nil)
                try XCTAssertEqual(t.fetchOne(db), .none)
            }
            
            do {
                try db.execute(sql: "DELETE FROM player")
                try db.execute(sql: "INSERT INTO player VALUES ('Alice')")
                try XCTAssertEqual(t.fetchOne(db), Value(rawValue: "Alice"))
            }
            
            do {
                try db.execute(sql: "DELETE FROM player")
                try db.execute(sql: "INSERT INTO player VALUES (NULL)")
                try XCTAssertNotEqual(t.fetchOne(db), nil)
                try XCTAssertEqual(t.fetchOne(db), .some(nil))
            }
        }
    }
    
    func test_fetch_StatementColumnConvertible() throws {
        try makeDatabaseQueue().write { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
            }
            try db.execute(sql: "INSERT INTO player VALUES (1, 'Alice')")
            
            let t = Table<Int64>("player")
            try XCTAssertEqual(t.fetchCursor(db).next(), 1)
            try XCTAssertEqual(t.fetchAll(db), [1])
            try XCTAssertEqual(t.fetchSet(db), [1])
            
            do {
                try db.execute(sql: "DELETE FROM player")
                try XCTAssertEqual(t.fetchOne(db), nil)
            }
            
            do {
                try db.execute(sql: "DELETE FROM player")
                try db.execute(sql: "INSERT INTO player VALUES (1, 'Alice')")
                try XCTAssertEqual(t.fetchOne(db), 1)
            }
        }
    }
    
    func test_fetch_optional_StatementColumnConvertible() throws {
        try makeDatabaseQueue().write { db in
            try db.create(table: "player") { t in
                t.column("name", .text)
            }
            try db.execute(sql: "INSERT INTO player VALUES ('Alice')")
            try db.execute(sql: "INSERT INTO player VALUES (NULL)")
            
            let t = Table<String?>("player")
            try XCTAssertEqual(t.fetchCursor(db).next(), "Alice")
            try XCTAssertEqual(t.fetchAll(db), ["Alice", nil])
            try XCTAssertEqual(t.fetchSet(db), ["Alice", nil])
            
            do {
                try db.execute(sql: "DELETE FROM player")
                try XCTAssertEqual(t.fetchOne(db), nil)
                try XCTAssertEqual(t.fetchOne(db), .none)
            }
            
            do {
                try db.execute(sql: "DELETE FROM player")
                try db.execute(sql: "INSERT INTO player VALUES ('Alice')")
                try XCTAssertEqual(t.fetchOne(db), "Alice")
            }
            
            do {
                try db.execute(sql: "DELETE FROM player")
                try db.execute(sql: "INSERT INTO player VALUES (NULL)")
                try XCTAssertNotEqual(t.fetchOne(db), nil)
                try XCTAssertEqual(t.fetchOne(db), .some(.none))
            }
        }
    }
    

    

    

    

    

    

    

    

    

    

    

    

    



}
