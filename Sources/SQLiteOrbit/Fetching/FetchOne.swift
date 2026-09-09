#if canImport(SwiftUI)
  // Scoped, because SwiftUI vends a `Table` of its own and this file is about the other one.
  import protocol SwiftUI.DynamicProperty
  import struct SwiftUI.Animation
  import struct SwiftUI.State
#endif

/// A property that observes a single value a query produces.
///
/// The property is populated the first time it is read, and refetches whenever a committed write
/// — from this process or another one sharing the database — touches anything the query read:
///
/// ```swift
/// @Table struct Reminder { let id: Int; var title: String; var isCompleted = false }
///
/// struct RemindersFooter: View {
///   @FetchOne(Reminder.where { !$0.isCompleted }.count()) var remaining = 0
///
///   var body: some View { Text("\(remaining) remaining") }
/// }
/// ```
///
/// A property whose value is not optional needs a value to hold until its first read finishes, and
/// a query that produces no row fails it with ``OrbitDatabaseRecordNotFoundError``, reported
/// through ``loadError``. Declare the value as optional to have an absent row be `nil` instead:
///
/// ```swift
/// @FetchOne(Reminder.find(id)) var reminder: Reminder?
/// ```
///
/// The database it reads from is ``OrbitDefaultDatabase/current`` unless one is passed as the
/// `database` argument.
@dynamicMemberLookup
@propertyWrapper
public struct FetchOne<Value: Sendable>: Sendable {
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

  private init(
    wrappedValue: Value,
    request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)?,
    scheduler: (any OrbitValueObservationScheduler)?
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

  /// The value the query produced.
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
  /// the projected value.
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

  /// Reads the observed query again.
  ///
  /// A read that failed ended the observation, so this also resumes it.
  ///
  /// - Throws: Whatever the read throws, which also becomes ``loadError``.
  public func load() async throws {
    try await storage.load()
  }

  // MARK: - Values without a query

  /// Creates a property holding a value that no query keeps current.
  ///
  /// - Parameter wrappedValue: The value the property holds.
  @_disfavoredOverload
  public init(wrappedValue: Value) {
    self.init(storage: OrbitFetchStorage(value: wrappedValue))
  }

  /// Creates a property holding a value that no query keeps current.
  ///
  /// A `@Selection` type describes the shape of a query's result rather than a table, so there is
  /// no query to derive from it. Pass one.
  ///
  /// - Parameter wrappedValue: The value the property holds.
  public init(wrappedValue: Value) where Value: _Selection, Value.QueryOutput == Value {
    self.init(storage: OrbitFetchStorage(value: wrappedValue))
  }

  @available(
    *,
    deprecated,
    message: """
      A '@Selection' type has no query of its own to fetch; pass one, or remove the unused \
      'database' and 'scheduler' arguments.
      """
  )
  public init(
    wrappedValue: Value,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Value: _Selection, Value.QueryOutput == Value {
    self.init(storage: OrbitFetchStorage(value: wrappedValue))
  }

  // MARK: - Tables

  /// Creates a property observing the first row of a table.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered. By default they are delivered as they are
  ///     produced, and the first read happens before the property is first read.
  public init(
    wrappedValue: Value,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Value: Table & QueryRepresentable, Value.QueryOutput == Value {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchOneStatementRequest<Value>(
        statement: Value.all.selectStar().asSelect().limit(1)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing the first row of a table, or `nil` when it has none.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init(
    wrappedValue: Value = ._none,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Value: _OptionalProtocol & Table, Value.QueryOutput == Value {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchOptionalProtocolStatementRequest<Value>(
        statement: Value.all.selectStar().asSelect().limit(1)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing the first row of a primary keyed table, or `nil` when it has
  /// none.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init(
    wrappedValue: Value = ._none,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Value: _OptionalProtocol & PrimaryKeyedTable, Value.QueryOutput == Value {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchOptionalProtocolStatementRequest<Value>(
        statement: Value.all.selectStar().asSelect().limit(1)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing the row the value it is declared with identifies.
  ///
  /// The primary key of `wrappedValue` is what the property looks up, so the property tracks that
  /// one row for as long as it exists:
  ///
  /// ```swift
  /// @FetchOne var reminder = Reminder(id: 42, title: "")
  /// ```
  ///
  /// - Parameters:
  ///   - wrappedValue: The row whose primary key identifies the row to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init(
    wrappedValue: Value,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Value: PrimaryKeyedTable & QueryRepresentable, Value.QueryOutput == Value {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchOneStatementRequest<Value>(
        statement: Value.all
          .selectStar()
          .asSelect()
          .find(Value.PrimaryKey(queryOutput: wrappedValue.primaryKey))
      ),
      database: database,
      scheduler: scheduler
    )
  }

  // MARK: - Queries

  /// Creates a property observing the first row a select statement produces.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<S: SelectStatement>(
    wrappedValue: Value,
    _ statement: S,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Value == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
    let statement: Select<S.From, S.From, ()> = statement.selectStar()
    self.init(
      wrappedValue: wrappedValue,
      statement.asSelect().limit(1),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing the first value a statement produces.
  ///
  /// ```swift
  /// @FetchOne(Reminder.all.count()) var count = 0
  /// ```
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<V: QueryRepresentable>(
    wrappedValue: Value,
    _ statement: some Statement<V>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Value == V.QueryOutput {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchOneStatementRequest<V>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing the first value a statement produces, or `nil` when it produces
  /// none.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<V: QueryRepresentable>(
    wrappedValue: Value = nil,
    _ statement: some Statement<V>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Value == V.QueryOutput? {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchOptionalStatementRequest<V>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing the first value a statement produces.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<S: Statement<Value>>(
    wrappedValue: Value,
    _ statement: S,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Value: QueryRepresentable, Value == S.QueryValue.QueryOutput {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchOneStatementRequest<Value>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing the first row a select statement produces, or `nil` when it
  /// produces none.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<S: SelectStatement>(
    wrappedValue: Value = ._none,
    _ statement: S,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  )
  where
    Value: _OptionalProtocol,
    Value == S.From.QueryOutput?,
    S.QueryValue == (),
    S.Joins == ()
  {
    let statement: Select<S.From, S.From, ()> = statement.selectStar()
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchOptionalStatementRequest<S.From>(
        statement: statement.asSelect().limit(1)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing the first value a statement of an optional produces.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<S: Statement>(
    wrappedValue: Value = ._none,
    _ statement: S,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  )
  where
    Value: _OptionalProtocol,
    S.QueryValue: QueryRepresentable & _OptionalProtocol,
    Value == S.QueryValue.QueryOutput
  {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchOptionalProtocolStatementRequest<S.QueryValue>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing the first value a statement of an optional produces.
  ///
  /// - Parameters:
  ///   - wrappedValue: The value to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init(
    wrappedValue: Value = ._none,
    _ statement: some Statement<Value>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Value: QueryRepresentable & _OptionalProtocol, Value.QueryOutput == Value {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchOptionalProtocolStatementRequest<Value>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }

  // MARK: - Replacing the query

  /// Observes the first row of a different select statement from now on.
  ///
  /// - Parameters:
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  public func load<S: SelectStatement>(
    _ statement: S,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription
  where Value == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
    let statement: Select<S.From, S.From, ()> = statement.selectStar()
    return try await load(
      statement.asSelect().limit(1),
      database: database,
      scheduler: scheduler
    )
  }

  /// Observes the first value of a different statement from now on.
  ///
  /// - Parameters:
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  public func load<V: QueryRepresentable>(
    _ statement: some Statement<V>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription
  where Value == V.QueryOutput {
    return try await storage.load(
      request: OrbitFetchOneStatementRequest<V>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }

  /// Observes the first value of a different statement from now on, or `nil` when it produces
  /// none.
  ///
  /// - Parameters:
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  public func load<V: QueryRepresentable>(
    _ statement: some Statement<V>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription
  where Value == V.QueryOutput? {
    return try await storage.load(
      request: OrbitFetchOptionalStatementRequest<V>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }

  /// Observes the first row of a different select statement from now on, or `nil` when it produces
  /// none.
  ///
  /// - Parameters:
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  public func load<S: SelectStatement>(
    _ statement: S,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription
  where
    Value: _OptionalProtocol,
    Value == S.From.QueryOutput?,
    S.QueryValue == (),
    S.Joins == ()
  {
    let statement: Select<S.From, S.From, ()> = statement.selectStar()
    return try await storage.load(
      request: OrbitFetchOptionalStatementRequest<S.From>(
        statement: statement.asSelect().limit(1)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Observes the first value of a different statement of an optional from now on.
  ///
  /// - Parameters:
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  public func load<S: Statement>(
    _ statement: S,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription
  where
    Value: _OptionalProtocol,
    S.QueryValue: QueryRepresentable & _OptionalProtocol,
    Value == S.QueryValue.QueryOutput
  {
    return try await storage.load(
      request: OrbitFetchOptionalProtocolStatementRequest<S.QueryValue>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }

  /// Observes the first value of a different statement of an optional from now on.
  ///
  /// - Parameters:
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  public func load(
    _ statement: some Statement<Value>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription
  where Value: QueryRepresentable & _OptionalProtocol, Value.QueryOutput == Value {
    return try await storage.load(
      request: OrbitFetchOptionalProtocolStatementRequest<Value>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }
}

extension FetchOne: CustomReflectable {
  /// A mirror reflecting the value.
  public var customMirror: Mirror {
    Mirror(reflecting: wrappedValue)
  }
}

extension FetchOne: Equatable where Value: Equatable {
  /// Returns whether two properties hold the same value.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.wrappedValue == rhs.wrappedValue
  }
}

#if canImport(SwiftUI)
  extension FetchOne: DynamicProperty {
    /// Reconciles the property SwiftUI built for this render with the one that survived the last.
    public func update() {
      let persisted = state.wrappedValue
      if persisted !== box {
        persisted.adoptIfNeeded(from: box)
      }
      persisted.observeForSwiftUI(generation: generation)
    }

    /// Creates a property observing the first row of a table, delivering changes with an
    /// animation.
    public init(
      wrappedValue: Value,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Value: Table & QueryRepresentable, Value.QueryOutput == Value {
      self.init(
        wrappedValue: wrappedValue,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing the row the value it is declared with identifies, delivering
    /// changes with an animation.
    public init(
      wrappedValue: Value,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Value: PrimaryKeyedTable & QueryRepresentable, Value.QueryOutput == Value {
      self.init(
        wrappedValue: wrappedValue,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing the first row of a table, delivering changes with an
    /// animation.
    public init(
      wrappedValue: Value = ._none,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Value: _OptionalProtocol & Table, Value.QueryOutput == Value {
      self.init(
        wrappedValue: wrappedValue,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing the first row of a primary keyed table, delivering changes
    /// with an animation.
    public init(
      wrappedValue: Value = ._none,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Value: _OptionalProtocol & PrimaryKeyedTable, Value.QueryOutput == Value {
      self.init(
        wrappedValue: wrappedValue,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a select statement, delivering changes with an animation.
    public init<S: SelectStatement>(
      wrappedValue: Value,
      _ statement: S,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Value == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a statement, delivering changes with an animation.
    public init<V: QueryRepresentable>(
      wrappedValue: Value,
      _ statement: some Statement<V>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Value == V.QueryOutput {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a statement, delivering changes with an animation.
    public init<V: QueryRepresentable>(
      wrappedValue: Value = nil,
      _ statement: some Statement<V>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Value == V.QueryOutput? {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a statement, delivering changes with an animation.
    public init<S: Statement<Value>>(
      wrappedValue: Value,
      _ statement: S,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Value: QueryRepresentable, Value == S.QueryValue.QueryOutput {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a select statement, delivering changes with an animation.
    public init<S: SelectStatement>(
      wrappedValue: Value = ._none,
      _ statement: S,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    )
    where
      Value: _OptionalProtocol,
      Value == S.From.QueryOutput?,
      S.QueryValue == (),
      S.Joins == ()
    {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a statement of an optional, delivering changes with an
    /// animation.
    public init<S: Statement>(
      wrappedValue: Value = ._none,
      _ statement: S,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    )
    where
      Value: _OptionalProtocol,
      S.QueryValue: QueryRepresentable & _OptionalProtocol,
      Value == S.QueryValue.QueryOutput
    {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a statement of an optional, delivering changes with an
    /// animation.
    public init(
      wrappedValue: Value = ._none,
      _ statement: some Statement<Value>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Value: QueryRepresentable & _OptionalProtocol, Value.QueryOutput == Value {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different select statement from now on, delivering changes with an animation.
    @discardableResult
    public func load<S: SelectStatement>(
      _ statement: S,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where Value == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
      try await load(
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different statement from now on, delivering changes with an animation.
    @discardableResult
    public func load<V: QueryRepresentable>(
      _ statement: some Statement<V>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where Value == V.QueryOutput {
      try await load(
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different statement from now on, delivering changes with an animation.
    @discardableResult
    public func load<V: QueryRepresentable>(
      _ statement: some Statement<V>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where Value == V.QueryOutput? {
      try await load(
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different select statement from now on, delivering changes with an animation.
    @discardableResult
    public func load<S: SelectStatement>(
      _ statement: S,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where
      Value: _OptionalProtocol,
      Value == S.From.QueryOutput?,
      S.QueryValue == (),
      S.Joins == ()
    {
      try await load(
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different statement of an optional from now on, delivering changes with an
    /// animation.
    @discardableResult
    public func load<S: Statement>(
      _ statement: S,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where
      Value: _OptionalProtocol,
      S.QueryValue: QueryRepresentable & _OptionalProtocol,
      Value == S.QueryValue.QueryOutput
    {
      try await load(
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different statement of an optional from now on, delivering changes with an
    /// animation.
    @discardableResult
    public func load(
      _ statement: some Statement<Value>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where Value: QueryRepresentable & _OptionalProtocol, Value.QueryOutput == Value {
      try await load(
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }
  }
#endif
