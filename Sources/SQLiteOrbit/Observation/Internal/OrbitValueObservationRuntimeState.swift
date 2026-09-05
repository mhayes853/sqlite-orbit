struct OrbitValueObservationSubscriber<Value: Sendable>: Sendable {
  let scheduler: any OrbitValueObservationScheduler
  let onError: @Sendable (any Error) -> Void
  let onChange: @Sendable (OrbitValueObservationChange<Value>) -> Void

  func receive(
    _ outcome: Result<OrbitValueObservationChange<Value>, any Error>,
    from isolation: isolated (any Actor)?
  ) {
    self.scheduler.schedule(from: isolation) {
      switch outcome {
      case .success(let change): self.onChange(change)
      case .failure(let error): self.onError(error)
      }
    }
  }
}

struct OrbitValueObservationPublication<Value: Sendable>: Sendable {
  let outcome: Result<OrbitValueObservationChange<Value>, any Error>
  let subscribers: [OrbitValueObservationSubscriber<Value>]
}

struct OrbitValueObservationReadRequest: Sendable {
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

  mutating func requireInitialRead() -> OrbitValueObservationReadRequest? {
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
    -> OrbitValueObservationReadRequest?
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

  mutating func completeRead(_ request: OrbitValueObservationReadRequest) -> Bool {
    self.readIsInFlight = false
    return request.revision == self.revision
  }

  mutating func takeRequestIfPossible() -> OrbitValueObservationReadRequest? {
    guard self.readIsRequired, !self.readIsInFlight else { return nil }
    self.readIsRequired = false
    self.readIsInFlight = true
    return OrbitValueObservationReadRequest(revision: self.revision, source: self.requiredSource)
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

  mutating func remove(_ identifier: UInt64) -> Bool {
    self.subscribers.remove(identifier) && self.subscribers.isEmpty
  }

  mutating func publish(
    _ change: OrbitValueObservationChange<Value>
  ) -> [OrbitValueObservationSubscriber<Value>] {
    self.latest = change
    return self.subscribers.all
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
