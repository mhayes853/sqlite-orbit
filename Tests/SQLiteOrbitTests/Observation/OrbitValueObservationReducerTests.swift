#if BuiltInSQLite
  import SQLiteOrbit
  import Testing

  @Suite
  struct OrbitValueObservationReducerTests {
    @Test
    func reducerStateIsSharedWithinARunButIndependentAcrossDatabasesAndRestarts() throws {
      let firstDatabase = try blockingItemsDatabase()
      let secondDatabase = try blockingItemsDatabase()
      try insertItemsBlocking(1, into: firstDatabase)
      try insertItemsBlocking(1, into: secondDatabase)
      let factories = TestCounter()
      let observation = counts.applying {
        factories.increment()
        return RunningTotal()
      }
      #expect(factories.value == 0)

      func subscribe(_ database: SQLiteQueue, _ values: TestRecorder<Int>) throws
        -> OrbitSubscription
      {
        try observation.subscribe(
          to: database,
          scheduling: .immediate,
          onError: { Issue.record($0) },
          onChange: { values.append($0.value) }
        )
      }

      let first = TestRecorder<Int>()
      let shared = TestRecorder<Int>()
      let second = TestRecorder<Int>()
      let firstSubscription = try subscribe(firstDatabase, first)
      let sharedSubscription = try subscribe(firstDatabase, shared)
      let secondSubscription = try subscribe(secondDatabase, second)
      defer {
        firstSubscription.cancel()
        sharedSubscription.cancel()
        secondSubscription.cancel()
      }
      #expect(factories.value == 2)
      #expect(first.values == [1] && shared.values == [1] && second.values == [1])

      try insertItemsBlocking(2, into: firstDatabase)
      #expect(first.values == [1, 3] && shared.values == [1, 3])
      firstSubscription.cancel()
      try insertItemsBlocking(3, into: firstDatabase)
      #expect(first.values == [1, 3] && shared.values == [1, 3, 6])
      sharedSubscription.cancel()

      let restarted = TestRecorder<Int>()
      let restartedSubscription = try subscribe(firstDatabase, restarted)
      defer { restartedSubscription.cancel() }
      #expect(factories.value == 3)
      #expect(restarted.values == [3])
      try insertItemsBlocking(2, into: secondDatabase)
      #expect(second.values == [1, 3])
      #expect(restarted.values == [3])
    }

    @Test
    func optionalOutputsCanEmitNilOrSkipWithoutLosingReplayOrOperatorOrdering() throws {
      let database = try blockingItemsDatabase()
      let received = TestRecorder<Int?>()
      let updates = TestRecorder<OrbitValueObservationUpdate<String?>>()
      let observation = OrbitValueObservation<Int?>
        .tracking { transaction in
          let count = try transaction.fetchOne(itemCountSQL) { Int($0[0].integerValue ?? 0) } ?? 0
          return count == 0 ? nil : count
        }
        .map { $0 == 1 ? nil : $0 }
        .removeDuplicates()
        .filter { _ in true }
        .compactMap { .some($0) }
        .applying { OptionalStringReducer(received: received) }
      let subscription = try observation.subscribe(
        to: database,
        scheduling: .immediate,
        onError: { Issue.record($0) },
        onUpdate: { updates.append($0) }
      )
      defer { subscription.cancel() }
      try insertItemsBlocking(1, into: database)

      let replay = TestRecorder<String?>()
      let lateSubscription = try observation.subscribe(
        to: database,
        scheduling: .immediate,
        onError: { Issue.record($0) },
        onChange: { replay.append($0.value) }
      )
      defer { lateSubscription.cancel() }
      #expect(replay.values == [nil])
      for id in 2...4 { try insertItemsBlocking(id, into: database) }

      #expect(received.values == [nil, 2, 3, 4])
      #expect(replay.values == [nil, "2", "4"])
      #expect(
        updates.values == [
          .emitted(.init(value: nil, source: .initial)),
          .noEmission(source: .transaction(.local)),
          .emitted(.init(value: "2", source: .transaction(.local))),
          .noEmission(source: .transaction(.local)),
          .emitted(.init(value: "4", source: .transaction(.local)))
        ]
      )
    }

    private var counts: OrbitValueObservation<Int> {
      .tracking { transaction in
        try transaction.fetchOne(itemCountSQL) { Int($0[0].integerValue ?? 0) } ?? 0
      }
    }
  }

  private struct RunningTotal: OrbitValueObservationReducer {
    var total = 0

    mutating func reduce(_ value: Int) -> Int? {
      total += value
      return total
    }
  }

  private struct OptionalStringReducer: OrbitValueObservationReducer {
    let received: TestRecorder<Int?>

    func reduce(_ value: Int?) -> String?? {
      received.append(value)
      guard let value else { return .some(nil) }
      return value.isMultiple(of: 2) ? .some(String(value)) : nil
    }
  }
#endif
