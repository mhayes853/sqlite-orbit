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
/// Each iteration creates a subscription with its own buffer. Iterations of the same observation
/// on the same database share the observation's fetch, reducer state, and lifecycle. Releasing an
/// iterator ends its subscription; the runtime stops when its last subscription ends.
///
/// An element that arrives while the consumer is busy is buffered according to an
/// ``OrbitValueObservationBufferingPolicy``. Elements are buffered without bound by default, so a
/// slow consumer still sees every one of them; buffer the newest element only to have it skip ahead
/// to the current state of the database instead.
///
/// ```swift
/// @Table struct Reminder { let id: Int; var title: String; var isCompleted = false }
///
/// let observation = OrbitValueObservation.tracking { try Reminder.all.fetchAll($0) }
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

  /// Starts the observation and returns an iterator over the elements it produces.
  ///
  /// Each call creates a subscription with its own buffer, sharing the observation runtime
  /// with other subscriptions to the same definition and database.
  ///
  /// - Returns: An iterator that ends its subscription when it is released.
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
  /// Its subscription ends once the iterator and the elements it buffered are released.
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
