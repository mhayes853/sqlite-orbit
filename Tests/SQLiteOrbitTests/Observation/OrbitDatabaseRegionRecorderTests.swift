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
      #expect(
        recorder.readRegion
          == nativeRecorderRegion(OrbitDatabaseRegion(column: "title", in: "items"))
      )
      #expect(recorder.changedRegion == .empty)
      #expect(recorder.committedRegion == .empty)
      #expect(!recorder.hasCommitted)
    }

    @Test
    func observingAnEntireWriteTransactionRecordsRollbackAndSubsequentCommit() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let recorder = OrbitDatabaseRegionRecorder()
      let items = nativeRecorderRegion(OrbitDatabaseRegion(table: "items"))
      let lists = nativeRecorderRegion(OrbitDatabaseRegion(table: "lists"))
      try owner.withWriteConnection { connection in
        try connection.executeScript(
          """
          CREATE TABLE items (id INTEGER PRIMARY KEY);
          CREATE TABLE lists (id INTEGER PRIMARY KEY);
          """
        )
        #expect(throws: RecorderTestFailure.self) {
          try connection.transaction(observer: recorder) { transaction in
            try transaction.execute("INSERT INTO items VALUES (1)")
            throw RecorderTestFailure()
          }
        }
        #expect(recorder.changedRegion == items)
        #expect(recorder.committedRegion == .empty)
        #expect(!recorder.hasCommitted)

        try connection.transaction(observer: recorder) { transaction in
          try transaction.execute("INSERT INTO lists VALUES (1)")
        }
      }

      #expect(recorder.changedRegion == items.union(lists))
      #expect(recorder.committedRegion == lists)
      #expect(recorder.hasCommitted)
      let itemCount = try owner.withReadConnection { connection in
        try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue ?? 0 }
      }
      #expect(itemCount == 0)
    }

    @Test
    func aScopedRecorderRetainsPartialCommitsWhenTheAccessThrows() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        try connection.executeScript(
          """
          CREATE TABLE items (id INTEGER PRIMARY KEY);
          CREATE TABLE lists (id INTEGER PRIMARY KEY);
          CREATE TABLE archive (id INTEGER PRIMARY KEY);
          """
        )
      }
      let recorder = OrbitDatabaseRegionRecorder()
      do {
        try owner.withWriteConnection { connection in
          try connection.withObservation(recorder) {
            try connection.execute("INSERT INTO items VALUES (1)")
            #expect(throws: RecorderTestFailure.self) {
              try connection.transaction { transaction in
                try transaction.execute("INSERT INTO archive VALUES (1)")
                throw RecorderTestFailure()
              }
            }
            try connection.execute("INSERT INTO lists VALUES (1)")
            throw RecorderTestFailure()
          }
        }
        Issue.record("The access did not report its failure")
      } catch {
        #expect(error is RecorderTestFailure)
      }

      let committed = nativeRecorderRegion(
        OrbitDatabaseRegion(table: "items").union(OrbitDatabaseRegion(table: "lists"))
      )
      #expect(recorder.committedRegion == committed)
      #expect(recorder.changedRegion == committed.union(OrbitDatabaseRegion(table: "archive")))
      #expect(recorder.hasCommitted)
      let archiveCount = try owner.withReadConnection { connection in
        try connection.fetchOne("SELECT count(*) FROM archive") { $0[0].integerValue ?? 0 }
      }
      #expect(archiveCount == 0)
    }

    @Test
    func aRecorderScopedInsideTheTransactionBodyDoesNotReceiveTheLaterCommit() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let recorder = OrbitDatabaseRegionRecorder()
      try owner.withWriteConnection { connection in
        try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try connection.transaction { transaction in
          try transaction.withObservation(recorder) {
            try transaction.execute("INSERT INTO items VALUES (1)")
          }
        }
      }

      #expect(recorder.changedRegion == nativeRecorderRegion(OrbitDatabaseRegion(table: "items")))
      #expect(recorder.committedRegion == .empty)
      #expect(!recorder.hasCommitted)
      let count = try owner.withReadConnection { connection in
        try connection.fetchOne("SELECT count(*) FROM items") { $0[0].integerValue ?? 0 }
      }
      #expect(count == 1)
    }

    private func nativeRecorderRegion(_ precise: OrbitDatabaseRegion) -> OrbitDatabaseRegion {
      #if Turso
        .fullDatabase
      #else
        precise
      #endif
    }

    private struct RecorderTestFailure: Error {}
  #endif
}
