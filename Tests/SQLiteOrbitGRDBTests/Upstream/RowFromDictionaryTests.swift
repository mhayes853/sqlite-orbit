// Selected test body from GRDB 7.11.1; see LICENSE and provenance.md.
import XCTest
import SQLiteOrbitGRDB

class RowFromDictionaryTests: GRDBTestCase {
    func testCoalesce() throws {
        let rows = [
            Row(["nickname": "Artie", "name": "Arthur"]),
            Row(["nickname": nil, "name": "Jacob"]),
            Row(["nickname": nil, "name": nil]),
        ]
        let values = rows.map { row in
            [
                row.coalesce(Array<String>()) as String?,
                row.coalesce(["nickname"]) as String?,
                row.coalesce(["nickname", "name"]) as String?,
                row.coalesce([Column("nickname"), Column("name")]) as String?,
            ]
        }
        XCTAssertEqual(values, [
            [nil, "Artie", "Artie", "Artie"],
            [nil, nil, "Jacob", "Jacob"],
            [nil, nil, nil, nil],
        ])
    }
}
