/// Why a value observation fetched a value.
///
/// ```swift
/// for try await change in observation.changes(in: database) {
///   switch change.source {
///   case .initial: print("first read:", change.value)
///   case .transaction(let origin): print("refetched after a \(origin) commit")
///   }
/// }
/// ```
public enum OrbitValueObservationSource: Hashable, Sendable {
  /// The fetch that establishes an observation's initial value.
  case initial

  /// A fetch associated with a committed transaction.
  case transaction(OrbitDatabaseTransactionOrigin)
}

/// A value emitted by an observation, together with the event that prompted its fetch.
///
/// ```swift
/// let observation = OrbitValueObservation.tracking { try $0.fetchAll(Reminder.all) }
/// try observation.subscribe(to: database, onError: { _ in }) { change in
///   print(change.value.count, "reminders after a", change.source, "fetch")
/// }
/// ```
public struct OrbitValueObservationChange<Value: Sendable>: Sendable {
  /// The value the observation produced.
  public let value: Value

  /// The event whose fetch produced ``value``.
  public let source: OrbitValueObservationSource

  /// Creates a change.
  ///
  /// - Parameters:
  ///   - value: The value the observation produced.
  ///   - source: The event whose fetch produced `value`.
  public init(value: Value, source: OrbitValueObservationSource) {
    self.value = value
    self.source = source
  }
}

extension OrbitValueObservationChange: Equatable where Value: Equatable {}
extension OrbitValueObservationChange: Hashable where Value: Hashable {}

private enum OrbitValueObservationRegionSource: Sendable {
  case automatic
  case constant(OrbitDatabaseRegion)
  case query(QueryFragment)

  var initialRegion: OrbitDatabaseRegion? {
    guard case .constant(let region) = self else { return nil }
    return region
  }
}

private struct OrbitValueObservationFetchOutput: Sendable {
  let payload: any Sendable
  let region: OrbitDatabaseRegion
}

private final class OrbitValueObservationReadRegionRecorder:
  OrbitDatabaseTransactionObserver
{
  private let recordedRegion = Lock(OrbitDatabaseRegion.empty)

  var region: OrbitDatabaseRegion {
    recordedRegion.withLock { $0 }
  }

  func databaseDidRead(in region: OrbitDatabaseRegion) {
    recordedRegion.withLock { $0.formUnion(region) }
  }
}

private typealias OrbitValueObservationFetch =
  @Sendable (borrowing SQLiteReadTransaction) throws -> any Sendable

private typealias OrbitValueObservationRuntimeFetch =
  @Sendable (borrowing SQLiteReadTransaction) throws -> OrbitValueObservationFetchOutput

private enum OrbitValueObservationReduction<Value: Sendable>: Sendable {
  case emit(Value)
  case skip
}

private struct OrbitValueObservationReducer<Value: Sendable>: Sendable {
  let reduce: @Sendable (any Sendable) throws -> OrbitValueObservationReduction<Value>
  let transactionNeedsFetch: @Sendable (OrbitDatabaseCommit) -> Bool
  var events = OrbitValueObservationEvents()
}

private struct OrbitValueObservationEventHandler: Sendable {
  let willStart: (@Sendable () -> Void)?
  let willFetch: (@Sendable () -> Void)?
  let databaseDidChange: (@Sendable () -> Void)?
  let didFail: (@Sendable (any Error) -> Void)?
  let didCancel: (@Sendable () -> Void)?
}

private struct OrbitValueObservationEvents: Sendable {
  private var handlers = [OrbitValueObservationEventHandler]()

  func appending(_ handler: OrbitValueObservationEventHandler) -> Self {
    var events = self
    events.handlers.append(handler)
    return events
  }

  func willStart() { for handler in handlers { handler.willStart?() } }
  func willFetch() { for handler in handlers { handler.willFetch?() } }
  func databaseDidChange() { for handler in handlers { handler.databaseDidChange?() } }
  func didCancel() { for handler in handlers { handler.didCancel?() } }
  func didFail(_ error: any Error) { for handler in handlers { handler.didFail?(error) } }
}

/// A value that is fetched initially and again whenever its database region may have changed.
///
/// An observation is a description, not a running process: nothing is read until you start it
/// with ``subscribe(to:onError:onChange:)``, ``changes(in:)``, or ``values(in:)``. Every
/// subscriber to the same observation value and database shares one runtime, so a chain built
/// once and started twice fetches once and hands the same value to both.
///
/// ```swift
/// @Table struct Reminder { let id: Int; var title: String; var isCompleted = false }
///
/// let database = try OrbitDatabase(path: OrbitDatabasePath("reminders.sqlite"))
/// let observation = OrbitValueObservation
///   .trackingAll(Reminder.where { !$0.isCompleted })
///   .removeDuplicates()
///
/// for try await reminders in observation.values(in: database) {
///   print("\(reminders.count) reminders left")
/// }
/// ```
public struct OrbitValueObservation<Value: Sendable>: Sendable {
  private let definition: OrbitValueObservationDefinition<Value>

  private init(
    regionSource: OrbitValueObservationRegionSource,
    fetch: @escaping @Sendable (borrowing SQLiteReadTransaction) throws -> any Sendable,
    makeReducer: @escaping @Sendable () -> OrbitValueObservationReducer<Value>
  ) {
    self.definition = OrbitValueObservationDefinition(
      regionSource: regionSource,
      fetch: fetch,
      makeReducer: makeReducer
    )
  }

  /// Creates an observation whose value is produced by `fetch`.
  ///
  /// `fetch` runs inside a read transaction, so everything it reads comes from one consistent
  /// snapshot of the database. The observation automatically tracks the regions read by `fetch`
  /// and runs it again after a committed write that may affect them.
  /// If `fetch` reads through ``SQLiteReadTransaction/sqliteConnection``, it must call
  /// ``SQLiteReadTransaction/notifyReads(in:)`` for those reads to be tracked.
  /// A database that reports a commit without first reporting its changed region is treated
  /// conservatively.
  ///
  /// ```swift
  /// let incompleteCount = OrbitValueObservation.tracking { transaction in
  ///   try Reminder.where { !$0.isCompleted }.fetchCount(transaction)
  /// }
  /// ```
  ///
  /// - Parameter fetch: Reads the observed value from a transaction.
  /// - Returns: An observation that produces whatever `fetch` returns.
  public static func tracking(
    _ fetch: @escaping @Sendable (borrowing SQLiteReadTransaction) throws -> Value
  ) -> Self {
    tracking(regionSource: .automatic, fetch)
  }

  /// Creates an observation whose value is produced by `fetch` and whose region is supplied by
  /// the caller.
  ///
  /// - Parameters:
  ///   - region: The database region read by `fetch`.
  ///   - fetch: Reads the observed value from a transaction.
  /// - Returns: An observation that produces whatever `fetch` returns.
  public static func tracking(
    region: OrbitDatabaseRegion,
    _ fetch: @escaping @Sendable (borrowing SQLiteReadTransaction) throws -> Value
  ) -> Self {
    tracking(regionSource: .constant(region), fetch)
  }

  private static func tracking(
    regionSource: OrbitValueObservationRegionSource,
    _ fetch: @escaping @Sendable (borrowing SQLiteReadTransaction) throws -> Value
  ) -> Self {
    Self(
      regionSource: regionSource,
      fetch: fetch,
      makeReducer: {
        OrbitValueObservationReducer(
          reduce: { payload in
            guard let value = payload as? Value else {
              preconditionFailure("invalid value observation payload")
            }
            return .emit(value)
          },
          transactionNeedsFetch: { _ in true }
        )
      }
    )
  }

  /// Creates an observation that fetches every value produced by a query.
  ///
  /// The observed region is derived from the query against the database's schema.
  ///
  /// - Parameter query: The query to observe and fetch.
  /// - Returns: An observation of all values produced by `query`.
  public static func trackingAll<QueryValue: QueryRepresentable>(
    _ query: some PartialSelectStatement<QueryValue>
  ) -> Self where Value == [QueryValue.QueryOutput] {
    trackingAllValues(query.query, as: QueryValue.self)
  }

  /// Creates an observation that fetches the first value produced by a query.
  ///
  /// The observed region is derived from the query against the database's schema.
  ///
  /// - Parameter query: The query to observe and fetch.
  /// - Returns: An observation of the first value produced by `query`, or `nil`.
  public static func trackingOne<QueryValue: QueryRepresentable>(
    _ query: some PartialSelectStatement<QueryValue>
  ) -> Self where Value == QueryValue.QueryOutput? {
    trackingOneValue(query.query, as: QueryValue.self)
  }

  /// Creates an observation that fetches every tuple produced by a query.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_disfavoredOverload
  public static func trackingAll<each QueryValue: QueryRepresentable>(
    _ query: some PartialSelectStatement<(repeat each QueryValue)>
  ) -> Self where Value == [(repeat (each QueryValue).QueryOutput)] {
    trackingAllTuples(query.query, as: (repeat each QueryValue).self)
  }

  /// Creates an observation that fetches the first tuple produced by a query.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_disfavoredOverload
  public static func trackingOne<each QueryValue: QueryRepresentable>(
    _ query: some PartialSelectStatement<(repeat each QueryValue)>
  ) -> Self where Value == (repeat (each QueryValue).QueryOutput)? {
    trackingOneTuple(query.query, as: (repeat each QueryValue).self)
  }

  /// Creates an observation that fetches every row produced by a table query.
  public static func trackingAll<S: SelectStatement>(
    _ query: S
  ) -> Self where S.QueryValue == (), S.Joins == (), Value == [S.From.QueryOutput] {
    trackingAllValues(query.query, as: S.From.self)
  }

  /// Creates an observation that fetches the first row produced by a table query.
  public static func trackingOne<S: SelectStatement>(
    _ query: S
  ) -> Self where S.QueryValue == (), S.Joins == (), Value == S.From.QueryOutput? {
    trackingOneValue(query.asSelect().limit(1).query, as: S.From.self)
  }

  /// Creates an observation that fetches every row produced by a table query.
  ///
  /// Joined tables are decoded after the query's `FROM` table.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public static func trackingAll<
    S: SelectStatement,
    FirstJoin: Table,
    each AdditionalJoin: Table
  >(
    _ query: S
  ) -> Self
  where
    S.QueryValue == (), S.Joins == (FirstJoin, repeat each AdditionalJoin),
    Value
      == [(S.From.QueryOutput, FirstJoin.QueryOutput, repeat (each AdditionalJoin).QueryOutput)]
  {
    let query = query.selectStar().query
    return trackingAllTuples(query, as: (S.From, FirstJoin, repeat each AdditionalJoin).self)
  }

  /// Creates an observation that fetches the first row produced by a table query.
  ///
  /// Joined tables are decoded after the query's `FROM` table.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public static func trackingOne<
    S: SelectStatement,
    FirstJoin: Table,
    each AdditionalJoin: Table
  >(
    _ query: S
  ) -> Self
  where
    S.QueryValue == (), S.Joins == (FirstJoin, repeat each AdditionalJoin),
    Value
      == (
        S.From.QueryOutput, FirstJoin.QueryOutput, repeat (each AdditionalJoin).QueryOutput
      )?
  {
    let query = query.asSelect().limit(1).selectStar().query
    return trackingOneTuple(query, as: (S.From, FirstJoin, repeat each AdditionalJoin).self)
  }

  /// Creates an observation that fetches every value decoded from a query fragment.
  ///
  /// - Parameters:
  ///   - query: The query fragment to observe and fetch.
  ///   - type: The representation used to decode each row.
  /// - Returns: An observation of all decoded values.
  public static func trackingAll<QueryValue: QueryRepresentable>(
    _ query: QueryFragment,
    as type: QueryValue.Type
  ) -> Self where Value == [QueryValue.QueryOutput] {
    trackingAllValues(query, as: type)
  }

  /// Creates an observation that fetches the first value decoded from a query fragment.
  ///
  /// - Parameters:
  ///   - query: The query fragment to observe and fetch.
  ///   - type: The representation used to decode the row.
  /// - Returns: An observation of the first decoded value, or `nil`.
  public static func trackingOne<QueryValue: QueryRepresentable>(
    _ query: QueryFragment,
    as type: QueryValue.Type
  ) -> Self where Value == QueryValue.QueryOutput? {
    trackingOneValue(query, as: type)
  }

  /// Creates an observation that fetches every tuple decoded from a query fragment.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_disfavoredOverload
  public static func trackingAll<each QueryValue: QueryRepresentable>(
    _ query: QueryFragment,
    as type: (repeat each QueryValue).Type
  ) -> Self where Value == [(repeat (each QueryValue).QueryOutput)] {
    trackingAllTuples(query, as: type)
  }

  /// Creates an observation that fetches the first tuple decoded from a query fragment.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_disfavoredOverload
  public static func trackingOne<each QueryValue: QueryRepresentable>(
    _ query: QueryFragment,
    as type: (repeat each QueryValue).Type
  ) -> Self where Value == (repeat (each QueryValue).QueryOutput)? {
    trackingOneTuple(query, as: type)
  }

  /// Creates an observation that fetches every value produced by typed SQL.
  public static func trackingAll<QueryValue: QueryRepresentable>(
    _ query: SQLQueryExpression<QueryValue>
  ) -> Self where Value == [QueryValue.QueryOutput] {
    trackingAllValues(query.query, as: QueryValue.self)
  }

  /// Creates an observation that fetches the first value produced by typed SQL.
  public static func trackingOne<QueryValue: QueryRepresentable>(
    _ query: SQLQueryExpression<QueryValue>
  ) -> Self where Value == QueryValue.QueryOutput? {
    trackingOneValue(query.query, as: QueryValue.self)
  }

  /// Creates an observation that fetches every tuple produced by typed SQL.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_disfavoredOverload
  public static func trackingAll<each QueryValue: QueryRepresentable>(
    _ query: SQLQueryExpression<(repeat each QueryValue)>
  ) -> Self where Value == [(repeat (each QueryValue).QueryOutput)] {
    trackingAllTuples(query.query, as: (repeat each QueryValue).self)
  }

  /// Creates an observation that fetches the first tuple produced by typed SQL.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @_disfavoredOverload
  public static func trackingOne<each QueryValue: QueryRepresentable>(
    _ query: SQLQueryExpression<(repeat each QueryValue)>
  ) -> Self where Value == (repeat (each QueryValue).QueryOutput)? {
    trackingOneTuple(query.query, as: (repeat each QueryValue).self)
  }

  private static func trackingAllValues<QueryValue: QueryRepresentable>(
    _ query: QueryFragment,
    as _: QueryValue.Type
  ) -> Self where Value == [QueryValue.QueryOutput] {
    tracking(regionSource: .query(query)) { transaction in
      try transaction.fetchAll(SQLQueryExpression<QueryValue>(query, as: QueryValue.self))
    }
  }

  private static func trackingOneValue<QueryValue: QueryRepresentable>(
    _ query: QueryFragment,
    as _: QueryValue.Type
  ) -> Self where Value == QueryValue.QueryOutput? {
    tracking(regionSource: .query(query)) { transaction in
      try transaction.fetchOne(SQLQueryExpression<QueryValue>(query, as: QueryValue.self))
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private static func trackingAllTuples<each QueryValue: QueryRepresentable>(
    _ query: QueryFragment,
    as _: (repeat each QueryValue).Type
  ) -> Self where Value == [(repeat (each QueryValue).QueryOutput)] {
    tracking(regionSource: .query(query)) { transaction in
      try transaction.fetchAll(
        SQLQueryExpression<(repeat each QueryValue)>(
          query,
          as: (repeat each QueryValue).self
        )
      )
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private static func trackingOneTuple<each QueryValue: QueryRepresentable>(
    _ query: QueryFragment,
    as _: (repeat each QueryValue).Type
  ) -> Self where Value == (repeat (each QueryValue).QueryOutput)? {
    tracking(regionSource: .query(query)) { transaction in
      try transaction.fetchOne(
        SQLQueryExpression<(repeat each QueryValue)>(
          query,
          as: (repeat each QueryValue).self
        )
      )
    }
  }

  private func mapReducer<Output: Sendable>(
    _ derive:
      @escaping @Sendable (OrbitValueObservationReducer<Value>) -> OrbitValueObservationReducer<
        Output
      >
  ) -> OrbitValueObservation<Output> {
    let definition = self.definition
    return OrbitValueObservation<Output>(
      regionSource: definition.regionSource,
      fetch: definition.fetch,
      makeReducer: { derive(definition.makeReducer()) }
    )
  }

  private func mapReduction<Output: Sendable>(
    _ makeTransform:
      @escaping @Sendable () -> @Sendable (Value) throws -> OrbitValueObservationReduction<Output>
  ) -> OrbitValueObservation<Output> {
    mapReducer { upstream in
      let transform = makeTransform()
      return OrbitValueObservationReducer<Output>(
        reduce: { payload in
          guard case .emit(let value) = try upstream.reduce(payload) else { return .skip }
          return try transform(value)
        },
        transactionNeedsFetch: upstream.transactionNeedsFetch,
        events: upstream.events
      )
    }
  }

  /// Transforms each value produced by this observation.
  ///
  /// The transform runs after the database access has ended, so it cannot read the database. A
  /// thrown error ends the observation and is reported to every subscriber.
  ///
  /// ```swift
  /// let titles = OrbitValueObservation
  ///   .tracking { try $0.fetchAll(Reminder.all) }
  ///   .map { reminders in reminders.map(\.title) }
  /// ```
  ///
  /// - Parameter transform: Converts each observed value.
  /// - Returns: An observation producing the transformed values.
  public func map<Output: Sendable>(
    _ transform: @escaping @Sendable (Value) throws -> Output
  ) -> OrbitValueObservation<Output> {
    mapReduction { { .emit(try transform($0)) } }
  }

  /// Produces only the values that satisfy `predicate`.
  ///
  /// A suppressed value is not delivered and does not become the value a late subscriber is caught
  /// up with. The predicate runs after the database access has ended; a thrown error ends the
  /// observation.
  ///
  /// ```swift
  /// let nonEmpty = OrbitValueObservation
  ///   .tracking { try $0.fetchAll(Reminder.all) }
  ///   .filter { !$0.isEmpty }
  /// ```
  ///
  /// - Parameter predicate: Returns whether a value should be delivered.
  /// - Returns: An observation producing only the values `predicate` accepts.
  public func filter(
    _ predicate: @escaping @Sendable (Value) throws -> Bool
  ) -> Self {
    mapReduction { { try predicate($0) ? .emit($0) : .skip } }
  }

  /// Transforms each value and suppresses `nil` results.
  ///
  /// The transform runs after the database access has ended; a thrown error ends the observation.
  ///
  /// ```swift
  /// let nextTitle = OrbitValueObservation
  ///   .tracking { try $0.fetchAll(Reminder.where { !$0.isCompleted }) }
  ///   .compactMap { $0.first?.title }
  /// ```
  ///
  /// - Parameter transform: Converts each observed value, returning `nil` to suppress it.
  /// - Returns: An observation producing the non-`nil` transformed values.
  public func compactMap<Output: Sendable>(
    _ transform: @escaping @Sendable (Value) throws -> Output?
  ) -> OrbitValueObservation<Output> {
    mapReduction { { try transform($0).map(OrbitValueObservationReduction.emit) ?? .skip } }
  }

  /// Suppresses a value when `predicate` considers it equal to the preceding emitted value.
  ///
  /// Use this to keep a write that changed rows you do not observe from waking your subscribers.
  ///
  /// ```swift
  /// let reminders = OrbitValueObservation
  ///   .tracking { try $0.fetchAll(Reminder.all) }
  ///   .removeDuplicates { $0.map(\.id) == $1.map(\.id) }
  /// ```
  ///
  /// - Parameter predicate: Compares the previously emitted value with a new one.
  /// - Returns: An observation that emits a value only when `predicate` reports it as different.
  public func removeDuplicates(
    by predicate: @escaping @Sendable (Value, Value) -> Bool
  ) -> Self {
    mapReduction {
      let previous = Lock<Value?>(nil)
      return { value in
        previous.withLock { previous in
          if let previousValue = previous, predicate(previousValue, value) { return .skip }
          previous = value
          return .emit(value)
        }
      }
    }
  }

  /// Skips fetching after committed transactions for which `predicate` returns `false`.
  ///
  /// Unlike ``filter(_:)``, this runs before the fetch, so a rejected commit costs no read at all.
  /// The initial value is always fetched. Inspect ``OrbitDatabaseCommit/origin`` to distinguish a
  /// notification sent by this process from one sent by another process.
  ///
  /// ```swift
  /// let localOnly = OrbitValueObservation
  ///   .tracking { try $0.fetchCount(Reminder.all) }
  ///   .filterTransactions { $0.origin == .local }
  /// ```
  ///
  /// - Parameter predicate: Returns whether a commit should prompt a fetch.
  /// - Returns: An observation that refetches only after the commits `predicate` accepts.
  public func filterTransactions(
    _ predicate: @escaping @Sendable (OrbitDatabaseCommit) -> Bool
  ) -> Self {
    filterTransactions { commit, _ in predicate(commit) }
  }

  /// Skips fetching after committed transactions for which `predicate` returns `false`, using the
  /// value the observation last produced.
  ///
  /// `previousValue` is the latest value accepted for delivery, or `nil` before the observation
  /// produces its first value. A value suppressed by ``removeDuplicates()`` does not replace it.
  /// The initial value is always fetched.
  ///
  /// ```swift
  /// // Stop refetching once every reminder is done, until a local write says otherwise.
  /// let untilFinished = OrbitValueObservation
  ///   .tracking { try $0.fetchAll(Reminder.all) }
  ///   .filterTransactions { commit, reminders in
  ///     commit.origin == .local || !(reminders?.allSatisfy(\.isCompleted) ?? false)
  ///   }
  /// ```
  ///
  /// - Parameter predicate: Returns whether a commit should prompt a fetch, given the value the
  ///   observation last produced.
  /// - Returns: An observation that refetches only after the commits `predicate` accepts.
  public func filterTransactions(
    _ predicate:
      @escaping @Sendable (
        _ commit: OrbitDatabaseCommit,
        _ previousValue: Value?
      ) -> Bool
  ) -> Self {
    mapReducer { upstream in
      let previous = Lock<Value?>(nil)
      return OrbitValueObservationReducer(
        reduce: { payload in
          let reduction = try upstream.reduce(payload)
          if case .emit(let value) = reduction { previous.withLock { $0 = value } }
          return reduction
        },
        transactionNeedsFetch: { commit in
          guard upstream.transactionNeedsFetch(commit) else { return false }
          return predicate(commit, previous.withLock { $0 })
        },
        events: upstream.events
      )
    }
  }

  /// Returns an observation that runs the given callbacks as it works.
  ///
  /// The callbacks are for tracing an observation, not for reacting to its values: they run
  /// wherever the observation happens to be working, including inside a write transaction for
  /// `willFetch`, so they should do as little as possible. `didReceiveValue` sees values at this
  /// operator's position in the chain, so a value an upstream ``filter(_:)`` or
  /// ``removeDuplicates()`` suppressed never reaches it.
  ///
  /// Subscribers to one observation and database share a single runtime, and these are that
  /// runtime's events rather than any one subscriber's. `willStart` runs for the fetch that the
  /// first subscriber triggers, and `didCancel` runs when the last subscriber goes away; a
  /// subscriber that joins or leaves in between raises neither.
  ///
  /// The order of `willFetch` and `databaseDidChange` depends on where the write came from. A
  /// local write is fetched inside its transaction, before the commit that the observation
  /// reports, so `willFetch` precedes `databaseDidChange`. Every other fetch follows the commit
  /// that prompted it.
  ///
  /// ```swift
  /// let traced = OrbitValueObservation
  ///   .tracking { try $0.fetchCount(Reminder.all) }
  ///   .handleEvents(
  ///     willStart: { logger.debug("observing reminders") },
  ///     didReceiveValue: { count in logger.debug("\(count) reminders") },
  ///     didCancel: { logger.debug("no subscribers left") }
  ///   )
  /// ```
  ///
  /// - Parameters:
  ///   - willStart: Runs when the first subscriber starts the observation.
  ///   - willFetch: Runs immediately before each fetch.
  ///   - databaseDidChange: Runs when a commit the observation cares about is reported.
  ///   - didReceiveValue: Runs for each value that reaches this point in the chain.
  ///   - didFail: Runs with the error that ended the observation.
  ///   - didCancel: Runs when the last subscriber goes away.
  /// - Returns: An observation that behaves identically and reports its work to these callbacks.
  public func handleEvents(
    willStart: (@Sendable () -> Void)? = nil,
    willFetch: (@Sendable () -> Void)? = nil,
    databaseDidChange: (@Sendable () -> Void)? = nil,
    didReceiveValue: (@Sendable (Value) -> Void)? = nil,
    didFail: (@Sendable (any Error) -> Void)? = nil,
    didCancel: (@Sendable () -> Void)? = nil
  ) -> Self {
    mapReducer { upstream in
      OrbitValueObservationReducer(
        reduce: { payload in
          let reduction = try upstream.reduce(payload)
          if case .emit(let value) = reduction { didReceiveValue?(value) }
          return reduction
        },
        transactionNeedsFetch: upstream.transactionNeedsFetch,
        events: upstream.events.appending(
          OrbitValueObservationEventHandler(
            willStart: willStart,
            willFetch: willFetch,
            databaseDidChange: databaseDidChange,
            didFail: didFail,
            didCancel: didCancel
          )
        )
      )
    }
  }

  /// Starts this observation and delivers its changes through callbacks on Swift's cooperative
  /// executor.
  ///
  /// The observation runs until the returned subscription is cancelled or released, so store it
  /// for as long as you want the callbacks.
  ///
  /// ```swift
  /// let subscription = try OrbitValueObservation
  ///   .tracking { try $0.fetchCount(Reminder.all) }
  ///   .subscribe(to: database) { error in
  ///     logger.error("reminder observation failed: \(error)")
  ///   } onChange: { change in
  ///     logger.info("\(change.value) reminders")
  ///   }
  /// ```
  ///
  /// - Parameters:
  ///   - database: The database to observe.
  ///   - isolation: The actor the caller is isolated to, used to decide whether a callback can run
  ///     without an extra hop. Defaults to the caller's isolation.
  ///   - onError: Receives the error that ends the observation.
  ///   - onChange: Receives each observed change.
  /// - Returns: A subscription that ends the observation when cancelled or released.
  /// - Throws: Whatever registering a transaction observer on `database` throws.
  public func subscribe<Database: OrbitObservableDatabase>(
    to database: Database,
    isolation: isolated (any Actor)? = #isolation,
    onError: @escaping @Sendable (any Error) -> Void,
    onChange: @escaping @Sendable (OrbitValueObservationChange<Value>) -> Void
  ) throws -> OrbitSubscription {
    try subscribe(
      to: database,
      scheduling: OrbitAsyncValueObservationScheduler.async(),
      isolation: isolation,
      onError: onError,
      onChange: onChange
    )
  }

  /// Starts this observation and delivers its changes through `scheduler`.
  ///
  /// The transaction observer is registered before the initial fetch, so a commit cannot fall into
  /// a gap between fetching and listening. A fetch error calls `onError` and ends the subscription.
  /// A scheduler that requests an immediate initial value makes this method perform a blocking
  /// read, so `onChange` has run once by the time it returns.
  ///
  /// ```swift
  /// let subscription = try OrbitValueObservation
  ///   .tracking { try $0.fetchCount(Reminder.all) }
  ///   .subscribe(to: database, scheduling: .immediate) { error in
  ///     logger.error("\(error)")
  ///   } onChange: { change in
  ///     counts.append(change.value)
  ///   }
  /// ```
  ///
  /// - Parameters:
  ///   - database: The database to observe.
  ///   - scheduler: Decides where and when callbacks run.
  ///   - isolation: The actor the caller is isolated to. Defaults to the caller's isolation.
  ///   - onError: Receives the error that ends the observation.
  ///   - onChange: Receives each observed change.
  /// - Returns: A subscription that ends the observation when cancelled or released.
  /// - Throws: Whatever registering a transaction observer on `database` throws.
  public func subscribe<
    Database: OrbitObservableDatabase,
    Scheduler: OrbitValueObservationScheduler
  >(
    to database: Database,
    scheduling scheduler: Scheduler,
    isolation: isolated (any Actor)? = #isolation,
    onError: @escaping @Sendable (any Error) -> Void,
    onChange: @escaping @Sendable (OrbitValueObservationChange<Value>) -> Void
  ) throws -> OrbitSubscription {
    let runtime = try definition.runtime(for: database)
    let subscription = runtime.addSubscriber(
      scheduling: scheduler,
      isolation: isolation,
      onError: onError,
      onChange: onChange
    )
    if scheduler.immediateInitialValue(from: isolation) {
      runtime.fetchInitialValueImmediatelyIfNeeded(isolation: isolation)
    } else {
      runtime.fetchInitialValueIfNeeded()
    }
    return subscription
  }

  /// Starts this observation with callbacks isolated to the main actor.
  ///
  /// With ``OrbitValueObservationScheduler/mainActor``, the initial value is delivered before this
  /// method returns, which is what lets a view start with real data rather than a placeholder.
  ///
  /// ```swift
  /// @MainActor final class RemindersModel {
  ///   private(set) var count = 0
  ///   private var subscription: OrbitSubscription?
  ///
  ///   func start(observing database: OrbitDatabase<SQLitePool>) throws {
  ///     subscription = try OrbitValueObservation
  ///       .tracking { try $0.fetchCount(Reminder.all) }
  ///       .subscribe(to: database, scheduling: .mainActor) { _ in
  ///       } onChange: { [self] change in count = change.value }
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - database: The database to observe.
  ///   - scheduler: A scheduler that guarantees main-actor delivery.
  ///   - onError: Receives the error that ends the observation.
  ///   - onChange: Receives each observed change.
  /// - Returns: A subscription that ends the observation when cancelled or released.
  /// - Throws: Whatever registering a transaction observer on `database` throws.
  @MainActor
  public func subscribe<
    Database: OrbitObservableDatabase,
    Scheduler: OrbitValueObservationMainActorScheduler
  >(
    to database: Database,
    scheduling scheduler: Scheduler,
    onError: @escaping @MainActor @Sendable (any Error) -> Void,
    onChange: @escaping @MainActor @Sendable (OrbitValueObservationChange<Value>) -> Void
  ) throws -> OrbitSubscription {
    try subscribe(
      to: database,
      scheduling: scheduler,
      isolation: MainActor.shared,
      onError: { error in
        MainActor.assumeIsolated { onError(error) }
      },
      onChange: { change in
        MainActor.assumeIsolated { onChange(change) }
      }
    )
  }

  /// Returns an asynchronous sequence of values and the sources that prompted their fetches.
  ///
  /// The observation starts when iteration begins and ends when the iterator is released.
  /// `bufferingPolicy` decides which elements survive when the observation produces them faster
  /// than the sequence is consumed; by default every one of them is kept.
  ///
  /// ```swift
  /// for try await change in observation.changes(in: database) {
  ///   if change.source == .transaction(.external) { logger.info("another process wrote") }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - database: The database to observe.
  ///   - bufferingPolicy: How elements are buffered for a consumer that falls behind.
  /// - Returns: An asynchronous sequence of changes, failing with the error that ends the
  ///   observation.
  public func changes<Database: OrbitObservableDatabase>(
    in database: Database,
    bufferingPolicy: OrbitValueObservationBufferingPolicy = .unbounded
  ) -> OrbitValueObservationSequence<OrbitValueObservationChange<Value>> {
    OrbitValueObservationSequence(bufferingPolicy: bufferingPolicy) { onError, onChange in
      try subscribe(to: database, onError: onError, onChange: onChange)
    }
  }

  /// Returns an asynchronous sequence of observed values without their source metadata.
  ///
  /// The observation starts when iteration begins and ends when the iterator is released.
  /// `bufferingPolicy` decides which elements survive when the observation produces them faster
  /// than the sequence is consumed; by default every one of them is kept.
  ///
  /// ```swift
  /// let reminders = OrbitValueObservation.tracking { try $0.fetchAll(Reminder.all) }
  /// for try await reminders in reminders.values(in: database, bufferingPolicy: .bufferingNewest(1)) {
  ///   render(reminders)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - database: The database to observe.
  ///   - bufferingPolicy: How elements are buffered for a consumer that falls behind.
  /// - Returns: An asynchronous sequence of values, failing with the error that ends the
  ///   observation.
  public func values<Database: OrbitObservableDatabase>(
    in database: Database,
    bufferingPolicy: OrbitValueObservationBufferingPolicy = .unbounded
  ) -> OrbitValueObservationSequence<Value> {
    OrbitValueObservationSequence(bufferingPolicy: bufferingPolicy) { onError, onValue in
      try subscribe(
        to: database,
        onError: onError,
        onChange: { onValue($0.value) }
      )
    }
  }
}

extension OrbitValueObservation where Value: Equatable {
  /// Suppresses consecutive equal values.
  ///
  /// ```swift
  /// let count = OrbitValueObservation
  ///   .tracking { try $0.fetchCount(Reminder.all) }
  ///   .removeDuplicates()
  /// ```
  ///
  /// - Returns: An observation that emits a value only when it differs from the last one emitted.
  public func removeDuplicates() -> Self {
    removeDuplicates(by: ==)
  }
}

private final class OrbitValueObservationDefinition<Value: Sendable>: Sendable {
  let regionSource: OrbitValueObservationRegionSource
  let fetch: OrbitValueObservationFetch
  let makeReducer: @Sendable () -> OrbitValueObservationReducer<Value>

  private struct WeakRuntime: Sendable {
    let value: @Sendable () -> OrbitValueObservationRuntime<Value>?

    init(_ value: OrbitValueObservationRuntime<Value>) {
      self.value = { [weak value] in value }
    }
  }

  private let runtimes = Lock<[ObjectIdentifier: WeakRuntime]>([:])

  init(
    regionSource: OrbitValueObservationRegionSource,
    fetch: @escaping OrbitValueObservationFetch,
    makeReducer: @escaping @Sendable () -> OrbitValueObservationReducer<Value>
  ) {
    self.regionSource = regionSource
    self.fetch = fetch
    self.makeReducer = makeReducer
  }

  func runtime<Database: OrbitObservableDatabase>(
    for database: Database
  ) throws -> OrbitValueObservationRuntime<Value> {
    let identifier = ObjectIdentifier(database)
    if let existing = activeRuntime(for: identifier) { return existing }

    let candidate = OrbitValueObservationRuntime(
      database: database,
      regionSource: regionSource,
      fetch: fetch,
      reducer: makeReducer()
    )
    try candidate.install(on: database)

    let selected = runtimes.withLock { runtimes in
      if let existing = runtimes[identifier]?.value(), existing.isActive {
        return existing
      }
      runtimes[identifier] = WeakRuntime(candidate)
      return candidate
    }
    if selected !== candidate { candidate.stop() }
    return selected
  }

  private func activeRuntime(
    for identifier: ObjectIdentifier
  ) -> OrbitValueObservationRuntime<Value>? {
    runtimes.withLock { runtimes in
      guard let runtime = runtimes[identifier]?.value(), runtime.isActive else {
        runtimes.removeValue(forKey: identifier)
        return nil
      }
      return runtime
    }
  }
}

private struct OrbitValueObservationDelivery: Sendable {
  static let idle = Self()

  var shouldDrain = false

  var didFail = false
}

private final class OrbitValueObservationRuntime<Value: Sendable>: OrbitDatabaseTransactionObserver
{
  private enum PendingLocal: Sendable {
    case fetched(Result<OrbitValueObservationFetchOutput, any Error>)
    case skipped
  }

  private struct State: Sendable {
    var isStopped = false

    var observedRegion: OrbitDatabaseRegion?
    var transactionRegion: OrbitDatabaseRegion?
    var pendingLocal: PendingLocal?

    var reads = OrbitValueObservationReadCoordinator()
    var subscribers = OrbitValueObservationSubscriberRegistry<Value>()
    var deliveries = OrbitValueObservationDeliveryQueue<Value>()

    init(observedRegion: OrbitDatabaseRegion?) {
      self.observedRegion = observedRegion
    }
  }

  private let fetch: OrbitValueObservationRuntimeFetch
  private let read: @Sendable () async -> Result<OrbitValueObservationFetchOutput, any Error>
  private let readBlocking: @Sendable () -> Result<OrbitValueObservationFetchOutput, any Error>
  private let reducer: OrbitValueObservationReducer<Value>
  private var events: OrbitValueObservationEvents { reducer.events }
  private let state: Lock<State>
  private let transactionSubscription = Lock<OrbitSubscription?>(nil)

  init<Database: OrbitObservableDatabase>(
    database: Database,
    regionSource: OrbitValueObservationRegionSource,
    fetch: @escaping OrbitValueObservationFetch,
    reducer: OrbitValueObservationReducer<Value>
  ) {
    self.reducer = reducer
    self.state = Lock(State(observedRegion: regionSource.initialRegion))
    let resolveAndFetch: OrbitValueObservationRuntimeFetch = { transaction in
      switch regionSource {
      case .automatic:
        let recorder = OrbitValueObservationReadRegionRecorder()
        let payload = try transaction.withObserver(recorder) {
          try fetch(transaction)
        }
        return OrbitValueObservationFetchOutput(payload: payload, region: recorder.region)
      case .constant(let region):
        return OrbitValueObservationFetchOutput(
          payload: try fetch(transaction),
          region: region
        )
      case .query(let query):
        return OrbitValueObservationFetchOutput(
          payload: try fetch(transaction),
          region: try OrbitDatabaseRegion(query, in: transaction)
        )
      }
    }
    self.fetch = resolveAndFetch
    self.read = {
      do {
        let output = try await database.read(resolveAndFetch)
        return .success(output)
      } catch {
        return .failure(error)
      }
    }
    self.readBlocking = {
      Result {
        try database.readBlocking(resolveAndFetch)
      }
    }
  }

  func install<Database: OrbitObservableDatabase>(on database: Database) throws {
    let observer = WeakValueObservationObserver(runtime: self)
    let subscription = try database.subscribe(transactionObserver: observer)
    transactionSubscription.withLock { $0 = subscription }
  }

  var isActive: Bool {
    state.withLock { !$0.isStopped }
  }

  // MARK: - Subscribers

  func addSubscriber<Scheduler: OrbitValueObservationScheduler>(
    scheduling scheduler: Scheduler,
    isolation: isolated (any Actor)?,
    onError: @escaping @Sendable (any Error) -> Void,
    onChange: @escaping @Sendable (OrbitValueObservationChange<Value>) -> Void
  ) -> OrbitSubscription {
    let subscriber = OrbitValueObservationSubscriber(
      scheduler: scheduler,
      onError: onError,
      onChange: onChange
    )
    let registration = state.withLock {
      state -> OrbitValueObservationSubscriberRegistry<Value>.Registration in
      state.subscribers.add(subscriber)
    }
    switch registration {
    case .success(let (identifier, latest, isFirstEver)):
      if isFirstEver { events.willStart() }
      if let latest {
        subscriber.receive(.success(latest), from: isolation)
      }
      return OrbitSubscription { [self] in removeSubscriber(identifier) }
    case .failure(let error):
      subscriber.receive(.failure(error), from: isolation)
      return OrbitSubscription {}
    }
  }

  private func removeSubscriber(_ identifier: UInt64) {
    let didCancel = state.withLock { state in
      state.subscribers.remove(identifier) && !state.isStopped
    }
    if didCancel { events.didCancel() }
  }

  // MARK: - Initial value

  func fetchInitialValueIfNeeded() {
    let request = state.withLock { state -> OrbitValueObservationReadRequest? in
      guard !state.isStopped else { return nil }
      return state.reads.requireInitialRead()
    }
    start(request)
  }

  func fetchInitialValueImmediatelyIfNeeded(
    isolation: isolated (any Actor)?
  ) {
    let shouldFetch = state.withLock { state -> Bool in
      guard !state.isStopped, !state.reads.initialFetchCompleted else { return false }
      // Discard an older asynchronous fetch if one is already in flight.
      state.reads.discardInFlightRead()
      return true
    }
    guard shouldFetch else { return }

    events.willFetch()
    let result = readBlocking()
    let delivery = state.withLock { state -> OrbitValueObservationDelivery in
      guard !state.isStopped, !state.reads.initialFetchCompleted else { return .idle }
      return accept(result, source: .initial, state: &state)
    }
    deliver(delivery, from: isolation)
  }

  // MARK: - Transactions

  func databaseDidChange(in region: OrbitDatabaseRegion) {
    state.withLock { state in
      guard !state.isStopped else { return }
      state.transactionRegion = state.transactionRegion?.union(region) ?? region
    }
  }

  func databaseWillCommit(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws {
    let commit = OrbitDatabaseCommit(origin: .local)
    let regionNeedsFetch = state.withLock { state in
      guard !state.isStopped else { return false }
      let observedRegion = state.observedRegion ?? .fullDatabase
      let needsFetch = observedRegion.overlaps(state.transactionRegion ?? .empty)
      state.transactionRegion = nil
      state.pendingLocal = .skipped
      return needsFetch
    }
    guard regionNeedsFetch, transactionNeedsFetch(commit) else { return }

    events.willFetch()
    let result = Result { try fetch(transaction) }
    state.withLock { state in
      guard !state.isStopped else { return }
      state.pendingLocal = .fetched(result)
    }
  }

  func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
    switch commit.origin {
    case .local:
      let pending = state.withLock { state in
        defer { state.pendingLocal = nil }
        return state.pendingLocal
      }
      switch pending {
      case .skipped:
        return
      case .fetched(let result):
        events.databaseDidChange()
        publishLocal(result)
        return
      case nil:
        guard committedTransactionNeedsFetch(commit) else { return }
        events.databaseDidChange()
        requestRead(source: .transaction(.local))
        return
      }

    case .external:
      guard committedTransactionNeedsFetch(commit) else { return }
      events.databaseDidChange()
      requestRead(source: .transaction(.external))
    }
  }

  func databaseDidRollback() {
    state.withLock {
      $0.transactionRegion = nil
      $0.pendingLocal = nil
    }
  }

  private func transactionNeedsFetch(_ commit: OrbitDatabaseCommit) -> Bool {
    reducer.transactionNeedsFetch(commit)
  }

  private func committedTransactionNeedsFetch(_ commit: OrbitDatabaseCommit) -> Bool {
    let regionNeedsFetch = state.withLock { state in
      guard !state.isStopped else { return false }
      let region = state.transactionRegion ?? .fullDatabase
      state.transactionRegion = nil
      return (state.observedRegion ?? .fullDatabase).overlaps(region)
    }
    return regionNeedsFetch && transactionNeedsFetch(commit)
  }

  private func publishLocal(
    _ result: Result<OrbitValueObservationFetchOutput, any Error>
  ) {
    let delivery = state.withLock { state -> OrbitValueObservationDelivery in
      guard !state.isStopped else { return .idle }
      // The fetch inside this transaction includes every commit visible before this one, so it
      // also satisfies an older external invalidation whose read has not completed yet.
      state.reads.supersedePendingRead()
      return accept(result, source: .transaction(.local), state: &state)
    }
    deliver(delivery, from: nil)
  }

  // MARK: - Reads

  private func requestRead(source: OrbitValueObservationSource) {
    let request = state.withLock { state -> OrbitValueObservationReadRequest? in
      guard !state.isStopped else { return nil }
      return state.reads.requireRead(source: source)
    }
    start(request)
  }

  private func start(_ request: OrbitValueObservationReadRequest?) {
    guard let request else { return }
    Task { [weak self] in
      guard let self else { return }
      events.willFetch()
      let result = await read()
      completeRead(result, request: request)
    }
  }

  private func completeRead(
    _ result: Result<OrbitValueObservationFetchOutput, any Error>,
    request: OrbitValueObservationReadRequest
  ) {
    let completed = state.withLock {
      state -> (OrbitValueObservationDelivery, OrbitValueObservationReadRequest?) in
      guard !state.isStopped else { return (.idle, nil) }
      let delivery =
        state.reads.completeRead(request)
        ? accept(result, source: request.source, state: &state)
        : .idle
      // Accepting a failure ends the observation, and an ended observation reads no further.
      guard !state.isStopped else { return (delivery, nil) }
      return (delivery, state.reads.takeRequestIfPossible())
    }
    deliver(completed.0, from: nil)
    start(completed.1)
  }

  private func accept(
    _ result: Result<OrbitValueObservationFetchOutput, any Error>,
    source: OrbitValueObservationSource,
    state: inout State
  ) -> OrbitValueObservationDelivery {
    state.reads.completeInitialFetch()
    let outcome: Result<OrbitValueObservationChange<Value>, any Error>
    switch result {
    case .success(let output):
      state.observedRegion = output.region
      do {
        guard case .emit(let value) = try reducer.reduce(output.payload) else { return .idle }
        outcome = .success(OrbitValueObservationChange(value: value, source: source))
      } catch {
        outcome = .failure(error)
      }
    case .failure(let error):
      outcome = .failure(error)
    }

    let owed: [OrbitValueObservationSubscriber<Value>]
    var didFail = false
    switch outcome {
    case .success(let change):
      owed = state.subscribers.publish(change)
    case .failure(let error):
      state.isStopped = true
      didFail = true
      owed = state.subscribers.fail(error)
    }
    let publication = OrbitValueObservationPublication(outcome: outcome, subscribers: owed)
    return OrbitValueObservationDelivery(
      shouldDrain: state.deliveries.enqueue(publication),
      didFail: didFail
    )
  }

  // MARK: - Delivery

  private func deliver(
    _ delivery: OrbitValueObservationDelivery,
    from isolation: isolated (any Actor)?
  ) {
    if delivery.didFail { stopObservingTransactions() }
    guard delivery.shouldDrain else { return }
    while let publication = state.withLock({ $0.deliveries.next() }) {
      if case .failure(let error) = publication.outcome { events.didFail(error) }
      for subscriber in publication.subscribers {
        subscriber.receive(publication.outcome, from: isolation)
      }
    }
  }

  // MARK: - Lifetime

  func stop() {
    let shouldStop = state.withLock { state in
      guard !state.isStopped else { return false }
      state.isStopped = true
      return true
    }
    if shouldStop { stopObservingTransactions() }
  }

  private func stopObservingTransactions() {
    let subscription = transactionSubscription.withLock { subscription in
      defer { subscription = nil }
      return subscription
    }
    subscription?.cancel()
  }
}

private final class WeakValueObservationObserver<Value: Sendable>: OrbitDatabaseTransactionObserver
{
  private let runtime: @Sendable () -> OrbitValueObservationRuntime<Value>?

  init(runtime: OrbitValueObservationRuntime<Value>) {
    self.runtime = { [weak runtime] in runtime }
  }

  func databaseDidChange(in region: OrbitDatabaseRegion) {
    runtime()?.databaseDidChange(in: region)
  }

  func databaseWillCommit(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws {
    try runtime()?.databaseWillCommit(transaction)
  }

  func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
    runtime()?.databaseDidCommit(commit)
  }

  func databaseDidRollback() {
    runtime()?.databaseDidRollback()
  }
}
