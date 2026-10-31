// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/SQLLiteralTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class SQLLiteralTests: GRDBTestCase {
    func testSQLInitializer() throws {
        try makeDatabaseQueue().inDatabase { db in
            let query = SQL(sql: """
                SELECT * FROM player
                WHERE id = \("?")
                """, arguments: [1])
            
            let (sql, arguments) = try query.build(db)
            XCTAssertEqual(sql, """
                SELECT * FROM player
                WHERE id = ?
                """)
            XCTAssertEqual(arguments, [1])
        }
    }
    
    func testPlusOperator() throws {
        try makeDatabaseQueue().inDatabase { db in
            var query = SQL(sql: "SELECT * ")
            query = query + SQL(sql: "FROM player ")
            query = query + SQL(sql: "WHERE id = ? ", arguments: [1])
            query = query + SQL(sql: "AND name = ?", arguments: ["Arthur"])
            
            let (sql, arguments) = try query.build(db)
            XCTAssertEqual(sql, """
                SELECT * FROM player WHERE id = ? AND name = ?
                """)
            XCTAssertEqual(arguments, [1, "Arthur"])
        }
    }
    
    func testPlusEqualOperator() throws {
        try makeDatabaseQueue().inDatabase { db in
            var query = SQL(sql: "SELECT * ")
            query += SQL(sql: "FROM player ")
            query += SQL(sql: "WHERE id = ? ", arguments: [1])
            query += SQL(sql: "AND name = ?", arguments: ["Arthur"])
            
            let (sql, arguments) = try query.build(db)
            XCTAssertEqual(sql, """
                SELECT * FROM player WHERE id = ? AND name = ?
                """)
            XCTAssertEqual(arguments, [1, "Arthur"])
        }
    }
    
    func testAppendLiteral() throws {
        try makeDatabaseQueue().inDatabase { db in
            var query = SQL(sql: "SELECT * ")
            query.append(literal: SQL(sql: "FROM player "))
            query.append(literal: SQL(sql: "WHERE id = ? ", arguments: [1]))
            query.append(literal: SQL(sql: "AND name = ?", arguments: ["Arthur"]))
            
            let (sql, arguments) = try query.build(db)
            XCTAssertEqual(sql, """
                SELECT * FROM player WHERE id = ? AND name = ?
                """)
            XCTAssertEqual(arguments, [1, "Arthur"])
        }
    }
    
    func testAppendRawSQL() throws {
        try makeDatabaseQueue().inDatabase { db in
            var query = SQL(sql: "SELECT * ")
            query.append(sql: "FROM player ")
            query.append(sql: "WHERE score > \(1000) ")
            query.append(sql: "AND \("name") = :name", arguments: ["name": "Arthur"])
            
            let (sql, arguments) = try query.build(db)
            XCTAssertEqual(sql, """
                SELECT * FROM player WHERE score > 1000 AND name = :name
                """)
            XCTAssertEqual(arguments, ["name": "Arthur"])
        }
    }
    
    func testSequenceJoined() throws {
        try makeDatabaseQueue().inDatabase { db in
            // A sequence that can't be consumed twice
            var i = 0
            let sequence = AnySequence<SQL> {
                return AnyIterator {
                    guard i < 3 else { return nil }
                    i += 1
                    return SQL(sql: "(\(i) = ?)", arguments: [i])
                }
            }
            do {
                i = 0
                let joined = sequence.joined()
                let (sql, arguments) = try joined.build(db)
                XCTAssertEqual(sql, "(1 = ?)(2 = ?)(3 = ?)")
                XCTAssertEqual(arguments, [1, 2, 3])
            }
            do {
                i = 0
                let joined = sequence.joined(separator: " AND ")
                let (sql, arguments) = try joined.build(db)
                XCTAssertEqual(sql, "(1 = ?) AND (2 = ?) AND (3 = ?)")
                XCTAssertEqual(arguments, [1, 2, 3])
            }
        }
    }
    
    func testCollectionJoined() throws {
        try makeDatabaseQueue().inDatabase { db in
            let collection = AnyCollection([
                SQL(sql: "SELECT * "),
                SQL(sql: "FROM player "),
                SQL(sql: "WHERE score > ? ", arguments: [1000]),
                SQL(sql: "AND name = :name", arguments: ["name": "Arthur"]),
            ])
            do {
                let joined = collection.joined()
                let (sql, arguments) = try joined.build(db)
                XCTAssertEqual(sql, """
                    SELECT * FROM player WHERE score > ? AND name = :name
                    """)
                XCTAssertEqual(arguments, [1000] + ["name": "Arthur"])
            }
            do {
                let joined = collection.joined(separator: " ")
                let (sql, arguments) = try joined.build(db)
                XCTAssertEqual(sql, """
                    SELECT *  FROM player  WHERE score > ?  AND name = :name
                    """)
                XCTAssertEqual(arguments, [1000] + ["name": "Arthur"])
            }
        }
    }
    

}

extension SQLLiteralTests {
    func testLiteralInitializer() throws {
        try makeDatabaseQueue().inDatabase { db in
            let query = SQL("""
                SELECT * FROM player
                WHERE id = \(1)
                """)
            
            let (sql, arguments) = try query.build(db)
            XCTAssertEqual(sql, """
                SELECT * FROM player
                WHERE id = ?
                """)
            XCTAssertEqual(arguments, [1])
        }
    }
    
    func testRawSQLInterpolation() throws {
        try makeDatabaseQueue().inDatabase { db in
            let query: SQL = """
                SELECT *
                \(sql: "FROM player")
                \(sql: "WHERE score > \(1000)")
                \(sql: "AND \("name") = :name", arguments: ["name": "Arthur"])
                """
            
            let (sql, arguments) = try query.build(db)
            XCTAssertEqual(sql, """
                SELECT *
                FROM player
                WHERE score > 1000
                AND name = :name
                """)
            XCTAssertEqual(arguments, ["name": "Arthur"])
        }
    }
    

    

    

    

    
    func testDatabaseValueConvertibleInterpolation() throws {
        try makeDatabaseQueue().inDatabase { db in
            func test<V: DatabaseValueConvertible>(value: V, isInterpolatedAs dbValue: DatabaseValue) throws {
                let query: SQL = "SELECT \(value)"
                let (sql, arguments) = try query.build(db)
                XCTAssertEqual(sql, "SELECT ?")
                XCTAssertEqual(arguments, [dbValue])
            }
            
            struct V: DatabaseValueConvertible {
                var databaseValue: DatabaseValue {
                    "V".databaseValue
                }
                
                static func fromDatabaseValue(_ dbValue: DatabaseValue) -> V? {
                    nil
                }
            }
            
            try test(value: 42, isInterpolatedAs: 42.databaseValue)
            try test(value: 1.23, isInterpolatedAs: 1.23.databaseValue)
            try test(value: "foo", isInterpolatedAs: "foo".databaseValue)
            try test(value: "foo".data(using: .utf8)!, isInterpolatedAs: "foo".data(using: .utf8)!.databaseValue)
            try test(value: V(), isInterpolatedAs: "V".databaseValue)
        }
    }
    
    func testDataInterpolation() throws {
        try makeDatabaseQueue().inDatabase { db in
            // This test makes sure the Sequence conformance of Data does not
            // kick in.
            let data = "SQLite".data(using: .utf8)!
            let query: SQL = "SELECT \(data)"
            
            let (sql, arguments) = try query.build(db)
            XCTAssertEqual(sql, "SELECT ?")
            XCTAssertEqual(arguments, [data])
        }
    }
    

    

    

    

    

    
    func testSQLLiteralInterpolation() throws {
        try makeDatabaseQueue().inDatabase { db in
            let condition: SQL = "name = \("Arthur")"
            let query: SQL = """
                SELECT *, \(true) FROM player
                WHERE \(literal: condition) AND score > \(1000)
                """
            
            let (sql, arguments) = try query.build(db)
            XCTAssertEqual(sql, """
                SELECT *, ? FROM player
                WHERE name = ? AND score > ?
                """)
            XCTAssertEqual(arguments, [true, "Arthur", 1000])
        }
    }
    

    

    

    

    

    

    

    

    

    

    

    

}

// Support for testProtocolResolution()
@discardableResult
private func acceptOrderingTerm_generic(_ x: some SQLOrderingTerm) -> String {
    String(describing: type(of: x))
}

@discardableResult
private func acceptSelectable_generic(_ x: some SQLSelectable) -> String {
    String(describing: type(of: x))
}

@discardableResult
private func acceptSpecificExpressible_generic(_ x: some SQLSpecificExpressible) -> String {
    String(describing: type(of: x))
}

@discardableResult
private func acceptExpressible_generic(_ x: some SQLExpressible) -> String {
    String(describing: type(of: x))
}

private func overloaded_generic(_ x: some SQLOrderingTerm) -> String {
    "SQLOrderingTerm"
}

private func overloaded_generic(_ x: some SQLSelectable) -> String {
    "SQLSelectable"
}

private func overloaded_generic(_ x: some SQLSpecificExpressible & SQLSelectable & SQLOrderingTerm) -> String {
    "SQLSpecificExpressible"
}

@discardableResult
private func acceptOrderingTerm_existential(_ x: any SQLOrderingTerm) -> String {
    String(describing: type(of: x))
}

@discardableResult
private func acceptSelectable_existential(_ x: any SQLSelectable) -> String {
    String(describing: type(of: x))
}

@discardableResult
private func acceptSpecificExpressible_existential(_ x: any SQLSpecificExpressible) -> String {
    String(describing: type(of: x))
}

@discardableResult
private func acceptExpressible_existential(_ x: any SQLExpressible) -> String {
    String(describing: type(of: x))
}

private func overloaded_existential(_ x: any SQLOrderingTerm) -> String {
    "SQLOrderingTerm"
}

private func overloaded_existential(_ x: any SQLSelectable) -> String {
    "SQLSelectable"
}

private func overloaded_existential(_ x: any SQLSpecificExpressible & SQLSelectable & SQLOrderingTerm) -> String {
    "SQLSpecificExpressible"
}
