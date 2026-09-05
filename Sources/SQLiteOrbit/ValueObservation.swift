/// Why a value observation fetched a value.
public enum ValueObservationSource: Hashable, Sendable {
  /// The fetch that establishes an observation's initial value.
  case initial

  /// A fetch associated with a committed transaction.
  case transaction(DatabaseTransactionOrigin)
}

/// A value emitted by an observation, together with the event that prompted its fetch.
public struct ValueObservationChange<Value: Sendable>: Sendable {
  public let value: Value
  public let source: ValueObservationSource

  public init(value: Value, source: ValueObservationSource) {
    self.value = value
    self.source = source
  }
}

extension ValueObservationChange: Equatable where Value: Equatable {}
extension ValueObservationChange: Hashable where Value: Hashable {}

private typealias ValueObservationFetch =
  @Sendable (borrowing SQLiteReadTransaction) throws -> any Sendable

private enum ValueObservationReduction<Value: Sendable>: Sendable {
  case emit(Value)
  case skip
}

private enum ValueObservationPrevious<Value: Sendable>: Sendable {
  case none
  case value(Value)
}

private struct ValueObservationReducer<Value: Sendable>: Sendable {
  let reduce: @Sendable (any Sendable) throws -> ValueObservationReduction<Value>
  let transactionNeedsFetch: @Sendable (DatabaseCommit) -> Bool
  var events = ValueObservationEvents()
}

/// One `handleEvents` operator's callbacks.
private struct ValueObservationEventHandler: Sendable {
  let willStart: (@Sendable () -> Void)?
  let willFetch: (@Sendable () -> Void)?
  let databaseDidChange: (@Sendable () -> Void)?
  let didFail: (@Sendable (any Error) -> Void)?
  let didCancel: (@Sendable () -> Void)?
}

/// The lifecycle callbacks a chain of operators installed, in the order they were written.
///
/// These are the events the runtime raises for itself rather than for one value, so unlike
/// ``ValueObservationReducer/reduce`` they cannot live at a single position in the chain.
private struct ValueObservationEvents: Sendable {
  private var handlers = [ValueObservationEventHandler]()

  func appending(_ handler: ValueObservationEventHandler) -> Self {
    var events = self
    events.handlers.append(handler)
    return events
  }

  func willStart() { send(\.willStart) }
  func willFetch() { send(\.willFetch) }
  func databaseDidChange() { send(\.databaseDidChange) }
  func didCancel() { send(\.didCancel) }

  func didFail(_ error: any Error) {
    for handler in handlers { handler.didFail?(error) }
  }

  private func send(_ callback: (ValueObservationEventHandler) -> (@Sendable () -> Void)?) {
    for handler in handlers { callback(handler)?() }
  }
}

/// A query that is fetched initially and again whenever the observed database changes.
public struct ValueObservation<Value: Sendable>: Sendable {
  private let definition: ValueObservationDefinition<Value>

  private init(
    fetch: @escaping ValueObservationFetch,
    makeReducer: @escaping @Sendable () -> ValueObservationReducer<Value>
  ) {
    self.definition = ValueObservationDefinition(
      fetch: fetch,
      makeReducer: makeReducer
    )
  }

  /// Creates an observation whose value is produced by `fetch`.
  public static func tracking(
    _ fetch: @escaping @Sendable (borrowing SQLiteReadTransaction) throws -> Value
  ) -> Self {
    Self(
      fetch: fetch,
      makeReducer: {
        ValueObservationReducer(
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

  /// Returns an observation that shares this one's fetch, with a reducer derived from this one's.
  ///
  /// The derivation runs once per runtime, so an operator that keeps state between values can
  /// create it here and have every subscriber to that runtime share it.
  private func mapReducer<Output: Sendable>(
    _ derive:
      @escaping @Sendable (ValueObservationReducer<Value>) -> ValueObservationReducer<Output>
  ) -> ValueObservation<Output> {
    let definition = self.definition
    return ValueObservation<Output>(
      fetch: definition.fetch,
      makeReducer: { derive(definition.makeReducer()) }
    )
  }

  /// Returns an observation that reduces each value this one emits, passing through the values it
  /// skips and the transaction filtering and lifecycle callbacks it carries.
  private func mapReduction<Output: Sendable>(
    _ transform: @escaping @Sendable (Value) throws -> ValueObservationReduction<Output>
  ) -> ValueObservation<Output> {
    mapReduction(perRuntime: { transform })
  }

  /// Returns an observation that reduces each value this one emits, using a transform built once
  /// per runtime so that it can keep state between values.
  private func mapReduction<Output: Sendable>(
    perRuntime makeTransform:
      @escaping @Sendable () -> @Sendable (Value) throws -> ValueObservationReduction<Output>
  ) -> ValueObservation<Output> {
    mapReducer { upstream in
      let transform = makeTransform()
      return ValueObservationReducer<Output>(
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
  /// The transform runs after the database access has ended. A thrown error ends the observation.
  public func map<Output: Sendable>(
    _ transform: @escaping @Sendable (Value) throws -> Output
  ) -> ValueObservation<Output> {
    mapReduction { .emit(try transform($0)) }
  }

  /// Produces only the values that satisfy `predicate`.
  ///
  /// The predicate runs after the database access has ended. A thrown error ends the observation.
  public func filter(
    _ predicate: @escaping @Sendable (Value) throws -> Bool
  ) -> Self {
    mapReduction { try predicate($0) ? .emit($0) : .skip }
  }

  /// Transforms each value and suppresses `nil` results.
  ///
  /// The transform runs after the database access has ended. A thrown error ends the observation.
  public func compactMap<Output: Sendable>(
    _ transform: @escaping @Sendable (Value) throws -> Output?
  ) -> ValueObservation<Output> {
    mapReduction { try transform($0).map(ValueObservationReduction.emit) ?? .skip }
  }

  /// Suppresses a value when `predicate` considers it equal to the preceding emitted value.
  public func removeDuplicates(
    by predicate: @escaping @Sendable (Value, Value) -> Bool
  ) -> Self {
    mapReduction(perRuntime: {
      let previous = Lock<ValueObservationPrevious<Value>>(.none)
      return { value in
        previous.withLock { previous in
          if case .value(let previousValue) = previous, predicate(previousValue, value) {
            return .skip
          }
          previous = .value(value)
          return .emit(value)
        }
      }
    })
  }

  /// Skips fetching after committed transactions for which `predicate` returns `false`.
  ///
  /// The initial value is always fetched. Inspect ``DatabaseCommit/origin`` to distinguish a
  /// notification sent by this process from one sent by another process.
  public func filterTransactions(
    _ predicate: @escaping @Sendable (DatabaseCommit) -> Bool
  ) -> Self {
    filterTransactions { commit, _ in predicate(commit) }
  }

  /// Skips fetching after committed transactions for which `predicate` returns `false`.
  ///
  /// `previousValue` is the latest value accepted for delivery, or `nil` before the observation
  /// produces its first value. A value suppressed by `removeDuplicates` does not replace it. The
  /// initial value is always fetched.
  public func filterTransactions(
    _ predicate:
      @escaping @Sendable (
        _ commit: DatabaseCommit,
        _ previousValue: Value?
      ) -> Bool
  ) -> Self {
    mapReducer { upstream in
      let previous = Lock<ValueObservationPrevious<Value>>(.none)
      return ValueObservationReducer(
        reduce: { payload in
          let reduction = try upstream.reduce(payload)
          if case .emit(let value) = reduction { previous.withLock { $0 = .value(value) } }
          return reduction
        },
        transactionNeedsFetch: { commit in
          guard upstream.transactionNeedsFetch(commit) else { return false }
          let previousValue = previous.withLock { previous -> Value? in
            guard case .value(let value) = previous else { return nil }
            return value
          }
          return predicate(commit, previousValue)
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
  public func handleEvents(
    willStart: (@Sendable () -> Void)? = nil,
    willFetch: (@Sendable () -> Void)? = nil,
    databaseDidChange: (@Sendable () -> Void)? = nil,
    didReceiveValue: (@Sendable (Value) -> Void)? = nil,
    didFail: (@Sendable (any Error) -> Void)? = nil,
    didCancel: (@Sendable () -> Void)? = nil
  ) -> Self {
    mapReducer { upstream in
      ValueObservationReducer(
        reduce: { payload in
          let reduction = try upstream.reduce(payload)
          if case .emit(let value) = reduction { didReceiveValue?(value) }
          return reduction
        },
        transactionNeedsFetch: upstream.transactionNeedsFetch,
        events: upstream.events.appending(
          ValueObservationEventHandler(
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

  /// Starts this observation and delivers its changes through callbacks using an asynchronous
  /// scheduler.
  @discardableResult
  public func subscribe<Database: SQLiteObservableDatabase>(
    to database: Database,
    isolation: isolated (any Actor)? = #isolation,
    onError: @escaping @Sendable (any Error) -> Void,
    onChange: @escaping @Sendable (ValueObservationChange<Value>) -> Void
  ) throws -> OrbitSubscription {
    try subscribe(
      to: database,
      scheduling: AsyncValueObservationScheduler.async(),
      isolation: isolation,
      onError: onError,
      onChange: onChange
    )
  }

  /// Starts this observation and delivers its changes through `scheduler`.
  ///
  /// The transaction observer is registered before the initial fetch, so a commit cannot fall into
  /// a gap between fetching and listening. A fetch error calls `onError` and ends the subscription.
  /// A scheduler that requests an immediate initial value makes this method perform a blocking read.
  @discardableResult
  public func subscribe<Database: SQLiteObservableDatabase, Scheduler: ValueObservationScheduler>(
    to database: Database,
    scheduling scheduler: Scheduler,
    isolation: isolated (any Actor)? = #isolation,
    onError: @escaping @Sendable (any Error) -> Void,
    onChange: @escaping @Sendable (ValueObservationChange<Value>) -> Void
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
  @MainActor
  @discardableResult
  public func subscribe<
    Database: SQLiteObservableDatabase,
    Scheduler: ValueObservationMainActorScheduler
  >(
    to database: Database,
    scheduling scheduler: Scheduler,
    onError: @escaping @MainActor @Sendable (any Error) -> Void,
    onChange: @escaping @MainActor @Sendable (ValueObservationChange<Value>) -> Void
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
  /// The observation starts when iteration begins. `bufferingPolicy` decides which elements
  /// survive when the observation produces them faster than the sequence is consumed; by default
  /// every one of them is kept.
  public func changes<Database: SQLiteObservableDatabase>(
    in database: Database,
    bufferingPolicy: ValueObservationBufferingPolicy = .unbounded
  ) -> ValueObservationSequence<ValueObservationChange<Value>> {
    ValueObservationSequence(bufferingPolicy: bufferingPolicy) { onError, onChange in
      try subscribe(to: database, onError: onError, onChange: onChange)
    }
  }

  /// Returns an asynchronous sequence of observed values without their source metadata.
  ///
  /// The observation starts when iteration begins. `bufferingPolicy` decides which elements
  /// survive when the observation produces them faster than the sequence is consumed; by default
  /// every one of them is kept.
  public func values<Database: SQLiteObservableDatabase>(
    in database: Database,
    bufferingPolicy: ValueObservationBufferingPolicy = .unbounded
  ) -> ValueObservationSequence<Value> {
    ValueObservationSequence(bufferingPolicy: bufferingPolicy) { onError, onValue in
      try subscribe(
        to: database,
        onError: onError,
        onChange: { onValue($0.value) }
      )
    }
  }
}

extension ValueObservation where Value: Equatable {
  /// Suppresses consecutive equal values.
  public func removeDuplicates() -> Self {
    removeDuplicates(by: ==)
  }
}

private final class ValueObservationDefinition<Value: Sendable>: Sendable {
  let fetch: ValueObservationFetch
  let makeReducer: @Sendable () -> ValueObservationReducer<Value>

  private struct WeakRuntime: Sendable {
    let value: @Sendable () -> ValueObservationRuntime<Value>?

    init(_ value: ValueObservationRuntime<Value>) {
      self.value = { [weak value] in value }
    }
  }

  private let runtimes = Lock<[ObjectIdentifier: WeakRuntime]>([:])

  init(
    fetch: @escaping ValueObservationFetch,
    makeReducer: @escaping @Sendable () -> ValueObservationReducer<Value>
  ) {
    self.fetch = fetch
    self.makeReducer = makeReducer
  }

  func runtime<Database: SQLiteObservableDatabase>(
    for database: Database
  ) throws -> ValueObservationRuntime<Value> {
    let identifier = ObjectIdentifier(database)
    if let existing = activeRuntime(for: identifier) { return existing }

    let candidate = ValueObservationRuntime(
      database: database,
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
  ) -> ValueObservationRuntime<Value>? {
    runtimes.withLock { runtimes in
      guard let runtime = runtimes[identifier]?.value(), runtime.isActive else {
        runtimes.removeValue(forKey: identifier)
        return nil
      }
      return runtime
    }
  }
}

/// What a caller must do outside the lock once a fetch has been accepted.
private struct ValueObservationDelivery: Sendable {
  static let idle = Self()

  /// Whether the caller took on draining the delivery queue.
  var shouldDrain = false

  /// Whether accepting the fetch ended the observation.
  var didFail = false
}

private final class ValueObservationRuntime<Value: Sendable>: DatabaseTransactionObserver {
  private enum PendingLocal: Sendable {
    case fetched(Result<any Sendable, any Error>)
    case skipped
  }

  private struct State: Sendable {
    /// Whether the runtime has been discarded, by a failure or by its definition replacing it.
    ///
    /// This outlives every other piece of state, so it is checked before any of them is consulted
    /// rather than being folded into one of them.
    var isStopped = false

    /// What the fetch performed inside a committing local transaction produced, until the commit
    /// it belongs to succeeds or rolls back.
    var pendingLocal: PendingLocal?

    var reads = ValueObservationReadCoordinator()
    var subscribers = ValueObservationSubscriberRegistry<Value>()
    var deliveries = ValueObservationDeliveryQueue<Value>()
  }

  private let fetch: ValueObservationFetch
  private let read: @Sendable () async -> Result<any Sendable, any Error>
  private let readBlocking: @Sendable () -> Result<any Sendable, any Error>
  private let reducer: ValueObservationReducer<Value>
  private var events: ValueObservationEvents { reducer.events }
  private let state = Lock(State())
  private let transactionSubscription = Lock<OrbitSubscription?>(nil)

  init<Database: SQLiteObservableDatabase>(
    database: Database,
    fetch: @escaping ValueObservationFetch,
    reducer: ValueObservationReducer<Value>
  ) {
    self.fetch = fetch
    self.reducer = reducer
    self.read = {
      do {
        let value = try await database.read { transaction in
          try fetch(transaction)
        }
        return .success(value)
      } catch {
        return .failure(error)
      }
    }
    self.readBlocking = {
      Result {
        try database.readBlocking { transaction in
          try fetch(transaction)
        }
      }
    }
  }

  func install<Database: SQLiteObservableDatabase>(on database: Database) throws {
    let observer = WeakValueObservationObserver(runtime: self)
    let subscription = try database.subscribe(transactionObserver: observer)
    transactionSubscription.withLock { $0 = subscription }
  }

  var isActive: Bool {
    state.withLock { !$0.isStopped }
  }

  // MARK: - Subscribers

  func addSubscriber<Scheduler: ValueObservationScheduler>(
    scheduling scheduler: Scheduler,
    isolation: isolated (any Actor)?,
    onError: @escaping @Sendable (any Error) -> Void,
    onChange: @escaping @Sendable (ValueObservationChange<Value>) -> Void
  ) -> OrbitSubscription {
    let subscriber = ValueObservationSubscriber(
      scheduler: scheduler,
      onError: onError,
      onChange: onChange
    )
    let registration = state.withLock {
      state -> ValueObservationSubscriberRegistry<Value>.Registration in
      if let error = state.subscribers.terminalError { return .failure(error) }
      precondition(!state.isStopped, "cannot subscribe to a discarded observation runtime")
      return state.subscribers.add(subscriber)
    }
    switch registration {
    case .success(let (identifier, latest)):
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
    let started = state.withLock { state -> (request: ValueObservationReadRequest?, start: Bool) in
      guard !state.isStopped, let request = state.reads.requireInitialRead() else {
        return (nil, false)
      }
      return (request, state.reads.takeDidStart())
    }
    if started.start { events.willStart() }
    start(started.request)
  }

  func fetchInitialValueImmediatelyIfNeeded(
    isolation: isolated (any Actor)?
  ) {
    let started = state.withLock { state -> (shouldFetch: Bool, start: Bool) in
      guard !state.isStopped, !state.reads.initialFetchCompleted else { return (false, false) }
      // Discard an older asynchronous fetch if one is already in flight.
      state.reads.discardInFlightRead()
      return (true, state.reads.takeDidStart())
    }
    guard started.shouldFetch else { return }

    if started.start { events.willStart() }
    events.willFetch()
    let result = readBlocking()
    let delivery = state.withLock { state -> ValueObservationDelivery in
      guard !state.isStopped, !state.reads.initialFetchCompleted else { return .idle }
      return accept(result, source: .initial, state: &state)
    }
    deliver(delivery, from: isolation)
  }

  // MARK: - Transactions

  func databaseWillCommit(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws {
    let commit = DatabaseCommit(origin: .local)
    guard transactionNeedsFetch(commit) else {
      state.withLock { state in
        guard !state.isStopped else { return }
        state.pendingLocal = .skipped
      }
      return
    }
    events.willFetch()
    let result = Result { try fetch(transaction) }
    state.withLock { state in
      guard !state.isStopped else { return }
      state.pendingLocal = .fetched(result)
    }
  }

  func databaseDidCommit(_ commit: DatabaseCommit) {
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
        guard transactionNeedsFetch(commit) else { return }
        events.databaseDidChange()
        requestRead(source: .transaction(.local))
        return
      }

    case .external:
      guard transactionNeedsFetch(commit) else { return }
      events.databaseDidChange()
      requestRead(source: .transaction(.external))
    }
  }

  func databaseDidRollback() {
    state.withLock { $0.pendingLocal = nil }
  }

  private func transactionNeedsFetch(_ commit: DatabaseCommit) -> Bool {
    reducer.transactionNeedsFetch(commit)
  }

  private func publishLocal(_ result: Result<any Sendable, any Error>) {
    let delivery = state.withLock { state -> ValueObservationDelivery in
      guard !state.isStopped else { return .idle }
      // The fetch inside this transaction includes every commit visible before this one, so it
      // also satisfies an older external invalidation whose read has not completed yet.
      state.reads.supersedePendingRead()
      return accept(result, source: .transaction(.local), state: &state)
    }
    deliver(delivery, from: nil)
  }

  // MARK: - Reads

  private func requestRead(source: ValueObservationSource) {
    let request = state.withLock { state -> ValueObservationReadRequest? in
      guard !state.isStopped else { return nil }
      return state.reads.requireRead(source: source)
    }
    start(request)
  }

  private func start(_ request: ValueObservationReadRequest?) {
    guard let request else { return }
    Task { [weak self] in
      guard let self else { return }
      events.willFetch()
      let result = await read()
      completeRead(result, request: request)
    }
  }

  private func completeRead(
    _ result: Result<any Sendable, any Error>,
    request: ValueObservationReadRequest
  ) {
    let completed = state.withLock {
      state -> (ValueObservationDelivery, ValueObservationReadRequest?) in
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

  /// Reduces `result` and queues whatever it owes subscribers.
  ///
  /// Queuing here rather than in a second locked step is what orders the publications: two
  /// contexts can accept a fetch at once, and the later value must not be queued first.
  private func accept(
    _ result: Result<any Sendable, any Error>,
    source: ValueObservationSource,
    state: inout State
  ) -> ValueObservationDelivery {
    state.reads.completeInitialFetch()
    let outcome: Result<ValueObservationChange<Value>, any Error>
    switch result {
    case .success(let payload):
      do {
        guard case .emit(let value) = try reducer.reduce(payload) else { return .idle }
        outcome = .success(ValueObservationChange(value: value, source: source))
      } catch {
        outcome = .failure(error)
      }
    case .failure(let error):
      outcome = .failure(error)
    }

    let owed: [ValueObservationSubscriber<Value>]
    var didFail = false
    switch outcome {
    case .success(let change):
      owed = state.subscribers.publish(change)
    case .failure(let error):
      state.isStopped = true
      didFail = true
      owed = state.subscribers.fail(error)
    }
    let publication = ValueObservationPublication(outcome: outcome, subscribers: owed)
    return ValueObservationDelivery(
      shouldDrain: state.deliveries.enqueue(publication),
      didFail: didFail
    )
  }

  // MARK: - Delivery

  private func deliver(
    _ delivery: ValueObservationDelivery,
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

private final class WeakValueObservationObserver<Value: Sendable>: DatabaseTransactionObserver {
  private let runtime: @Sendable () -> ValueObservationRuntime<Value>?

  init(runtime: ValueObservationRuntime<Value>) {
    self.runtime = { [weak runtime] in runtime }
  }

  func databaseWillCommit(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws {
    try runtime()?.databaseWillCommit(transaction)
  }

  func databaseDidCommit(_ commit: DatabaseCommit) {
    runtime()?.databaseDidCommit(commit)
  }

  func databaseDidRollback() {
    runtime()?.databaseDidRollback()
  }
}
