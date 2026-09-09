#if BuiltInSQLite && canImport(Observation)
  import Dispatch
  import Observation
  import StructuredQueriesSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct OrbitValueObservationExternalValueTests {
    private struct Filters: Sendable {
      var usesPrimary = true
      var primary = 1
      var secondary = 10
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private final class LockedObservableFlag: Observable, Sendable {
      private let registrar = ObservationRegistrar()
      private let storage: Lock<Bool>

      init(_ value: Bool) {
        self.storage = Lock(value)
      }

      var value: Bool {
        get {
          registrar.access(self, keyPath: \.value)
          return storage.withLock { $0 }
        }
        set {
          registrar.withMutation(of: self, keyPath: \.value) {
            storage.withLock { $0 = newValue }
          }
        }
      }
    }

    @Test
    func dynamicMemberObservationTracksOnlyTheAccessedField() {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let changes = Lock(0)

      withObservationTracking {
        _ = filters.primary
      } onChange: {
        changes.withLock { $0 += 1 }
      }

      filters.secondary = 11
      #expect(changes.withLock { $0 } == 0)

      filters.primary = 2
      #expect(changes.withLock { $0 } == 1)
    }

    @Test
    func wholeValueObservationTracksEveryMemberMutation() {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let changes = Lock(0)

      withObservationTracking {
        _ = filters.value
      } onChange: {
        changes.withLock { $0 += 1 }
      }

      filters.secondary = 11
      #expect(changes.withLock { $0 } == 1)
    }

    @Test
    func replacingTheWholeValueInvalidatesMemberObservation() {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let changes = Lock(0)

      withObservationTracking {
        _ = filters.primary
      } onChange: {
        changes.withLock { $0 += 1 }
      }

      filters.value = Filters(primary: 2)
      #expect(changes.withLock { $0 } == 1)
    }

    @Test
    func keyPathUpdateIsAtomicAndFieldSpecific() {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let primaryChanges = Lock(0)
      let secondaryChanges = Lock(0)

      withObservationTracking {
        _ = filters.primary
      } onChange: {
        primaryChanges.withLock { $0 += 1 }
      }
      withObservationTracking {
        _ = filters.secondary
      } onChange: {
        secondaryChanges.withLock { $0 += 1 }
      }

      filters.update(\.primary) { $0 += 1 }

      #expect(filters.primary == 2)
      #expect(primaryChanges.withLock { $0 } == 1)
      #expect(secondaryChanges.withLock { $0 } == 0)
    }

    @Test
    func modifyAccessorsPreserveObservationGranularity() {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let primaryChanges = Lock(0)
      let secondaryChanges = Lock(0)

      withObservationTracking {
        _ = filters.primary
      } onChange: {
        primaryChanges.withLock { $0 += 1 }
      }
      withObservationTracking {
        _ = filters.secondary
      } onChange: {
        secondaryChanges.withLock { $0 += 1 }
      }

      filters.primary += 1

      #expect(filters.primary == 2)
      #expect(primaryChanges.withLock { $0 } == 1)
      #expect(secondaryChanges.withLock { $0 } == 0)

      filters.value.primary += 1

      #expect(filters.primary == 3)
      #expect(secondaryChanges.withLock { $0 } == 1)
    }

    @Test
    func externalValueChangesRefetchAnObservation() async throws {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let driver = try SQLiteQueue(path: .memory)
      let external = OrbitValueObservation.ExternalValue(false)
      let changes = Lock([OrbitValueObservationChange<Bool>]())
      let subscription = try OrbitValueObservation<Bool>
        .tracking { _ in external.value }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { change in changes.withLock { $0.append(change) } }
        )

      external.value = true
      try await waitUntil(timeout: .seconds(5)) { changes.withLock { $0.count == 2 } }

      #expect(changes.withLock { $0.map(\.value) } == [false, true])
      #expect(changes.withLock { $0.map(\.source) } == [.initial, .observable])
      _ = subscription
    }

    @Test
    func manuallyImplementedSendableObservableChangesRefetchAnObservation() async throws {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let driver = try SQLiteQueue(path: .memory)
      let external = LockedObservableFlag(false)
      let values = Lock([Bool]())
      let subscription = try OrbitValueObservation<Bool>
        .tracking(region: .empty) { _ in external.value }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { change in values.withLock { $0.append(change.value) } }
        )

      external.value = true
      try await waitUntil(timeout: .seconds(5)) { values.withLock { $0.count == 2 } }

      #expect(values.withLock { $0 } == [false, true])
      _ = subscription
    }

    @Test
    func anExternalChangeDuringAFetchDiscardsTheStaleResult() async throws {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let driver = try SQLiteQueue(path: .memory)
      let external = OrbitValueObservation.ExternalValue(0)
      let fetchCount = Lock(0)
      let values = Lock([Int]())
      let secondFetchStarted = DispatchSemaphore(value: 0)
      let releaseSecondFetch = DispatchSemaphore(value: 0)
      let subscription = try OrbitValueObservation<Int>
        .tracking { _ in
          let value = external.value
          let invocation = fetchCount.withLock { count in
            count += 1
            return count
          }
          if invocation == 2 {
            secondFetchStarted.signal()
            releaseSecondFetch.wait()
          }
          return value
        }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { change in values.withLock { $0.append(change.value) } }
        )

      external.value = 1
      #expect(secondFetchStarted.blockingWait(timeout: .now() + 5) == .success)
      external.value = 2
      releaseSecondFetch.signal()
      try await waitUntil(timeout: .seconds(5)) { values.withLock { $0.count == 2 } }

      #expect(values.withLock { $0 } == [0, 2])
      #expect(fetchCount.withLock { $0 } == 3)
      _ = subscription
    }

    @Test
    func rolledBackLocalFetchPreservesTheActiveExternalDependencies() async throws {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute(
          """
          CREATE TABLE settings (usesSecondary INTEGER NOT NULL);
          INSERT INTO settings VALUES (0);
          CREATE TABLE parents (id INTEGER PRIMARY KEY);
          CREATE TABLE children (
            parent_id INTEGER NOT NULL REFERENCES parents(id)
              DEFERRABLE INITIALLY DEFERRED
          );
          """
        )
      }
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let fetchCount = Lock(0)
      let values = Lock([Int]())
      let subscription = try OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.withLock { $0 += 1 }
          let usesSecondary =
            try transaction.fetchOne(
              #sql("SELECT usesSecondary FROM settings", as: Bool.self)
            ) ?? false
          return usesSecondary ? filters.secondary : filters.primary
        }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { change in values.withLock { $0.append(change.value) } }
        )

      await #expect(throws: (any Error).self) {
        try await driver.write { transaction in
          try transaction.execute("UPDATE settings SET usesSecondary = 1")
          try transaction.execute("INSERT INTO children VALUES (1)")
        }
      }
      #expect(fetchCount.withLock { $0 } == 2)
      #expect(values.withLock { $0 } == [1])

      filters.secondary = 11
      #expect(fetchCount.withLock { $0 } == 2)

      filters.primary = 2
      try await waitUntil(timeout: .seconds(5)) { values.withLock { $0.count == 2 } }
      #expect(values.withLock { $0 } == [1, 2])
      #expect(fetchCount.withLock { $0 } == 3)
      _ = subscription
    }

    @Test
    func eachFetchReplacesItsExternalFieldDependencies() async throws {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let driver = try SQLiteQueue(path: .memory)
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let values = Lock([Int]())
      let fetchCount = Lock(0)
      let subscription = try OrbitValueObservation<Int>
        .tracking { _ in
          fetchCount.withLock { $0 += 1 }
          return filters.usesPrimary ? filters.primary : filters.secondary
        }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { change in values.withLock { $0.append(change.value) } }
        )

      filters.secondary = 11
      #expect(fetchCount.withLock { $0 } == 1)

      filters.usesPrimary = false
      try await waitUntil(timeout: .seconds(5)) { values.withLock { $0.count == 2 } }
      #expect(values.withLock { $0 } == [1, 11])

      filters.primary = 2
      #expect(fetchCount.withLock { $0 } == 2)

      filters.secondary = 12
      try await waitUntil(timeout: .seconds(5)) { values.withLock { $0.count == 3 } }
      #expect(values.withLock { $0 } == [1, 11, 12])
      #expect(fetchCount.withLock { $0 } == 3)
      _ = subscription
    }
  }
#endif
