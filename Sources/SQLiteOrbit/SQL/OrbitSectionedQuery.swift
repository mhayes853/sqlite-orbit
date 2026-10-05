#if StructuredQueries
  public import StructuredQueriesSQLite

  /// A reusable request that decodes an element and section key from every result row.
  ///
  /// Create one with a select statement's `sectioned(by:)` helper, or initialize it from a
  /// statement selecting `(element, key)`. Read it with `fetch`, observe it with
  /// `OrbitValueObservation.tracking`, or pass it to `Fetch`.
  ///
  /// Elements and keys must be `QueryRepresentable`. Use an `@Selection` type for multi-column
  /// elements; plain tuple elements are not supported.
  ///
  /// Keys retain their decoded type and use `Hashable` equality. This groups result rows without
  /// performing SQL aggregation. Sections follow their keys' first appearance in the result.
  public struct OrbitSectionedQuery<Element: QueryRepresentable, Key: QueryRepresentable>:
    OrbitFetchKeyRequest
  where Element.QueryOutput: Sendable, Key.QueryOutput: Hashable & Sendable {
    /// The section collection produced by this request.
    public typealias Value = OrbitFetchSectionCollection<Element.QueryOutput, Key.QueryOutput>

    /// The query, including its bindings, selecting the element's columns followed by the key's.
    public let sql: SQL

    /// Uses a statement that already selects `(element, key)`, preserving its ordering.
    ///
    /// This also accepts typed raw SQL, for example `#sql("SELECT title, priority FROM reminders",
    /// as: (String, Int?).self)`. Use `sectioned(by:)` to add a key and its ordering to a query.
    public init(_ statement: some Statement<(Element, Key)>) {
      self.sql = SQL(fragment: statement.query)
    }

    /// Reads the grouped rows in a transaction or borrowed connection.
    /// - Throws: Any statement or decoding error.
    public func fetch<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitFetchSectionCollection<Element.QueryOutput, Key.QueryOutput>
    where
      Transaction: OrbitDatabaseReadTransaction & ~Copyable & ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try transaction.fetchSections(sql) { row in
        (try row.decode(Element.self), try row.decode(Key.self))
      }
    }
  }

  extension SelectStatement where QueryValue == (), Joins == () {
    /// Selects the table and a typed section key, ordering by the key before existing ordering.
    ///
    /// ```swift
    /// let request = Reminder.order(by: \.title).sectioned(by: \.priority)
    /// let sections = try await database.read { try request.fetch($0) }
    /// ```
    /// The closure accepts an expression or ordering term, including descending and null ordering.
    /// Filtering and limits remain part of the query; limits apply after the section ordering.
    public func sectioned<Key: QueryRepresentable>(
      @_OrbitFetchSectionBuilder<Key> by sectioning: (From.TableColumns) -> _OrbitFetchSectioning<
        Key
      >
    ) -> OrbitSectionedQuery<From, Key>
    where From.QueryOutput: Sendable, Key.QueryOutput: Hashable & Sendable {
      let sectioned: Select<(From, Key), From, ()> =
        orbitSectionedColumns(of: From.self, sectioning(From.columns)) + asSelect()
      return OrbitSectionedQuery(sectioned)
    }

    /// Groups the table's rows by a column, ordering by it before existing ordering.
    public func sectioned<Key: QueryRepresentable>(
      by keyPath: KeyPath<From.TableColumns, some QueryExpression<Key>>
    ) -> OrbitSectionedQuery<From, Key>
    where From.QueryOutput: Sendable, Key.QueryOutput: Hashable & Sendable {
      sectioned { $0[keyPath: keyPath] }
    }
  }

  // The first-table overload wins over the all-table overload when its join pack is empty.
  // swift-format-ignore: AmbiguousTrailingClosureOverload
  extension Select where Columns: QueryRepresentable, From: Table {
    /// Adds a typed section key to an explicit projection, ordering by it before existing ordering.
    ///
    /// The section expression may reference a column absent from the projection. With `DISTINCT`,
    /// uniqueness applies to the resulting `(element, key)` projection.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public func sectioned<Key: QueryRepresentable, each J: Table>(
      @_OrbitFetchSectionBuilder<Key> by sectioning: (From.TableColumns) -> _OrbitFetchSectioning<
        Key
      >
    ) -> OrbitSectionedQuery<Columns, Key>
    where
      Joins == (repeat each J), Columns.QueryOutput: Sendable,
      Key.QueryOutput: Hashable & Sendable
    {
      sectioned(by: sectioning(From.columns))
    }

    /// Groups an explicit projection by a column of its first table.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public func sectioned<Key: QueryRepresentable, each J: Table>(
      by keyPath: KeyPath<From.TableColumns, some QueryExpression<Key>>
    ) -> OrbitSectionedQuery<Columns, Key>
    where
      Joins == (repeat each J), Columns.QueryOutput: Sendable,
      Key.QueryOutput: Hashable & Sendable
    {
      sectioned { $0[keyPath: keyPath] }
    }

    /// Groups an explicit projection by an expression of any of its joined tables.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @_disfavoredOverload
    public func sectioned<Key: QueryRepresentable, each J: Table>(
      @_OrbitFetchSectionBuilder<Key> by sectioning: (
        From.TableColumns, repeat (each J).TableColumns
      ) -> _OrbitFetchSectioning<Key>
    ) -> OrbitSectionedQuery<Columns, Key>
    where
      Joins == (repeat each J), Columns.QueryOutput: Sendable,
      Key.QueryOutput: Hashable & Sendable
    {
      sectioned(by: sectioning(From.columns, repeat (each J).columns))
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func sectioned<Key: QueryRepresentable, each J: Table>(
      by sectioning: _OrbitFetchSectioning<Key>
    ) -> OrbitSectionedQuery<Columns, Key>
    where
      Joins == (repeat each J), Columns.QueryOutput: Sendable,
      Key.QueryOutput: Hashable & Sendable
    {
      let ordered: Select<Columns, From, Joins> =
        orbitSectionedOrder(of: From.self, sectioning) + asSelect()
      let sectioned: Select<(Columns, Key), From, Joins> =
        ordered + orbitSectionedColumn(of: From.self, sectioning)
      return OrbitSectionedQuery(sectioned)
    }
  }
  /// A statement selecting every column of a table, then the section expression, ordered by it.
  private func orbitSectionedColumns<From: Table, Key: QueryRepresentable>(
    of _: From.Type,
    _ sectionBy: _OrbitFetchSectioning<Key>
  ) -> Select<(From, Key), From, ()> {
    From.unscoped
      .select { ($0, SQLQueryExpression(sectionBy.select, as: Key.self)) }
      .order { _ in SQLQueryExpression(sectionBy.order) }
  }

  /// A statement selecting the section expression alone.
  private func orbitSectionedColumn<From: Table, Key: QueryRepresentable>(
    of _: From.Type,
    _ sectionBy: _OrbitFetchSectioning<Key>
  ) -> Select<Key, From, ()> {
    From.unscoped.asSelect()
      .select { _ in SQLQueryExpression(sectionBy.select, as: Key.self) }
  }

  /// A statement ordering by the section expression alone.
  private func orbitSectionedOrder<From: Table, Key>(
    of _: From.Type,
    _ sectionBy: _OrbitFetchSectioning<Key>
  ) -> Select<(), From, ()> {
    From.unscoped.asSelect()
      .order { _ in SQLQueryExpression(sectionBy.order) }
  }

#endif
