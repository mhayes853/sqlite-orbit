/// Why a value observation fetched a value.
///
/// ```swift
/// for try await change in observation.changes(in: database) {
///   switch change.source {
///   case .initial: print("first read:", change.value)
///   case .transaction(let origin): print("refetched after a \(origin) commit")
///   case .observable: print("refetched after observable state changed")
///   }
/// }
/// ```
public enum OrbitValueObservationSource: Hashable, Sendable {
  /// The fetch that establishes an observation's initial value.
  case initial

  /// A fetch associated with a committed transaction.
  case transaction(OrbitDatabaseTransactionOrigin)

  /// A fetch prompted by a change to an observable value read by the fetch closure.
  case observable
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
  case constantOnFirstFetch
  case constant(OrbitDatabaseRegion)
  case query(QueryFragment)

  var initialRegion: OrbitDatabaseRegion? {
    guard case .constant(let region) = self else { return nil }
    return region
  }

  /// Runs `fetch`, working out the region it read the way this source says to.
  func fetch(
    _ fetch: OrbitValueObservationFetch,
    in transaction: borrowing SQLiteReadTransaction,
    firstFetchRegion: OrbitValueObservationFirstFetchRegion
  ) throws -> (payload: any Sendable, region: OrbitDatabaseRegion) {
    switch self {
    case .automatic:
      return try Self.fetchRecordingRegion(fetch, in: transaction)
    case .constantOnFirstFetch:
      if let region = firstFetchRegion.region { return (try fetch(transaction), region) }
      let output = try Self.fetchRecordingRegion(fetch, in: transaction)
      firstFetchRegion.record(output.region)
      return output
    case .constant(let region):
      return (try fetch(transaction), region)
    case .query(let query):
      return (try fetch(transaction), try OrbitDatabaseRegion(query, in: transaction))
    }
  }

  private static func fetchRecordingRegion(
    _ fetch: OrbitValueObservationFetch,
    in transaction: borrowing SQLiteReadTransaction
  ) throws -> (payload: any Sendable, region: OrbitDatabaseRegion) {
    let recorder = OrbitValueObservationReadRegionRecorder()
    let payload = try transaction.withObserver(recorder) {
      try fetch(transaction)
    }
    return (payload, recorder.region)
  }
}

private struct OrbitValueObservationFetchOutput: Sendable {
  let payload: any Sendable
  let region: OrbitDatabaseRegion
  let externalDependencies: ExternalDependencies?
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

/// The region an observation recorded the first time it fetched, for it to reuse afterwards.
///
/// One of these belongs to one runtime rather than to the observation it came from, because the
/// same observation subscribed to two databases is two schemas, and a region recorded against one
/// says nothing about the other.
private final class OrbitValueObservationFirstFetchRegion: Sendable {
  private let recorded = Lock<OrbitDatabaseRegion?>(nil)

  var region: OrbitDatabaseRegion? {
    recorded.withLock { $0 }
  }

  func record(_ region: OrbitDatabaseRegion) {
    recorded.withLock { recorded in
      guard recorded == nil else { return }
      recorded = region
    }
  }
}

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

/// A value fetched initially and again whenever a recorded database or observable dependency may
/// have changed.
///
/// An observation is a description, not a running process: nothing is read until you start it
/// with ``subscribe(to:isolation:onError:onChange:)``, ``changes(in:bufferingPolicy:)``, or
/// ``values(in:bufferingPolicy:)``. Every subscriber to the same observation value and database
/// shares one runtime, so a chain built once and started twice fetches once and hands the same
/// value to both.
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
    refetchController: any OrbitValueObservationRefetchController = .immediate,
    makeReducer: @escaping @Sendable () -> OrbitValueObservationReducer<Value>
  ) {
    self.definition = OrbitValueObservationDefinition(
      regionSource: regionSource,
      fetch: fetch,
      refetchController: refetchController,
      makeReducer: makeReducer
    )
  }

  /// Creates an observation whose value is produced by `fetch`.
  ///
  /// `fetch` runs inside a read transaction, so everything it reads comes from one consistent
  /// snapshot of the database. The observation automatically tracks the regions read by `fetch`
  /// and runs it again after a committed write that may affect them. On systems with Observation,
  /// it also tracks observable properties read by `fetch` and runs again when one changes.
  /// ``ExternalValue`` provides thread-safe, field-sensitive observation for captured values.
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

  /// Creates an observation whose value is produced by `fetch`, watching whatever the first
  /// fetch read.
  ///
  /// ``tracking(_:)`` works out the region to watch on every fetch, because a fetch is free to
  /// read a different part of the database each time it runs. When it is not — when the fetch
  /// reads the same tables whatever the data says — that is a read authorizer installed and a
  /// region built for an answer already known. This records the region the first fetch read and
  /// watches it from then on, so every later fetch is the query and nothing else.
  ///
  /// Use it only when the fetch's reads do not depend on what it finds. A fetch that reads one
  /// table and then, depending on a row it found there, reads a second is not one of these: the
  /// second table would go unwatched whenever the first fetch happened not to reach it, and a
  /// write to it would be missed. ``tracking(region:_:)`` says the same thing ahead of time, for
  /// a fetch whose region you already know.
  ///
  /// ```swift
  /// let incompleteCount = OrbitValueObservation.trackingConstantRegion { transaction in
  ///   try Reminder.where { !$0.isCompleted }.fetchCount(transaction)
  /// }
  /// ```
  ///
  /// - Parameter fetch: Reads the observed value from a transaction, reading the same tables
  ///   every time.
  /// - Returns: An observation that produces whatever `fetch` returns.
  public static func trackingConstantRegion(
    _ fetch: @escaping @Sendable (borrowing SQLiteReadTransaction) throws -> Value
  ) -> Self {
    tracking(regionSource: .constantOnFirstFetch, fetch)
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
      refetchController: definition.refetchController,
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

  /// Returns an observation that uses `controller` for fetches prompted after a commit or
  /// observable dependency change.
  ///
  /// The initial fetch and the transaction-local fetch used by serial SQLite drivers are unchanged.
  /// Turso commits are handled after commit, so this controller controls their refetch behavior.
  ///
  /// ```swift
  /// let observation = OrbitValueObservation
  ///   .tracking { try $0.fetchAll(Reminder.all) }
  ///   .refetching(.coalesced)
  /// ```
  public func refetching<Controller: OrbitValueObservationRefetchController>(
    _ controller: Controller
  ) -> Self {
    let definition = self.definition
    return Self(
      regionSource: definition.regionSource,
      fetch: definition.fetch,
      refetchController: controller,
      makeReducer: definition.makeReducer
    )
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

  /// Observes for as long as the calling task runs, delivering each change to `onChange`.
  ///
  /// This is the observation as a piece of work rather than as a token or a sequence: it belongs
  /// to the task that called it, it keeps that task busy, and cancelling the task ends both. That
  /// is what makes it the shape to hand a task group or a `.task` modifier, which have a task to
  /// spend and nowhere to store a subscription.
  ///
  /// ``values(in:bufferingPolicy:)`` describes the same observation as a sequence, and differs in
  /// who waits on whom: its consumer asks for the next value and the sequence buffers whatever
  /// arrives in between, while this delivers every change through `scheduler` the moment the
  /// observation produces it, with nothing buffered and no consumer to fall behind.
  ///
  /// ```swift
  /// .task {
  ///   try? await observation.subscribe(to: database, scheduling: .mainActor) { change in
  ///     reminders = change.value
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - database: The database to observe.
  ///   - scheduler: Decides where and when `onChange` runs.
  ///   - isolation: The actor the caller is isolated to. Defaults to the caller's isolation.
  ///   - onChange: Receives each observed change.
  /// - Throws: Whatever registering a transaction observer on `database` throws, or the error that
  ///   ends the observation. Cancelling the calling task returns rather than throwing.
  public func subscribe<
    Database: OrbitObservableDatabase,
    Scheduler: OrbitValueObservationScheduler
  >(
    to database: Database,
    scheduling scheduler: Scheduler,
    isolation: isolated (any Actor)? = #isolation,
    onChange: @escaping @Sendable (OrbitValueObservationChange<Value>) -> Void
  ) async throws {
    let completion = OrbitOneShotSignal()
    let subscription = try subscribe(
      to: database,
      scheduling: scheduler,
      isolation: isolation,
      onError: { error in completion.finish(.failure(error)) },
      onChange: onChange
    )
    defer { subscription.cancel() }
    try await withTaskCancellationHandler {
      try await completion.wait()
    } onCancel: {
      // Stop observing the moment the task is cancelled, not when it gets around to returning.
      subscription.cancel()
      completion.finish(.success(()))
    }
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

/// A one-shot signal that something waited on has finished, and how.
///
/// A task-scoped observation ends with the error that ended it or with the cancellation that
/// ended its task, and a fetch property's explicit load ends with its first result or with the
/// cancellation of the task awaiting it. Either can race the other, so the first to finish the
/// signal is the one the waiter sees and the other is dropped. Waiting does not watch for
/// cancellation itself, because what a cancellation means is up to the waiter.
final class OrbitOneShotSignal: Sendable {
  private enum State {
    case waiting(CheckedContinuation<Void, any Error>?)
    case finished(Result<Void, any Error>)
  }

  private let state = Lock(State.waiting(nil))

  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation in
      let result = state.withLock { state -> Result<Void, any Error>? in
        if case .finished(let result) = state { return result }
        state = .waiting(continuation)
        return nil
      }
      if let result { continuation.resume(with: result) }
    }
  }

  func finish(_ result: Result<Void, any Error>) {
    let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
      guard case .waiting(let continuation) = state else { return nil }
      state = .finished(result)
      return continuation
    }
    continuation?.resume(with: result)
  }
}

private final class OrbitValueObservationDefinition<Value: Sendable>: Sendable {
  let regionSource: OrbitValueObservationRegionSource
  let fetch: OrbitValueObservationFetch
  let refetchController: any OrbitValueObservationRefetchController
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
    refetchController: any OrbitValueObservationRefetchController,
    makeReducer: @escaping @Sendable () -> OrbitValueObservationReducer<Value>
  ) {
    self.regionSource = regionSource
    self.fetch = fetch
    self.refetchController = refetchController
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
      refetchController: refetchController,
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

private struct OrbitValueObservationAcceptance: Sendable {
  let delivery: OrbitValueObservationDelivery
  let requiresObservableRefetch: Bool
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
    var refetches = OrbitValueObservationRefetchCoordinator()
    var isRefetching = false
    var refetchReasons: Set<OrbitValueObservationRefetchReason> = []
    var refetchCommits: [OrbitDatabaseCommit] = []
    var affectedRegion: OrbitDatabaseRegion?
    var activeWriterBarriers: [SQLitePoolWriterBarrier] = []
    var subscribers = OrbitValueObservationSubscriberRegistry<Value>()
    var deliveries = OrbitValueObservationDeliveryQueue<Value>()

    init(observedRegion: OrbitDatabaseRegion?) {
      self.observedRegion = observedRegion
    }

    /// Forgets the invalidations a refetch controller would otherwise be told about, once a fetch
    /// that covers all of them has been accepted.
    mutating func dropOutstandingInvalidations() {
      refetchReasons.removeAll()
      refetchCommits.removeAll()
      affectedRegion = nil
      activeWriterBarriers.removeAll()
    }
  }

  private let fetch: OrbitValueObservationRuntimeFetch
  private let read: @Sendable () async -> Result<OrbitValueObservationFetchOutput, any Error>
  private let readBlocking: @Sendable () -> Result<OrbitValueObservationFetchOutput, any Error>
  private let refetchController: any OrbitValueObservationRefetchController
  private let reducer: OrbitValueObservationReducer<Value>
  private var events: OrbitValueObservationEvents { reducer.events }
  private let state: Lock<State>
  private let transactionSubscription = Lock<OrbitSubscription?>(nil)
  private let externalTracking: ExternalTracking

  init<Database: OrbitObservableDatabase>(
    database: Database,
    regionSource: OrbitValueObservationRegionSource,
    fetch: @escaping OrbitValueObservationFetch,
    refetchController: any OrbitValueObservationRefetchController,
    reducer: OrbitValueObservationReducer<Value>
  ) {
    let externalTracking = ExternalTracking()
    let firstFetchRegion = OrbitValueObservationFirstFetchRegion()
    self.reducer = reducer
    self.refetchController = refetchController
    self.state = Lock(State(observedRegion: regionSource.initialRegion))
    self.externalTracking = externalTracking
    let resolveAndFetch: OrbitValueObservationRuntimeFetch = { transaction in
      let capture = try externalTracking.capture {
        try regionSource.fetch(fetch, in: transaction, firstFetchRegion: firstFetchRegion)
      }
      return OrbitValueObservationFetchOutput(
        payload: capture.output.payload,
        region: capture.output.region,
        externalDependencies: capture.dependencies
      )
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
    externalTracking.onDependencyChange { [weak self] in
      self?.requestRefetch(
        source: .observable,
        reason: .observableChange,
        affectedRegion: nil,
        activeWriterBarrier: nil
      )
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
    let request = state.withLock { state -> OrbitValueObservationFetchRequest? in
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
      guard !state.isStopped, !state.reads.initialFetchCompleted else {
        discard(result)
        return .idle
      }
      return accept(result, source: .initial, state: &state)?.delivery ?? .idle
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
    let affectedRegion = state.withLock { state -> OrbitDatabaseRegion? in
      guard !state.isStopped else { return nil }
      let affectedRegion = state.transactionRegion ?? .empty
      let observedRegion = state.observedRegion ?? .fullDatabase
      state.transactionRegion = nil
      state.pendingLocal = .skipped
      return observedRegion.overlaps(affectedRegion) ? affectedRegion : nil
    }
    guard let affectedRegion else { return }
    let commit = OrbitDatabaseCommit(origin: .local, region: affectedRegion)
    guard reducer.transactionNeedsFetch(commit) else { return }

    events.willFetch()
    let result = Result { try fetch(transaction) }
    state.withLock { state in
      guard !state.isStopped else { return }
      state.pendingLocal = .fetched(result)
    }
  }

  func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
    // A local commit this runtime saw coming was either fetched inside its transaction or judged
    // irrelevant there. Any other commit is refetched after the fact.
    if commit.origin == .local {
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
        break
      }
    }

    guard let affectedRegion = committedTransactionAffectedRegion(commit) else { return }
    events.databaseDidChange()
    requestRefetch(
      source: .transaction(commit.origin),
      reason: commit.origin == .local ? .databaseChange : .externalProcessChange,
      affectedRegion: affectedRegion,
      activeWriterBarrier: commit.activeWriterBarrier
    )
  }

  func databaseDidRollback() {
    let pending = state.withLock { state in
      defer {
        state.transactionRegion = nil
        state.pendingLocal = nil
      }
      return state.pendingLocal
    }
    discard(pending)
  }

  private func committedTransactionAffectedRegion(
    _ commit: OrbitDatabaseCommit
  ) -> OrbitDatabaseRegion? {
    let affectedRegion = state.withLock { state -> OrbitDatabaseRegion? in
      guard !state.isStopped else { return nil }
      let region = state.transactionRegion ?? commit.region
      state.transactionRegion = nil
      return (state.observedRegion ?? .fullDatabase).overlaps(region) ? region : nil
    }
    guard let affectedRegion, reducer.transactionNeedsFetch(commit) else { return nil }
    return affectedRegion
  }

  private func publishLocal(
    _ result: Result<OrbitValueObservationFetchOutput, any Error>
  ) {
    let delivery = state.withLock { state -> OrbitValueObservationDelivery in
      guard !state.isStopped else {
        discard(result)
        return .idle
      }
      guard let acceptance = accept(result, source: .transaction(.local), state: &state) else {
        return .idle
      }
      // The fetch inside this transaction includes every commit visible before this one, so it
      // also satisfies an older external invalidation whose read has not completed yet.
      state.reads.supersedePendingRead()
      state.refetches.supersedePendingFetch()
      state.dropOutstandingInvalidations()
      return acceptance.delivery
    }
    deliver(delivery, from: nil)
  }

  // MARK: - Reads

  private func requestRefetch(
    source: OrbitValueObservationSource,
    reason: OrbitValueObservationRefetchReason,
    affectedRegion: OrbitDatabaseRegion?,
    activeWriterBarrier: SQLitePoolWriterBarrier?
  ) {
    let action = state.withLock { state -> (
      initialRequest: OrbitValueObservationFetchRequest?,
      controllerRevision: UInt64?
    ) in
      guard !state.isStopped else { return (nil, nil) }

      // Recorded whether or not a controller will see them, so that one running later is told the
      // truth about what is outstanding. Accepting the initial value drops them again.
      state.refetchReasons.insert(reason)
      if case .transaction(let origin) = source, let affectedRegion {
        state.refetchCommits.append(OrbitDatabaseCommit(origin: origin, region: affectedRegion))
      }
      if let affectedRegion {
        state.affectedRegion = state.affectedRegion?.union(affectedRegion) ?? affectedRegion
      }
      if let activeWriterBarrier {
        state.activeWriterBarriers.append(activeWriterBarrier)
      }

      // Until the initial value is established, the existing revision loop makes that fetch cover
      // every invalidation and avoids publishing a refetch before the initial value.
      guard state.reads.initialFetchCompleted else {
        return (state.reads.requireRead(source: source), nil)
      }

      state.refetches.require(source: source)
      guard !state.isRefetching else { return (nil, nil) }
      state.isRefetching = true
      return (nil, state.refetches.invalidationRevision)
    }
    start(action.initialRequest)
    if let controllerRevision = action.controllerRevision {
      startRefetching(startedAt: controllerRevision)
    }
  }

  private func startRefetching(startedAt invalidationRevision: UInt64) {
    let operation = OrbitValueObservationRefetchOperation(
      snapshot: { [weak self] in
        self?.refetchSnapshot()
          ?? OrbitValueObservationRefetchSnapshot(
            hasActiveWriters: false,
            affectedRegion: nil,
            trackedRegion: nil,
            reasons: [],
            commits: []
          )
      },
      wait: { [weak self] in
        guard let self else { return }
        await self.waitForActiveWriters()
      },
      fetch: { [weak self] behavior in
        guard let self else { return .cancelled }
        return await self.performRefetch(publishing: behavior)
      }
    )
    Task { [weak self, refetchController] in
      let context = OrbitValueObservationRefetchContext(operation: operation)
      await refetchController.refetch(using: consume context)
      self?.finishRefetching(conclusively: operation.didConclude, startedAt: invalidationRevision)
    }
  }

  private func refetchSnapshot() -> OrbitValueObservationRefetchSnapshot {
    state.withLock { state in
      OrbitValueObservationRefetchSnapshot(
        hasActiveWriters: state.activeWriterBarriers.contains { $0.hasActiveWriters },
        affectedRegion: state.affectedRegion,
        trackedRegion: state.observedRegion,
        reasons: state.refetchReasons,
        commits: state.refetchCommits
      )
    }
  }

  private func waitForActiveWriters() async {
    let barriers = state.withLock { $0.activeWriterBarriers }
    for barrier in barriers where barrier.hasActiveWriters {
      await barrier.wait()
    }
  }

  private func performRefetch(
    publishing behavior: OrbitValueObservationPublicationBehavior
  ) async -> OrbitValueObservationFetchResult {
    guard
      let request = state.withLock({ state -> OrbitValueObservationFetchRequest? in
        guard !state.isStopped else { return nil }
        return state.refetches.beginFetch()
      })
    else { return .cancelled }

    events.willFetch()
    let result = await read()
    let completed = state.withLock { state -> (
      result: OrbitValueObservationFetchResult,
      delivery: OrbitValueObservationDelivery
    ) in
      guard !state.isStopped else {
        discard(result)
        return (.cancelled, .idle)
      }
      if behavior == .ifCurrent, !state.refetches.isCurrent(request) {
        state.refetches.finishSupersededFetch()
        discard(result)
        return (.superseded, .idle)
      }

      let acceptance = accept(
        result,
        source: request.source,
        forcingPublication: behavior == .force,
        state: &state
      )
      guard let acceptance else {
        state.refetches.finishSupersededFetch()
        return (.superseded, .idle)
      }

      state.refetches.finishPublishedFetch()
      state.dropOutstandingInvalidations()
      if acceptance.requiresObservableRefetch {
        state.refetches.require(source: .observable)
        state.refetchReasons.insert(.observableChange)
      }
      return (.published, acceptance.delivery)
    }
    deliver(completed.delivery, from: nil)
    return completed.result
  }

  private func finishRefetching(conclusively: Bool, startedAt invalidationRevision: UInt64) {
    let restartRevision = state.withLock { state -> UInt64? in
      state.isRefetching = false
      guard !state.isStopped, state.refetches.hasPendingFetch else { return nil }
      // A controller that reached a conclusive fetch did what it was asked and is run again for
      // whatever arrived since. One that returned without ever concluding is only run again when
      // there is something new for it to look at, so a controller that never fetches raises the
      // invalidation it was given once and then stops, rather than spinning.
      guard conclusively || state.refetches.invalidationRevision != invalidationRevision else {
        return nil
      }
      state.isRefetching = true
      return state.refetches.invalidationRevision
    }
    if let restartRevision { startRefetching(startedAt: restartRevision) }
  }

  private func start(_ request: OrbitValueObservationFetchRequest?) {
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
    request: OrbitValueObservationFetchRequest
  ) {
    let completed = state.withLock {
      state -> (OrbitValueObservationDelivery, OrbitValueObservationFetchRequest?) in
      guard !state.isStopped else {
        discard(result)
        return (.idle, nil)
      }
      let delivery: OrbitValueObservationDelivery
      if state.reads.completeRead(request) {
        delivery = accept(result, source: request.source, state: &state)?.delivery ?? .idle
      } else {
        discard(result)
        delivery = .idle
      }
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
    forcingPublication: Bool = false,
    state: inout State
  ) -> OrbitValueObservationAcceptance? {
    let outcome: Result<OrbitValueObservationChange<Value>, any Error>
    var requiresObservableRefetch = false
    switch result {
    case .success(let output):
      let dependenciesAreCurrent = externalTracking.accept(output.externalDependencies)
      guard dependenciesAreCurrent || forcingPublication else { return nil }
      requiresObservableRefetch = !dependenciesAreCurrent
      completeInitialFetch(state: &state)
      state.observedRegion = output.region
      do {
        guard case .emit(let value) = try reducer.reduce(output.payload) else {
          return OrbitValueObservationAcceptance(
            delivery: .idle,
            requiresObservableRefetch: requiresObservableRefetch
          )
        }
        outcome = .success(OrbitValueObservationChange(value: value, source: source))
      } catch {
        outcome = .failure(error)
      }
    case .failure(let error):
      completeInitialFetch(state: &state)
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
    return OrbitValueObservationAcceptance(
      delivery: OrbitValueObservationDelivery(
        shouldDrain: state.deliveries.enqueue(publication),
        didFail: didFail
      ),
      requiresObservableRefetch: requiresObservableRefetch
    )
  }

  /// Marks the initial read done, dropping the invalidations it answered.
  ///
  /// Every invalidation raised before the initial value forced that read to run again, so the one
  /// finally accepted covers all of them and a controller running afterwards must not see them.
  private func completeInitialFetch(state: inout State) {
    guard !state.reads.initialFetchCompleted else { return }
    state.reads.completeInitialFetch()
    state.dropOutstandingInvalidations()
  }

  private func discard(
    _ result: Result<OrbitValueObservationFetchOutput, any Error>
  ) {
    guard case .success(let output) = result else { return }
    output.externalDependencies?.cancel()
  }

  private func discard(_ pending: PendingLocal?) {
    guard case .fetched(let result) = pending else { return }
    discard(result)
  }

  // MARK: - Delivery

  private func deliver(
    _ delivery: OrbitValueObservationDelivery,
    from isolation: isolated (any Actor)?
  ) {
    if delivery.didFail {
      externalTracking.stop()
      stopObservingTransactions()
    }
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
    let stopped = state.withLock { state -> (Bool, PendingLocal?) in
      guard !state.isStopped else { return (false, nil) }
      state.isStopped = true
      defer { state.pendingLocal = nil }
      return (true, state.pendingLocal)
    }
    guard stopped.0 else { return }
    discard(stopped.1)
    externalTracking.stop()
    stopObservingTransactions()
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
