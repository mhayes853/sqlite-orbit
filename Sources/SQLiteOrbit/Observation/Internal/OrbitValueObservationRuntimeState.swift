// One subscriber attached to a value observation runtime.
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

// Something a runtime owes a fixed set of subscribers, captured when the outcome was produced.
//
// See `OrbitValueObservationSubscriberRegistry.publish(_:)` for why they travel with the
// outcome.
struct OrbitValueObservationPublication<Value: Sendable>: Sendable {
  let outcome: Result<OrbitValueObservationChange<Value>, any Error>
  let subscribers: [OrbitValueObservationSubscriber<Value>]
}

// A read a runtime has issued, and the revision the observation was at when it was issued.
struct OrbitValueObservationReadRequest: Sendable {
  let revision: UInt64
  let source: OrbitValueObservationSource
}

// Decides when a value observation reads, and which finished reads still describe the database.
//
// One read runs at a time. Every invalidation bumps a revision, so a read issued before an
// invalidation and finished after it is stale: its value is dropped and the read is reissued.
// That costs a redundant fetch but never publishes a value older than a commit already seen.
struct OrbitValueObservationReadCoordinator: Sendable {
  private(set) var initialFetchCompleted = false
  private var revision: UInt64 = 0
  private var readIsRequired = false
  private var readIsInFlight = false
  private var requiredSource = OrbitValueObservationSource.initial

  // Records that a fetch has resolved the observation's first value.
  mutating func completeInitialFetch() {
    self.initialFetchCompleted = true
  }

  // Requires the initial read, returning the request to issue when this call is the one that
  // needs it, and `nil` when the initial value is already fetched or already being fetched.
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

  // Requires a read because `source` invalidated the observation, returning the request to issue
  // when no read is already in flight.
  mutating func requireRead(source: OrbitValueObservationSource)
    -> OrbitValueObservationReadRequest?
  {
    self.revision &+= 1
    self.readIsRequired = true
    self.requiredSource = source
    return self.takeRequestIfPossible()
  }

  // Invalidates the read in flight, for a caller about to fetch the value itself.
  mutating func discardInFlightRead() {
    self.revision &+= 1
  }

  // Invalidates the read in flight and clears any pending requirement, for a caller holding a
  // fetch that already satisfies it.
  mutating func supersedePendingRead() {
    self.revision &+= 1
    self.readIsRequired = false
  }

  // Records that `request` finished, reporting whether its value still describes the database.
  mutating func completeRead(_ request: OrbitValueObservationReadRequest) -> Bool {
    self.readIsInFlight = false
    return request.revision == self.revision
  }

  // Returns the next read to issue, when one is required and none is in flight.
  mutating func takeRequestIfPossible() -> OrbitValueObservationReadRequest? {
    guard self.readIsRequired, !self.readIsInFlight else { return nil }
    self.readIsRequired = false
    self.readIsInFlight = true
    return OrbitValueObservationReadRequest(revision: self.revision, source: self.requiredSource)
  }
}

// The subscribers attached to one value observation runtime, and the value a late one is caught
// up with.
struct OrbitValueObservationSubscriberRegistry<Value: Sendable>: Sendable {
  // A subscriber's place in the registry, or the error that ended the observation before it
  // arrived.
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

  // The error that ended the observation, once one has.
  private(set) var terminalError: (any Error)?

  // Adds `subscriber` unless the observation has already failed, reporting the value it is owed
  // and whether it is the subscriber that started the observation.
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

  // Removes the subscriber under `identifier`, reporting whether that emptied the registry.
  //
  // A repeated removal reports `false`, so a subscription cancelled twice is one departure.
  mutating func remove(_ identifier: UInt64) -> Bool {
    self.subscribers.remove(identifier) && self.subscribers.isEmpty
  }

  // Records `change` as the value a late subscriber is caught up with, and returns the
  // subscribers it is owed now.
  //
  // Capturing them here rather than when the change is delivered is what keeps a subscriber that
  // registers in between from receiving it twice: it is caught up through `add(_:)` instead.
  mutating func publish(
    _ change: OrbitValueObservationChange<Value>
  ) -> [OrbitValueObservationSubscriber<Value>] {
    self.latest = change
    return self.subscribers.all
  }

  // Ends the registry with `error` and returns the subscribers owed it.
  //
  // A subscriber offered afterwards is refused with the same error rather than added.
  mutating func fail(_ error: any Error) -> [OrbitValueObservationSubscriber<Value>] {
    self.terminalError = error
    return self.subscribers.removeAll()
  }
}

// The publications a runtime has produced but not yet handed to its subscribers.
//
// Values are produced from more than one context — a committing writer, and a read that has just
// finished — so they are queued and drained by whichever caller finds the queue idle, which is
// what keeps a subscriber from seeing a later value before an earlier one.
struct OrbitValueObservationDeliveryQueue<Value: Sendable>: Sendable {
  private var publications = [OrbitValueObservationPublication<Value>]()
  private var isDelivering = false

  // Queues `publication`, reporting whether the caller takes on draining the queue.
  mutating func enqueue(_ publication: OrbitValueObservationPublication<Value>) -> Bool {
    self.publications.append(publication)
    guard !self.isDelivering else { return false }
    self.isDelivering = true
    return true
  }

  // Removes the next publication to deliver, ending the drain once the queue is empty.
  mutating func next() -> OrbitValueObservationPublication<Value>? {
    guard !self.publications.isEmpty else {
      self.isDelivering = false
      return nil
    }
    return self.publications.removeFirst()
  }
}
