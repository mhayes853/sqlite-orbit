// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/SQLRequestTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class SQLRequestTests: GRDBTestCase {
    

    
    func testSQLRequestWithArgumentsAndAdapter() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request = SQLRequest<Int>(sql: "SELECT ?, ?", arguments: [1, 2], adapter: SuffixRowAdapter(fromIndex: 1))
            let preparedRequest = try request.makePreparedRequest(db, forSingleResult: false)
            XCTAssertEqual(preparedRequest.statement.sql, "SELECT ?, ?")
            XCTAssertNotNil(preparedRequest.adapter)
            let int = try request.fetchOne(db)!
            XCTAssertEqual(int, 2)
        }
    }
    

    

    
    func testSQLLiteralInitializer() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request = SQLRequest<String>(literal: SQL(sql: """
                SELECT ?
                """, arguments: ["O'Brien"]))
            
            let (sql, arguments) = try request.build(db)
            XCTAssertEqual(sql, """
                SELECT ?
                """)
            XCTAssertEqual(arguments, ["O'Brien"])
            
            let string = try request.fetchOne(db)!
            XCTAssertEqual(string, "O'Brien")
        }
    }
    
    func testLiteralInitializer() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request = SQLRequest<String>("""
                SELECT \("O'Brien")
                """)
            
            let (sql, arguments) = try request.build(db)
            XCTAssertEqual(sql, """
                SELECT ?
                """)
            XCTAssertEqual(arguments, ["O'Brien"])
            
            let string = try request.fetchOne(db)!
            XCTAssertEqual(string, "O'Brien")
        }
    }
    
    func testSQLLiteralInitializerWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request = SQLRequest<String>(literal: """
                SELECT \("O'Brien")
                """)
            
            let (sql, arguments) = try request.build(db)
            XCTAssertEqual(sql, """
                SELECT ?
                """)
            XCTAssertEqual(arguments, ["O'Brien"])
            
            let string = try request.fetchOne(db)!
            XCTAssertEqual(string, "O'Brien")
        }
    }
    

}
