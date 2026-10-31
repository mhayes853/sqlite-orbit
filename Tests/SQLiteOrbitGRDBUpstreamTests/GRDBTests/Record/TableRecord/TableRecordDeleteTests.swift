// Generated from GRDB 7.11.1 Tests/GRDBTests/Record/TableRecord/TableRecordDeleteTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

// Table records
private struct Hacker : TableRecord {
    static let databaseTableName = "hackers"
    var id: Int64? // Optional
}

extension Hacker: Identifiable { }

private struct Person : Codable, PersistableRecord, FetchableRecord, Hashable {
    static let databaseTableName = "persons"
    var id: Int64 // Non-optional
    var name: String
    var email: String
    
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
    }
}

extension Person: Identifiable { }

private struct Citizenship : TableRecord {
    static let databaseTableName = "citizenships"
}

// View records

private struct PersonView : Codable, PersistableRecord, FetchableRecord, Hashable {
    static let databaseTableName = "personsView"
    var id: Int64 // Non-optional
    var name: String
    var email: String
    
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
    }
}

extension PersonView: Identifiable { }

private struct CitizenshipView : TableRecord {
    static let databaseTableName = "citizenshipsView"
}

// Schema source



class TableRecordDeleteTests: GRDBTestCase {
    
    override func setup(_ dbWriter: some DatabaseWriter) throws {
        try dbWriter.write { db in
            try db.execute(sql: "CREATE TABLE hackers (name TEXT)")
            try db.execute(sql: "CREATE TABLE persons (id INTEGER PRIMARY KEY, name TEXT, email TEXT UNIQUE)")
            try db.execute(sql: "CREATE TABLE citizenships (personId INTEGER NOT NULL, countryIsoCode TEXT NOT NULL, PRIMARY KEY (personId, countryIsoCode))")
            
            // mutable views
            try db.execute(sql: """
                CREATE VIEW personsView AS SELECT * FROM persons;
                -- Insert trigger
                CREATE TRIGGER personsView_insert
                INSTEAD OF INSERT ON personsView
                BEGIN
                  INSERT INTO persons (id, name, email)
                  VALUES (NEW.id, NEW.name, NEW.email);
                END;
                -- Delete trigger
                CREATE TRIGGER personsView_delete
                INSTEAD OF DELETE ON personsView
                BEGIN
                  DELETE FROM persons WHERE id = OLD.id;
                END;
                """)
            try db.execute(sql: """
                CREATE VIEW citizenshipsView AS SELECT * FROM citizenships;
                -- Insert trigger
                CREATE TRIGGER citizenshipsView_insert
                INSTEAD OF INSERT ON citizenshipsView
                BEGIN
                  INSERT INTO citizenships (personId, countryIsoCode)
                  VALUES (NEW.personId, NEW.countryIsoCode);
                END;
                -- Delete trigger
                CREATE TRIGGER citizenshipsView_delete
                INSTEAD OF DELETE ON citizenshipsView
                BEGIN
                  DELETE FROM citizenships WHERE personId = OLD.personId AND countryIsoCode = OLD.countryIsoCode;
                END;
                """)
        }
    }
    
    func testImplicitRowIDPrimaryKey() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            var deleted = try Hacker.deleteOne(db, key: 1)
            XCTAssertEqual(self.lastSQLQuery, "DELETE FROM \"hackers\" WHERE \"rowid\" = 1")
            XCTAssertFalse(deleted)
            
            try db.execute(sql: "INSERT INTO hackers (rowid, name) VALUES (?, ?)", arguments: [1, "Arthur"])
            deleted = try Hacker.deleteOne(db, key: 1)
            XCTAssertTrue(deleted)
            XCTAssertEqual(try Hacker.fetchCount(db), 0)
            
            try db.execute(sql: "INSERT INTO hackers (rowid, name) VALUES (?, ?)", arguments: [1, "Arthur"])
            try XCTAssertFalse(Hacker.deleteOne(db, id: nil))
            deleted = try Hacker.deleteOne(db, id: 1)
            XCTAssertTrue(deleted)
            XCTAssertEqual(try Hacker.fetchCount(db), 0)
            
            do {
                try db.execute(sql: "INSERT INTO hackers (rowid, name) VALUES (?, ?)", arguments: [1, "Arthur"])
                try db.execute(sql: "INSERT INTO hackers (rowid, name) VALUES (?, ?)", arguments: [2, "Barbara"])
                try db.execute(sql: "INSERT INTO hackers (rowid, name) VALUES (?, ?)", arguments: [3, "Craig"])
                let deletedCount = try Hacker.deleteAll(db, keys: [2, 3, 4])
                XCTAssertEqual(self.lastSQLQuery, "DELETE FROM \"hackers\" WHERE \"rowid\" IN (2, 3, 4)")
                XCTAssertEqual(deletedCount, 2)
                XCTAssertEqual(try Hacker.fetchCount(db), 1)
            }
            
            do {
                try db.execute(sql: "INSERT INTO hackers (rowid, name) VALUES (?, ?)", arguments: [2, "Barbara"])
                try db.execute(sql: "INSERT INTO hackers (rowid, name) VALUES (?, ?)", arguments: [3, "Craig"])
                let deletedCount = try Hacker.deleteAll(db, ids: [2, 3, 4])
                XCTAssertEqual(self.lastSQLQuery, "DELETE FROM \"hackers\" WHERE \"rowid\" IN (2, 3, 4)")
                XCTAssertEqual(deletedCount, 2)
                XCTAssertEqual(try Hacker.fetchCount(db), 1)
            }
        }
    }

    func testSingleColumnPrimaryKey_table() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            var deleted = try Person.deleteOne(db, key: 1)
            XCTAssertEqual(self.lastSQLQuery, "DELETE FROM \"persons\" WHERE \"id\" = 1")
            XCTAssertFalse(deleted)
            
            try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [1, "Arthur", "arthur@example.com"])
            deleted = try Person.deleteOne(db, key: 1)
            XCTAssertTrue(deleted)
            XCTAssertEqual(try Person.fetchCount(db), 0)
            
            try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [1, "Arthur", "arthur@example.com"])
            deleted = try Person.deleteOne(db, id: 1)
            XCTAssertTrue(deleted)
            XCTAssertEqual(try Person.fetchCount(db), 0)
            
            do {
                try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [1, "Arthur", "arthur@example.com"])
                try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [2, "Barbara", "barbara@example.com"])
                try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [3, "Craig", "craig@example.com"])
                let deletedCount = try Person.deleteAll(db, keys: [2, 3, 4])
                XCTAssertEqual(self.lastSQLQuery, "DELETE FROM \"persons\" WHERE \"id\" IN (2, 3, 4)")
                XCTAssertEqual(deletedCount, 2)
                XCTAssertEqual(try Person.fetchCount(db), 1)
            }
            
            do {
                try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [2, "Barbara", "barbara@example.com"])
                try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [3, "Craig", "craig@example.com"])
                let deletedCount = try Person.deleteAll(db, ids: [2, 3, 4])
                XCTAssertEqual(self.lastSQLQuery, "DELETE FROM \"persons\" WHERE \"id\" IN (2, 3, 4)")
                XCTAssertEqual(deletedCount, 2)
                XCTAssertEqual(try Person.fetchCount(db), 1)
            }
        }
    }



    func testMultipleColumnPrimaryKey_table() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            var deleted = try Citizenship.deleteOne(db, key: ["personId": 1, "countryIsoCode": "FR"])
            XCTAssertEqual(self.lastSQLQuery, "DELETE FROM \"citizenships\" WHERE (\"personId\" = 1) AND (\"countryIsoCode\" = 'FR')")
            XCTAssertFalse(deleted)
            
            try db.execute(sql: "INSERT INTO citizenships (personId, countryIsoCode) VALUES (?, ?)", arguments: [1, "FR"])
            deleted = try Citizenship.deleteOne(db, key: ["personId": 1, "countryIsoCode": "FR"])
            XCTAssertTrue(deleted)
            XCTAssertEqual(try Citizenship.fetchCount(db), 0)
            
            try db.execute(sql: "INSERT INTO citizenships (personId, countryIsoCode) VALUES (?, ?)", arguments: [1, "FR"])
            try db.execute(sql: "INSERT INTO citizenships (personId, countryIsoCode) VALUES (?, ?)", arguments: [1, "US"])
            try db.execute(sql: "INSERT INTO citizenships (personId, countryIsoCode) VALUES (?, ?)", arguments: [2, "US"])
            let deletedCount = try Citizenship.deleteAll(db, keys: [["personId": 1, "countryIsoCode": "FR"], ["personId": 1, "countryIsoCode": "US"], ["personId": 1, "countryIsoCode": "DE"]])
            XCTAssertEqual(deletedCount, 2)
            XCTAssertEqual(try Citizenship.fetchCount(db), 1)
        }
    }



    func testUniqueIndex() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            var deleted = try Person.deleteOne(db, key: ["email": "arthur@example.com"])
            XCTAssertEqual(self.lastSQLQuery, "DELETE FROM \"persons\" WHERE \"email\" = 'arthur@example.com'")
            XCTAssertFalse(deleted)
            
            try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [1, "Arthur", "arthur@example.com"])
            deleted = try Person.deleteOne(db, key: ["email": "arthur@example.com"])
            XCTAssertTrue(deleted)
            XCTAssertEqual(try Person.fetchCount(db), 0)
            
            try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [1, "Arthur", "arthur@example.com"])
            try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [2, "Barbara", "barbara@example.com"])
            try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [3, "Craig", "craig@example.com"])
            let deletedCount = try Person.deleteAll(db, keys: [["email": "arthur@example.com"], ["email": "barbara@example.com"], ["email": "david@example.com"]])
            XCTAssertEqual(deletedCount, 2)
            XCTAssertEqual(try Person.fetchCount(db), 1)
        }
    }

    func testImplicitUniqueIndexOnSingleColumnPrimaryKey_table() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            var deleted = try Person.deleteOne(db, key: ["id": 1])
            XCTAssertEqual(self.lastSQLQuery, "DELETE FROM \"persons\" WHERE \"id\" = 1")
            XCTAssertFalse(deleted)
            
            try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [1, "Arthur", "arthur@example.com"])
            deleted = try Person.deleteOne(db, key: ["id": 1])
            XCTAssertTrue(deleted)
            XCTAssertEqual(try Person.fetchCount(db), 0)
            
            try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [1, "Arthur", "arthur@example.com"])
            try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [2, "Barbara", "barbara@example.com"])
            try db.execute(sql: "INSERT INTO persons (id, name, email) VALUES (?, ?, ?)", arguments: [3, "Craig", "craig@example.com"])
            let deletedCount = try Person.deleteAll(db, keys: [["id": 2], ["id": 3], ["id": 4]])
            XCTAssertEqual(deletedCount, 2)
            XCTAssertEqual(try Person.fetchCount(db), 1)
        }
    }
    

    

    

    

    

    

    

    

    

    

    

    

    

    

    

    
    func testGroupedRequestDeleteAll() throws {
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
                t.primaryKey(["countryCode", "citizenId"])
            }
            do {
                try Player.all().groupByPrimaryKey().deleteAll(db)
                XCTAssertEqual(self.lastSQLQuery, """
                    DELETE FROM "player" WHERE "id" IN (\
                    SELECT "id" \
                    FROM "player" \
                    GROUP BY "id")
                    """)
            }
            do {
                try Player.all().group(-Column("id")).deleteAll(db)
                XCTAssertEqual(self.lastSQLQuery, """
                    DELETE FROM "player" WHERE "id" IN (\
                    SELECT "id" \
                    FROM "player" \
                    GROUP BY -"id")
                    """)
            }
            do {
                try Player.all().group(Column.rowID).deleteAll(db)
                XCTAssertEqual(self.lastSQLQuery, """
                    DELETE FROM "player" WHERE "id" IN (\
                    SELECT "id" \
                    FROM "player" \
                    GROUP BY "rowid")
                    """)
            }
            do {
                try Passport.all().groupByPrimaryKey().deleteAll(db)
                XCTAssertEqual(self.lastSQLQuery, """
                    DELETE FROM "passport" WHERE "rowid" IN (\
                    SELECT "rowid" \
                    FROM "passport" \
                    GROUP BY "rowid")
                    """)
            }
            do {
                try Passport.all().group(Column.rowID).deleteAll(db)
                XCTAssertEqual(self.lastSQLQuery, """
                    DELETE FROM "passport" WHERE "rowid" IN (\
                    SELECT "rowid" \
                    FROM "passport" \
                    GROUP BY "rowid")
                    """)
            }
        }
    }
    
    func testGroupedRequestDeleteAndFetchCursor() throws {
#if GRDBCUSTOMSQLITE || SQLITE_HAS_CODEC
        guard Database.sqliteLibVersionNumber >= 3035000 else {
            throw XCTSkip("RETURNING clause is not available")
        }
#else
        guard #available(iOS 15, macOS 12, tvOS 15, watchOS 8, *) else {
            throw XCTSkip("RETURNING clause is not available")
        }
#endif
        
        try makeDatabaseQueue().inDatabase { db in
            struct Player: MutablePersistableRecord, FetchableRecord {
                func encode(to container: inout PersistenceContainer) { preconditionFailure("should not be called") }
                init(row: Row) { preconditionFailure("should not be called") }
            }
            struct Passport: MutablePersistableRecord, FetchableRecord {
                func encode(to container: inout PersistenceContainer) { preconditionFailure("should not be called") }
                init(row: Row) { preconditionFailure("should not be called") }
            }
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("score", .integer)
            }
            try db.create(table: "passport") { t in
                t.column("countryCode", .text).notNull()
                t.column("citizenId", .integer).notNull()
                t.primaryKey(["countryCode", "citizenId"])
            }
            do {
                _ = try Player.all().groupByPrimaryKey().deleteAndFetchCursor(db).next()
                XCTAssertEqual(self.lastSQLQuery, """
                    DELETE FROM "player" WHERE "id" IN (\
                    SELECT "id" \
                    FROM "player" \
                    GROUP BY "id") \
                    RETURNING *
                    """)
            }
            do {
                _ = try Player.all().group(-Column("id")).deleteAndFetchCursor(db).next()
                XCTAssertEqual(self.lastSQLQuery, """
                    DELETE FROM "player" WHERE "id" IN (\
                    SELECT "id" \
                    FROM "player" \
                    GROUP BY -"id") \
                    RETURNING *
                    """)
            }
            do {
                _ = try Player.all().group(Column.rowID).deleteAndFetchCursor(db).next()
                XCTAssertEqual(self.lastSQLQuery, """
                    DELETE FROM "player" WHERE "id" IN (\
                    SELECT "id" \
                    FROM "player" \
                    GROUP BY "rowid") \
                    RETURNING *
                    """)
            }
            do {
                _ = try Passport.all().groupByPrimaryKey().deleteAndFetchCursor(db).next()
                XCTAssertEqual(self.lastSQLQuery, """
                    DELETE FROM "passport" WHERE "rowid" IN (\
                    SELECT "rowid" \
                    FROM "passport" \
                    GROUP BY "rowid") \
                    RETURNING *
                    """)
            }
            do {
                _ = try Passport.all().group(Column.rowID).deleteAndFetchCursor(db).next()
                XCTAssertEqual(self.lastSQLQuery, """
                    DELETE FROM "passport" WHERE "rowid" IN (\
                    SELECT "rowid" \
                    FROM "passport" \
                    GROUP BY "rowid") \
                    RETURNING *
                    """)
            }
        }
    }
}
