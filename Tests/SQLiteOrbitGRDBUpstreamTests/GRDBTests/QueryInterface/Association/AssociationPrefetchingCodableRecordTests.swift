// Generated from GRDB 7.11.1 Tests/GRDBTests/QueryInterface/Association/AssociationPrefetchingCodableRecordTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

private struct A: TableRecord, FetchableRecord, Decodable, Equatable {
    var cola1: Int64
    var cola2: String
}
private struct B: TableRecord, FetchableRecord, Decodable, Equatable, Hashable {
    var colb1: Int64
    var colb2: Int64?
    var colb3: String
}
private struct C: TableRecord, FetchableRecord, Decodable, Equatable {
    var colc1: Int64
    var colc2: Int64
}
private struct D: TableRecord, FetchableRecord, Decodable, Equatable {
    var cold1: Int64
    var cold2: Int64?
    var cold3: String
}

class AssociationPrefetchingCodableRecordTests: GRDBTestCase {
    override func setup(_ dbWriter: some DatabaseWriter) throws {
        try dbWriter.write { db in
            try db.create(table: "a") { t in
                t.autoIncrementedPrimaryKey("cola1")
                t.column("cola2", .text)
            }
            try db.create(table: "b") { t in
                t.autoIncrementedPrimaryKey("colb1")
                t.column("colb2", .integer).references("a")
                t.column("colb3", .text)
            }
            try db.create(table: "c") { t in
                t.autoIncrementedPrimaryKey("colc1")
                t.column("colc2", .integer).references("a")
            }
            try db.create(table: "d") { t in
                t.autoIncrementedPrimaryKey("cold1")
                t.column("cold2", .integer).references("c")
                t.column("cold3", .text)
            }
            try db.execute(
                sql: """
                    INSERT INTO a (cola1, cola2) VALUES (?, ?);
                    INSERT INTO a (cola1, cola2) VALUES (?, ?);
                    INSERT INTO a (cola1, cola2) VALUES (?, ?);
                    INSERT INTO b (colb1, colb2, colb3) VALUES (?, ?, ?);
                    INSERT INTO b (colb1, colb2, colb3) VALUES (?, ?, ?);
                    INSERT INTO b (colb1, colb2, colb3) VALUES (?, ?, ?);
                    INSERT INTO b (colb1, colb2, colb3) VALUES (?, ?, ?);
                    INSERT INTO c (colc1, colc2) VALUES (?, ?);
                    INSERT INTO c (colc1, colc2) VALUES (?, ?);
                    INSERT INTO c (colc1, colc2) VALUES (?, ?);
                    INSERT INTO d (cold1, cold2, cold3) VALUES (?, ?, ?);
                    INSERT INTO d (cold1, cold2, cold3) VALUES (?, ?, ?);
                    INSERT INTO d (cold1, cold2, cold3) VALUES (?, ?, ?);
                    INSERT INTO d (cold1, cold2, cold3) VALUES (?, ?, ?);
                    INSERT INTO d (cold1, cold2, cold3) VALUES (?, ?, ?);
                    """,
                arguments: [
                    1, "a1",
                    2, "a2",
                    3, "a3",
                    4, 1, "b1",
                    5, 1, "b2",
                    6, 2, "b3",
                    14, nil, "b4",
                    7, 1,
                    8, 2,
                    9, 2,
                    10, 7, "d1",
                    11, 8, "d2",
                    12, 8, "d3",
                    13, 9, "d4",
                    14, nil, "d5",
                ])
        }
    }
    
    func testMissingIncludingAllHasMany() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.read { db in
            let request = A.orderByPrimaryKey()
            
            do {
                struct Record: FetchableRecord, Decodable, Equatable {
                    var a: A
                    var bs: [B]? // Support for missing association
                }
                
                // Record.fetchAll
                do {
                    let records = try Record.fetchAll(db, request)
                    try XCTAssertEqual(records, [
                        Record(
                            a: A(row: ["cola1": 1, "cola2": "a1"]),
                            bs: nil),
                        Record(
                            a: A(row: ["cola1": 2, "cola2": "a2"]),
                            bs: nil),
                        Record(
                            a: A(row: ["cola1": 3, "cola2": "a3"]),
                            bs: nil),
                    ])
                }
                
                // Record.fetchOne
                do {
                    let record = try Record.fetchOne(db, request)!
                    try XCTAssertEqual(record, Record(
                        a: A(row: ["cola1": 1, "cola2": "a1"]),
                        bs: nil))
                }
            }
            
            // Test container.decodeNil
            do {
                struct Record: FetchableRecord, Decodable, Equatable {
                    var a: A
                    var bs: [B]? // Support for missing association
                    
                    init(a: A, bs: [B]?) {
                        self.a = a
                        self.bs = bs
                    }
                    
                    enum CodingKeys: CodingKey { case a, bs }
                    init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        a = try container.decode(A.self, forKey: .a)
                        if try container.decodeNil(forKey: .bs) {
                            bs = nil
                        } else {
                            bs = []
                        }
                    }
                }
                
                // Record.fetchAll
                do {
                    let records = try Record.fetchAll(db, request)
                    try XCTAssertEqual(records, [
                        Record(
                            a: A(row: ["cola1": 1, "cola2": "a1"]),
                            bs: nil),
                        Record(
                            a: A(row: ["cola1": 2, "cola2": "a2"]),
                            bs: nil),
                        Record(
                            a: A(row: ["cola1": 3, "cola2": "a3"]),
                            bs: nil),
                    ])
                }
                
                // Record.fetchOne
                do {
                    let record = try Record.fetchOne(db, request)!
                    try XCTAssertEqual(record, Record(
                        a: A(row: ["cola1": 1, "cola2": "a1"]),
                        bs: nil))
                }
            }        }
    }


    



    

    

    

    

    

    

}
