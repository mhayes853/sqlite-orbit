// Generated from GRDB 7.11.1 Tests/GRDBTests/Record/PersistableRecord/RecordMappedOnMutableViewTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

private struct Player: Codable,
                       Equatable,
                       Identifiable,
                       FetchableRecord,
                       PersistableRecord
{
    var id: String
    var name: String
    var teamId: String?
    var isCaptain: Bool
}

private struct Team: Codable,
                     Equatable,
                     Identifiable,
                     FetchableRecord,
                     PersistableRecord
{
    var id: String
    var name: String
    
    static let captain = hasOne(Captain.self, using: Captain.teamForeignKey)
}

private struct Captain: Codable,
                        Equatable,
                        Identifiable,
                        FetchableRecord,
                        PersistableRecord
{
    var id: String
    var name: String
    var teamId: String
    
    enum Columns {
        static let teamId = Column(CodingKeys.teamId)
    }
    
    static let teamForeignKey = ForeignKey([Columns.teamId])
    static let team = belongsTo(Team.self, using: teamForeignKey)
}



class RecordMappedOnMutableViewTests : GRDBTestCase {
    private lazy var migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("Teams and players") { db in
            try db.create(table: "team") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
            }
            
            try db.create(table: "player") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.belongsTo("team", onDelete: .setNull)
                t.column("isCaptain", .boolean).notNull()
            }
            
            // One unique captain per team
            try db.create(
                indexOn: "player", columns: ["teamId"],
                options: .unique,
                condition: Column("isCaptain"))
        }
        
        migrator.registerMigration("Read-only captains") { db in
            try db.execute(sql: """
                CREATE VIEW captain AS
                SELECT id, name, teamId
                FROM player
                WHERE isCaptain AND teamId IS NOT NULL;
                """)
        }
        
        migrator.registerMigration("Captain CRUD") { db in
            try db.execute(sql: """
                -- Insert trigger
                CREATE TRIGGER captain_insert
                INSTEAD OF INSERT ON captain
                BEGIN
                    -- Remove previous captain
                    UPDATE player SET isCaptain = 0
                    WHERE teamId = NEW.teamId AND isCaptain;
                    
                    -- Insert new captain
                    INSERT INTO player(id, name, teamId, isCaptain)
                    VALUES (NEW.id, NEW.name, NEW.teamId, 1);
                END;
                
                -- Update trigger
                CREATE TRIGGER captain_update
                INSTEAD OF UPDATE ON captain
                BEGIN
                    -- Remove previous captain
                    UPDATE player SET isCaptain = 0
                    WHERE teamId = NEW.teamId AND isCaptain AND id <> NEW.id;
                    
                    -- Update captain
                    UPDATE player SET name = NEW.name, teamId = NEW.teamId, isCaptain = 1
                    WHERE id = NEW.id;
                END;
                
                -- Delete trigger
                CREATE TRIGGER captain_delete
                INSTEAD OF DELETE ON captain
                BEGIN
                    DELETE FROM player WHERE id = OLD.id;
                END;
                """)
        }
        
        return migrator
    }()
    
    func test_read_only() throws {
        // No schema source, no CRUD
        let dbQueue = try makeDatabaseQueue()
        try migrator.migrate(dbQueue, upTo: "Read-only captains")
        try dbQueue.write { db in
            try Team(id: "red", name: "Red").insert(db)
            try Team(id: "blue", name: "Blue").insert(db)
            try Player(id: "alice", name: "Alice", teamId: "red", isCaptain: true).insert(db)
            try Player(id: "bob", name: "Bob", teamId: "blue", isCaptain: true).insert(db)
            try Player(id: "craig", name: "Craig", teamId: "blue", isCaptain: false).insert(db)

            let captains = try Captain.fetchAll(db)
            XCTAssertEqual(captains.count, 2)
            XCTAssert(captains.contains(Captain(id: "alice", name: "Alice", teamId: "red")))
            XCTAssert(captains.contains(Captain(id: "bob", name: "Bob", teamId: "blue")))
        }
    }
    

    

    

    

    

    

}
