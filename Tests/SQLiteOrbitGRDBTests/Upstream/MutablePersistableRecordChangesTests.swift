import XCTest
import SQLiteOrbitGRDB

private struct Player: FetchableRecord, MutablePersistableRecord, Codable {
    static let databaseTableName = "players"

    var id: Int64?
    var name: String?
    var score: Int?
    var creationDate: Date?

    init(id: Int64? = nil, name: String? = nil, score: Int? = nil, creationDate: Date? = nil) {
        self.id = id
        self.name = name
        self.score = score
        self.creationDate = creationDate
    }

    mutating func willInsert(_ db: Database) throws {
        if creationDate == nil {
           creationDate = Date()
        }
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

class MutablePersistableRecordChangesTests: GRDBTestCase {
    override func setup(_ dbWriter: some DatabaseWriter) throws {
        try dbWriter.write { db in
            try db.create(table: "players") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text)
                t.column("score", .integer)
                t.column("creationDate", .datetime)
            }
        }
    }

    func testDegenerateDatabaseEqualsWithSelf() throws {
        struct DegenerateRecord: MutablePersistableRecord {
            static let databaseTableName = "degenerated"
            func encode(to container: inout PersistenceContainer) {
            }
        }
        let record = DegenerateRecord()
        XCTAssertTrue(record.databaseEquals(record))
        try XCTAssertTrue(record.databaseChanges(from: record).isEmpty)

        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            // table must exist
            try db.create(table: DegenerateRecord.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
            }
            let totalChangesCount = db.totalChangesCount
            try XCTAssertFalse(record.updateChanges(db, from: record))
            XCTAssertEqual(db.totalChangesCount, totalChangesCount)
        }
    }
        func testDatabaseEqualsWithSelf() throws {
        do {
            let player = Player(id: nil, name: nil, score: nil, creationDate: nil)
            XCTAssertTrue(player.databaseEquals(player))
            try XCTAssertTrue(player.databaseChanges(from: player).isEmpty)

            let dbQueue = try makeDatabaseQueue()
            try dbQueue.inDatabase { db in
                let totalChangesCount = db.totalChangesCount
                try XCTAssertFalse(player.updateChanges(db, from: player))
                XCTAssertEqual(db.totalChangesCount, totalChangesCount)
            }
        }
        do {
            let player = Player(id: 1, name: "foo", score: 42, creationDate: Date())
            XCTAssertTrue(player.databaseEquals(player))
            try XCTAssertTrue(player.databaseChanges(from: player).isEmpty)

            let dbQueue = try makeDatabaseQueue()
            try dbQueue.inDatabase { db in
                let totalChangesCount = db.totalChangesCount
                try XCTAssertFalse(player.updateChanges(db, from: player))
                XCTAssertEqual(db.totalChangesCount, totalChangesCount)
            }
        }
    }
    func testDatabaseChangesWithClass() throws {
        class Player: Encodable, EncodableRecord {
            var id: Int64
            var name: String
            var score: Int

            init(id: Int64, name: String, score: Int) {
                self.id = id
                self.name = name
                self.score = score
            }
        }

        var player = Player(id: 1, name: "Arthur", score: 1000)
        do {
            let changes = try player.databaseChanges { _ in }
            XCTAssert(changes.isEmpty)
        }
        do {
            let changes = try player.databaseChanges {
                $0.name = "Barbara"
            }
            XCTAssertEqual(changes, ["name": "Arthur".databaseValue])
        }
        do {
            let changes = try player.databaseChanges {
                $0.name = "Craig"
                $0.score = 200
            }
            XCTAssertEqual(changes, ["name": "Barbara".databaseValue, "score": 1000.databaseValue])
        }
    }
        func testDatabaseChangesWithStruct() throws {
        struct Player: Encodable, EncodableRecord {
            var id: Int64
            var name: String
            var score: Int
        }

        var player = Player(id: 1, name: "Arthur", score: 1000)
        do {
            let changes = try player.databaseChanges { _ in }
            XCTAssert(changes.isEmpty)
        }
        do {
            let changes = try player.databaseChanges {
                $0.name = "Barbara"
            }
            XCTAssertEqual(changes, ["name": "Arthur".databaseValue])
        }
        do {
            let changes = try player.databaseChanges {
                $0.name = "Craig"
                $0.score = 200
            }
            XCTAssertEqual(changes, ["name": "Barbara".databaseValue, "score": 1000.databaseValue])
        }
    }

}
