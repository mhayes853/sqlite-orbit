/// Everything a fetch property needs to observe one request against one database.
///
/// A source is built once, when a property is created or given a new request, and is what the
/// storage re-subscribes to. Building it renders the request's statement, so two sources compare
/// equal by ``OrbitFetchRequestID`` exactly when they describe the same read.
struct OrbitFetchSource<Value: Sendable>: Sendable {
  let id: OrbitFetchRequestID
  let database: any OrbitObservableDatabase
  let scheduler: any OrbitValueObservationScheduler
  let observation: OrbitValueObservation<Value>

  init(
    request: some OrbitFetchKeyRequest<Value>,
    database: any OrbitObservableDatabase,
    scheduler: (any OrbitValueObservationScheduler)?
  ) {
    let scheduler = scheduler ?? OrbitImmediateValueObservationScheduler()
    self.id = OrbitFetchRequestID(request: request, database: database, scheduler: scheduler)
    self.database = database
    self.scheduler = scheduler
    self.observation = OrbitValueObservation.tracking { try request.fetch($0) }
  }
}

/// What makes one fetch property's read the same read as another's.
///
/// A SwiftUI view is re-created constantly, and each time it is, its fetch properties are built
/// again. Comparing identifiers is how the storage that survived the re-creation decides whether
/// the newly built property describes the same read — in which case the observation continues
/// undisturbed — or a different one it should adopt.
struct OrbitFetchRequestID: Hashable, Sendable {
  private let database: ObjectIdentifier
  private let requestType: ObjectIdentifier
  private let request: OrbitAnyHashableSendable
  // Schedulers are not `Hashable`, and two of the same kind are interchangeable often enough that
  // their type is the most identity that can be read off them.
  private let schedulerType: ObjectIdentifier

  init(
    request: some OrbitFetchKeyRequest,
    database: any OrbitObservableDatabase,
    scheduler: any OrbitValueObservationScheduler
  ) {
    self.database = ObjectIdentifier(database)
    self.requestType = ObjectIdentifier(type(of: request))
    self.request = OrbitAnyHashableSendable(request)
    self.schedulerType = ObjectIdentifier(type(of: scheduler))
  }
}

struct OrbitAnyHashableSendable: Hashable, @unchecked Sendable {
  private let base: AnyHashable

  init(_ base: some Hashable & Sendable) {
    self.base = AnyHashable(base)
  }
}

/// The value a fetch property reads, the state of the read that produced it, and the observation
/// keeping both current.
///
/// One storage backs one property. It is a reference so that every copy of the property wrapper
/// struct — and every ``OrbitFetchReader`` projected out of it — sees the same value, and so that
/// SwiftUI can keep it alive across the re-creation of the view that declared it.
///
/// The observation does not start until something reads the storage. A property that is never read
/// never queries, which is what makes it safe for SwiftUI to build and discard properties as
/// freely as it does.
final class OrbitFetchStorage<Value: Sendable>: Sendable {
  private struct State {
    var value: Value
    var isLoading = false
    var loadError: (any Error)?
    var source: OrbitFetchSource<Value>?
    var subscription: OrbitSubscription?
    var hasStarted = false
    var generation: UInt64 = 0
    var observers = IdentifiedRegistry<@Sendable () -> Void>()
    var firstResult: OrbitFetchSignal?
    var swiftUIObservation: OrbitSubscription?
  }

  private let state: Lock<State>
  // One registrar covers the value, the error, and whether a read is in flight, because nothing
  // changes any one of them without publishing all three.
  private let registrar = OrbitFetchObservationRegistrar()

  init(
    value: Value,
    source: OrbitFetchSource<Value>? = nil,
    loadError: (any Error)? = nil
  ) {
    self.state = Lock(State(value: value, loadError: loadError, source: source))
  }

  deinit {
    let subscription = state.withLock { state -> OrbitSubscription? in
      defer { state.subscription = nil }
      return state.subscription
    }
    subscription?.cancel()
  }

  // MARK: - Reading

  /// The value, starting the observation and recording the read for Observation.
  var value: Value {
    startIfNeeded()
    registrar.access()
    return state.withLock { $0.value }
  }

  /// The value as it stands, without starting the observation or recording a read.
  var untrackedValue: Value {
    state.withLock { $0.value }
  }

  var isLoading: Bool {
    startIfNeeded()
    registrar.access()
    return state.withLock { $0.isLoading }
  }

  var loadError: (any Error)? {
    startIfNeeded()
    registrar.access()
    return state.withLock { $0.loadError }
  }

  var requestID: OrbitFetchRequestID? {
    state.withLock { $0.source?.id }
  }

  /// Holds the observation that keeps a SwiftUI view without the Observation framework redrawing.
  func setSwiftUIObservation(_ observation: OrbitSubscription?) {
    let previous = state.withLock { state -> OrbitSubscription? in
      defer { state.swiftUIObservation = observation }
      return state.swiftUIObservation
    }
    previous?.cancel()
  }

  /// Registers `handler` to run after each change, for observers the Observation framework cannot
  /// serve.
  ///
  /// - Parameter handler: Runs wherever the change was published.
  /// - Returns: A subscription that unregisters `handler` when cancelled or released.
  func addObserver(_ handler: @escaping @Sendable () -> Void) -> OrbitSubscription {
    startIfNeeded()
    let identifier = state.withLock { $0.observers.insert(handler) }
    return OrbitSubscription { [weak self] in
      _ = self?.state.withLock { $0.observers.remove(identifier) }
    }
  }

  // MARK: - Loading

  /// Reads the current request again.
  ///
  /// Reading again means observing again from scratch, which is what lets this start a property
  /// nothing has read yet, and resume one whose observation a failed read ended. A detached
  /// property, which has no request left to read, does nothing.
  ///
  /// - Throws: Whatever the read throws, which also becomes ``loadError``.
  func load() async throws {
    guard let source = state.withLock({ $0.source }) else { return }
    try await load(source)
  }

  /// Reads a request, and observes it from now on.
  ///
  /// - Parameter source: The request, database, and scheduler to observe.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  func load(_ source: OrbitFetchSource<Value>) async throws {
    state.withLock { state in
      state.source = source
      state.hasStarted = true
    }
    try await subscribeAwaitingFirstResult(to: source)
  }

  /// Stops observing, keeping the value the observation last produced.
  func detach() {
    let subscription = state.withLock { state -> OrbitSubscription? in
      state.generation &+= 1
      state.source = nil
      state.hasStarted = true
      state.isLoading = false
      defer { state.subscription = nil }
      return state.subscription
    }
    subscription?.cancel()
  }

  /// Takes over another storage's value and request.
  ///
  /// This is what assigning one projected value to another does, and what a SwiftUI view's
  /// surviving storage does when the view is re-created with a different query.
  ///
  /// - Parameter other: The storage to adopt from. It keeps observing whatever it was observing.
  func adopt(from other: OrbitFetchStorage<Value>) {
    let (value, source, loadError) = other.state.withLock { ($0.value, $0.source, $0.loadError) }
    let (previous, wasObserving) = state.withLock { state -> (OrbitSubscription?, Bool) in
      state.generation &+= 1
      state.value = value
      state.source = source
      state.loadError = loadError
      state.isLoading = false
      state.hasStarted = false
      let previous = state.subscription
      state.subscription = nil
      return (previous, !state.observers.isEmpty)
    }
    previous?.cancel()
    publishChange()
    // Something is already watching this storage, so its observation cannot wait for the next
    // read to restart it.
    if wasObserving { startIfNeeded() }
  }

  // MARK: - Observing

  private func startIfNeeded() {
    let source = state.withLock { state -> OrbitFetchSource<Value>? in
      guard !state.hasStarted, let source = state.source else { return nil }
      state.hasStarted = true
      return source
    }
    guard let source else { return }
    subscribe(to: source, immediately: true, signal: nil)
  }

  private func subscribeAwaitingFirstResult(to source: OrbitFetchSource<Value>) async throws {
    let signal = OrbitFetchSignal()
    // The initial read is deferred whatever the scheduler asks for: an immediate one would block
    // the calling thread, and this call is already suspending for the value.
    subscribe(to: source, immediately: false, signal: signal)
    try await signal.wait()
  }

  private func subscribe(
    to source: OrbitFetchSource<Value>,
    immediately: Bool,
    signal: OrbitFetchSignal?
  ) {
    let (generation, previous, previousSignal) = state.withLock {
      state -> (UInt64, OrbitSubscription?, OrbitFetchSignal?) in
      state.generation &+= 1
      state.isLoading = true
      let previous = state.subscription
      let previousSignal = state.firstResult
      state.subscription = nil
      state.firstResult = signal
      return (state.generation, previous, previousSignal)
    }
    previous?.cancel()
    previousSignal?.finish(CancellationError())
    publishChange()

    let scheduler: any OrbitValueObservationScheduler =
      immediately ? source.scheduler : OrbitDeferredFetchScheduler(base: source.scheduler)
    do {
      let subscription = try source.observation.subscribe(
        to: source.database,
        scheduling: scheduler,
        isolation: nil,
        onError: { [weak self] error in
          self?.receive(.failure(error), generation: generation)
        },
        onChange: { [weak self] change in
          self?.receive(.success(change.value), generation: generation)
        }
      )
      let isStale = state.withLock { state -> Bool in
        guard state.generation == generation else { return true }
        state.subscription = subscription
        return false
      }
      if isStale { subscription.cancel() }
    } catch {
      receive(.failure(error), generation: generation)
    }
  }

  private func receive(_ result: Result<Value, any Error>, generation: UInt64) {
    var signal: OrbitFetchSignal?
    let didAccept = registrar.withMutation {
      state.withLock { state -> Bool in
        guard state.generation == generation else { return false }
        switch result {
        case .success(let value):
          state.value = value
          state.loadError = nil
        case .failure(let error):
          state.loadError = error
        }
        state.isLoading = false
        signal = state.firstResult
        state.firstResult = nil
        return true
      }
    }
    guard didAccept else { return }
    switch result {
    case .success: signal?.finish(nil)
    case .failure(let error): signal?.finish(error)
    }
    notifyObservers()
  }

  /// Reports a change that was made directly to the storage rather than delivered by a fetch.
  private func publishChange() {
    registrar.withMutation {}
    notifyObservers()
  }

  private func notifyObservers() {
    for observer in state.withLock({ $0.observers.all }) {
      observer()
    }
  }
}

/// A scheduler that publishes like the one it wraps, but never asks for a blocking initial read.
struct OrbitDeferredFetchScheduler: OrbitValueObservationScheduler {
  let base: any OrbitValueObservationScheduler

  func immediateInitialValue(from isolation: isolated (any Actor)?) -> Bool {
    false
  }

  func schedule(
    from isolation: isolated (any Actor)?,
    _ action: @escaping @Sendable () -> Void
  ) {
    base.schedule(from: isolation, action)
  }
}

/// A one-shot signal that a fetch has produced its first result.
final class OrbitFetchSignal: Sendable {
  private struct State {
    var continuation: CheckedContinuation<Void, any Error>?
    var error: (any Error)?
    var hasFinished = false
  }

  private let state = Lock(State())

  func wait() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let hasFinished = state.withLock { state -> Bool in
          guard !state.hasFinished else { return true }
          state.continuation = continuation
          return false
        }
        guard hasFinished else { return }
        if let error = state.withLock({ $0.error }) {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    } onCancel: {
      finish(CancellationError())
    }
  }

  func finish(_ error: (any Error)?) {
    let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
      guard !state.hasFinished else { return nil }
      state.hasFinished = true
      state.error = error
      defer { state.continuation = nil }
      return state.continuation
    }
    guard let continuation else { return }
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }
}

extension OrbitFetchStorage {
  /// Creates a storage that observes `request`, resolving the database to read from.
  ///
  /// A property created without a database, in a process that has no
  /// ``OrbitDefaultDatabase/current`` one, keeps `value` and reports the failure through
  /// ``loadError`` rather than trapping.
  static func make(
    value: Value,
    request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)?,
    scheduler: (any OrbitValueObservationScheduler)?
  ) -> OrbitFetchStorage<Value> {
    guard let database = database ?? OrbitDefaultDatabase.current else {
      return OrbitFetchStorage(value: value, loadError: OrbitMissingDefaultDatabaseError())
    }
    return OrbitFetchStorage(
      value: value,
      source: OrbitFetchSource(request: request, database: database, scheduler: scheduler)
    )
  }

  /// Observes `request` from now on, resolving the database to read from.
  ///
  /// - Returns: A subscription that stops observing when it is cancelled or released.
  func load(
    request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)?,
    scheduler: (any OrbitValueObservationScheduler)?
  ) async throws -> OrbitFetchSubscription {
    guard let database = database ?? OrbitDefaultDatabase.current else {
      throw OrbitMissingDefaultDatabaseError()
    }
    try await load(OrbitFetchSource(request: request, database: database, scheduler: scheduler))
    return OrbitFetchSubscription { [self] in detach() }
  }

  /// Takes over `other`'s request when it describes a different read from this one's.
  func adoptIfNeeded(from other: OrbitFetchStorage<Value>) {
    guard let otherID = other.requestID, otherID != requestID else { return }
    adopt(from: other)
  }
}
