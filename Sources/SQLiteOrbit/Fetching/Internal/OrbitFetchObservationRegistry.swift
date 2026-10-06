/// A request's value and concrete type, independent of its database and delivery scheduler.
struct OrbitFetchRequestID: Hashable, Sendable {
  let type: ObjectIdentifier
  let value: OrbitAnyHashableSendable

  init(_ request: some OrbitFetchKeyRequest) {
    type = ObjectIdentifier(Swift.type(of: request))
    value = OrbitAnyHashableSendable(request)
  }
}

/// Reuses live observation definitions for equal requests. The observation owns its runtimes,
/// sharing each database's reads while subscribers independently choose callback scheduling.
final class OrbitFetchObservationRegistry: Sendable {
  static let shared = OrbitFetchObservationRegistry()

  private struct WeakObservation: Sendable {
    let value: @Sendable () -> (any Sendable)?
    let entry: ObjectIdentifier
  }

  private final class Entry: Sendable {
    let id: OrbitFetchRequestID

    init(id: OrbitFetchRequestID) { self.id = id }

    deinit { OrbitFetchObservationRegistry.shared.forget(id, entry: ObjectIdentifier(self)) }
  }

  private let observations = Lock<[OrbitFetchRequestID: WeakObservation]>([:])

  func observation<Request: OrbitFetchKeyRequest>(
    for request: Request
  ) -> OrbitValueObservation<Request.Value> {
    let id = OrbitFetchRequestID(request)
    if let existing = observations.withLock({
      $0[id]?.value() as? OrbitValueObservation<Request.Value>
    }) {
      return existing
    }
    let entry = Entry(id: id)
    let candidate = OrbitValueObservation.tracking { [entry] transaction in
      try withExtendedLifetime(entry) { try request.fetch(transaction) }
    }
    let weakCopy = candidate.weakCopy
    return observations.withLock { observations in
      if let existing = observations[id]?.value() as? OrbitValueObservation<Request.Value> {
        return existing
      }
      observations[id] = WeakObservation(value: { weakCopy() }, entry: ObjectIdentifier(entry))
      return candidate
    }
  }

  func holdsObservation(for source: OrbitFetchSourceID) -> Bool {
    guard let id = source.requestID else { return false }
    let lookup = observations.withLock { $0[id]?.value }
    return lookup?() != nil
  }

  private func forget(_ id: OrbitFetchRequestID, entry: ObjectIdentifier) {
    observations.withLock { observations in
      guard observations[id]?.entry == entry else { return }
      observations.removeValue(forKey: id)
    }
  }
}
