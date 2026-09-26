#if canImport(SwiftUI)
  // Scoped, because SwiftUI vends a `Table` of its own and this file is about the other one.
  import protocol SwiftUI.DynamicProperty
  import struct SwiftUI.Animation
#endif

/// A property that observes a request or value observation against a database.
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
/// A configured value observation can be passed directly, preserving its operators and shared
/// runtime:
///
/// ```swift
/// let titles = OrbitValueObservation
///   .trackingAll(Reminder.order(by: \.title))
///   .map { $0.map(\.title) }
///   .removeDuplicates()
///
/// @Fetch(titles) var reminderTitles = [String]()
/// ```
///
/// The property is populated the first time it is read, and refetches whenever a committed write
/// touches anything its source read.
/// The database it reads from is resolved as ``OrbitDefaultDatabase`` describes: the `database`
/// argument first, then the SwiftUI environment, then the default.
/// A custom scheduler passed to this property must be `Hashable`; its equality defines when a
/// rebuilt property keeps its existing observation.
@dynamicMemberLookup
@propertyWrapper
public struct Fetch<Value: Sendable>: Sendable {
  @OrbitFetchState private var storage: OrbitFetchStorage<Value>

  private init(storage: OrbitFetchStorage<Value>) {
    _storage = OrbitFetchState(wrappedValue: storage)
  }

  /// The value the request or observation produced.
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

  /// Reads the observed request or observation again.
  ///
  /// A read that failed ended the subscription, so this also resumes it.
  ///
  /// - Throws: Whatever the read throws, which also becomes ``loadError``.
  public func load() async throws {
    try await storage.load()
  }

  /// Creates a property holding a value that no source keeps current.
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
  ///   - database: The database to read from, or `nil` to resolve one the way
  ///     ``OrbitDefaultDatabase`` describes.
  ///   - scheduler: Where values are delivered. By default they are delivered as they are
  ///     produced, and the first read happens before the property is first read.
  public init(
    wrappedValue: Value,
    _ request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler & Hashable)? = nil
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

  /// Creates a property subscribing to a value observation.
  ///
  /// Copies of one observation have one identity and keep the same subscription when SwiftUI
  /// rebuilds a view. Use the overload with an explicit `id` when the declaration constructs a
  /// new observation on each rebuild.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the observation's initial fetch finishes.
  ///   - observation: The observation to subscribe to without changing it.
  ///   - database: The database to observe, or `nil` to resolve one the way
  ///     ``OrbitDefaultDatabase`` describes.
  ///   - scheduler: Where values are delivered. By default they are delivered as they are
  ///     produced, and the initial fetch happens before the property is first read.
  public init(
    wrappedValue: Value,
    _ observation: OrbitValueObservation<Value>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler & Hashable)? = nil
  ) {
    self.init(
      storage: .make(
        value: wrappedValue,
        observation: observation,
        identity: .intrinsic(observation.identity),
        database: database,
        scheduler: scheduler
      )
    )
  }

  /// Creates a property subscribing to a value observation with a stable declaration identity.
  ///
  /// SwiftUI preserves the existing subscription while `id` is unchanged and replaces it with
  /// the newly declared observation when `id` changes.
  public init<ID: Hashable & Sendable>(
    wrappedValue: Value,
    _ observation: OrbitValueObservation<Value>,
    id: ID,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler & Hashable)? = nil
  ) {
    self.init(
      storage: .make(
        value: wrappedValue,
        observation: observation,
        identity: OrbitFetchObservationIdentity(id),
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
  ///   - database: The database to read from, or `nil` to resolve one the way
  ///     ``OrbitDefaultDatabase`` describes.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  public func load(
    _ request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler & Hashable)? = nil
  ) async throws -> OrbitFetchSubscription {
    try await storage.load(request: request, database: database, scheduler: scheduler)
  }

  /// Subscribes to a value observation from now on.
  ///
  /// The property keeps the value it has until the observation produces its own. When the
  /// observation suppresses its initial value, the load still completes and the existing value
  /// remains in place.
  @discardableResult
  public func load(
    _ observation: OrbitValueObservation<Value>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler & Hashable)? = nil
  ) async throws -> OrbitFetchSubscription {
    try await storage.load(
      observation: observation,
      identity: .intrinsic(observation.identity),
      database: database,
      scheduler: scheduler
    )
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
      _storage.reconcile()
    }

    /// Creates a property observing a request, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The value to hold until the first read finishes.
    ///   - request: The request to observe.
    ///   - database: The database to read from, or `nil` to resolve one the way
    ///     ``OrbitDefaultDatabase`` describes.
    ///   - animation: The animation applied to every change.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
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

    /// Creates a property subscribing to a value observation, delivering changes with an
    /// animation.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public init(
      wrappedValue: Value,
      _ observation: OrbitValueObservation<Value>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) {
      self.init(
        wrappedValue: wrappedValue,
        observation,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property subscribing to a value observation with a stable declaration identity,
    /// delivering changes with an animation.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public init<ID: Hashable & Sendable>(
      wrappedValue: Value,
      _ observation: OrbitValueObservation<Value>,
      id: ID,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) {
      self.init(
        wrappedValue: wrappedValue,
        observation,
        id: id,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different request from now on, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - request: The request to observe.
    ///   - database: The database to read from, or `nil` to resolve one the way
    ///     ``OrbitDefaultDatabase`` describes.
    ///   - animation: The animation applied to every change.
    /// - Returns: The observation this started.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
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

    /// Subscribes to a value observation from now on, delivering changes with an animation.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @discardableResult
    public func load(
      _ observation: OrbitValueObservation<Value>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription {
      try await load(
        observation,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }
  }
#endif
