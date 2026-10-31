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
    
    func testSQLInterpolation() throws {
        // This test assumes SQLRequest interpolation is based on
        // SQLInterpolation, just like `SQL` literal. We thus test much less
        // cases.
        struct Player: Codable, TableRecord, FetchableRecord, PersistableRecord {
            var id: Int64
            var name: String
            
            static func filter(id: Int64) -> SQLRequest<Player> {
                """
                SELECT *
                FROM \(self)
                WHERE \(CodingKeys.id) = \(id)
                """
            }

            static func filter(ids: [Int64]) -> SQLRequest<Player> {
                """
                SELECT *
                FROM \(self)
                WHERE \(CodingKeys.id) IN \(ids)
                """
            }

            static func filter<IDS>(excludedIds: IDS) -> SQLRequest<Player>
            where IDS: Sequence, IDS.Element == Int64
            {
                """
                SELECT *
                FROM \(self)
                WHERE \(CodingKeys.id) NOT IN \(excludedIds)
                """
            }
            
            // The test pass if this method compiles.
            static func complexRequest() -> SQLRequest<Player> {
                let query: SQL = "SELECT * FROM \(self)"
                return SQLRequest(literal: query)
            }
        }
        
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
            }
            
            try Player(id: 1, name: "Arthur").insert(db)
            try Player(id: 42, name: "Barbara").insert(db)
            
            do {
                let request = Player.filter(id: 42)
                
                let (sql, arguments) = try request.build(db)
                XCTAssertEqual(sql, """
                    SELECT *
                    FROM "player"
                    WHERE "id" = ?
                    """)
                XCTAssertEqual(arguments, [42])
                
                let player = try request.fetchOne(db)!
                XCTAssertEqual(player.name, "Barbara")
            }
            
            do {
                let request = Player.filter(ids: [1, 2, 3])
                
                let (sql, arguments) = try request.build(db)
                XCTAssertEqual(sql, """
                    SELECT *
                    FROM "player"
                    WHERE "id" IN (?,?,?)
                    """)
                XCTAssertEqual(arguments, [1, 2, 3])
                
                let players = try request.fetchAll(db)
                XCTAssertEqual(players.count, 1)
                XCTAssertEqual(players[0].name, "Arthur")
            }
            
            do {
                let request = Player.filter(ids: [])
                
                let (sql, arguments) = try request.build(db)
                XCTAssertEqual(sql, """
                    SELECT *
                    FROM "player"
                    WHERE "id" IN (SELECT NULL WHERE NULL)
                    """)
                XCTAssert(arguments.isEmpty)
                
                let players = try request.fetchAll(db)
                XCTAssert(players.isEmpty)
            }
            
            do {
                let request = Player.filter(excludedIds: [42, 666])
                
                let (sql, arguments) = try request.build(db)
                XCTAssertEqual(sql, """
                    SELECT *
                    FROM "player"
                    WHERE "id" NOT IN (?,?)
                    """)
                XCTAssertEqual(arguments, [42, 666])
                
                let players = try request.fetchAll(db)
                XCTAssertEqual(players.count, 1)
                XCTAssertEqual(players[0].name, "Arthur")
            }
            
            do {
                let request = Player.filter(excludedIds: [])
                
                let (sql, arguments) = try request.build(db)
                XCTAssertEqual(sql, """
                    SELECT *
                    FROM "player"
                    WHERE "id" NOT IN (SELECT NULL WHERE NULL)
                    """)
                XCTAssert(arguments.isEmpty)
                
                let players = try request.fetchAll(db)
                XCTAssertEqual(players.count, 2)
            }
        }
    }
}
