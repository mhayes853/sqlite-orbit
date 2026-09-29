#if BuiltInSQLite && canImport(Observation)
  import Observation
  import StructuredQueriesSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct OrbitValueObservationExternalValueTests {
    struct Filters: Sendable {
      var usesPrimary = true
      var primary = 1
      var secondary = 10
    }

    /// The ways to change `primary` from 1 to 2 through its own member.
    enum MemberMutation: CaseIterable, Sendable {
      case assignment, modify, keyPathUpdate

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func apply(to filters: OrbitValueObservation<Never>.ExternalValue<Filters>) {
        switch self {
        case .assignment: filters.primary = 2
        case .modify: filters.primary += 1
        case .keyPathUpdate: filters.update(\.primary) { $0 += 1 }
        }
      }
    }

    /// The ways to change `primary` from 1 to 2 through the whole value.
    enum WholeValueMutation: CaseIterable, Sendable {
      case replacement, modify

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      func apply(to filters: OrbitValueObservation<Never>.ExternalValue<Filters>) {
        switch self {
        case .replacement: filters.value = Filters(primary: 2)
        case .modify: filters.value.primary += 1
        }
      }
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

    @Test(arguments: MemberMutation.allCases)
    func aMemberMutationInvalidatesOnlyThatMembersObservers(_ mutation: MemberMutation) {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let primaryChanges = TestCounter()
      let secondaryChanges = TestCounter()

      withObservationTracking {
        _ = filters.primary
      } onChange: {
        primaryChanges.increment()
      }
      withObservationTracking {
        _ = filters.secondary
      } onChange: {
        secondaryChanges.increment()
      }

      mutation.apply(to: filters)

      #expect(filters.primary == 2)
      #expect(primaryChanges.value == 1)
      #expect(secondaryChanges.value == 0)
    }

    @Test(arguments: WholeValueMutation.allCases)
    func aWholeValueMutationInvalidatesEveryMembersObservers(_ mutation: WholeValueMutation) {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let changes = TestCounter()

      // The member it changes is not the one observed, so only a whole-value change reaches it.
      withObservationTracking {
        _ = filters.secondary
      } onChange: {
        changes.increment()
      }

      mutation.apply(to: filters)

      #expect(filters.primary == 2)
      #expect(changes.value == 1)
    }

    @Test
    func wholeValueObservationTracksEveryMemberMutation() {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let changes = TestCounter()

      withObservationTracking {
        _ = filters.value
      } onChange: {
        changes.increment()
      }

      filters.secondary = 11
      #expect(changes.value == 1)
    }

    @Test
    func externalValueChangesRefetchAnObservation() async throws {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let driver = try SQLiteQueue(path: .memory)
      let external = OrbitValueObservation.ExternalValue(false)
      let changes = TestRecorder<OrbitValueObservationChange<Bool>>()
      let subscription = try OrbitValueObservation<Bool>
        .tracking { _ in external.value }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { change in changes.append(change) }
        )

      external.value = true
      try await changes.waitForCount(2)

      #expect(changes.values.map(\.value) == [false, true])
      #expect(changes.values.map(\.source) == [.initial, .observable])
      _ = subscription
    }

    @Test
    func manuallyImplementedSendableObservableChangesRefetchAnObservation() async throws {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let driver = try SQLiteQueue(path: .memory)
      let external = LockedObservableFlag(false)
      let values = TestRecorder<Bool>()
      let subscription = try OrbitValueObservation<Bool>
        .tracking(region: .empty) { _ in external.value }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { change in values.append(change.value) }
        )

      external.value = true
      try await values.waitForCount(2)

      #expect(values.values == [false, true])
      _ = subscription
    }

    @Test
    func anExternalChangeDuringAFetchDiscardsTheStaleResult() async throws {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let driver = try SQLiteQueue(path: .memory)
      let external = OrbitValueObservation.ExternalValue(0)
      let fetchCount = TestCounter()
      let values = TestRecorder<Int>()
      let secondFetch = TestGate()
      let subscription = try OrbitValueObservation<Int>
        .tracking { _ in
          let value = external.value
          let invocation = fetchCount.increment()
          if invocation == 2 {
            try secondFetch.enter()
          }
          return value
        }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { change in values.append(change.value) }
        )

      external.value = 1
      try await secondFetch.waitUntilEntered()
      external.value = 2
      secondFetch.open()
      try await values.waitForCount(2)

      #expect(values.values == [0, 2])
      #expect(fetchCount.value == 3)
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
      let fetchCount = TestCounter()
      let values = TestRecorder<Int>()
      let subscription = try OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.increment()
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
          onChange: { change in values.append(change.value) }
        )

      await #expect(throws: (any Error).self) {
        try await driver.write { transaction in
          try transaction.execute("UPDATE settings SET usesSecondary = 1")
          try transaction.execute("INSERT INTO children VALUES (1)")
        }
      }
      #expect(fetchCount.value == 2)
      #expect(values.values == [1])

      filters.secondary = 11
      #expect(fetchCount.value == 2)

      filters.primary = 2
      try await values.waitForCount(2)
      #expect(values.values == [1, 2])
      #expect(fetchCount.value == 3)
      _ = subscription
    }

    @Test
    func eachFetchReplacesItsExternalFieldDependencies() async throws {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { return }
      let driver = try SQLiteQueue(path: .memory)
      let filters = OrbitValueObservation.ExternalValue(Filters())
      let values = TestRecorder<Int>()
      let fetchCount = TestCounter()
      let subscription = try OrbitValueObservation<Int>
        .tracking { _ in
          fetchCount.increment()
          return filters.usesPrimary ? filters.primary : filters.secondary
        }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { change in values.append(change.value) }
        )

      filters.secondary = 11
      #expect(fetchCount.value == 1)

      filters.usesPrimary = false
      try await values.waitForCount(2)
      #expect(values.values == [1, 11])

      filters.primary = 2
      #expect(fetchCount.value == 2)

      filters.secondary = 12
      try await values.waitForCount(3)
      #expect(values.values == [1, 11, 12])
      #expect(fetchCount.value == 3)
      _ = subscription
    }
  }
#endif
