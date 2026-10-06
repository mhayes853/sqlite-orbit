#if StructuredQueries
  public import StructuredQueriesSQLite

  /// A reusable request that decodes an element and section key from every result row.
  ///
  /// Create one with a select statement's `sectionedRequest(by:)` helper, or initialize it from a
  /// statement selecting `(element, key)`. Read it with `fetch`, observe it with
  /// `OrbitValueObservation.tracking`, or pass it to `Fetch`.
  ///
  /// Elements and keys must be `QueryRepresentable`. Use an `@Selection` type for multi-column
  /// elements; plain tuple elements are not supported.
  ///
  /// Keys retain their decoded type and use `Hashable` equality. This groups result rows without
  /// performing SQL aggregation. Sections follow their keys' first appearance in the result.
  public struct OrbitSectionedRequest<Element: QueryRepresentable, Key: QueryRepresentable>:
    OrbitFetchKeyRequest
  where Element.QueryOutput: Sendable, Key.QueryOutput: Hashable & Sendable {
    /// The section collection produced by this request.
    public typealias Value = OrbitFetchSectionCollection<Element.QueryOutput, Key.QueryOutput>

    /// The query, including its bindings, selecting the element's columns followed by the key's.
    public let sql: SQL

    /// Uses a statement that already selects `(element, key)`, preserving its ordering.
    ///
    /// This also accepts typed raw SQL, for example `#sql("SELECT title, priority FROM reminders",
    /// as: (String, Int?).self)`. Use `sectionedRequest(by:)` to add a key and its ordering to a query.
    public init(_ statement: some Statement<(Element, Key)>) {
      self.sql = SQL(fragment: statement.query)
    }

    /// Reads the grouped rows in a transaction or borrowed connection.
    /// - Throws: Any statement or decoding error.
    public func fetch<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> Value
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
    /// let request = Reminder.order(by: \.title).sectionedRequest(by: \.priority)
    /// let sections = try await database.read { try request.fetch($0) }
    /// ```
    /// The closure accepts an expression or ordering term, including descending and null ordering.
    /// Filtering and limits remain part of the query; limits apply after the section ordering.
    public func sectionedRequest<Key: QueryRepresentable>(
      @_OrbitFetchSectionBuilder<Key> by sectioning: (From.TableColumns) -> _OrbitFetchSectioning<
        Key
      >
    ) -> OrbitSectionedRequest<From, Key>
    where From.QueryOutput: Sendable, Key.QueryOutput: Hashable & Sendable {
      let section = sectioning(From.columns)
      let columns = From.unscoped
        .select { ($0, SQLQueryExpression(section.select, as: Key.self)) }
        .order { _ in SQLQueryExpression(section.order) }
      return OrbitSectionedRequest(columns + asSelect())
    }

    /// Groups the table's rows by a column, ordering by it before existing ordering.
    public func sectionedRequest<Key: QueryRepresentable>(
      by keyPath: KeyPath<From.TableColumns, some QueryExpression<Key>>
    ) -> OrbitSectionedRequest<From, Key>
    where From.QueryOutput: Sendable, Key.QueryOutput: Hashable & Sendable {
      sectionedRequest { $0[keyPath: keyPath] }
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
    public func sectionedRequest<Key: QueryRepresentable, each J: Table>(
      @_OrbitFetchSectionBuilder<Key> by sectioning: (From.TableColumns) -> _OrbitFetchSectioning<
        Key
      >
    ) -> OrbitSectionedRequest<Columns, Key>
    where
      Joins == (repeat each J), Columns.QueryOutput: Sendable,
      Key.QueryOutput: Hashable & Sendable
    {
      sectionedRequest(by: sectioning(From.columns))
    }

    /// Groups an explicit projection by a column of its first table.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    public func sectionedRequest<Key: QueryRepresentable, each J: Table>(
      by keyPath: KeyPath<From.TableColumns, some QueryExpression<Key>>
    ) -> OrbitSectionedRequest<Columns, Key>
    where
      Joins == (repeat each J), Columns.QueryOutput: Sendable,
      Key.QueryOutput: Hashable & Sendable
    {
      sectionedRequest { $0[keyPath: keyPath] }
    }

    /// Groups an explicit projection by an expression of any of its joined tables.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @_disfavoredOverload
    public func sectionedRequest<Key: QueryRepresentable, each J: Table>(
      @_OrbitFetchSectionBuilder<Key> by sectioning: (
        From.TableColumns, repeat (each J).TableColumns
      ) -> _OrbitFetchSectioning<Key>
    ) -> OrbitSectionedRequest<Columns, Key>
    where
      Joins == (repeat each J), Columns.QueryOutput: Sendable,
      Key.QueryOutput: Hashable & Sendable
    {
      sectionedRequest(by: sectioning(From.columns, repeat (each J).columns))
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func sectionedRequest<Key: QueryRepresentable, each J: Table>(
      by sectioning: _OrbitFetchSectioning<Key>
    ) -> OrbitSectionedRequest<Columns, Key>
    where
      Joins == (repeat each J), Columns.QueryOutput: Sendable,
      Key.QueryOutput: Hashable & Sendable
    {
      let order = From.unscoped.asSelect().order { _ in SQLQueryExpression(sectioning.order) }
      let column = From.unscoped.asSelect()
        .select { _ in SQLQueryExpression(sectioning.select, as: Key.self) }
      let ordered: Select<Columns, From, Joins> = order + self
      return OrbitSectionedRequest(ordered + column)
    }
  }
#endif
