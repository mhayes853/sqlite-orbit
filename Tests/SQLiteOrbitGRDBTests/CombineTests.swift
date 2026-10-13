#if canImport(Combine)
  import Combine
  import Foundation
  import SQLiteOrbitGRDB
  import Testing

  @Suite("GRDB Combine observation", .timeLimit(.minutes(1)))
  struct GRDBCombineObservationTests {
    @Test @MainActor func publisherDeliversInitialValueAndCommittedChanges() async throws {
      let database = try DatabaseQueue()
      try await database.write { try $0.execute(sql: "CREATE TABLE t(n INTEGER)") }
      let output = AsyncStream<Int>.makeStream()
      let observation = ValueObservation.tracking {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t")!
      }
      let subscription = observation.publisher(in: database)
        .sink(
          receiveCompletion: { completion in
            if case .failure(let error) = completion { Issue.record(error) }
            output.continuation.finish()
          },
          receiveValue: { output.continuation.yield($0) }
        )
      defer {
        subscription.cancel()
        output.continuation.finish()
      }
      var iterator = output.stream.makeAsyncIterator()
      #expect(await iterator.next() == 0)
      try await database.write { try $0.execute(sql: "INSERT INTO t VALUES(1)") }
      #expect(await iterator.next() == 1)
      subscription.cancel()
    }
  }
#endif
