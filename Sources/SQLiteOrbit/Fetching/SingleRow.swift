#if canImport(SwiftUI)
  import protocol SwiftUI.DynamicProperty
  import struct SwiftUI.Environment
  import struct SwiftUI.State
#endif

/// A property that observes and writes the singleton row of a ``SingleRowTable``.
///
/// An empty table reads as its ``SingleRowTable/defaultValue`` without inserting anything. The
/// first save inserts that value, and later saves update the same primary key:
///
/// ```swift
/// @SingleRow(Settings.self) var settings
///
/// try await $settings.update {
///   $0.notificationsEnabled = false
/// }
/// ```
///
/// The database is resolved exactly as it is for the fetch properties: an explicit `database`
/// argument first, then the SwiftUI environment, then ``OrbitDefaultDatabase``.
@propertyWrapper
public struct SingleRow<Value>: Sendable
where
  Value: SingleRowTable & Sendable,
  Value.PrimaryKey.QueryOutput: Equatable & Sendable
{
  #if canImport(SwiftUI)
    private let box: OrbitRowStorage<Value>
    private let state: SwiftUI.State<OrbitRowStorage<Value>>
    private let writeGeneration = SwiftUI.State(wrappedValue: 0)
    private let fetchGeneration = SwiftUI.State(wrappedValue: 0)
    @Environment(\.orbitDatabase) private var environmentDatabase

    private var storage: OrbitRowStorage<Value> { state.wrappedValue }
  #else
    private let storage: OrbitRowStorage<Value>
  #endif

  /// Creates a property observing this table's singleton row.
  public init(
    _ type: Value.Type,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler & Hashable)? = nil
  ) {
    let storage = OrbitRowStorage(
      fetch: .make(
        value: Value.defaultValue,
        request: OrbitFetchSingleRowRequest<Value>(),
        database: database,
        scheduler: scheduler
      )
    )
    #if canImport(SwiftUI)
      self.box = storage
      self.state = SwiftUI.State(wrappedValue: storage)
    #else
      self.storage = storage
    #endif
  }

  /// The persisted singleton, or its default when no row has been persisted.
  public var wrappedValue: Value { storage.value }

  /// Returns this property, which exposes its loading and saving operations and state.
  public var projectedValue: Self { self }

  /// A read-only view onto the value.
  public var reader: OrbitFetchReader<Value> { storage.reader }

  /// Whether a read is in flight.
  public var isLoading: Bool { storage.isLoading }

  /// The error the most recent read failed with, if it failed.
  public var loadError: (any Error)? { storage.loadError }

  /// Whether one or more saves are in flight.
  public var isSaving: Bool { storage.isSaving }

  /// The error the most recent save failed with, if it failed.
  public var saveError: (any Error)? { storage.saveError }

  /// Reads the singleton again.
  public func load() async throws {
    try await storage.load()
  }

  /// Persists a complete replacement for the singleton.
  ///
  /// - Throws: ``OrbitRowIdentityMismatchError`` when `value` does not have the default row's
  ///   primary key, or whatever opening or executing the transaction throws.
  public func save(_ value: Value) async throws {
    let expectedKey = Value.defaultValue.primaryKey
    guard value.primaryKey == expectedKey else {
      return try await storage.write { _ in throw OrbitRowIdentityMismatchError() }
    }
    try await storage.write { database in
      try await database.write { transaction in
        try transaction.execute(Value.upsert { Value.Draft(value) })
      }
    }
  }

  /// Mutates the latest persisted singleton inside one write transaction.
  ///
  /// When the table is empty, the mutation starts from ``SingleRowTable/defaultValue`` and inserts
  /// it. Reading immediately before changing it prevents a stale property value from overwriting a
  /// change another writer committed first.
  @discardableResult
  public func update<Result: Sendable>(
    _ mutation: @escaping @Sendable (inout Value) throws -> Result
  ) async throws -> Result {
    let expectedKey = Value.defaultValue.primaryKey
    return try await storage.write { database in
      try await database.write { transaction in
        let statement: Select<Value, Value, ()> = Value.all.selectStar()
        var value =
          try transaction.fetchOne(
            statement.find(Value.PrimaryKey(queryOutput: expectedKey))
          ) ?? Value.defaultValue
        let result = try mutation(&value)
        guard value.primaryKey == expectedKey else {
          throw OrbitRowIdentityMismatchError()
        }
        try transaction.execute(Value.upsert { Value.Draft(value) })
        return result
      }
    }
  }
}

private struct OrbitFetchSingleRowRequest<Value>: OrbitFetchKeyRequest
where
  Value: SingleRowTable & Sendable,
  Value.PrimaryKey.QueryOutput: Equatable & Sendable
{
  private let query: QueryFragment

  init() {
    let statement: Select<Value, Value, ()> = Value.all.selectStar()
    self.query =
      statement
      .find(Value.PrimaryKey(queryOutput: Value.defaultValue.primaryKey))
      .query
  }

  func fetch(_ transaction: borrowing SQLiteReadTransaction) throws -> Value {
    try transaction.fetchOne(SQLQueryExpression(query, as: Value.self)) ?? Value.defaultValue
  }
}

#if canImport(SwiftUI)
  extension SingleRow: DynamicProperty {
    public func update() {
      storage.fetch.update(
        declared: box.fetch,
        database: environmentDatabase,
        generation: fetchGeneration
      )
      observeWritesForSwiftUI()
    }

    private func observeWritesForSwiftUI() {
      guard #unavailable(iOS 17, macOS 14, tvOS 17, watchOS 10) else { return }
      _ = writeGeneration.wrappedValue
      nonisolated(unsafe) let generation = writeGeneration
      storage.setSwiftUIObservation(
        storage.addWriteObserver {
          Task { @MainActor in generation.wrappedValue &+= 1 }
        }
      )
    }
  }
#endif
