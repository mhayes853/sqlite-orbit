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

  /// Transforms each value produced by this observation.
  ///
  /// The transform runs after the database access has ended. A thrown error ends the observation.
  public func map<Output: Sendable>(
    _ transform: @escaping @Sendable (Value) throws -> Output
  ) -> ValueObservation<Output> {
    let definition = self.definition
    return ValueObservation<Output>(
      fetch: definition.fetch,
      makeReducer: {
        let upstream = definition.makeReducer()
        return ValueObservationReducer<Output>(
          reduce: { payload in
            switch try upstream.reduce(payload) {
            case .emit(let value):
              return .emit(try transform(value))
            case .skip:
              return .skip
            }
          },
          transactionNeedsFetch: upstream.transactionNeedsFetch
        )
      }
    )
  }

  /// Produces only the values that satisfy `predicate`.
  ///
  /// The predicate runs after the database access has ended. A thrown error ends the observation.
  public func filter(
    _ predicate: @escaping @Sendable (Value) throws -> Bool
  ) -> Self {
    let definition = self.definition
    return Self(
      fetch: definition.fetch,
      makeReducer: {
        let upstream = definition.makeReducer()
        return ValueObservationReducer(
          reduce: { payload in
            switch try upstream.reduce(payload) {
            case .emit(let value):
              return try predicate(value) ? .emit(value) : .skip
            case .skip:
              return .skip
            }
          },
          transactionNeedsFetch: upstream.transactionNeedsFetch
        )
      }
    )
  }

  /// Transforms each value and suppresses `nil` results.
  ///
  /// The transform runs after the database access has ended. A thrown error ends the observation.
  public func compactMap<Output: Sendable>(
    _ transform: @escaping @Sendable (Value) throws -> Output?
  ) -> ValueObservation<Output> {
    let definition = self.definition
    return ValueObservation<Output>(
      fetch: definition.fetch,
      makeReducer: {
        let upstream = definition.makeReducer()
        return ValueObservationReducer<Output>(
          reduce: { payload in
            switch try upstream.reduce(payload) {
            case .emit(let value):
              return try transform(value).map(ValueObservationReduction.emit) ?? .skip
            case .skip:
              return .skip
            }
          },
          transactionNeedsFetch: upstream.transactionNeedsFetch
        )
      }
    )
  }

  /// Suppresses a value when `predicate` considers it equal to the preceding emitted value.
  public func removeDuplicates(
    by predicate: @escaping @Sendable (Value, Value) -> Bool
  ) -> Self {
    let definition = self.definition
    return Self(
      fetch: definition.fetch,
      makeReducer: {
        let upstream = definition.makeReducer()
        let previous = Lock<ValueObservationPrevious<Value>>(.none)
        return ValueObservationReducer(
          reduce: { payload in
            switch try upstream.reduce(payload) {
            case .emit(let value):
              let isDuplicate = previous.withLock { previous in
                switch previous {
                case .none:
                  previous = .value(value)
                  return false
                case .value(let previousValue):
                  guard !predicate(previousValue, value) else { return true }
                  previous = .value(value)
                  return false
                }
              }
              return isDuplicate ? .skip : .emit(value)
            case .skip:
              return .skip
            }
          },
          transactionNeedsFetch: upstream.transactionNeedsFetch
        )
      }
    )
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
    let definition = self.definition
    return Self(
      fetch: definition.fetch,
      makeReducer: {
        let upstream = definition.makeReducer()
        let previous = Lock<ValueObservationPrevious<Value>>(.none)
        return ValueObservationReducer(
          reduce: { payload in
            let reduction = try upstream.reduce(payload)
            if case .emit(let value) = reduction {
              previous.withLock { $0 = .value(value) }
            }
            return reduction
          },
          transactionNeedsFetch: { commit in
            guard upstream.transactionNeedsFetch(commit) else { return false }
            let previousValue = previous.withLock { previous -> Value? in
              switch previous {
              case .none:
                nil
              case .value(let value):
                value
              }
            }
            return predicate(commit, previousValue)
          }
        )
      }
    )
  }

  /// Starts this observation and delivers its changes through callbacks using an asynchronous
  /// scheduler.
  @discardableResult
  public func subscribe<Database: SQLiteObservableDatabase>(
    to database: Database,
    isolation: isolated (any Actor)? = #isolation,
    onError: @escaping @Sendable (any Error) -> Void,
    onChange: @escaping @Sendable (ValueObservationChange<Value>) -> Void
  ) throws -> SQLiteCrossSubscription {
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
  ) throws -> SQLiteCrossSubscription {
    try subscribeImplementation(
      to: database,
      scheduling: scheduler,
      isolation: isolation,
      onError: onError,
      onChange: onChange
    )
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
  ) throws -> SQLiteCrossSubscription {
    try subscribeImplementation(
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

  private func subscribeImplementation<Database: SQLiteObservableDatabase>(
    to database: Database,
    scheduling scheduler: any ValueObservationScheduler,
    isolation: isolated (any Actor)?,
    onError: @escaping @Sendable (any Error) -> Void,
    onChange: @escaping @Sendable (ValueObservationChange<Value>) -> Void
  ) throws -> SQLiteCrossSubscription {
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

  /// Returns an asynchronous sequence of values and the sources that prompted their fetches.
  public func changes<Database: SQLiteObservableDatabase>(
    in database: Database
  ) -> AsyncThrowingStream<ValueObservationChange<Value>, any Error> {
    let holder = ValueObservationSubscriptionHolder()
    return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      do {
        let subscription = try subscribe(
          to: database,
          onError: { continuation.finish(throwing: $0) },
          onChange: { continuation.yield($0) }
        )
        holder.store(subscription)
      } catch {
        continuation.finish(throwing: error)
      }
      continuation.onTermination = { _ in holder.cancel() }
    }
  }

  /// Returns an asynchronous sequence of observed values without their source metadata.
  public func values<Database: SQLiteObservableDatabase>(
    in database: Database
  ) -> AsyncThrowingStream<Value, any Error> {
    let holder = ValueObservationSubscriptionHolder()
    return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      do {
        let subscription = try subscribe(
          to: database,
          onError: { continuation.finish(throwing: $0) },
          onChange: { continuation.yield($0.value) }
        )
        holder.store(subscription)
      } catch {
        continuation.finish(throwing: error)
      }
      continuation.onTermination = { _ in holder.cancel() }
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

private final class ValueObservationRuntime<Value: Sendable>: DatabaseTransactionObserver {
  private enum PendingLocal: Sendable {
    case fetched(Result<any Sendable, any Error>)
    case skipped
  }

  private struct Subscriber: Sendable {
    let scheduler: any ValueObservationScheduler
    let onError: @Sendable (any Error) -> Void
    let onChange: @Sendable (ValueObservationChange<Value>) -> Void

    func receive(
      _ change: ValueObservationChange<Value>,
      from isolation: isolated (any Actor)?
    ) {
      scheduler.schedule(from: isolation) { onChange(change) }
    }

    func receive(
      _ error: any Error,
      from isolation: isolated (any Actor)?
    ) {
      scheduler.schedule(from: isolation) { onError(error) }
    }
  }

  private enum SubscriberRegistration: Sendable {
    case active(UInt64, ValueObservationChange<Value>?)
    case failed(any Error)
  }

  private struct State: Sendable {
    var nextSubscriberIdentifier: UInt64 = 0
    var subscribers = [UInt64: Subscriber]()
    var latest: ValueObservationChange<Value>?
    var initialFetchCompleted = false
    var pendingLocal: PendingLocal?
    var revision: UInt64 = 0
    var readIsRequired = false
    var readIsInFlight = false
    var requiredReadSource = ValueObservationSource.initial
    var publications = [Publication]()
    var isDelivering = false
    var terminalError: (any Error)?
    var isStopped = false
  }

  private struct ReadRequest: Sendable {
    let revision: UInt64
    let source: ValueObservationSource
  }

  private enum Publication: Sendable {
    case change(ValueObservationChange<Value>, [Subscriber])
    case failure(any Error, [Subscriber])
  }

  private let fetch: ValueObservationFetch
  private let read: @Sendable () async -> Result<any Sendable, any Error>
  private let readBlocking: @Sendable () -> Result<any Sendable, any Error>
  private let reducer: ValueObservationReducer<Value>
  private let state = Lock(State())
  private let transactionSubscription = Lock<SQLiteCrossSubscription?>(nil)

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

  func addSubscriber<Scheduler: ValueObservationScheduler>(
    scheduling scheduler: Scheduler,
    isolation: isolated (any Actor)?,
    onError: @escaping @Sendable (any Error) -> Void,
    onChange: @escaping @Sendable (ValueObservationChange<Value>) -> Void
  ) -> SQLiteCrossSubscription {
    let subscriber = Subscriber(
      scheduler: scheduler,
      onError: onError,
      onChange: onChange
    )
    let registration = state.withLock { state -> SubscriberRegistration in
      if let error = state.terminalError { return .failed(error) }
      precondition(!state.isStopped, "cannot subscribe to a discarded observation runtime")
      let identifier = state.nextSubscriberIdentifier
      state.nextSubscriberIdentifier &+= 1
      state.subscribers[identifier] = subscriber
      return .active(identifier, state.latest)
    }
    switch registration {
    case .active(let identifier, let latest):
      if let latest {
        subscriber.receive(latest, from: isolation)
      }
      return SQLiteCrossSubscription { [self] in removeSubscriber(identifier) }
    case .failed(let error):
      subscriber.receive(error, from: isolation)
      return SQLiteCrossSubscription {}
    }
  }

  func fetchInitialValueIfNeeded() {
    let request = state.withLock { state -> ReadRequest? in
      guard
        !state.isStopped,
        !state.initialFetchCompleted,
        !state.readIsInFlight,
        !state.readIsRequired
      else { return nil }
      state.readIsRequired = true
      state.requiredReadSource = .initial
      return takeReadRequestIfPossible(state: &state)
    }
    start(request)
  }

  func fetchInitialValueImmediatelyIfNeeded(
    isolation: isolated (any Actor)?
  ) {
    let shouldFetch = state.withLock { state in
      guard !state.isStopped, !state.initialFetchCompleted else { return false }
      // Discard an older asynchronous fetch if one is already in flight.
      state.revision &+= 1
      return true
    }
    guard shouldFetch else { return }

    let result = readBlocking()
    let completion = state.withLock { state -> (deliver: Bool, stop: Bool) in
      guard !state.isStopped, !state.initialFetchCompleted,
        let publication = accept(result, source: .initial, state: &state)
      else { return (false, false) }
      let shouldStop = if case .failure = publication { true } else { false }
      return (enqueue(publication, state: &state), shouldStop)
    }

    if completion.stop { stopObservingTransactions() }
    if completion.deliver { deliverPublications(from: isolation) }
  }

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
    let result = Result { try fetch(transaction) }
    state.withLock { state in
      guard !state.isStopped else { return }
      state.pendingLocal = .fetched(result)
    }
  }

  func databaseDidCommit(_ commit: DatabaseCommit) {
    switch commit.origin {
    case .local:
      let pending = state.withLock { $0.pendingLocal.take() }
      switch pending {
      case .skipped:
        return
      case .fetched(let result):
        publishLocal(result)
        return
      case nil:
        guard transactionNeedsFetch(commit) else { return }
        requestRead(source: .transaction(.local))
        return
      }

    case .external:
      guard transactionNeedsFetch(commit) else { return }
      requestRead(source: .transaction(.external))
    }
  }

  private func transactionNeedsFetch(_ commit: DatabaseCommit) -> Bool {
    reducer.transactionNeedsFetch(commit)
  }

  private func publishLocal(_ result: Result<any Sendable, any Error>) {
    let publication = state.withLock { state -> Publication? in
      guard !state.isStopped else { return nil }
      state.revision &+= 1
      // The fetch inside this transaction includes every commit visible before this one, so it
      // also satisfies an older external invalidation whose read has not completed yet.
      state.readIsRequired = false
      return accept(result, source: .transaction(.local), state: &state)
    }
    if let publication { deliver(publication) }
  }

  func databaseDidRollback() {
    state.withLock { $0.pendingLocal = nil }
  }

  private func requestRead(source: ValueObservationSource) {
    let request = state.withLock { state -> ReadRequest? in
      guard !state.isStopped else { return nil }
      state.revision &+= 1
      state.readIsRequired = true
      state.requiredReadSource = source
      return takeReadRequestIfPossible(state: &state)
    }
    start(request)
  }

  private func takeReadRequestIfPossible(state: inout State) -> ReadRequest? {
    guard
      !state.isStopped,
      state.readIsRequired,
      !state.readIsInFlight
    else { return nil }
    state.readIsRequired = false
    state.readIsInFlight = true
    return ReadRequest(revision: state.revision, source: state.requiredReadSource)
  }

  private func start(_ request: ReadRequest?) {
    guard let request else { return }
    Task { [weak self] in
      guard let self else { return }
      let result = await read()
      completeRead(result, request: request)
    }
  }

  private func completeRead(
    _ result: Result<any Sendable, any Error>,
    request: ReadRequest
  ) {
    let completed = state.withLock { state -> (Publication?, ReadRequest?) in
      guard !state.isStopped else { return (nil, nil) }
      state.readIsInFlight = false
      let publication =
        request.revision == state.revision
        ? accept(result, source: request.source, state: &state)
        : nil
      return (publication, takeReadRequestIfPossible(state: &state))
    }
    if let publication = completed.0 { deliver(publication) }
    start(completed.1)
  }

  private func accept(
    _ result: Result<any Sendable, any Error>,
    source: ValueObservationSource,
    state: inout State
  ) -> Publication? {
    state.initialFetchCompleted = true
    switch result {
    case .success(let payload):
      let reduction: ValueObservationReduction<Value>
      do {
        reduction = try reducer.reduce(payload)
      } catch {
        return fail(error, state: &state)
      }
      guard case .emit(let value) = reduction else {
        return nil
      }
      let change = ValueObservationChange(value: value, source: source)
      state.latest = change
      return .change(change, Array(state.subscribers.values))

    case .failure(let error):
      return fail(error, state: &state)
    }
  }

  private func fail(
    _ error: any Error,
    state: inout State
  ) -> Publication {
    state.isStopped = true
    state.terminalError = error
    let subscribers = Array(state.subscribers.values)
    state.subscribers.removeAll()
    return .failure(error, subscribers)
  }

  private func deliver(_ publication: Publication) {
    if case .failure = publication {
      stopObservingTransactions()
    }
    let shouldStartDelivery = state.withLock { state in
      enqueue(publication, state: &state)
    }
    guard shouldStartDelivery else { return }
    deliverPublications(from: nil)
  }

  private func enqueue(
    _ publication: Publication,
    state: inout State
  ) -> Bool {
    state.publications.append(publication)
    guard !state.isDelivering else { return false }
    state.isDelivering = true
    return true
  }

  private func deliverPublications(
    from isolation: isolated (any Actor)?
  ) {
    while let publication = state.withLock({ state -> Publication? in
      guard !state.publications.isEmpty else {
        state.isDelivering = false
        return nil
      }
      return state.publications.removeFirst()
    }) {
      switch publication {
      case .change(let change, let subscribers):
        for subscriber in subscribers {
          subscriber.receive(change, from: isolation)
        }
      case .failure(let error, let subscribers):
        for subscriber in subscribers {
          subscriber.receive(error, from: isolation)
        }
      }
    }
  }

  private func removeSubscriber(_ identifier: UInt64) {
    _ = state.withLock { $0.subscribers.removeValue(forKey: identifier) }
  }

  func stop() {
    let shouldStop = state.withLock { state in
      guard !state.isStopped else { return false }
      state.isStopped = true
      state.subscribers.removeAll()
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

private final class ValueObservationSubscriptionHolder: Sendable {
  private struct State: Sendable {
    var subscription: SQLiteCrossSubscription?
    var isCancelled = false
  }

  private let state = Lock(State())

  func store(_ subscription: SQLiteCrossSubscription) {
    let cancelImmediately = state.withLock { state in
      if state.isCancelled { return true }
      state.subscription = subscription
      return false
    }
    if cancelImmediately { subscription.cancel() }
  }

  func cancel() {
    let subscription = state.withLock { state in
      state.isCancelled = true
      defer { state.subscription = nil }
      return state.subscription
    }
    subscription?.cancel()
  }
}

extension Optional {
  fileprivate mutating func take() -> Wrapped? {
    defer { self = nil }
    return self
  }
}
