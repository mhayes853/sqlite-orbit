#if canImport(SwiftUI)
  // Scoped, because SwiftUI vends a `Table` of its own and this file is about the other one.
  import protocol SwiftUI.DynamicProperty
  import struct SwiftUI.Animation
  import struct SwiftUI.State
#endif

/// A property that observes every row a query produces.
///
/// The property is populated the first time it is read, and refetches whenever a committed write
/// — from this process or another one sharing the database — touches anything the query read:
///
/// ```swift
/// @Table struct Reminder { let id: Int; var title: String; var isCompleted = false }
///
/// struct RemindersView: View {
///   @FetchAll(Reminder.where { !$0.isCompleted }.order(by: \.title)) var reminders
///
///   var body: some View {
///     List(reminders, id: \.id) { reminder in Text(reminder.title) }
///   }
/// }
/// ```
///
/// Declared without a query, it fetches every row of its element's table:
///
/// ```swift
/// @FetchAll var reminders: [Reminder]
/// ```
///
/// The database it reads from is ``OrbitDefaultDatabase/current`` unless one is passed as the
/// `database` argument. The projected value reaches the rest of the property — its
/// ``isLoading`` and ``loadError``, a reader for one of its members, and ``load(_:database:)``,
/// which swaps the query being observed:
///
/// ```swift
/// try await $reminders.load(Reminder.order { $0.createdAt.desc() })
/// ```
@dynamicMemberLookup
@propertyWrapper
public struct FetchAll<Element: Sendable>: Sendable {
  #if canImport(SwiftUI)
    private let box: OrbitFetchStorage<OrbitFetchSectionCollection<Element, String?>>
    private let state:
      SwiftUI.State<OrbitFetchStorage<OrbitFetchSectionCollection<Element, String?>>>
    private let generation = SwiftUI.State(wrappedValue: 0)

    var storage: OrbitFetchStorage<OrbitFetchSectionCollection<Element, String?>> {
      state.wrappedValue
    }
  #else
    let storage: OrbitFetchStorage<OrbitFetchSectionCollection<Element, String?>>
  #endif

  init(storage: OrbitFetchStorage<OrbitFetchSectionCollection<Element, String?>>) {
    #if canImport(SwiftUI)
      self.box = storage
      self.state = SwiftUI.State(wrappedValue: storage)
    #else
      self.storage = storage
    #endif
  }

  init(
    wrappedValue: [Element],
    request: some OrbitFetchKeyRequest<OrbitFetchSectionCollection<Element, String?>>,
    database: (any OrbitObservableDatabase)?,
    scheduler: (any OrbitValueObservationScheduler)?
  ) {
    self.init(
      storage: .make(
        value: OrbitFetchSectionCollection(elements: wrappedValue, sectionName: nil),
        request: request,
        database: database,
        scheduler: scheduler
      )
    )
  }

  /// The rows the query produced.
  public var wrappedValue: [Element] {
    storage.value.elements
  }

  /// Returns this property wrapper, which is how its ``isLoading``, ``loadError``, ``load()``,
  /// and member readers are reached.
  public var projectedValue: Self {
    get { self }
    nonmutating set { storage.adopt(from: newValue.storage) }
  }

  /// A read-only view onto the rows.
  public var reader: OrbitFetchReader<[Element]> {
    let storage = self.storage
    return OrbitFetchReader(
      storage: storage,
      tracked: { storage.value.elements },
      untracked: { storage.untrackedValue.elements }
    )
  }

  /// A read-only view onto the sections.
  public var sectionsReader: OrbitFetchReader<OrbitFetchSectionCollection<Element, String?>> {
    OrbitFetchReader(storage)
  }

  /// Returns a reader of one member of the rows.
  ///
  /// You do not call this subscript. Swift calls it when a member of the collection is reached
  /// through the projected value, as in `$reminders.count`.
  public subscript<Member: Sendable>(
    dynamicMember keyPath: KeyPath<[Element], Member>
  ) -> OrbitFetchReader<Member> {
    reader[dynamicMember: keyPath]
  }

  /// Whether a read is in flight.
  public var isLoading: Bool {
    storage.isLoading
  }

  /// The error the most recent read failed with, if it failed.
  ///
  /// A failed read leaves the rows it last produced in place.
  public var loadError: (any Error)? {
    storage.loadError
  }

  /// The rows as they stand, and every set of rows the observation produces afterwards.
  public var values: OrbitFetchSequence<[Element]> {
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

  /// Creates a property holding rows that no query keeps current.
  ///
  /// - Parameter wrappedValue: The rows the property holds.
  @_disfavoredOverload
  public init(wrappedValue: [Element] = []) {
    self.init(
      storage: OrbitFetchStorage(
        value: OrbitFetchSectionCollection(elements: wrappedValue, sectionName: nil)
      )
    )
  }

  /// Creates a property holding rows that no query keeps current.
  ///
  /// A `@Selection` type describes the shape of a query's result rather than a table, so there is
  /// no query to derive from it. Pass one.
  ///
  /// - Parameter wrappedValue: The rows the property holds.
  public init(wrappedValue: [Element] = [])
  where Element: _Selection, Element.QueryOutput == Element {
    self.init(
      storage: OrbitFetchStorage(
        value: OrbitFetchSectionCollection(elements: wrappedValue, sectionName: nil)
      )
    )
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
    wrappedValue: [Element] = [],
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  )
  where Element: _Selection, Element.QueryOutput == Element {
    self.init(
      storage: OrbitFetchStorage(
        value: OrbitFetchSectionCollection(elements: wrappedValue, sectionName: nil)
      )
    )
  }

  // MARK: - Queries

  /// Creates a property observing every row of a table.
  ///
  /// ```swift
  /// @FetchAll var reminders: [Reminder]
  /// ```
  ///
  /// - Parameters:
  ///   - wrappedValue: The rows to hold until the first read finishes.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered. By default they are delivered as they are
  ///     produced, and the first read happens before the property is first read.
  public init(
    wrappedValue: [Element] = [],
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  )
  where Element: Table, Element.QueryOutput == Element {
    self.init(
      wrappedValue: wrappedValue,
      Element.all.selectStar().asSelect(),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing every row a select statement produces.
  ///
  /// ```swift
  /// @FetchAll(Reminder.where { !$0.isCompleted }) var reminders
  /// ```
  ///
  /// - Parameters:
  ///   - wrappedValue: The rows to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<S: SelectStatement>(
    wrappedValue: [Element] = [],
    _ statement: S,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  )
  where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
    let statement: Select<S.From, S.From, ()> = statement.selectStar()
    self.init(
      wrappedValue: wrappedValue,
      statement,
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing every value a statement produces.
  ///
  /// ```swift
  /// @FetchAll(Reminder.select(\.title)) var titles
  /// @FetchAll(#sql("SELECT title FROM reminders", as: String.self)) var titles
  /// ```
  ///
  /// - Parameters:
  ///   - wrappedValue: The values to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<V: QueryRepresentable>(
    wrappedValue: [Element] = [],
    _ statement: some Statement<V>,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  )
  where Element == V.QueryOutput {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchAllStatementRequest<V>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing every value a statement produces.
  ///
  /// - Parameters:
  ///   - wrappedValue: The values to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<S: Statement<Element>>(
    wrappedValue: [Element] = [],
    _ statement: S,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  )
  where Element: QueryRepresentable, Element == S.QueryValue.QueryOutput {
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchAllStatementRequest<Element>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }

  // MARK: - Replacing the query

  /// Observes a different select statement from now on.
  ///
  /// The property keeps the rows it has until the new statement produces its own.
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
  where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
    let statement: Select<S.From, S.From, ()> = statement.selectStar()
    return try await load(statement, database: database, scheduler: scheduler)
  }

  /// Observes a different statement from now on.
  ///
  /// ```swift
  /// try await $reminders.load(Reminder.order { $0.createdAt.desc() })
  /// ```
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
  where Element == V.QueryOutput {
    return try await storage.load(
      request: OrbitFetchAllStatementRequest<V>(statement: statement),
      database: database,
      scheduler: scheduler
    )
  }
}

extension FetchAll: CustomReflectable {
  /// A mirror reflecting the rows.
  public var customMirror: Mirror {
    Mirror(reflecting: wrappedValue)
  }
}

extension FetchAll: Equatable where Element: Equatable {
  /// Returns whether two properties hold the same rows.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.wrappedValue == rhs.wrappedValue
  }
}

#if canImport(SwiftUI)
  extension FetchAll: DynamicProperty {
    /// Reconciles the property SwiftUI built for this render with the one that survived the last.
    public func update() {
      let persisted = state.wrappedValue
      if persisted !== box {
        persisted.adoptIfNeeded(from: box)
      }
      persisted.observeForSwiftUI(generation: generation)
    }

    /// Creates a property observing every row of a table, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The rows to hold until the first read finishes.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    public init(
      wrappedValue: [Element] = [],
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    )
    where Element: Table, Element.QueryOutput == Element {
      self.init(
        wrappedValue: wrappedValue,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a select statement, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The rows to hold until the first read finishes.
    ///   - statement: The statement to observe.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    public init<S: SelectStatement>(
      wrappedValue: [Element] = [],
      _ statement: S,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    )
    where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a statement, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The values to hold until the first read finishes.
    ///   - statement: The statement to observe.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    public init<V: QueryRepresentable>(
      wrappedValue: [Element] = [],
      _ statement: some Statement<V>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    )
    where Element == V.QueryOutput {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a statement, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The values to hold until the first read finishes.
    ///   - statement: The statement to observe.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    public init<S: Statement<Element>>(
      wrappedValue: [Element] = [],
      _ statement: S,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    )
    where Element: QueryRepresentable, Element == S.QueryValue.QueryOutput {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different select statement from now on, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - statement: The statement to observe.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    /// - Returns: The observation this started.
    @discardableResult
    public func load<S: SelectStatement>(
      _ statement: S,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
      try await load(
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different statement from now on, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - statement: The statement to observe.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    /// - Returns: The observation this started.
    @discardableResult
    public func load<V: QueryRepresentable>(
      _ statement: some Statement<V>,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where Element == V.QueryOutput {
      try await load(
        statement,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }
  }
#endif
