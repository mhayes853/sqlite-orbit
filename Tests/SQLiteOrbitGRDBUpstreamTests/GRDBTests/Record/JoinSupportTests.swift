// Generated from GRDB 7.11.1 Tests/GRDBTests/Record/JoinSupportTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

let expectedSQL = """
    SELECT
        "t1".*,
        "t2Left".*,
        "t2Right".*,
        "t3"."t1id", "t3"."name",
        COUNT(DISTINCT t5.id) AS t5count
    FROM t1
    LEFT JOIN t2 t2Left ON t2Left.t1id = t1.id AND t2Left.name = 'left'
    LEFT JOIN t2 t2Right ON t2Right.t1id = t1.id AND t2Right.name = 'right'
    LEFT JOIN t3 ON t3.t1id = t1.id
    LEFT JOIN t4 ON t4.t1id = t1.id
    LEFT JOIN t5 ON t5.t3id = t3.t1id OR t5.t4id = t4.t1id
    GROUP BY t1.id
    ORDER BY t1.id
    """

let testedLiteral: SQL = """
    SELECT
        \(columnsOf: T1.self),
        \(columnsOf: T2.self, tableAlias: "t2Left"),
        \(columnsOf: T2.self, tableAlias: "t2Right"),
        \(columnsOf: T3.self),
        COUNT(DISTINCT t5.id) AS t5count
    FROM t1
    LEFT JOIN t2 t2Left ON t2Left.t1id = t1.id AND t2Left.name = 'left'
    LEFT JOIN t2 t2Right ON t2Right.t1id = t1.id AND t2Right.name = 'right'
    LEFT JOIN t3 ON t3.t1id = t1.id
    LEFT JOIN t4 ON t4.t1id = t1.id
    LEFT JOIN t5 ON t5.t3id = t3.t1id OR t5.t4id = t4.t1id
    GROUP BY t1.id
    ORDER BY t1.id
    """

private struct T1: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "t1"
    var id: Int64
    var name: String
}

private struct T2: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "t2"
    var id: Int64
    var t1id: Int64
    var name: String
}

private struct T3: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "t3"
    static var databaseSelection: [any SQLSelectable] { [Column("t1id"), Column("name")] }
    var t1id: Int64
    var name: String
}

private struct T4: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "t4"
    var t1id: Int64
    var name: String
}

private struct T5: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "t5"
    var id: Int64
    var t3id: Int64?
    var t4id: Int64?
    var name: String
}







class JoinSupportTests: GRDBTestCase {
    
    override func setup(_ dbWriter: some DatabaseWriter) throws {
        try dbWriter.write { db in
            try db.create(table: "t1") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text).notNull()
            }
            try db.create(table: "t2") { t in
                t.primaryKey("id", .integer)
                t.column("t1id", .integer).notNull().references("t1", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.uniqueKey(["t1id", "name"])
            }
            try db.create(table: "t3") { t in
                t.primaryKey("t1id", .integer).references("t1", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("ignored", .integer)
            }
            try db.create(table: "t4") { t in
                t.primaryKey("t1id", .integer).references("t1", onDelete: .cascade)
                t.column("name", .text).notNull()
            }
            try db.create(table: "t5") { t in
                t.primaryKey("id", .integer)
                t.column("t3id", .integer).references("t3", onDelete: .cascade)
                t.column("t4id", .integer).references("t4", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.check(sql: "(t3id IS NOT NULL) + (t4id IS NOT NULL) = 1")
            }
            
            // Sample data
            
            try db.execute(sql: """
                INSERT INTO t1 (id, name) VALUES (1, 'A1');
                INSERT INTO t1 (id, name) VALUES (2, 'A2');
                INSERT INTO t1 (id, name) VALUES (3, 'A3');
                INSERT INTO t2 (id, t1id, name) VALUES (1, 1, 'left');
                INSERT INTO t2 (id, t1id, name) VALUES (2, 1, 'right');
                INSERT INTO t2 (id, t1id, name) VALUES (3, 2, 'left');
                INSERT INTO t3 (t1id, name) VALUES (1, 'A3');
                INSERT INTO t4 (t1id, name) VALUES (1, 'A4');
                INSERT INTO t4 (t1id, name) VALUES (2, 'B4');
                INSERT INTO t5 (id, t3id, t4id, name) VALUES (1, 1, NULL, 'A5');
                INSERT INTO t5 (id, t3id, t4id, name) VALUES (2, 1, NULL, 'B5');
                INSERT INTO t5 (id, t3id, t4id, name) VALUES (3, NULL, 1, 'C5');
                INSERT INTO t5 (id, t3id, t4id, name) VALUES (4, NULL, 1, 'D5');
                INSERT INTO t5 (id, t3id, t4id, name) VALUES (5, NULL, 1, 'E5');
                INSERT INTO t5 (id, t3id, t4id, name) VALUES (6, NULL, 2, 'F5');
                INSERT INTO t5 (id, t3id, t4id, name) VALUES (7, NULL, 2, 'G5');
                """)
        }
    }
    

    
    func testNumberOfSelectedColumnsIncludeGeneratedColumns() throws {
        #if !GRDBCUSTOMSQLITE
        throw XCTSkip("Generated columns are not available")
        #else
        struct T: TableRecord { }
        let dbQueue = try makeDatabaseQueue()
        
        try dbQueue.inTransaction { db in
            try db.execute(sql: "CREATE TABLE t (a, b ALWAYS GENERATED AS (a) VIRTUAL)")
            try XCTAssertEqual(T.numberOfSelectedColumns(db), 2)
            return .rollback
        }
        
        try dbQueue.inTransaction { db in
            try db.execute(sql: "CREATE TABLE t (a, b ALWAYS GENERATED AS (a) STORED)")
            try XCTAssertEqual(T.numberOfSelectedColumns(db), 2)
            return .rollback
        }
        #endif
    }
    
    func testSampleData() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let rows = try SQLRequest<Row>(literal: testedLiteral).fetchAll(db)
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(rows[0], [
                // t1.*
                "id": 1, "name": "A1",
                // t2Left.*
                "id": 1, "t1id": 1, "name": "left",
                // t2Right.*
                "id": 2, "t1id": 1, "name": "right",
                // t3.*
                "t1id": 1, "name": "A3",
                // t5count
                "t5count": 5])
            XCTAssertEqual(rows[1], [
                // t1.*
                "id": 2, "name": "A2",
                // t2Left.*
                "id": 3, "t1id": 2, "name": "left",
                // t2Right.*
                "id": nil, "t1id": nil, "name": nil,
                // t3.*
                "t1id": nil, "name": nil,
                // t5count
                "t5count": 2])
            XCTAssertEqual(rows[2], [
                // t1.*
                "id": 3, "name": "A3",
                // t2Left.*
                "id": nil, "t1id": nil, "name": nil,
                // t2Right.*
                "id": nil, "t1id": nil, "name": nil,
                // t3.*
                "t1id": nil, "name": nil,
                // t5count
                "t5count": 0])
        }
    }
    
    func testTestedSQL() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let (testedSQL, _) = try testedLiteral.build(db)
            XCTAssertEqual(testedSQL, expectedSQL)
        }
    }
    

    

    

    

    

    

}
