/// How a ``ValueObservationSequence`` buffers elements that an observation produces faster than the
/// sequence's consumer takes them.
public enum ValueObservationBufferingPolicy: Hashable, Sendable {
  /// Buffers every element the observation produces.
  case unbounded

  /// Buffers at most `limit` elements, discarding the newest element once the buffer is full.
  case bufferingOldest(Int)

  /// Buffers at most `limit` elements, discarding the oldest element once the buffer is full.
  case bufferingNewest(Int)
}

extension ValueObservationBufferingPolicy {
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

/// An asynchronous sequence of the elements a ``ValueObservation`` produces for a database.
///
/// The observation starts when iteration begins, and ends when the iterator and the sequence's
/// buffered elements are released. Iterating the same sequence more than once, or from more than
/// one task, starts an independent observation for each iteration; those iterations do not share
/// elements with each other.
///
/// An element that arrives while the consumer is busy is buffered according to a
/// ``ValueObservationBufferingPolicy``. Elements are buffered without bound by default, so a slow
/// consumer still sees every one of them; buffer the newest element only to have it skip ahead to
/// the current state of the database instead.
public struct ValueObservationSequence<Element: Sendable>: AsyncSequence, Sendable {
  public typealias Failure = any Error

  private let bufferingPolicy: ValueObservationBufferingPolicy
  private let subscribe:
    @Sendable (
      _ onError: @escaping @Sendable (any Error) -> Void,
      _ onElement: @escaping @Sendable (Element) -> Void
    ) throws -> SQLiteCrossSubscription

  init(
    bufferingPolicy: ValueObservationBufferingPolicy,
    subscribe:
      @escaping @Sendable (
        _ onError: @escaping @Sendable (any Error) -> Void,
        _ onElement: @escaping @Sendable (Element) -> Void
      ) throws -> SQLiteCrossSubscription
  ) {
    self.bufferingPolicy = bufferingPolicy
    self.subscribe = subscribe
  }

  /// Returns this sequence with a different buffering policy.
  public func buffering(_ policy: ValueObservationBufferingPolicy) -> Self {
    Self(bufferingPolicy: policy, subscribe: self.subscribe)
  }

  public func makeAsyncIterator() -> AsyncIterator {
    let holder = ValueObservationSubscriptionHolder()
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

  public struct AsyncIterator: AsyncIteratorProtocol {
    private var base: AsyncThrowingStream<Element, any Error>.AsyncIterator

    fileprivate init(base: AsyncThrowingStream<Element, any Error>.AsyncIterator) {
      self.base = base
    }

    public mutating func next() async throws -> Element? {
      try await self.base.next()
    }

    public mutating func next(
      isolation actor: isolated (any Actor)?
    ) async throws(any Error) -> Element? {
      try await self.base.next(isolation: actor)
    }
  }
}

/// Holds the subscription a sequence's iteration owns, so that a cancellation racing the initial
/// subscribe still tears the observation down.
private final class ValueObservationSubscriptionHolder: Sendable {
  private struct State: Sendable {
    var subscription: SQLiteCrossSubscription?
    var isCancelled = false
  }

  private let state = Lock(State())

  func store(_ subscription: SQLiteCrossSubscription) {
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
