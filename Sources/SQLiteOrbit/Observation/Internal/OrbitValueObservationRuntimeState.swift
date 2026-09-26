/// Whether a subscriber is still subscribed, shared by every copy of it.
///
/// A publication takes its recipients from the registry and a scheduler can run their callbacks
/// long afterwards, so cancellation has to be recognized again at the moment a callback would run.
final class OrbitValueObservationSubscriberLifetime: Sendable {
  private let isCancelled = Lock(false)

  var isSubscribed: Bool { self.isCancelled.withLock { !$0 } }

  func cancel() {
    self.isCancelled.withLock { $0 = true }
  }
}

struct OrbitValueObservationSubscriber<Value: Sendable>: Sendable {
  let lifetime = OrbitValueObservationSubscriberLifetime()
  let scheduler: any OrbitValueObservationScheduler
  let onNoEmission: (@Sendable (OrbitValueObservationSource) -> Void)?
  let onError: @Sendable (any Error) -> Void
  let onChange: @Sendable (OrbitValueObservationChange<Value>) -> Void

  func receive(
    _ event: OrbitValueObservationPublicationEvent<Value>,
    from isolation: isolated (any Actor)?
  ) {
    guard self.lifetime.isSubscribed else { return }
    if case .noEmission = event, onNoEmission == nil {
      return
    }
    self.scheduler.schedule(from: isolation) {
      [lifetime, onNoEmission, onError, onChange] in
      guard lifetime.isSubscribed else { return }
      switch event {
      case .noEmission(let source):
        onNoEmission?(source)
      case .outcome(.success(let change)):
        onChange(change)
      case .outcome(.failure(let error)):
        onError(error)
      }
    }
  }
}

enum OrbitValueObservationPublicationEvent<Value: Sendable>: Sendable {
  case noEmission(source: OrbitValueObservationSource)
  case outcome(Result<OrbitValueObservationChange<Value>, any Error>)
}

struct OrbitValueObservationPublication<Value: Sendable>: Sendable {
  let event: OrbitValueObservationPublicationEvent<Value>
  let subscribers: [OrbitValueObservationSubscriber<Value>]
}

/// A fetch a coordinator handed out: the revision it was issued at, which tells whether it is
/// still current when it completes, and the source its value is reported with.
struct OrbitValueObservationFetchRequest: Sendable {
  let revision: UInt64
  let source: OrbitValueObservationSource
}

struct OrbitValueObservationReadCoordinator: Sendable {
  private(set) var initialFetchCompleted = false
  private var revision: UInt64 = 0
  private var readIsRequired = false
  private var readIsInFlight = false
  private var requiredSource = OrbitValueObservationSource.initial

  mutating func completeInitialFetch() {
    self.initialFetchCompleted = true
  }

  mutating func requireInitialRead() -> OrbitValueObservationFetchRequest? {
    guard
      !self.initialFetchCompleted,
      !self.readIsInFlight,
      !self.readIsRequired
    else { return nil }
    self.readIsRequired = true
    self.requiredSource = .initial
    return self.takeRequestIfPossible()
  }

  mutating func requireRead(source: OrbitValueObservationSource)
    -> OrbitValueObservationFetchRequest?
  {
    self.revision &+= 1
    self.readIsRequired = true
    self.requiredSource = source
    return self.takeRequestIfPossible()
  }

  mutating func discardInFlightRead() {
    self.revision &+= 1
  }

  mutating func supersedePendingRead() {
    self.revision &+= 1
    self.readIsRequired = false
  }

  mutating func completeRead(_ request: OrbitValueObservationFetchRequest) -> Bool {
    self.readIsInFlight = false
    return request.revision == self.revision
  }

  mutating func takeRequestIfPossible() -> OrbitValueObservationFetchRequest? {
    guard self.readIsRequired, !self.readIsInFlight else { return nil }
    self.readIsRequired = false
    self.readIsInFlight = true
    return OrbitValueObservationFetchRequest(revision: self.revision, source: self.requiredSource)
  }
}

struct OrbitValueObservationRefetchCoordinator: Sendable {
  private var revision: UInt64 = 0
  private var isRequired = false
  private var isFetchInFlight = false
  private var source = OrbitValueObservationSource.observable

  var hasPendingFetch: Bool { isRequired && !isFetchInFlight }

  /// Counts the invalidations raised so far, so that a refetch controller's caller can tell
  /// whether anything new arrived while the controller ran.
  var invalidationRevision: UInt64 { revision }

  mutating func require(source: OrbitValueObservationSource) {
    revision &+= 1
    isRequired = true
    self.source = source
  }

  mutating func beginFetch() -> OrbitValueObservationFetchRequest? {
    guard isRequired, !isFetchInFlight else { return nil }
    isFetchInFlight = true
    return OrbitValueObservationFetchRequest(revision: revision, source: source)
  }

  func isCurrent(_ request: OrbitValueObservationFetchRequest) -> Bool {
    request.revision == revision
  }

  mutating func finishSupersededFetch() {
    isFetchInFlight = false
  }

  mutating func finishPublishedFetch() {
    isFetchInFlight = false
    isRequired = false
  }

  mutating func supersedePendingFetch() {
    revision &+= 1
    isRequired = false
  }
}

struct OrbitValueObservationSubscriberRegistry<Value: Sendable>: Sendable {
  typealias Registration = Result<
    (
      identifier: UInt64,
      latest: OrbitValueObservationChange<Value>?,
      noEmissionSource: OrbitValueObservationSource?,
      isFirstEver: Bool
    ), any Error
  >

  private var subscribers = IdentifiedRegistry<OrbitValueObservationSubscriber<Value>>()
  private var didStart = false
  private var latest: OrbitValueObservationChange<Value>?
  private var noEmissionSource: OrbitValueObservationSource?

  private(set) var terminalError: (any Error)?

  mutating func add(_ subscriber: OrbitValueObservationSubscriber<Value>) -> Registration {
    if let terminalError = self.terminalError { return .failure(terminalError) }
    let isFirstEver = !self.didStart
    self.didStart = true
    return .success(
      (
        identifier: self.subscribers.insert(subscriber),
        latest: self.latest,
        noEmissionSource: self.noEmissionSource,
        isFirstEver: isFirstEver
      )
    )
  }

  /// Unsubscribes a subscriber, so that a publication already on its way to it is dropped.
  ///
  /// - Returns: Whether that left the observation with no subscribers at all.
  mutating func remove(_ identifier: UInt64) -> Bool {
    guard let subscriber = self.subscribers.removeValue(identifier) else { return false }
    subscriber.lifetime.cancel()
    return self.subscribers.isEmpty
  }

  mutating func publish(
    _ change: OrbitValueObservationChange<Value>
  ) -> [OrbitValueObservationSubscriber<Value>] {
    self.latest = change
    self.noEmissionSource = nil
    return self.subscribers.all
  }

  mutating func publishNoEmission(
    source: OrbitValueObservationSource
  ) -> [OrbitValueObservationSubscriber<Value>] {
    if latest == nil { noEmissionSource = source }
    return subscribers.all.filter { $0.onNoEmission != nil }
  }

  mutating func fail(_ error: any Error) -> [OrbitValueObservationSubscriber<Value>] {
    self.terminalError = error
    return self.subscribers.removeAll()
  }
}

struct OrbitValueObservationDeliveryQueue<Value: Sendable>: Sendable {
  private var publications = [OrbitValueObservationPublication<Value>]()
  private var isDelivering = false

  mutating func enqueue(_ publication: OrbitValueObservationPublication<Value>) -> Bool {
    self.publications.append(publication)
    guard !self.isDelivering else { return false }
    self.isDelivering = true
    return true
  }

  mutating func next() -> OrbitValueObservationPublication<Value>? {
    guard !self.publications.isEmpty else {
      self.isDelivering = false
      return nil
    }
    return self.publications.removeFirst()
  }
}

/// The region an observation has registered with its database, and what each fetch in flight can
/// rely on the database having honored since the fetch began.
///
/// A database may skip commits outside the registered region. A fetch that reads beyond what was
/// registered for all of its duration may therefore have missed a commit made after its snapshot
/// but before the registration grew to cover what it read. Such a fetch is either withheld, and
/// made again once the registration covers what it read, or published, leaving the observation
/// owing a fetch that starts once the registration covers it.
///
/// The region is kept conservatively: an update that narrows it counts as soon as it is decided,
/// since the database may start honoring it at any moment, and one that widens it counts only once
/// the database has applied it.
struct OrbitValueObservationAdvertisement: Sendable {
  private(set) var region: OrbitDatabaseRegion

  /// Whether the database may skip commits outside `region`. One that reports every commit covers
  /// every fetch, and there is nothing to register with it.
  private var isFiltered = true

  /// What withheld fetches read, which the registration must cover before they are made again.
  private var withheldRegion = OrbitDatabaseRegion.empty

  /// Whether the last accepted fetch read outside what was registered throughout it.
  private var owesCoveringFetch = false

  /// For each fetch in flight, the intersection of every region registered since it began.
  private var floors = [UInt64: OrbitDatabaseRegion]()
  private var nextFetch: UInt64 = 0

  init(region: OrbitDatabaseRegion) {
    self.region = region
  }

  /// Records that the database reports every commit whatever its registered region.
  mutating func stopFiltering() {
    isFiltered = false
    region = .fullDatabase
    floors.removeAll()
  }

  /// Starts tracking what is registered during a fetch, which must begin before its snapshot.
  mutating func beginFetch() -> UInt64 {
    defer { nextFetch &+= 1 }
    if isFiltered { floors[nextFetch] = region }
    return nextFetch
  }

  /// Stops tracking a fetch.
  ///
  /// - Returns: The region the database honored for all of the fetch's duration.
  mutating func endFetch(_ fetch: UInt64) -> OrbitDatabaseRegion {
    guard isFiltered else { return .fullDatabase }
    return floors.removeValue(forKey: fetch) ?? .empty
  }

  /// Records a fetch that read `region` but is withheld because it was not covered.
  mutating func withhold(read region: OrbitDatabaseRegion) {
    withheldRegion.formUnion(region)
  }

  /// Records that the observation accepted a fetch that read `region`.
  ///
  /// - Parameters:
  ///   - region: The region the fetch read.
  ///   - floor: The region the database honored for all of the fetch's duration.
  mutating func accept(read region: OrbitDatabaseRegion, floor: OrbitDatabaseRegion) {
    owesCoveringFetch = !floor.contains(region)
    withheldRegion = .empty
  }

  /// Takes the fetch owed for an uncovered read that was published, once the registered region
  /// covers `observed`, what that read.
  mutating func takeCoveringFetch(observing observed: OrbitDatabaseRegion) -> Bool {
    guard owesCoveringFetch, region.contains(observed) else { return false }
    owesCoveringFetch = false
    return true
  }

  /// Decides to register what the observation needs covered, counting whatever that drops from
  /// the current registration as dropped already.
  ///
  /// - Parameter observed: The region the last accepted fetch read.
  /// - Returns: The region to register, or `nil` if it is registered already.
  mutating func beginUpdate(observing observed: OrbitDatabaseRegion) -> OrbitDatabaseRegion? {
    let target = observed.union(withheldRegion)
    guard isFiltered, target != region else { return nil }
    region.formIntersection(target)
    for fetch in floors.keys {
      floors[fetch]?.formIntersection(target)
    }
    return target
  }

  /// Records that the database applied `target`.
  mutating func finishUpdate(to target: OrbitDatabaseRegion) {
    region = target
  }
}
