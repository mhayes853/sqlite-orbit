// Selected test body from GRDB 7.11.1; see LICENSE and provenance.md.
import XCTest
import SQLiteOrbitGRDB

class RowFromStatementTests: GRDBTestCase {
    func testCoalesce() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let values = try Array(Row
                .fetchCursor(db, sql: """
                    SELECT           'Artie' AS nickname, 'Arthur' AS name
                    UNION ALL SELECT NULL, 'Jacob'
                    UNION ALL SELECT NULL, NULL
                    """)
                .map { row in
                    [
                        row.coalesce(Array<String>()) as String?,
                        row.coalesce(["nickname"]) as String?,
                        row.coalesce(["nickname", "name"]) as String?,
                        row.coalesce([Column("nickname"), Column("name")]) as String?,
                    ]
                })
            XCTAssertEqual(values, [
                [nil, "Artie", "Artie", "Artie"],
                [nil, nil, "Jacob", "Jacob"],
                [nil, nil, nil, nil],
            ])
        }
    }
}
