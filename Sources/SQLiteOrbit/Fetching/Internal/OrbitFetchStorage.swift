/// Everything a fetch property needs to observe one source against one database.
///
/// A source is built once, when a property is created or given a new request or observation, and
/// is what the storage re-subscribes to. Request-backed sources share the observation the request
/// describes. Observation-backed sources retain the exact observation they were given, whose
/// definition already shares one runtime between its subscribers.
struct OrbitFetchSource<Value: Sendable>: Sendable {
  let id: OrbitFetchSourceID
  let database: any OrbitObservableDatabase
  let scheduler: any OrbitValueObservationScheduler
  let observation: OrbitValueObservation<Value>

  /// Keeps a request's registry entry alive. An observation-backed source needs no entry because
  /// the observation itself owns its shared definition.
  private let sharedRequestObservation: OrbitFetchObservationBox<Value>?

  init(
    request: some OrbitFetchKeyRequest<Value>,
    database: any OrbitObservableDatabase,
    scheduler: (any OrbitValueObservationScheduler & Hashable)?
  ) {
    let id = OrbitFetchSourceID(request: request, database: database, scheduler: scheduler)
    let shared = OrbitFetchObservationRegistry.shared.box(for: id) {
      OrbitValueObservation.tracking { try request.fetch($0) }
    }
    self.id = id
    self.database = database
    self.scheduler = scheduler ?? OrbitImmediateValueObservationScheduler()
    self.observation = shared.observation
    self.sharedRequestObservation = shared
  }

  init(
    observation: OrbitValueObservation<Value>,
    identity: OrbitFetchObservationIdentity,
    database: any OrbitObservableDatabase,
    scheduler: (any OrbitValueObservationScheduler & Hashable)?
  ) {
    self.id = OrbitFetchSourceID(
      observation: identity,
      database: database,
      scheduler: scheduler
    )
    self.database = database
    self.scheduler = scheduler ?? OrbitImmediateValueObservationScheduler()
    self.observation = observation
    self.sharedRequestObservation = nil
  }
}

/// What a storage needs to build its source again against a different database.
///
/// A property that was not handed a database at its declaration resolves one later — from the
/// SwiftUI environment, or from ``OrbitDefaultDatabase/current`` once the process has set one —
/// and needs its request or observation back to do it. Holding source construction as a closure is
/// what lets the storage forget its concrete input while retaining everything needed to observe
/// whichever database it ends up reading from.
struct OrbitFetchSourceBinding<Value: Sendable>: Sendable {
  /// Whether the property named its database itself, in which case nothing may replace it.
  let isDatabaseExplicit: Bool
  let makeSource: @Sendable (any OrbitObservableDatabase) -> OrbitFetchSource<Value>
  let makeID: @Sendable ((any OrbitObservableDatabase)?) -> OrbitFetchSourceID

  init(
    request: some OrbitFetchKeyRequest<Value>,
    isDatabaseExplicit: Bool,
    scheduler: (any OrbitValueObservationScheduler & Hashable)?
  ) {
    self.isDatabaseExplicit = isDatabaseExplicit
    self.makeSource = { database in
      OrbitFetchSource(request: request, database: database, scheduler: scheduler)
    }
    self.makeID = { database in
      OrbitFetchSourceID(request: request, database: database, scheduler: scheduler)
    }
  }

  init(
    observation: OrbitValueObservation<Value>,
    identity: OrbitFetchObservationIdentity,
    isDatabaseExplicit: Bool,
    scheduler: (any OrbitValueObservationScheduler & Hashable)?
  ) {
    self.isDatabaseExplicit = isDatabaseExplicit
    self.makeSource = { database in
      OrbitFetchSource(
        observation: observation,
        identity: identity,
        database: database,
        scheduler: scheduler
      )
    }
    self.makeID = { database in
      OrbitFetchSourceID(observation: identity, database: database, scheduler: scheduler)
    }
  }
}

/// The identity of an observation declaration, either the observation's definition or an explicit
/// value supplied by a caller whose declaration rebuilds the observation.
enum OrbitFetchObservationIdentity: Hashable, Sendable {
  case intrinsic(ObjectIdentifier)
  case explicit(type: ObjectIdentifier, value: OrbitAnyHashableSendable)

  init<ID: Hashable & Sendable>(_ id: ID) {
    self = .explicit(type: ObjectIdentifier(ID.self), value: OrbitAnyHashableSendable(id))
  }
}

/// What makes one fetch property's read the same read as another's.
///
/// A SwiftUI view is re-created constantly, and each time it is, its fetch properties are built
/// again. Comparing identifiers is how the storage that survived the re-creation decides whether
/// the newly built property describes the same read — in which case the observation continues
/// undisturbed — or a different one it should adopt.
struct OrbitFetchSourceID: Hashable, Sendable {
  private enum Input: Hashable, Sendable {
    case request(type: ObjectIdentifier, value: OrbitAnyHashableSendable)
    case observation(OrbitFetchObservationIdentity)
  }

  private let database: ObjectIdentifier?
  private let input: Input
  private let scheduler: OrbitAnyHashableSendable?

  init(
    request: some OrbitFetchKeyRequest,
    database: (any OrbitObservableDatabase)?,
    scheduler: (any OrbitValueObservationScheduler & Hashable)?
  ) {
    self.database = database.map { ObjectIdentifier($0) }
    self.input = .request(
      type: ObjectIdentifier(type(of: request)),
      value: OrbitAnyHashableSendable(request)
    )
    self.scheduler = scheduler.map { OrbitAnyHashableSendable($0) }
  }

  init(
    observation: OrbitFetchObservationIdentity,
    database: (any OrbitObservableDatabase)?,
    scheduler: (any OrbitValueObservationScheduler & Hashable)?
  ) {
    self.database = database.map { ObjectIdentifier($0) }
    self.input = .observation(observation)
    self.scheduler = scheduler.map { OrbitAnyHashableSendable($0) }
  }
}

/// A request of any type, compared and hashed as itself.
///
/// `AnyHashable` would say this in one word, but it erases `Sendable` along with the type. Holding
/// the existential instead keeps the guarantee the requests came with.
struct OrbitAnyHashableSendable: Hashable, Sendable {
  private let base: any Hashable & Sendable

  init(_ base: some Hashable & Sendable) {
    self.base = base
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    AnyHashable(lhs.base) == AnyHashable(rhs.base)
  }

  func hash(into hasher: inout Hasher) {
    base.hash(into: &hasher)
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
    var binding: OrbitFetchSourceBinding<Value>?
    // The declaration key survives explicit loads, assignments, and cancellation. SwiftUI only
    // replaces a source when the declaration changes, not whenever its current source differs.
    var sourceID: OrbitFetchSourceID?
    var subscription: OrbitSubscription?
    var hasStarted = false
    var generation: UInt64 = 0
    var observers = IdentifiedRegistry<@Sendable () -> Void>()
    var firstResult: OrbitOneShotSignal?
    var swiftUIObservation: OrbitSubscription?

    /// What a replaced observation leaves behind, so that cancelling it and completing the load
    /// that was waiting on it happen after the lock is released.
    struct InvalidatedObservation {
      let subscription: OrbitSubscription?
      let firstResult: OrbitOneShotSignal?
    }

    mutating func invalidateObservation() -> InvalidatedObservation {
      generation &+= 1
      isLoading = false
      defer {
        subscription = nil
        firstResult = nil
      }
      return InvalidatedObservation(subscription: subscription, firstResult: firstResult)
    }
  }

  private let state: Lock<State>
  private let defaultDatabase: OrbitDefaultDatabaseSource
  // One registrar covers the value, the error, and whether a read is in flight, because nothing
  // changes any one of them without publishing all three.
  private let registrar = OrbitFetchObservationRegistrar()

  init(
    value: Value,
    source: OrbitFetchSource<Value>? = nil,
    binding: OrbitFetchSourceBinding<Value>? = nil,
    defaultDatabase: OrbitDefaultDatabaseSource = OrbitDefaultDatabaseSource(),
    loadError: (any Error)? = nil,
    sourceID: OrbitFetchSourceID? = nil
  ) {
    self.defaultDatabase = defaultDatabase
    self.state = Lock(
      State(
        value: value,
        loadError: loadError,
        source: source,
        binding: binding,
        sourceID: sourceID ?? source?.id
      )
    )
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

  var sourceID: OrbitFetchSourceID? {
    state.withLock { $0.sourceID }
  }

  /// The database the current source reads from, after taking a newly available default if needed.
  ///
  /// Mutable fetch properties call this instead of resolving the default independently, because a
  /// SwiftUI environment database may have replaced it after the property was created.
  func databaseForWriting() -> any OrbitObservableDatabase {
    attachIfNeeded(database: nil)
    return state.withLock { $0.source?.database } ?? defaultDatabase.current
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

  /// Reads the current source again.
  ///
  /// Reading again means observing again from scratch, which is what lets this start a property
  /// nothing has read yet, and resume one whose observation a failed read ended. A detached
  /// property, which has no source left to read, does nothing.
  ///
  /// - Throws: Whatever the read throws, which also becomes ``loadError``.
  func load() async throws {
    attachIfNeeded(database: nil)
    guard let source = state.withLock({ $0.source }) else { return }
    try await load(source)
  }

  /// Reads a source, and observes it from now on.
  ///
  /// - Parameter source: The observation, database, and scheduler to use.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  func load(_ source: OrbitFetchSource<Value>) async throws {
    let signal = OrbitOneShotSignal()
    subscribe(to: source, signal: signal)
    try await withTaskCancellationHandler {
      try await signal.wait()
    } onCancel: {
      signal.finish(.failure(CancellationError()))
    }
  }

  /// Stops observing, keeping the value the observation last produced.
  func detach() {
    let invalidated = state.withLock { state -> State.InvalidatedObservation in
      state.source = nil
      state.binding = nil
      state.hasStarted = true
      return state.invalidateObservation()
    }
    finish(invalidated)
  }

  /// Takes over another storage's value and source.
  ///
  /// This is what assigning one projected value to another does, and what a SwiftUI view's
  /// surviving storage does when the view is re-created with a different query.
  ///
  /// - Parameters:
  ///   - other: The storage to adopt from. It keeps observing whatever it was observing.
  ///   - updatingDeclaration: Adopts only a changed declaration, replacing its identity together
  ///     with the value and source. Explicit assignments leave the declaration identity alone.
  func adopt(from other: OrbitFetchStorage<Value>, updatingDeclaration: Bool = false) {
    let (value, source, binding, loadError, sourceID) = other.state.withLock {
      ($0.value, $0.source, $0.binding, $0.loadError, $0.sourceID)
    }
    let adoption = state.withLock {
      state -> (invalidated: State.InvalidatedObservation, wasObserving: Bool)? in
      if updatingDeclaration {
        guard let sourceID, state.sourceID != sourceID else { return nil }
        state.sourceID = sourceID
      }
      let invalidated = state.invalidateObservation()
      state.value = value
      state.source = source
      state.binding = binding
      state.loadError = loadError
      state.hasStarted = false
      return (invalidated, !state.observers.isEmpty)
    }
    guard let (invalidated, wasObserving) = adoption else { return }
    finish(invalidated)
    // Something is already watching this storage, so its observation cannot wait for the next
    // read to restart it.
    if wasObserving { startIfNeeded() }
  }

  // MARK: - Observing

  /// Ends a replaced observation, outside the lock that replaced it.
  private func finish(_ invalidated: State.InvalidatedObservation) {
    invalidated.subscription?.cancel()
    invalidated.firstResult?.finish(.failure(CancellationError()))
    publishChange()
  }

  private func startIfNeeded() {
    attachIfNeeded(database: nil)
    subscribe()
  }

  private func subscribe(
    to source: OrbitFetchSource<Value>? = nil,
    signal: OrbitOneShotSignal? = nil
  ) {
    let starting = state.withLock {
      state -> (
        source: OrbitFetchSource<Value>,
        generation: UInt64,
        invalidated: State.InvalidatedObservation
      )? in
      if let source {
        state.source = source
      } else if state.hasStarted {
        return nil
      }
      guard let source = state.source else { return nil }
      let invalidated = state.invalidateObservation()
      state.hasStarted = true
      state.isLoading = true
      state.firstResult = signal
      return (source, state.generation, invalidated)
    }
    guard let (source, generation, invalidated) = starting else { return }
    finish(invalidated)

    // An explicit load awaits its first result, so its initial read must not block the caller.
    let scheduler: any OrbitValueObservationScheduler =
      signal == nil ? source.scheduler : OrbitDeferredFetchScheduler(base: source.scheduler)
    do {
      let subscription = try source.observation.subscribe(
        to: source.database,
        scheduling: scheduler,
        isolation: nil,
        onError: { [weak self] error in
          self?.receive(.failure(error), generation: generation)
        },
        onUpdate: { [weak self] update in
          switch update {
          case .emitted(let change):
            self?.receive(.success(change.value), generation: generation)
          case .noEmission:
            self?.receiveInitialFetchCompletion(generation: generation)
          }
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
    var signal: OrbitOneShotSignal?
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
    signal?.finish(result.map { _ in () })
    notifyObservers()
  }

  /// Finishes a successful initial read whose observation reducer suppressed its value.
  private func receiveInitialFetchCompletion(generation: UInt64) {
    var signal: OrbitOneShotSignal?
    let didAccept = registrar.withMutation {
      state.withLock { state -> Bool in
        guard state.generation == generation, state.isLoading else { return false }
        state.isLoading = false
        state.loadError = nil
        signal = state.firstResult
        state.firstResult = nil
        return true
      }
    }
    guard didAccept else { return }
    signal?.finish(.success(()))
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

extension OrbitFetchStorage {
  /// Creates a storage that observes `request`, resolving the database to read from.
  ///
  /// A property created before its database is available retains enough information to attach the
  /// database later. Reading it while it still has no database terminates with setup instructions.
  static func make(
    value: Value,
    request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)?,
    scheduler: (any OrbitValueObservationScheduler & Hashable)?
  ) -> OrbitFetchStorage<Value> {
    let binding = OrbitFetchSourceBinding(
      request: request,
      isDatabaseExplicit: database != nil,
      scheduler: scheduler
    )
    return make(value: value, binding: binding, database: database)
  }

  /// Creates a storage that subscribes to `observation`, resolving the database it observes.
  static func make(
    value: Value,
    observation: OrbitValueObservation<Value>,
    identity: OrbitFetchObservationIdentity,
    database: (any OrbitObservableDatabase)?,
    scheduler: (any OrbitValueObservationScheduler & Hashable)?
  ) -> OrbitFetchStorage<Value> {
    let binding = OrbitFetchSourceBinding(
      observation: observation,
      identity: identity,
      isDatabaseExplicit: database != nil,
      scheduler: scheduler
    )
    return make(value: value, binding: binding, database: database)
  }

  private static func make(
    value: Value,
    binding: OrbitFetchSourceBinding<Value>,
    database: (any OrbitObservableDatabase)?
  ) -> OrbitFetchStorage<Value> {
    let defaultDatabase = OrbitDefaultDatabaseSource()
    guard let database = database ?? defaultDatabase.currentIfConfigured else {
      return OrbitFetchStorage(
        value: value,
        binding: binding,
        defaultDatabase: defaultDatabase,
        sourceID: binding.makeID(nil)
      )
    }
    return OrbitFetchStorage(
      value: value,
      source: binding.makeSource(database),
      binding: binding,
      defaultDatabase: defaultDatabase
    )
  }

  /// Observes `request` from now on, resolving the database to read from.
  ///
  /// - Returns: A subscription that stops observing when it is cancelled or released.
  func load(
    request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)?,
    scheduler: (any OrbitValueObservationScheduler & Hashable)?
  ) async throws -> OrbitFetchSubscription {
    let binding = OrbitFetchSourceBinding(
      request: request,
      isDatabaseExplicit: database != nil,
      scheduler: scheduler
    )
    return try await load(binding: binding, database: database)
  }

  /// Subscribes to `observation` from now on, resolving the database it observes.
  func load(
    observation: OrbitValueObservation<Value>,
    identity: OrbitFetchObservationIdentity,
    database: (any OrbitObservableDatabase)?,
    scheduler: (any OrbitValueObservationScheduler & Hashable)?
  ) async throws -> OrbitFetchSubscription {
    let binding = OrbitFetchSourceBinding(
      observation: observation,
      identity: identity,
      isDatabaseExplicit: database != nil,
      scheduler: scheduler
    )
    return try await load(binding: binding, database: database)
  }

  private func load(
    binding: OrbitFetchSourceBinding<Value>,
    database: (any OrbitObservableDatabase)?
  ) async throws -> OrbitFetchSubscription {
    let database = database ?? defaultDatabase.current
    state.withLock { $0.binding = binding }
    try await load(binding.makeSource(database))
    return OrbitFetchSubscription { [self] in detach() }
  }

  /// Reads from `database` from now on, unless the property named a database of its own.
  ///
  /// This is the second and third of the three places a fetch property's database can come from.
  /// A property that names one in its declaration is never re-sourced. Otherwise a database
  /// offered by the SwiftUI environment wins, and a property that has not resolved one at all —
  /// because the process had no default when it was created — falls back to whatever
  /// ``OrbitDefaultDatabase/current`` is by now.
  ///
  /// Re-sourcing replaces the current observation, so this does nothing whenever the storage
  /// already reads from the database it is offered, which is what makes it safe to call on every
  /// SwiftUI render.
  ///
  /// - Parameter database: The database the environment offers, or `nil` when it offers none.
  func attachIfNeeded(database: (any OrbitObservableDatabase)?) {
    let attachment = state.withLock {
      state -> (binding: OrbitFetchSourceBinding<Value>, database: any OrbitObservableDatabase)? in
      guard let binding = state.binding, !binding.isDatabaseExplicit else { return nil }
      guard let database = database ?? (state.source == nil ? defaultDatabase.current : nil) else {
        return nil
      }
      guard state.source?.database !== database else { return nil }
      return (binding, database)
    }
    guard let attachment else { return }
    // Building a request-backed source may render its statement, which is work the lock has no
    // reason to hold, and adopting takes the lock again for itself.
    adopt(
      from: OrbitFetchStorage(
        value: untrackedValue,
        source: attachment.binding.makeSource(attachment.database),
        binding: attachment.binding
      )
    )
  }

  /// Takes over `other`'s source when it describes a different read from this one's.
  func adoptIfNeeded(from other: OrbitFetchStorage<Value>) {
    adopt(from: other, updatingDeclaration: true)
  }
}
