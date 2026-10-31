// Generated from GRDB 7.11.1 Tests/GRDBTests/Record/TableRecord/TableRecordUpdateTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

private struct Player: Codable, Identifiable, PersistableRecord, FetchableRecord, Hashable {
    var id: Int64
    var name: String
    var score: Int
    var bonus: Int
    
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let score = Column(CodingKeys.score)
        static let bonus = Column(CodingKeys.bonus)
    }
    
    static func createTable(_ db: Database) throws {
        try db.create(table: "player") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text)
            t.column("score", .integer)
            t.column("bonus", .integer)
        }
    }
}

private struct PlayerView: Codable, Identifiable, PersistableRecord, FetchableRecord, Hashable {
    var id: Int64
    var name: String
    var score: Int
    var bonus: Int
    
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let score = Column(CodingKeys.score)
        static let bonus = Column(CodingKeys.bonus)
    }
    
    static func createTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIEW playerView AS SELECT * FROM player;
            -- Insert trigger
            CREATE TRIGGER playerView_insert
            INSTEAD OF INSERT ON playerView
            BEGIN
              INSERT INTO player (id, name, score, bonus)
              VALUES (NEW.id, NEW.name, NEW.score, NEW.bonus);
            END;
            -- Update trigger
            CREATE TRIGGER playerView_update
            INSTEAD OF UPDATE ON playerView
            BEGIN
              UPDATE player SET name = NEW.name, score = NEW.score, bonus = NEW.bonus
              WHERE id = OLD.id;
            END;
            """)
    }
}



private typealias Columns = Player.Columns

private extension QueryInterfaceRequest<Player> {

}

class TableRecordUpdateTests: GRDBTestCase {

    

    

    

    

    

    





    

    

    

    

    

    







    
    func testNilAssignment() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score.set(to: nil))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = NULL
                """)
        }
    }
    

    
    func testComplexAssignment() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score.set(to: Columns.score * (Columns.bonus + 1)))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" * ("bonus" + 1)
                """)
        }
    }
    

    
    func testAssignmentSubtractAndAssign() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score -= 1)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" - 1
                """)
            
            try Player.updateAll(db, Columns.score -= Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" - "bonus"
                """)
            
            try Player.updateAll(db, Columns.score -= -Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" - (-"bonus")
                """)
            
            try Player.updateAll(db, Columns.score -= Columns.bonus * 2)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" - ("bonus" * 2)
                """)
        }
    }
    

    
    func testAssignmentAddAndAssign() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score += 1)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" + 1
                """)
            
            try Player.updateAll(db, Columns.score += Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" + "bonus"
                """)
            
            try Player.updateAll(db, Columns.score += -Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" + (-"bonus")
                """)
            
            try Player.updateAll(db, Columns.score += Columns.bonus * 2)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" + ("bonus" * 2)
                """)
        }
    }
    

    
    func testAssignmentMultiplyAndAssign() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score *= 1)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" * 1
                """)
            
            try Player.updateAll(db, Columns.score *= Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" * "bonus"
                """)
            
            try Player.updateAll(db, Columns.score *= -Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" * (-"bonus")
                """)
            
            try Player.updateAll(db, Columns.score *= Columns.bonus * 2)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" * ("bonus" * 2)
                """)
        }
    }
    

    
    func testAssignmentDivideAndAssign() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score /= 1)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" / 1
                """)
            
            try Player.updateAll(db, Columns.score /= Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" / "bonus"
                """)
            
            try Player.updateAll(db, Columns.score /= -Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" / (-"bonus")
                """)
            
            try Player.updateAll(db, Columns.score /= Columns.bonus * 2)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" / ("bonus" * 2)
                """)
        }
    }
    

    
    func testAssignmentBitwiseAndAssign() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score &= 1)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" & 1
                """)
            
            try Player.updateAll(db, Columns.score &= Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" & "bonus"
                """)
            
            try Player.updateAll(db, Columns.score &= -Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" & (-"bonus")
                """)
            
            try Player.updateAll(db, Columns.score &= Columns.bonus * 2)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" & ("bonus" * 2)
                """)
        }
    }
    


    func testAssignmentBitwiseOrAssign() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score |= 1)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" | 1
                """)
            
            try Player.updateAll(db, Columns.score |= Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" | "bonus"
                """)
            
            try Player.updateAll(db, Columns.score |= -Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" | (-"bonus")
                """)
            
            try Player.updateAll(db, Columns.score |= Columns.bonus * 2)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" | ("bonus" * 2)
                """)
        }
    }
    

    
    func testAssignmentLeftShiftAssign() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score <<= 1)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" << 1
                """)
            
            try Player.updateAll(db, Columns.score <<= Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" << "bonus"
                """)
            
            try Player.updateAll(db, Columns.score <<= -Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" << (-"bonus")
                """)
            
            try Player.updateAll(db, Columns.score <<= Columns.bonus * 2)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" << ("bonus" * 2)
                """)
        }
    }
    


    func testAssignmentRightShiftAssign() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score >>= 1)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" >> 1
                """)
            
            try Player.updateAll(db, Columns.score >>= Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" >> "bonus"
                """)
            
            try Player.updateAll(db, Columns.score >>= -Columns.bonus)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" >> (-"bonus")
                """)
            
            try Player.updateAll(db, Columns.score >>= Columns.bonus * 2)
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = "score" >> ("bonus" * 2)
                """)
        }
    }
    

    
    func testMultipleAssignments() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Columns.score.set(to: 0), Columns.bonus.set(to: 1))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = 0, "bonus" = 1
                """)
            
            try Player.updateAll(db, [Columns.score.set(to: 0), Columns.bonus.set(to: 1)])
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = 0, "bonus" = 1
                """)
            
            try Player.all().updateAll(db, Columns.score.set(to: 0), Columns.bonus.set(to: 1))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = 0, "bonus" = 1
                """)
            
            try Player.all().updateAll(db, [Columns.score.set(to: 0), Columns.bonus.set(to: 1)])
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = 0, "bonus" = 1
                """)
        }
    }
    


    func testUpdateAllWithoutAssignmentDoesNotAccessTheDatabase() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            clearSQLQueries()
            try XCTAssertEqual(Player.updateAll(db, []), 0)
            try XCTAssertEqual(Player.all().updateAll(db, []), 0)
            XCTAssert(sqlQueries.isEmpty)
        }
    }


    

    



    
    func testConflictPolicyAbort() throws {
        struct AbortPlayer: PersistableRecord {
            static let databaseTableName = "player"
            static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .abort, update: .abort)
            func encode(to container: inout PersistenceContainer) { }
        }
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try AbortPlayer.updateAll(db, Column("score").set(to: 0))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = 0
                """)
            
            try AbortPlayer.updateAll(db, [Column("score").set(to: 0)])
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = 0
                """)
            
            try AbortPlayer.all().updateAll(db, Column("score").set(to: 0))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = 0
                """)
            
            try AbortPlayer.all().updateAll(db, [Column("score").set(to: 0)])
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = 0
                """)
        }
    }
    

    
    func testConflictPolicyIgnore() throws {
        struct IgnorePlayer: PersistableRecord {
            static let databaseTableName = "player"
            static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .abort, update: .ignore)
            func encode(to container: inout PersistenceContainer) { }
        }
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try IgnorePlayer.updateAll(db, Column("score").set(to: 0))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE OR IGNORE "player" SET "score" = 0
                """)
            
            try IgnorePlayer.updateAll(db, [Column("score").set(to: 0)])
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE OR IGNORE "player" SET "score" = 0
                """)
            
            try IgnorePlayer.all().updateAll(db, Column("score").set(to: 0))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE OR IGNORE "player" SET "score" = 0
                """)
            
            try IgnorePlayer.all().updateAll(db, [Column("score").set(to: 0)])
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE OR IGNORE "player" SET "score" = 0
                """)
        }
    }
    

    

    


    func testConflictPolicyCustom() throws {
        try makeDatabaseQueue().write { db in
            try Player.createTable(db)
            
            try Player.updateAll(db, Column("score").set(to: 0))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE "player" SET "score" = 0
                """)
            
            try Player.updateAll(db, onConflict: .ignore, Column("score").set(to: 0))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE OR IGNORE "player" SET "score" = 0
                """)
            
            try Player.updateAll(db, onConflict: .ignore, [Column("score").set(to: 0)])
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE OR IGNORE "player" SET "score" = 0
                """)
            
            try Player.all().updateAll(db, onConflict: .ignore, Column("score").set(to: 0))
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE OR IGNORE "player" SET "score" = 0
                """)
            
            try Player.all().updateAll(db, onConflict: .ignore, [Column("score").set(to: 0)])
            XCTAssertEqual(self.lastSQLQuery, """
                UPDATE OR IGNORE "player" SET "score" = 0
                """)
        }
    }
    

    

    

    
    func testGroupedRequestUpdate() throws {
        try makeDatabaseQueue().inDatabase { db in
            struct Player: MutablePersistableRecord {
                func encode(to container: inout PersistenceContainer) { preconditionFailure("should not be called") }
            }
            struct Passport: MutablePersistableRecord {
                func encode(to container: inout PersistenceContainer) { preconditionFailure("should not be called") }
            }
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("score", .integer)
            }
            try db.create(table: "passport") { t in
                t.column("countryCode", .text).notNull()
                t.column("citizenId", .integer).notNull()
                t.column("active", .boolean)
                t.primaryKey(["countryCode", "citizenId"])
            }
            do {
                try Player.all().groupByPrimaryKey().updateAll(db, Column("score").set(to: 0))
                XCTAssertEqual(self.lastSQLQuery, """
                    UPDATE "player" SET "score" = 0 WHERE "id" IN (\
                    SELECT "id" \
                    FROM "player" \
                    GROUP BY "id")
                    """)
            }
            do {
                try Player.all().group(Column.rowID).updateAll(db, Column("score").set(to: 0))
                XCTAssertEqual(self.lastSQLQuery, """
                    UPDATE "player" SET "score" = 0 WHERE "id" IN (\
                    SELECT "id" \
                    FROM "player" \
                    GROUP BY "rowid")
                    """)
            }
            do {
                try Passport.all().groupByPrimaryKey().updateAll(db, Column("active").set(to: true))
                XCTAssertEqual(self.lastSQLQuery, """
                    UPDATE "passport" SET "active" = 1 WHERE "rowid" IN (\
                    SELECT "rowid" \
                    FROM "passport" \
                    GROUP BY "rowid")
                    """)
            }
            do {
                try Passport.all().group(Column.rowID).updateAll(db, Column("active").set(to: true))
                XCTAssertEqual(self.lastSQLQuery, """
                    UPDATE "passport" SET "active" = 1 WHERE "rowid" IN (\
                    SELECT "rowid" \
                    FROM "passport" \
                    GROUP BY "rowid")
                    """)
            }
        }
    }
    

}
