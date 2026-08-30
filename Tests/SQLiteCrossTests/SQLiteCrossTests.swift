import Foundation
import SQLiteCross
import Testing

@Test
func transactionCommitRoundTripsThroughJSON() throws {
  let commit = TransactionCommit(
    database: DatabaseIdentifier(rawValue: "example-database"),
    source: ProcessIdentifier(rawValue: "example-process"),
    region: .tables(["item", "tag"])
  )

  let data = try JSONEncoder().encode(commit)
  let decoded = try JSONDecoder().decode(TransactionCommit.self, from: data)

  #expect(decoded == commit)
}

@Test
func databaseChangeRegionsFormUnions() {
  #expect(
    DatabaseChangeRegion.tables(["item"]).union(.tables(["item", "tag"]))
      == .tables(["item", "tag"])
  )
  #expect(DatabaseChangeRegion.tables(["item"]).union(.fullDatabase) == .fullDatabase)
}
