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
  let onInitialFetchCompletedWithoutValue: (@Sendable () -> Void)?
  let onError: @Sendable (any Error) -> Void
  let onChange: @Sendable (OrbitValueObservationChange<Value>) -> Void

  func receive(
    _ event: OrbitValueObservationPublicationEvent<Value>,
    from isolation: isolated (any Actor)?
  ) {
    guard self.lifetime.isSubscribed else { return }
    if case .initialFetchCompletedWithoutValue = event,
      onInitialFetchCompletedWithoutValue == nil
    {
      return
    }
    self.scheduler.schedule(from: isolation) {
      [lifetime, onInitialFetchCompletedWithoutValue, onError, onChange] in
      guard lifetime.isSubscribed else { return }
      switch event {
      case .initialFetchCompletedWithoutValue:
        onInitialFetchCompletedWithoutValue?()
      case .outcome(.success(let change)):
        onChange(change)
      case .outcome(.failure(let error)):
        onError(error)
      }
    }
  }
}

enum OrbitValueObservationPublicationEvent<Value: Sendable>: Sendable {
  case initialFetchCompletedWithoutValue
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
      isFirstEver: Bool
    ), any Error
  >

  private var subscribers = IdentifiedRegistry<OrbitValueObservationSubscriber<Value>>()
  private var didStart = false
  private var latest: OrbitValueObservationChange<Value>?

  private(set) var terminalError: (any Error)?

  mutating func add(_ subscriber: OrbitValueObservationSubscriber<Value>) -> Registration {
    if let terminalError = self.terminalError { return .failure(terminalError) }
    let isFirstEver = !self.didStart
    self.didStart = true
    return .success(
      (
        identifier: self.subscribers.insert(subscriber),
        latest: self.latest,
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
    return self.subscribers.all
  }

  var awaitingInitialFetchCompletion: [OrbitValueObservationSubscriber<Value>] {
    subscribers.all.filter { $0.onInitialFetchCompletedWithoutValue != nil }
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
