/// The observation behind one fetch request, held for as long as a property is reading through it.
///
/// Two properties that describe the same read — the same request, database, and scheduler — share
/// one of these, and therefore one ``OrbitValueObservation``, which is what puts them on one
/// subscription to the database rather than two. The box is what makes "for as long as a property
/// is reading" expressible: every source that joined holds it, and the last one to be released
/// takes the shared observation away with it.
final class OrbitFetchObservationBox<Value: Sendable>: Sendable {
  let observation: OrbitValueObservation<Value>

  private let id: OrbitFetchSourceID

  init(id: OrbitFetchSourceID, observation: OrbitValueObservation<Value>) {
    self.id = id
    self.observation = observation
  }

  deinit {
    OrbitFetchObservationRegistry.shared.forgetIfReleased(id)
  }
}

/// Every fetch observation currently being read through, by the read it describes.
///
/// A screen that shows the same query in two places — a list and its count in a tab bar, say —
/// declares two properties that would each open their own subscription and each refetch on every
/// commit, doing the same work twice and, for a moment, disagreeing about the answer. Looking a
/// request up here instead is what makes the second property join the first's observation.
///
/// Entries are weak, so the registry never keeps an observation alive; it only finds the one a
/// property is already holding.
final class OrbitFetchObservationRegistry: Sendable {
  static let shared = OrbitFetchObservationRegistry()

  /// A box held weakly, as a closure rather than a `weak var`, so that reading an entry cannot
  /// release anything while the registry's lock is held.
  private struct WeakBox: Sendable {
    let object: @Sendable () -> (any AnyObject & Sendable)?

    init(_ object: any AnyObject & Sendable) {
      self.object = { [weak object] in object }
    }
  }

  private let boxes = Lock<[OrbitFetchSourceID: WeakBox]>([:])

  /// Whether a property is currently reading through the observation of `id`, which is what a
  /// test asserts the release of a shared observation against.
  ///
  /// - Parameter id: The read to look for.
  /// - Returns: Whether the read has a live observation.
  func holdsObservation(for id: OrbitFetchSourceID) -> Bool {
    boxes.withLock { boxes in boxes[id]?.object() != nil }
  }

  /// Returns the observation of `id`, starting one with `makeObservation` if no property is
  /// reading through it yet.
  ///
  /// - Parameters:
  ///   - id: The read to share.
  ///   - makeObservation: Builds the observation, when this read has none.
  /// - Returns: A box to hold for as long as the caller reads through the observation.
  func box<Value: Sendable>(
    for id: OrbitFetchSourceID,
    makeObservation: () -> OrbitValueObservation<Value>
  ) -> OrbitFetchObservationBox<Value> {
    if let existing = boxes.withLock({ $0[id]?.object() as? OrbitFetchObservationBox<Value> }) {
      return existing
    }
    // Built before the lock is taken, and released after it is given back, because releasing a box
    // is what asks the registry to forget one.
    let candidate = OrbitFetchObservationBox(id: id, observation: makeObservation())
    return boxes.withLock { boxes in
      if let existing = boxes[id]?.object() as? OrbitFetchObservationBox<Value> { return existing }
      boxes[id] = WeakBox(candidate)
      return candidate
    }
  }

  /// Drops `id` when the box that registered it has been released.
  ///
  /// A box that lost the race to register itself is released while another box is registered under
  /// the same identifier, and that one must survive.
  ///
  /// - Parameter id: The read to forget.
  func forgetIfReleased(_ id: OrbitFetchSourceID) {
    boxes.withLock { boxes in
      guard boxes[id]?.object() == nil else { return }
      boxes.removeValue(forKey: id)
    }
  }
}
