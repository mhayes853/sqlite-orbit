#if canImport(SwiftUI)
  import protocol SwiftUI.DynamicProperty
  import struct SwiftUI.Environment
  import struct SwiftUI.State
#endif

/// A property that observes and writes one primary-keyed table row.
///
/// The primary key is fixed for the property's lifetime, which gives its read and write sides one
/// coherent identity. A missing row is `nil`; saving updates an existing row and never silently
/// recreates one that was deleted:
///
/// ```swift
/// @Row(Reminder.self, id: 42) var reminder: Reminder?
///
/// try await $reminder.update { $0.title = "Buy oat milk" }
/// try await $reminder.delete()
/// ```
///
/// The database is resolved exactly as it is for the fetch properties: an explicit `database`
/// argument first, then the SwiftUI environment, then ``OrbitDefaultDatabase``.
@propertyWrapper
public struct Row<Value>: Sendable
where
  Value: PrimaryKeyedTable & Sendable,
  Value.QueryOutput == Value,
  Value.PrimaryKey.QueryOutput: Equatable & Sendable
{
  private let primaryKey: Value.PrimaryKey.QueryOutput

  #if canImport(SwiftUI)
    private let box: OrbitRowStorage<Value?>
    private let state: SwiftUI.State<OrbitRowStorage<Value?>>
    private let writeGeneration = SwiftUI.State(wrappedValue: 0)
    private let fetchGeneration = SwiftUI.State(wrappedValue: 0)
    @Environment(\.orbitDatabase) private var environmentDatabase
    private var defaultDatabase = OrbitDefaultDatabaseSource()

    private var storage: OrbitRowStorage<Value?> { state.wrappedValue }
  #else
    private let storage: OrbitRowStorage<Value?>
  #endif

  /// Creates a property observing the row with `primaryKey`.
  public init(
    _ type: Value.Type,
    id primaryKey: Value.PrimaryKey.QueryOutput,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler & Hashable)? = nil
  ) {
    self.primaryKey = primaryKey
    let statement: Select<Value, Value, ()> = Value.all.selectStar()
    let storage = OrbitRowStorage(
      fetch: .make(
        value: nil,
        request: OrbitFetchOptionalStatementRequest<Value>(
          statement: statement.find(Value.PrimaryKey(queryOutput: primaryKey))
        ),
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

  /// The observed row, or `nil` when it does not exist.
  public var wrappedValue: Value? { storage.value }

  /// Returns this property, which exposes its loading and saving operations and state.
  public var projectedValue: Self { self }

  /// A read-only view onto the optional row.
  public var reader: OrbitFetchReader<Value?> { storage.reader }

  /// Whether a read is in flight.
  public var isLoading: Bool { storage.isLoading }

  /// The error the most recent read failed with, if it failed.
  public var loadError: (any Error)? { storage.loadError }

  /// Whether one or more saves are in flight.
  public var isSaving: Bool { storage.isSaving }

  /// The error the most recent save failed with, if it failed.
  public var saveError: (any Error)? { storage.saveError }

  /// Reads the row again.
  public func load() async throws {
    try await storage.load()
  }

  /// Replaces the existing row.
  ///
  /// This does not insert a missing row. Insertion is deliberately kept explicit so that an edit
  /// racing a deletion cannot unexpectedly resurrect the row.
  ///
  /// - Throws: ``OrbitRowIdentityMismatchError`` when `value` has a different primary key,
  ///   ``OrbitDatabaseRecordNotFoundError`` when the row is missing, or whatever executing the
  ///   transaction throws.
  public func save(_ value: Value) async throws {
    let primaryKey = self.primaryKey
    guard value.primaryKey == primaryKey else {
      return try await storage.write { _ in throw OrbitRowIdentityMismatchError() }
    }
    try await storage.write { database in
      try await database.write { transaction in
        try transaction.execute(Value.update(value))
        guard transaction.changesCount == 1 else {
          throw OrbitDatabaseRecordNotFoundError()
        }
      }
    }
  }

  /// Mutates the latest version of the row inside one write transaction.
  ///
  /// Reading immediately before changing it prevents a stale property value from overwriting a
  /// change another writer committed first.
  @discardableResult
  public func update<Result: Sendable>(
    _ mutation: @escaping @Sendable (inout Value) throws -> Result
  ) async throws -> Result {
    let primaryKey = self.primaryKey
    return try await storage.write { database in
      try await database.write { transaction in
        var value = try transaction.find(
          Value.all,
          key: Value.PrimaryKey(queryOutput: primaryKey)
        )
        let result = try mutation(&value)
        guard value.primaryKey == primaryKey else {
          throw OrbitRowIdentityMismatchError()
        }
        try transaction.execute(Value.update(value))
        guard transaction.changesCount == 1 else {
          throw OrbitDatabaseRecordNotFoundError()
        }
        return result
      }
    }
  }

  /// Deletes the row.
  ///
  /// - Throws: ``OrbitDatabaseRecordNotFoundError`` when it is already missing, or whatever
  ///   executing the transaction throws.
  public func delete() async throws {
    let primaryKey = self.primaryKey
    try await storage.write { database in
      try await database.write { transaction in
        try transaction.execute(
          Value.find(Value.PrimaryKey(queryOutput: primaryKey)).delete()
        )
        guard transaction.changesCount == 1 else {
          throw OrbitDatabaseRecordNotFoundError()
        }
      }
    }
  }

  @MainActor
  func updateBlocking<Result: Sendable>(
    _ mutation: @escaping @Sendable (inout Value) throws -> Result
  ) throws -> Result {
    let primaryKey = self.primaryKey
    return try storage.writeBlocking { database in
      try database.writeBlocking { transaction in
        var value = try transaction.find(
          Value.all,
          key: Value.PrimaryKey(queryOutput: primaryKey)
        )
        let result = try mutation(&value)
        guard value.primaryKey == primaryKey else {
          throw OrbitRowIdentityMismatchError()
        }
        try transaction.execute(Value.update(value))
        guard transaction.changesCount == 1 else {
          throw OrbitDatabaseRecordNotFoundError()
        }
        return result
      }
    }
  }
}

#if canImport(SwiftUI)
  extension Row: DynamicProperty {
    public func update() {
      storage.fetch.update(
        declared: box.fetch,
        database: environmentDatabase ?? defaultDatabase.currentIfConfigured,
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
