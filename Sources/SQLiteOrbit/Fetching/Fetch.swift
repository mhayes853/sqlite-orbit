#if canImport(SwiftUI)
  import SwiftUI
#endif

/// A property that observes whatever a request reads from a database.
///
/// ``FetchAll`` and ``FetchOne`` cover a single query. When a screen needs several, running them
/// in one transaction is what keeps them consistent with one another, and that is what a
/// ``OrbitFetchKeyRequest`` describes:
///
/// ```swift
/// struct RemindersOverview: OrbitFetchKeyRequest {
///   struct Value: Sendable {
///     var incompleteCount = 0
///     var newest: [Reminder] = []
///   }
///
///   func fetch(_ transaction: borrowing SQLiteReadTransaction) throws -> Value {
///     try Value(
///       incompleteCount: transaction.fetchCount(Reminder.where { !$0.isCompleted }),
///       newest: transaction.fetchAll(Reminder.order { $0.createdAt.desc() }.limit(10))
///     )
///   }
/// }
///
/// struct RemindersView: View {
///   @Fetch(RemindersOverview()) var overview = RemindersOverview.Value()
///
///   var body: some View {
///     Text("\(overview.incompleteCount) remaining")
///     ForEach(overview.newest, id: \.id) { reminder in Text(reminder.title) }
///   }
/// }
/// ```
///
/// The property is populated the first time it is read, and refetches whenever a committed write
/// touches anything the request read — every region of it, whichever query read it.
@dynamicMemberLookup
@propertyWrapper
public struct Fetch<Value: Sendable>: Sendable {
  #if canImport(SwiftUI)
    private let box: OrbitFetchStorage<Value>
    private let state: SwiftUI.State<OrbitFetchStorage<Value>>
    private let generation = SwiftUI.State(wrappedValue: 0)

    private var storage: OrbitFetchStorage<Value> { state.wrappedValue }
  #else
    private let storage: OrbitFetchStorage<Value>
  #endif

  private init(storage: OrbitFetchStorage<Value>) {
    #if canImport(SwiftUI)
      self.box = storage
      self.state = SwiftUI.State(wrappedValue: storage)
    #else
      self.storage = storage
    #endif
  }

  /// The value the request read.
  public var wrappedValue: Value {
    storage.value
  }

  /// Returns this property wrapper, which is how its ``isLoading``, ``loadError``, ``load()``,
  /// and member readers are reached.
  public var projectedValue: Self {
    get { self }
    nonmutating set { storage.adopt(from: newValue.storage) }
  }

  /// A read-only view onto the value.
  public var reader: OrbitFetchReader<Value> {
    OrbitFetchReader(storage)
  }

  /// Returns a reader of one member of the value.
  ///
  /// You do not call this subscript. Swift calls it when a member of the value is reached through
  /// the projected value, as in `$overview.incompleteCount`.
  public subscript<Member: Sendable>(
    dynamicMember keyPath: KeyPath<Value, Member>
  ) -> OrbitFetchReader<Member> {
    reader[dynamicMember: keyPath]
  }

  /// Whether a read is in flight.
  public var isLoading: Bool {
    storage.isLoading
  }

  /// The error the most recent read failed with, if it failed.
  ///
  /// A failed read leaves the value it last produced in place.
  public var loadError: (any Error)? {
    storage.loadError
  }

  /// The value as it stands, and every value the observation produces afterwards.
  public var values: OrbitFetchSequence<Value> {
    reader.values
  }

  /// Reads the observed request again.
  ///
  /// A read that failed ended the observation, so this also resumes it.
  ///
  /// - Throws: Whatever the read throws, which also becomes ``loadError``.
  public func load() async throws {
    try await storage.load()
  }

  /// Creates a property holding a value that no request keeps current.
  ///
  /// - Parameter wrappedValue: The value the property holds.
  @_disfavoredOverload
  public init(wrappedValue: Value) {
    self.init(storage: OrbitFetchStorage(value: wrappedValue))
  }

  /// Creates a property observing a request.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - request: The request to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered. By default they are delivered as they are
  ///     produced, and the first read happens before the property is first read.
  public init(
    wrappedValue: Value,
    _ request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) {
    self.init(
      storage: .make(
        value: wrappedValue,
        request: request,
        database: database,
        scheduler: scheduler
      )
    )
  }

  /// Observes a different request from now on.
  ///
  /// The property keeps the value it has until the new request produces its own.
  ///
  /// - Parameters:
  ///   - request: The request to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  public func load(
    _ request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription {
    try await storage.load(request: request, database: database, scheduler: scheduler)
  }
}

extension Fetch: CustomReflectable {
  /// A mirror reflecting the value.
  public var customMirror: Mirror {
    Mirror(reflecting: wrappedValue)
  }
}

extension Fetch: Equatable where Value: Equatable {
  /// Returns whether two properties hold the same value.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.wrappedValue == rhs.wrappedValue
  }
}

#if canImport(SwiftUI)
  extension Fetch: DynamicProperty {
    /// Reconciles the property SwiftUI built for this render with the one that survived the last.
    public func update() {
      let persisted = state.wrappedValue
      if persisted !== box {
        persisted.adoptIfNeeded(from: box)
      }
      persisted.observeForSwiftUI(generation: generation)
    }

    /// Creates a property observing a request, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The value to hold until the first read finishes.
    ///   - request: The request to observe.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    public init(
      wrappedValue: Value,
      _ request: some OrbitFetchKeyRequest<Value>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) {
      self.init(
        wrappedValue: wrappedValue,
        request,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different request from now on, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - request: The request to observe.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    /// - Returns: The observation this started.
    @discardableResult
    public func load(
      _ request: some OrbitFetchKeyRequest<Value>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription {
      try await load(
        request,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }
  }
#endif
