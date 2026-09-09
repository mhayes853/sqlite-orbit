#if canImport(SwiftUI)
  // Scoped, because SwiftUI vends a `Table` of its own and this file is about the other one.
  import struct SwiftUI.Animation
#endif

extension FetchAll {
  /// The rows, grouped into sections.
  ///
  /// A property built with a `sectionBy:` expression groups its rows by it. One built without
  /// still has sections: a single one, named `nil`, holding every row.
  ///
  /// ```swift
  /// @FetchAll(Reminder.order(by: \.title), sectionBy: \.priority) var reminders
  ///
  /// var body: some View {
  ///   List {
  ///     ForEach($reminders.sections) { section in
  ///       Section(section.name ?? "None") {
  ///         ForEach(section, id: \.id) { reminder in Text(reminder.title) }
  ///       }
  ///     }
  ///   }
  /// }
  /// ```
  public var sections: OrbitFetchSectionCollection<Element, String?> {
    storage.value
  }

  /// Creates a property observing every row of a table, grouped into sections.
  ///
  /// Rows are ordered by `sectioning` and grouped into one section per distinct value of it. The
  /// expression is evaluated by the database, and its value as text names the section. A closure
  /// that returns `nil` groups nothing, leaving one section of every row.
  ///
  /// ```swift
  /// @FetchAll(sectionBy: \.priority) var reminders: [Reminder]
  /// ```
  ///
  /// - Parameters:
  ///   - wrappedValue: The rows to hold until the first read finishes.
  ///   - sectioning: The expression, or an ordering of one, to group rows by.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init(
    wrappedValue: [Element] = [],
    @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (Element.TableColumns) ->
      _OrbitFetchSectioning<String?>?,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Element: Table, Element.QueryOutput == Element {
    guard let sectioning = sectioning(Element.columns) else {
      self.init(wrappedValue: wrappedValue, database: database, scheduler: scheduler)
      return
    }
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchSectionedStatementRequest<Element, String?>(
        query: orbitSectionedQuery(Element.all.asSelect(), sectionBy: sectioning)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing a select statement, grouped into sections.
  ///
  /// ```swift
  /// @FetchAll(Reminder.order(by: \.title), sectionBy: \.priority) var reminders
  /// ```
  ///
  /// - Parameters:
  ///   - wrappedValue: The rows to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - sectioning: The expression, or an ordering of one, to group rows by.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<S: SelectStatement>(
    wrappedValue: [Element] = [],
    _ statement: S,
    @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (S.From.TableColumns) ->
      _OrbitFetchSectioning<String?>?,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
    guard let sectioning = sectioning(S.From.columns) else {
      self.init(wrappedValue: wrappedValue, statement, database: database, scheduler: scheduler)
      return
    }
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchSectionedStatementRequest<S.From, String?>(
        query: orbitSectionedQuery(statement, sectionBy: sectioning)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing a statement with joins, grouped by an expression of its `FROM`
  /// table.
  ///
  /// - Parameters:
  ///   - wrappedValue: The rows to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - sectioning: The expression, or an ordering of one, to group rows by.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public init<V: QueryRepresentable, From: Table, each J: Table>(
    wrappedValue: [Element] = [],
    _ statement: Select<V, From, (repeat each J)>,
    @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (From.TableColumns) ->
      _OrbitFetchSectioning<String?>?,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Element == V.QueryOutput {
    guard let sectioning = sectioning(From.columns) else {
      self.init(wrappedValue: wrappedValue, statement, database: database, scheduler: scheduler)
      return
    }
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchSectionedStatementRequest<V, String?>(
        query: orbitSectionedQuery(statement, sectionBy: sectioning)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing a statement with joins, grouped by an expression of any of its
  /// tables.
  ///
  /// - Parameters:
  ///   - wrappedValue: The rows to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - sectioning: The expression, or an ordering of one, to group rows by.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public init<V: QueryRepresentable, From: Table, J1: Table, each J2: Table>(
    wrappedValue: [Element] = [],
    _ statement: Select<V, From, (J1, repeat each J2)>,
    @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (
      From.TableColumns, J1.TableColumns, repeat (each J2).TableColumns
    ) -> _OrbitFetchSectioning<String?>?,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Element == V.QueryOutput {
    guard
      let sectioning = sectioning(From.columns, J1.columns, repeat (each J2).columns)
    else {
      self.init(wrappedValue: wrappedValue, statement, database: database, scheduler: scheduler)
      return
    }
    self.init(
      wrappedValue: wrappedValue,
      request: OrbitFetchSectionedStatementRequest<V, String?>(
        query: orbitSectionedQuery(statement, sectionBy: sectioning)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Observes a different select statement from now on, grouped into sections.
  ///
  /// - Parameters:
  ///   - statement: The statement to observe.
  ///   - sectioning: The expression, or an ordering of one, to group rows by.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  public func load<S: SelectStatement>(
    _ statement: S,
    @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (S.From.TableColumns) ->
      _OrbitFetchSectioning<String?>?,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription
  where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
    guard let sectioning = sectioning(S.From.columns) else {
      return try await load(statement, database: database, scheduler: scheduler)
    }
    return try await storage.load(
      request: OrbitFetchSectionedStatementRequest<S.From, String?>(
        query: orbitSectionedQuery(statement, sectionBy: sectioning)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Observes a different statement with joins from now on, grouped by an expression of its
  /// `FROM` table.
  ///
  /// - Parameters:
  ///   - statement: The statement to observe.
  ///   - sectioning: The expression, or an ordering of one, to group rows by.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @discardableResult
  public func load<V: QueryRepresentable, From: Table, each J: Table>(
    _ statement: Select<V, From, (repeat each J)>,
    @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (From.TableColumns) ->
      _OrbitFetchSectioning<String?>?,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription
  where Element == V.QueryOutput {
    guard let sectioning = sectioning(From.columns) else {
      return try await load(statement, database: database, scheduler: scheduler)
    }
    return try await storage.load(
      request: OrbitFetchSectionedStatementRequest<V, String?>(
        query: orbitSectionedQuery(statement, sectionBy: sectioning)
      ),
      database: database,
      scheduler: scheduler
    )
  }

  /// Observes a different statement with joins from now on, grouped by an expression of any of
  /// its tables.
  ///
  /// - Parameters:
  ///   - statement: The statement to observe.
  ///   - sectioning: The expression, or an ordering of one, to group rows by.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @discardableResult
  public func load<V: QueryRepresentable, From: Table, J1: Table, each J2: Table>(
    _ statement: Select<V, From, (J1, repeat each J2)>,
    @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (
      From.TableColumns, J1.TableColumns, repeat (each J2).TableColumns
    ) -> _OrbitFetchSectioning<String?>?,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription
  where Element == V.QueryOutput {
    guard
      let sectioning = sectioning(From.columns, J1.columns, repeat (each J2).columns)
    else {
      return try await load(statement, database: database, scheduler: scheduler)
    }
    return try await storage.load(
      request: OrbitFetchSectionedStatementRequest<V, String?>(
        query: orbitSectionedQuery(statement, sectionBy: sectioning)
      ),
      database: database,
      scheduler: scheduler
    )
  }
  /// Creates a property observing every row of a table, grouped by one of its columns.
  ///
  /// ```swift
  /// @FetchAll(sectionBy: \.priority) var reminders: [Reminder]
  /// ```
  ///
  /// - Parameters:
  ///   - wrappedValue: The rows to hold until the first read finishes.
  ///   - sectionKeyPath: A key path to the column to group rows by.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init(
    wrappedValue: [Element] = [],
    sectionBy sectionKeyPath: KeyPath<
      Element.TableColumns, some QueryExpression<some _OptionalPromotable<String?>>
    >,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Element: Table, Element.QueryOutput == Element {
    self.init(
      wrappedValue: wrappedValue,
      sectionBy: { $0[keyPath: sectionKeyPath] },
      database: database,
      scheduler: scheduler
    )
  }

  /// Creates a property observing a select statement, grouped by one of its table's columns.
  ///
  /// ```swift
  /// @FetchAll(Reminder.order(by: \.title), sectionBy: \.priority) var reminders
  /// ```
  ///
  /// - Parameters:
  ///   - wrappedValue: The rows to hold until the first read finishes.
  ///   - statement: The statement to observe.
  ///   - sectionKeyPath: A key path to the column to group rows by.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  public init<S: SelectStatement>(
    wrappedValue: [Element] = [],
    _ statement: S,
    sectionBy sectionKeyPath: KeyPath<
      S.From.TableColumns, some QueryExpression<some _OptionalPromotable<String?>>
    >,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
    self.init(
      wrappedValue: wrappedValue,
      statement,
      sectionBy: { $0[keyPath: sectionKeyPath] },
      database: database,
      scheduler: scheduler
    )
  }

  /// Observes a different select statement from now on, grouped by one of its table's columns.
  ///
  /// - Parameters:
  ///   - statement: The statement to observe.
  ///   - sectionKeyPath: A key path to the column to group rows by.
  ///   - database: The database to read from, or `nil` to read from
  ///     ``OrbitDefaultDatabase/current``.
  ///   - scheduler: Where values are delivered.
  /// - Returns: The observation this started.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  public func load<S: SelectStatement>(
    _ statement: S,
    sectionBy sectionKeyPath: KeyPath<
      S.From.TableColumns, some QueryExpression<some _OptionalPromotable<String?>>
    >,
    database: (any OrbitObservableDatabase)? = nil,
    scheduler: (any OrbitValueObservationScheduler)? = nil
  ) async throws -> OrbitFetchSubscription
  where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
    try await load(
      statement,
      sectionBy: { $0[keyPath: sectionKeyPath] },
      database: database,
      scheduler: scheduler
    )
  }
}

/// Rewrites a select statement to order by the section expression and select it alongside every
/// column of the statement's table.
private func orbitSectionedQuery<S: SelectStatement>(
  _ statement: S,
  sectionBy sectioning: _OrbitFetchSectioning<String?>
) -> QueryFragment where S.QueryValue == (), S.Joins == () {
  let sectioned: Select<(S.From, String?), S.From, ()> =
    orbitSectionedColumns(of: S.From.self, sectioning) + statement.asSelect()
  return sectioned.query
}

/// Rewrites a statement to order by the section expression and select it alongside its own
/// columns.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
private func orbitSectionedQuery<V: QueryRepresentable, From: Table, each J: Table>(
  _ statement: Select<V, From, (repeat each J)>,
  sectionBy sectioning: _OrbitFetchSectioning<String?>
) -> QueryFragment {
  let ordered: Select<V, From, (repeat each J)> =
    orbitSectionedOrder(of: From.self, sectioning) + statement
  let sectioned: Select<(V, String?), From, (repeat each J)> =
    ordered + orbitSectionedColumn(of: From.self, sectioning)
  return sectioned.query
}

#if canImport(SwiftUI)
  extension FetchAll {
    /// Creates a property observing every row of a table, grouped into sections, delivering
    /// changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The rows to hold until the first read finishes.
    ///   - sectioning: The expression, or an ordering of one, to group rows by.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    public init(
      wrappedValue: [Element] = [],
      @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (Element.TableColumns) ->
        _OrbitFetchSectioning<String?>?,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Element: Table, Element.QueryOutput == Element {
      self.init(
        wrappedValue: wrappedValue,
        sectionBy: sectioning,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing every row of a table, grouped by one of its columns,
    /// delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The rows to hold until the first read finishes.
    ///   - sectionKeyPath: A key path to the column to group rows by.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    public init(
      wrappedValue: [Element] = [],
      sectionBy sectionKeyPath: KeyPath<
        Element.TableColumns, some QueryExpression<some _OptionalPromotable<String?>>
      >,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Element: Table, Element.QueryOutput == Element {
      self.init(
        wrappedValue: wrappedValue,
        sectionBy: sectionKeyPath,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a select statement, grouped into sections, delivering changes
    /// with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The rows to hold until the first read finishes.
    ///   - statement: The statement to observe.
    ///   - sectioning: The expression, or an ordering of one, to group rows by.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    public init<S: SelectStatement>(
      wrappedValue: [Element] = [],
      _ statement: S,
      @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (S.From.TableColumns) ->
        _OrbitFetchSectioning<String?>?,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        sectionBy: sectioning,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a select statement, grouped by one of its table's columns,
    /// delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The rows to hold until the first read finishes.
    ///   - statement: The statement to observe.
    ///   - sectionKeyPath: A key path to the column to group rows by.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    public init<S: SelectStatement>(
      wrappedValue: [Element] = [],
      _ statement: S,
      sectionBy sectionKeyPath: KeyPath<
        S.From.TableColumns, some QueryExpression<some _OptionalPromotable<String?>>
      >,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        sectionBy: sectionKeyPath,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a statement with joins, grouped by an expression of its
    /// `FROM` table, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The rows to hold until the first read finishes.
    ///   - statement: The statement to observe.
    ///   - sectioning: The expression, or an ordering of one, to group rows by.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public init<V: QueryRepresentable, From: Table, each J: Table>(
      wrappedValue: [Element] = [],
      _ statement: Select<V, From, (repeat each J)>,
      @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (From.TableColumns) ->
        _OrbitFetchSectioning<String?>?,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Element == V.QueryOutput {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        sectionBy: sectioning,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Creates a property observing a statement with joins, grouped by an expression of any of
    /// its tables, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - wrappedValue: The rows to hold until the first read finishes.
    ///   - statement: The statement to observe.
    ///   - sectioning: The expression, or an ordering of one, to group rows by.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public init<V: QueryRepresentable, From: Table, J1: Table, each J2: Table>(
      wrappedValue: [Element] = [],
      _ statement: Select<V, From, (J1, repeat each J2)>,
      @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (
        From.TableColumns, J1.TableColumns, repeat (each J2).TableColumns
      ) -> _OrbitFetchSectioning<String?>?,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) where Element == V.QueryOutput {
      self.init(
        wrappedValue: wrappedValue,
        statement,
        sectionBy: sectioning,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different select statement from now on, grouped into sections, delivering
    /// changes with an animation.
    ///
    /// - Parameters:
    ///   - statement: The statement to observe.
    ///   - sectioning: The expression, or an ordering of one, to group rows by.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    /// - Returns: The observation this started.
    @discardableResult
    public func load<S: SelectStatement>(
      _ statement: S,
      @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (S.From.TableColumns) ->
        _OrbitFetchSectioning<String?>?,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
      try await load(
        statement,
        sectionBy: sectioning,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different select statement from now on, grouped by one of its table's columns,
    /// delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - statement: The statement to observe.
    ///   - sectionKeyPath: A key path to the column to group rows by.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    /// - Returns: The observation this started.
    @discardableResult
    public func load<S: SelectStatement>(
      _ statement: S,
      sectionBy sectionKeyPath: KeyPath<
        S.From.TableColumns, some QueryExpression<some _OptionalPromotable<String?>>
      >,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where Element == S.From.QueryOutput, S.QueryValue == (), S.Joins == () {
      try await load(
        statement,
        sectionBy: sectionKeyPath,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different statement with joins from now on, grouped by an expression of its
    /// `FROM` table, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - statement: The statement to observe.
    ///   - sectioning: The expression, or an ordering of one, to group rows by.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    /// - Returns: The observation this started.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @discardableResult
    public func load<V: QueryRepresentable, From: Table, each J: Table>(
      _ statement: Select<V, From, (repeat each J)>,
      @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (From.TableColumns) ->
        _OrbitFetchSectioning<String?>?,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where Element == V.QueryOutput {
      try await load(
        statement,
        sectionBy: sectioning,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }

    /// Observes a different statement with joins from now on, grouped by an expression of any of
    /// its tables, delivering changes with an animation.
    ///
    /// - Parameters:
    ///   - statement: The statement to observe.
    ///   - sectioning: The expression, or an ordering of one, to group rows by.
    ///   - database: The database to read from, or `nil` to read from
    ///     ``OrbitDefaultDatabase/current``.
    ///   - animation: The animation applied to every change.
    /// - Returns: The observation this started.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @discardableResult
    public func load<V: QueryRepresentable, From: Table, J1: Table, each J2: Table>(
      _ statement: Select<V, From, (J1, repeat each J2)>,
      @_OrbitFetchSectionBuilder<String?> sectionBy sectioning: (
        From.TableColumns, J1.TableColumns, repeat (each J2).TableColumns
      ) -> _OrbitFetchSectioning<String?>?,
      database: (any OrbitObservableDatabase)? = nil,
      animation: Animation?
    ) async throws -> OrbitFetchSubscription
    where Element == V.QueryOutput {
      try await load(
        statement,
        sectionBy: sectioning,
        database: database,
        scheduler: OrbitFetchAnimationScheduler(animation: animation)
      )
    }
  }
#endif
