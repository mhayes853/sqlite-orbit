/// How an ``OrbitValueObservationSequence`` buffers elements that an observation produces faster
/// than the sequence's consumer takes them.
///
/// ```swift
/// // Skip ahead to the current state of the database rather than replaying every intermediate one.
/// let latest = observation.values(in: database, bufferingPolicy: .bufferingNewest(1))
/// ```
public enum OrbitValueObservationBufferingPolicy: Hashable, Sendable {
  /// Buffers every element the observation produces.
  case unbounded

  /// Buffers at most this many elements, discarding the newest element once the buffer is full.
  case bufferingOldest(Int)

  /// Buffers at most this many elements, discarding the oldest element once the buffer is full.
  case bufferingNewest(Int)
}

extension OrbitValueObservationBufferingPolicy {
  fileprivate func streamPolicy<Element>()
    -> AsyncThrowingStream<Element, any Error>.Continuation.BufferingPolicy
  {
    switch self {
    case .unbounded: .unbounded
    case .bufferingOldest(let limit): .bufferingOldest(limit)
    case .bufferingNewest(let limit): .bufferingNewest(limit)
    }
  }
}

/// An asynchronous sequence of the elements an ``OrbitValueObservation`` produces for a database.
///
/// The observation starts when iteration begins, and ends when the iterator and the sequence's
/// buffered elements are released. Iterating the same sequence more than once, or from more than
/// one task, starts an independent observation for each iteration; those iterations do not share
/// elements with each other.
///
/// An element that arrives while the consumer is busy is buffered according to an
/// ``OrbitValueObservationBufferingPolicy``. Elements are buffered without bound by default, so a
/// slow consumer still sees every one of them; buffer the newest element only to have it skip ahead
/// to the current state of the database instead.
///
/// ```swift
/// @Table struct Reminder { let id: Int; var title: String; var isCompleted = false }
///
/// let observation = OrbitValueObservation.tracking { try $0.fetchAll(Reminder.all) }
/// for try await reminders in observation.values(in: database) {
///   print("\(reminders.count) reminders")
/// }
/// ```
public struct OrbitValueObservationSequence<Element: Sendable>: AsyncSequence, Sendable {
  /// The error type the sequence fails with, which is the error that ended the observation.
  public typealias Failure = any Error

  private let bufferingPolicy: OrbitValueObservationBufferingPolicy
  private let subscribe:
    @Sendable (
      _ onError: @escaping @Sendable (any Error) -> Void,
      _ onElement: @escaping @Sendable (Element) -> Void
    ) throws -> OrbitSubscription

  init(
    bufferingPolicy: OrbitValueObservationBufferingPolicy,
    subscribe:
      @escaping @Sendable (
        _ onError: @escaping @Sendable (any Error) -> Void,
        _ onElement: @escaping @Sendable (Element) -> Void
      ) throws -> OrbitSubscription
  ) {
    self.bufferingPolicy = bufferingPolicy
    self.subscribe = subscribe
  }

  /// Returns this sequence with a different buffering policy.
  ///
  /// ```swift
  /// for try await reminders in observation.values(in: database).buffering(.bufferingNewest(1)) {
  ///   render(reminders)
  /// }
  /// ```
  ///
  /// - Parameter policy: How elements are buffered for a consumer that falls behind.
  /// - Returns: A sequence that observes the same database with `policy`.
  public func buffering(_ policy: OrbitValueObservationBufferingPolicy) -> Self {
    Self(bufferingPolicy: policy, subscribe: self.subscribe)
  }

  /// Starts the observation and returns an iterator over the elements it produces.
  ///
  /// Each call starts an independent observation; iterators do not share elements.
  ///
  /// - Returns: An iterator that ends the observation when it is released.
  public func makeAsyncIterator() -> AsyncIterator {
    let holder = OrbitValueObservationSubscriptionHolder()
    let subscribe = self.subscribe
    let stream = AsyncThrowingStream<Element, any Error>(
      bufferingPolicy: self.bufferingPolicy.streamPolicy()
    ) { continuation in
      do {
        let subscription = try subscribe(
          { continuation.finish(throwing: $0) },
          { continuation.yield($0) }
        )
        holder.store(subscription)
      } catch {
        continuation.finish(throwing: error)
      }
      continuation.onTermination = { _ in holder.cancel() }
    }
    return AsyncIterator(base: stream.makeAsyncIterator())
  }

  /// An iterator over the elements one observation produces.
  ///
  /// The observation stops once the iterator and the elements it buffered are released.
  ///
  /// ```swift
  /// var iterator = observation.values(in: database).makeAsyncIterator()
  /// let reminders = try await iterator.next()
  /// ```
  public struct AsyncIterator: AsyncIteratorProtocol {
    private var base: AsyncThrowingStream<Element, any Error>.AsyncIterator

    fileprivate init(base: AsyncThrowingStream<Element, any Error>.AsyncIterator) {
      self.base = base
    }

    /// Returns the next element, waiting for one when none is buffered.
    ///
    /// - Returns: The next element, or `nil` once the observation has ended.
    /// - Throws: The error that ended the observation.
    public mutating func next() async throws -> Element? {
      try await self.base.next()
    }

    /// Returns the next element, resuming on `actor`.
    ///
    /// - Parameter actor: The actor to resume on.
    /// - Returns: The next element, or `nil` once the observation has ended.
    /// - Throws: The error that ended the observation.
    @available(iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2, *)
    public mutating func next(
      isolation actor: isolated (any Actor)?
    ) async throws(any Error) -> Element? {
      try await self.base.next(isolation: actor)
    }
  }
}

private final class OrbitValueObservationSubscriptionHolder: Sendable {
  private struct State: Sendable {
    var subscription: OrbitSubscription?
    var isCancelled = false
  }

  private let state = Lock(State())

  func store(_ subscription: OrbitSubscription) {
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
