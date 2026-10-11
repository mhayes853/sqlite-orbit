/// The database a fetch source reads from, and whether the property may also write to it.
///
/// Every database a property resolves for itself — from the SwiftUI environment or from
/// ``OrbitDefaultDatabase`` — is an ``OrbitObservableDatabaseWriter``. Only a read-only property's
/// explicit `database:` argument can be a reader alone, and a read-only property never writes. Keeping
/// the distinction in the type is what lets ``Row`` and ``SingleRow`` write to the database they read
/// from without a runtime cast.
enum OrbitFetchDatabase: Sendable {
  case reader(any OrbitObservableDatabase)
  case writer(any OrbitObservableDatabaseWriter)

  /// The database to observe.
  var observable: any OrbitObservableDatabase {
    switch self {
    case .reader(let database): database
    case .writer(let database): database
    }
  }

  /// The database to write to, when the property was given one it may write to.
  var writer: (any OrbitObservableDatabaseWriter)? {
    switch self {
    case .reader: nil
    case .writer(let database): database
    }
  }
}

/// Everything a fetch property needs to observe one source against one database.
///
/// A source is built once, when a property is created or given a new request or observation, and
/// is what the storage re-subscribes to. Request-backed sources share the observation the request
/// describes. Observation-backed sources retain the exact observation they were given, whose
/// definition already shares one runtime between its subscribers.
///
/// A source has no scheduler. Where values are delivered belongs to the property rather than to
/// what it reads, which is what lets a rebuilt property change it without observing again.
struct OrbitFetchSource<Value: Sendable>: Sendable {
  let id: OrbitFetchSourceID
  let database: OrbitFetchDatabase
  let observation: OrbitValueObservation<Value>

  init(
    request: some OrbitFetchKeyRequest<Value>,
    database: OrbitFetchDatabase
  ) {
    self.id = OrbitFetchSourceID(request: request, database: database.observable)
    self.database = database
    self.observation = request.observation()
  }

  init(
    observation: OrbitValueObservation<Value>,
    identity: OrbitFetchObservationIdentity,
    database: OrbitFetchDatabase
  ) {
    self.id = OrbitFetchSourceID(observation: identity, database: database.observable)
    self.database = database
    self.observation = observation
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
  let makeSource: @Sendable (OrbitFetchDatabase) -> OrbitFetchSource<Value>
  let makeID: @Sendable ((any OrbitObservableDatabase)?) -> OrbitFetchSourceID

  init(
    request: some OrbitFetchKeyRequest<Value>,
    isDatabaseExplicit: Bool
  ) {
    self.isDatabaseExplicit = isDatabaseExplicit
    self.makeSource = { database in
      OrbitFetchSource(request: request, database: database)
    }
    self.makeID = { database in
      OrbitFetchSourceID(request: request, database: database)
    }
  }

  init(
    observation: OrbitValueObservation<Value>,
    identity: OrbitFetchObservationIdentity,
    isDatabaseExplicit: Bool
  ) {
    self.isDatabaseExplicit = isDatabaseExplicit
    self.makeSource = { database in
      OrbitFetchSource(observation: observation, identity: identity, database: database)
    }
    self.makeID = { database in
      OrbitFetchSourceID(observation: identity, database: database)
    }
  }
}

/// The identity of an observation declaration, either the observation's definition or an explicit
/// value supplied by a caller whose declaration rebuilds the observation.
enum OrbitFetchObservationIdentity: Hashable, Sendable {
  case intrinsic(OrbitValueObservationIdentity)
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
///
/// The scheduler is deliberately not part of it. A property rebuilt with a different scheduler
/// describes the same read delivered differently, which the storage handles by swapping the
/// scheduler in rather than by observing again.
struct OrbitFetchSourceID: Hashable, Sendable {
  private enum Input: Hashable, Sendable {
    case request(OrbitFetchRequestID)
    case observation(OrbitFetchObservationIdentity)
  }

  private let database: ObjectIdentifier?
  private let input: Input

  var requestID: OrbitFetchRequestID? {
    guard case .request(let id) = input else { return nil }
    return id
  }

  init(
    request: some OrbitFetchKeyRequest,
    database: (any OrbitObservableDatabase)?
  ) {
    self.database = database.map { ObjectIdentifier($0) }
    self.input = .request(OrbitFetchRequestID(request))
  }

  init(
    observation: OrbitFetchObservationIdentity,
    database: (any OrbitObservableDatabase)?
  ) {
    self.database = database.map { ObjectIdentifier($0) }
    self.input = .observation(observation)
  }
}

/// A value of any type — a request, or a caller's explicit observation identity — compared and
/// hashed as itself.
///
/// `AnyHashable` would say this in one word, but it erases `Sendable` along with the type. Holding
/// the existential instead keeps the guarantee the values came with.
struct OrbitAnyHashableSendable: Hashable, Sendable {
  private let base: any Hashable & Sendable

  init(_ base: some Hashable & Sendable) {
    self.base = base
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    AnyHashable(lhs.base) == AnyHashable(rhs.base)
  }

  func hash(into hasher: inout Hasher) {
    AnyHashable(base).hash(into: &hasher)
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
    // Whether the scheduler is still the one the declaration asked for. An explicit load or
    // assignment chooses a scheduler of its own, which a rebuilt declaration must not undo, just as
    // it does not undo the source.
    var schedulerFollowsDeclaration = true
    var subscription: OrbitSubscription?
    var lifetime: OrbitFetchLoadLifetime?
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
      let lifetime: OrbitFetchLoadLifetime?
    }

    mutating func invalidateObservation() -> InvalidatedObservation {
      generation &+= 1
      isLoading = false
      defer {
        subscription = nil
        firstResult = nil
        lifetime = nil
      }
      return InvalidatedObservation(
        subscription: subscription,
        firstResult: firstResult,
        lifetime: lifetime
      )
    }
  }

  private let state: Lock<State>
  private let defaultDatabase: OrbitDefaultDatabaseSource
  // Every observation this storage starts delivers through this, so replacing the scheduler it
  // forwards to takes effect without observing again.
  private let scheduler: OrbitFetchScheduler
  // One registrar covers the value, the error, and whether a read is in flight, because nothing
  // changes any one of them without publishing all three.
  private let registrar = OrbitFetchObservationRegistrar()

  init(
    value: Value,
    source: OrbitFetchSource<Value>? = nil,
    binding: OrbitFetchSourceBinding<Value>? = nil,
    defaultDatabase: OrbitDefaultDatabaseSource = OrbitDefaultDatabaseSource(),
    loadError: (any Error)? = nil,
    sourceID: OrbitFetchSourceID? = nil,
    scheduler: any OrbitValueObservationScheduler = OrbitImmediateValueObservationScheduler()
  ) {
    self.defaultDatabase = defaultDatabase
    self.scheduler = OrbitFetchScheduler(scheduler)
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
    let (subscription, lifetime) = state.withLock { state in
      (state.subscription, state.lifetime)
    }
    subscription?.cancel()
    lifetime?.finish(.success(()))
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

  /// The scheduler deliveries currently go through.
  var currentScheduler: any OrbitValueObservationScheduler {
    scheduler.current
  }

  /// The database the current source reads from, after taking a newly available default if needed.
  ///
  /// Mutable fetch properties call this instead of resolving the default independently, because a
  /// SwiftUI environment database may have replaced it after the property was created.
  ///
  /// Only a storage made with ``make(value:request:writableDatabase:scheduler:)`` may call this.
  /// Every database such a storage can resolve is a writer, so finding a reader is a programmer
  /// error rather than a condition to report.
  func databaseForWriting() -> any OrbitObservableDatabaseWriter {
    attachIfNeeded(database: nil)
    guard let database = state.withLock({ $0.source?.database }) else {
      return defaultDatabase.current
    }
    guard let writer = database.writer else {
      preconditionFailure("A read-only fetch property was asked for a database to write to.")
    }
    return writer
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
  /// - Parameters:
  ///   - source: The observation and database to use.
  ///   - binding: How to rebuild `source` against another database, when it is a new declaration.
  /// - Returns: A token for this registration, even if another load replaces it before resuming.
  /// - Throws: Whatever the first read throws, which also becomes ``loadError``.
  @discardableResult
  func load(
    _ source: OrbitFetchSource<Value>,
    binding: OrbitFetchSourceBinding<Value>? = nil
  ) async throws -> OrbitFetchLoad {
    let signal = OrbitOneShotSignal()
    guard let registration = subscribe(to: source, binding: binding, signal: signal) else {
      throw CancellationError()
    }
    try await withTaskCancellationHandler {
      try await signal.wait()
    } onCancel: {
      signal.finish(.failure(CancellationError()))
    }
    return OrbitFetchLoad(lifetime: registration.lifetime)
  }

  /// Stops observing, keeping the value the observation last produced.
  /// A load token may only detach the generation that it started.
  func detach(generation: UInt64? = nil) {
    let invalidated = state.withLock { state -> State.InvalidatedObservation? in
      guard generation == nil || state.generation == generation else { return nil }
      state.source = nil
      state.binding = nil
      state.hasStarted = true
      return state.invalidateObservation()
    }
    guard let invalidated else { return }
    finish(invalidated)
  }

  /// Why one storage is taking over another's source.
  enum Adoption {
    /// An explicit assignment of one projected value to another, which replaces the source and the
    /// scheduler whatever they are.
    case assignment
    /// A SwiftUI view rebuilding the property, which replaces the source only when the declaration
    /// describes a different read, and the scheduler whenever no explicit load or assignment has
    /// chosen one since.
    case declaration
  }

  /// Takes over another storage's value and source.
  ///
  /// This is what assigning one projected value to another does, and what a SwiftUI view's
  /// surviving storage does when the view is re-created with a different query.
  ///
  /// A rebuilt declaration that describes the same read but asks for a different scheduler keeps
  /// observing, and delivers through the new scheduler from then on.
  ///
  /// - Parameters:
  ///   - other: The storage to adopt from. It keeps observing whatever it was observing.
  ///   - adoption: Why the source is being taken over, which decides what is replaced.
  func adopt(from other: OrbitFetchStorage<Value>, as adoption: Adoption = .assignment) {
    let (value, source, binding, loadError, sourceID) = other.state.withLock {
      ($0.value, $0.source, $0.binding, $0.loadError, $0.sourceID)
    }
    let otherScheduler = other.scheduler.current
    replaceObservation { state in
      switch adoption {
      case .assignment:
        state.schedulerFollowsDeclaration = false
        scheduler.replace(with: otherScheduler)
      case .declaration:
        guard let sourceID else { return false }
        guard state.sourceID != sourceID else {
          // The same read: the observation continues, and only where it delivers may change.
          if state.schedulerFollowsDeclaration { scheduler.replace(with: otherScheduler) }
          return false
        }
        state.sourceID = sourceID
        state.schedulerFollowsDeclaration = true
        scheduler.replace(with: otherScheduler)
      }
      state.value = value
      state.source = source
      state.binding = binding
      state.loadError = loadError
      return true
    }
  }

  // MARK: - Observing

  /// Ends the current observation and lets the next read start another, if `replace` changes what
  /// the storage observes.
  ///
  /// - Parameter replace: Updates the state under the lock, returning whether it replaced anything.
  private func replaceObservation(_ replace: (inout State) -> Bool) {
    let replaced = state.withLock {
      state -> (invalidated: State.InvalidatedObservation, wasObserving: Bool)? in
      guard replace(&state) else { return nil }
      let invalidated = state.invalidateObservation()
      state.hasStarted = false
      return (invalidated, !state.observers.isEmpty)
    }
    guard let (invalidated, wasObserving) = replaced else { return }
    finish(invalidated)
    // Something is already watching this storage, so its observation cannot wait for the next
    // read to restart it.
    if wasObserving { startIfNeeded() }
  }

  /// Ends a replaced observation, outside the lock that replaced it.
  private func finish(_ invalidated: State.InvalidatedObservation) {
    invalidated.subscription?.cancel()
    invalidated.firstResult?.finish(.failure(CancellationError()))
    invalidated.lifetime?.finish(.success(()))
    publishChange()
  }

  private func startIfNeeded() {
    attachIfNeeded(database: nil)
    subscribe()
  }

  @discardableResult
  private func subscribe(
    to source: OrbitFetchSource<Value>? = nil,
    binding: OrbitFetchSourceBinding<Value>? = nil,
    signal: OrbitOneShotSignal? = nil
  ) -> (generation: UInt64, lifetime: OrbitFetchLoadLifetime)? {
    let starting = state.withLock {
      state -> (
        source: OrbitFetchSource<Value>,
        generation: UInt64,
        lifetime: OrbitFetchLoadLifetime,
        invalidated: State.InvalidatedObservation
      )? in
      if let source {
        state.source = source
        if let binding { state.binding = binding }
      } else if state.hasStarted {
        return nil
      }
      guard let source = state.source else { return nil }
      let invalidated = state.invalidateObservation()
      state.hasStarted = true
      state.isLoading = true
      state.firstResult = signal
      let generation = state.generation
      let lifetime = OrbitFetchLoadLifetime { [weak self] in
        self?.detach(generation: generation)
      }
      state.lifetime = lifetime
      return (source, generation, lifetime, invalidated)
    }
    guard let (source, generation, lifetime, invalidated) = starting else { return nil }
    finish(invalidated)

    // An explicit load awaits its first result, so its initial read must not block the caller.
    // Whether the initial value is immediate is decided here, once, by the scheduler current now. A
    // scheduler swapped in later only changes where later deliveries run.
    let scheduler: any OrbitValueObservationScheduler =
      signal == nil ? self.scheduler : self.scheduler.deferringInitialValue()
    do {
      let subscription = try source.observation.subscribe(
        to: source.database.observable,
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
    return (generation, lifetime)
  }

  private func receive(_ result: Result<Value, any Error>, generation: UInt64) {
    var signal: OrbitOneShotSignal?
    var lifetime: OrbitFetchLoadLifetime?
    let didAccept = registrar.withMutation {
      state.withLock { state -> Bool in
        guard state.generation == generation else { return false }
        switch result {
        case .success(let value):
          state.value = value
          state.loadError = nil
        case .failure(let error):
          state.loadError = error
          lifetime = state.lifetime
        }
        state.isLoading = false
        signal = state.firstResult
        state.firstResult = nil
        return true
      }
    }
    guard didAccept else { return }
    signal?.finish(result.map { _ in () })
    lifetime?.finish(result.map { _ in () })
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

extension OrbitFetchStorage {
  /// Creates a storage that observes `request`, resolving the database to read from.
  ///
  /// A property created before its database is available retains enough information to attach the
  /// database later. Reading it while it still has no database terminates with setup instructions.
  static func make(
    value: Value,
    request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)?,
    scheduler: any OrbitValueObservationScheduler = OrbitImmediateValueObservationScheduler()
  ) -> OrbitFetchStorage<Value> {
    let binding = OrbitFetchSourceBinding(request: request, isDatabaseExplicit: database != nil)
    return make(
      value: value,
      binding: binding,
      database: database.map { .reader($0) },
      scheduler: scheduler
    )
  }

  /// Creates a storage that observes `request` and can hand its database out for writing.
  ///
  /// Every database this storage can resolve is a writer, which is what
  /// ``databaseForWriting()`` relies on.
  static func make(
    value: Value,
    request: some OrbitFetchKeyRequest<Value>,
    writableDatabase database: (any OrbitObservableDatabaseWriter)?,
    scheduler: any OrbitValueObservationScheduler = OrbitImmediateValueObservationScheduler()
  ) -> OrbitFetchStorage<Value> {
    let binding = OrbitFetchSourceBinding(request: request, isDatabaseExplicit: database != nil)
    return make(
      value: value,
      binding: binding,
      database: database.map { .writer($0) },
      scheduler: scheduler
    )
  }

  /// Creates a storage that subscribes to `observation`, resolving the database it observes.
  static func make(
    value: Value,
    observation: OrbitValueObservation<Value>,
    identity: OrbitFetchObservationIdentity,
    database: (any OrbitObservableDatabase)?,
    scheduler: any OrbitValueObservationScheduler = OrbitImmediateValueObservationScheduler()
  ) -> OrbitFetchStorage<Value> {
    let binding = OrbitFetchSourceBinding(
      observation: observation,
      identity: identity,
      isDatabaseExplicit: database != nil
    )
    return make(
      value: value,
      binding: binding,
      database: database.map { .reader($0) },
      scheduler: scheduler
    )
  }

  private static func make(
    value: Value,
    binding: OrbitFetchSourceBinding<Value>,
    database: OrbitFetchDatabase?,
    scheduler: any OrbitValueObservationScheduler
  ) -> OrbitFetchStorage<Value> {
    let defaultDatabase = OrbitDefaultDatabaseSource()
    let source = (database ?? defaultDatabase.currentIfConfigured.map { .writer($0) })
      .map(binding.makeSource)
    return OrbitFetchStorage(
      value: value,
      source: source,
      binding: binding,
      defaultDatabase: defaultDatabase,
      sourceID: source?.id ?? binding.makeID(nil),
      scheduler: scheduler
    )
  }

  /// Observes `request` from now on, resolving the database to read from.
  ///
  /// - Parameters:
  ///   - request: The request to observe.
  ///   - database: The database to read from, or `nil` to keep the one the property resolved.
  ///   - scheduler: Where values are delivered from now on. A declaration rebuilt later does not
  ///     replace it.
  /// - Returns: A load that stops this observation when it is cancelled.
  func load(
    request: some OrbitFetchKeyRequest<Value>,
    database: (any OrbitObservableDatabase)?,
    scheduler: any OrbitValueObservationScheduler = OrbitImmediateValueObservationScheduler()
  ) async throws -> OrbitFetchLoad {
    let (database, isDatabaseExplicit) = databaseForReplacement(database)
    let binding = OrbitFetchSourceBinding(request: request, isDatabaseExplicit: isDatabaseExplicit)
    return try await load(binding: binding, database: database, scheduler: scheduler)
  }

  /// Subscribes to `observation` from now on, resolving the database it observes.
  func load(
    observation: OrbitValueObservation<Value>,
    identity: OrbitFetchObservationIdentity,
    database: (any OrbitObservableDatabase)?,
    scheduler: any OrbitValueObservationScheduler = OrbitImmediateValueObservationScheduler()
  ) async throws -> OrbitFetchLoad {
    let (database, isDatabaseExplicit) = databaseForReplacement(database)
    let binding = OrbitFetchSourceBinding(
      observation: observation,
      identity: identity,
      isDatabaseExplicit: isDatabaseExplicit
    )
    return try await load(binding: binding, database: database, scheduler: scheduler)
  }

  /// Keeps the current database and its resolution policy together when replacing a query.
  private func databaseForReplacement(
    _ database: (any OrbitObservableDatabase)?
  ) -> (OrbitFetchDatabase, isExplicit: Bool) {
    if let database { return (.reader(database), true) }
    let current = state.withLock { ($0.source?.database, $0.binding?.isDatabaseExplicit == true) }
    return (current.0 ?? .writer(defaultDatabase.current), current.1)
  }

  private func load(
    binding: OrbitFetchSourceBinding<Value>,
    database: OrbitFetchDatabase,
    scheduler: any OrbitValueObservationScheduler
  ) async throws -> OrbitFetchLoad {
    state.withLock { state in
      state.schedulerFollowsDeclaration = false
      self.scheduler.replace(with: scheduler)
    }
    return try await load(binding.makeSource(database), binding: binding)
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
  func attachIfNeeded(database: (any OrbitObservableDatabaseWriter)?) {
    let attachment = state.withLock {
      state -> (
        binding: OrbitFetchSourceBinding<Value>,
        database: any OrbitObservableDatabaseWriter
      )? in
      guard let binding = state.binding, !binding.isDatabaseExplicit else { return nil }
      guard let database = database ?? (state.source == nil ? defaultDatabase.current : nil) else {
        return nil
      }
      guard state.source?.database.observable !== database else { return nil }
      return (binding, database)
    }
    guard let attachment else { return }
    // Building a request-backed source may render its statement, which is work the lock has no
    // reason to hold. The value, the declaration, and the scheduler all stay as they are.
    let source = attachment.binding.makeSource(.writer(attachment.database))
    replaceObservation { state in
      state.source = source
      state.binding = attachment.binding
      state.loadError = nil
      return true
    }
  }

  /// Takes over `other`'s source when it describes a different read from this one's, and its
  /// scheduler when nothing explicit has replaced the declared one.
  func adoptIfNeeded(from other: OrbitFetchStorage<Value>) {
    adopt(from: other, as: .declaration)
  }
}

/// The scheduler a fetch storage subscribes with, which forwards each delivery to whichever
/// scheduler the property holds at that moment.
///
/// A SwiftUI view rebuilds its properties on every render, and a property rebuilt with a new
/// animation describes the same read delivered differently. Forwarding is what lets the storage
/// take the new scheduler without observing again.
///
/// Whether an observation delivers its initial value before subscription returns is decided once,
/// when it subscribes, by the scheduler current then. Replacing the scheduler only changes where
/// later deliveries run.
///
/// The scheduler being replaced may still hold deliveries it has not run. Each delivery is numbered
/// when it is scheduled, and one that runs after a later one has already run is dropped: every
/// delivery carries a complete value, so the later one has already superseded it.
final class OrbitFetchScheduler: OrbitValueObservationScheduler {
  private struct State {
    var current: any OrbitValueObservationScheduler
    var scheduled: UInt64 = 0
    var delivered: UInt64 = 0
  }

  private let state: Lock<State>

  init(_ current: any OrbitValueObservationScheduler) {
    self.state = Lock(State(current: current))
  }

  /// The scheduler deliveries are forwarded to.
  var current: any OrbitValueObservationScheduler {
    state.withLock { $0.current }
  }

  /// Forwards every delivery scheduled from now on to `scheduler`.
  func replace(with scheduler: any OrbitValueObservationScheduler) {
    state.withLock { $0.current = scheduler }
  }

  func immediateInitialValue(from isolation: isolated (any Actor)?) -> Bool {
    current.immediateInitialValue(from: isolation)
  }

  func schedule(
    from isolation: isolated (any Actor)?,
    _ action: @escaping @Sendable () -> Void
  ) {
    let (scheduler, sequence) = state.withLock { state in
      state.scheduled &+= 1
      return (state.current, state.scheduled)
    }
    scheduler.schedule(from: isolation) { [self] in
      guard claim(sequence) else { return }
      action()
    }
  }

  /// Records that the delivery numbered `sequence` is running, unless a later one already has.
  private func claim(_ sequence: UInt64) -> Bool {
    state.withLock { state in
      guard sequence > state.delivered else { return false }
      state.delivered = sequence
      return true
    }
  }
}
