import SQLiteOrbit
import Testing

@Suite
struct OrbitDatabaseRegionRecorderPublicTests {
  @Test
  func rollbackPreservesProvisionalChangesWithoutTurningThemIntoCommittedChanges() {
    let recorder = OrbitDatabaseRegionRecorder()
    let read = OrbitDatabaseRegion(column: "title", in: "items")
    let changed = OrbitDatabaseRegion(table: "items")
    let pending = OrbitDatabaseRegion(table: "pending")

    #expect(recorder.readRegion == .empty)
    #expect(recorder.changedRegion == .empty)
    #expect(recorder.committedRegion == .empty)
    #expect(!recorder.hasCommitted)

    recorder.databaseDidRead(in: read)
    recorder.databaseDidChange(in: changed)
    recorder.databaseDidRollback()
    recorder.databaseDidChange(in: pending)

    #expect(recorder.readRegion == read)
    #expect(recorder.changedRegion == changed.union(pending))
    #expect(recorder.committedRegion == .empty)
    #expect(!recorder.hasCommitted)
  }

  @Test
  func commitPayloadIncludesEarlierChangesAndDoesNotCommitUnrelatedProvisionalChanges() {
    let recorder = OrbitDatabaseRegionRecorder()
    let earlier = OrbitDatabaseRegion(table: "earlier")
    let observed = OrbitDatabaseRegion(table: "observed")
    let rolledBack = OrbitDatabaseRegion(table: "rolled_back")
    let external = OrbitDatabaseRegion(table: "external")

    recorder.databaseDidChange(in: rolledBack)
    recorder.databaseDidRollback()
    recorder.databaseDidChange(in: observed)
    recorder.databaseDidCommit(OrbitDatabaseCommit(origin: .local, region: earlier.union(observed)))
    recorder.databaseDidCommit(OrbitDatabaseCommit(origin: .external, region: external))

    #expect(recorder.changedRegion == rolledBack.union(observed))
    #expect(recorder.committedRegion == earlier.union(observed).union(external))
    #expect(recorder.hasCommitted)
  }

  @Test
  func anEmptyCommitIsDistinguishableFromReceivingNoCommit() {
    let recorder = OrbitDatabaseRegionRecorder()
    recorder.databaseDidCommit(OrbitDatabaseCommit(origin: .local, region: .empty))

    #expect(recorder.hasCommitted)
    #expect(recorder.committedRegion == .empty)
    #expect(recorder.changedRegion == .empty)
  }

  #if BuiltInSQLite
    @Test
    func aPublicReadTransactionRecordsTheColumnsItReads() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        try connection.executeScript(
          """
          CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
          INSERT INTO items VALUES (1, 'Milk');
          """
        )
      }
      let recorder = OrbitDatabaseRegionRecorder()
      let title = try owner.withReadConnection { connection in
        try connection.transaction(observer: recorder) { transaction in
          try transaction.fetchOne("SELECT title FROM items") { $0[0].textValue ?? "" }
        }
      }

      #expect(title == "Milk")
      #if Turso
        let expectedReadRegion = OrbitDatabaseRegion.fullDatabase
      #else
        let expectedReadRegion = OrbitDatabaseRegion(column: "title", in: "items")
      #endif
      #expect(recorder.readRegion == expectedReadRegion)
      #expect(recorder.changedRegion == .empty)
      #expect(recorder.committedRegion == .empty)
      #expect(!recorder.hasCommitted)
    }
  #endif
}
