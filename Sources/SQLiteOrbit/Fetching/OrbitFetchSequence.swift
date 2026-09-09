/// An asynchronous sequence of the values a fetch property observes.
///
/// A property's ``OrbitFetchReader/values`` vends one of these, which is how something that is
/// neither a SwiftUI view nor an `@Observable` model — a controller, a test, an actor keeping a
/// cache warm — follows a query:
///
/// ```swift
/// @FetchAll(Reminder.all) var reminders
///
/// for await reminders in $reminders.values {
///   render(reminders)
/// }
/// ```
///
/// Iteration begins with the value as it stands and continues with each one the observation
/// produces afterwards. A consumer that falls behind skips ahead to the current value rather than
/// replaying the ones it missed, because a fetch property only ever holds the latest.
///
/// The sequence never ends on its own, and it never fails: a read that fails is reported through
/// ``OrbitFetchReader/loadError`` and leaves the last value in place. Cancelling the task that
/// iterates it is what ends it.
///
/// Iterating the same sequence more than once, or from more than one task, observes independently
/// for each iteration.
public struct OrbitFetchSequence<Element: Sendable>: AsyncSequence, Sendable {
  /// The sequence never fails; a failed read is reported through ``OrbitFetchReader/loadError``.
  public typealias Failure = Never

  private let storage: any OrbitFetchReaderStorage
  private let value: @Sendable () -> Element

  init(storage: any OrbitFetchReaderStorage, value: @escaping @Sendable () -> Element) {
    self.storage = storage
    self.value = value
  }

  /// Starts observing and returns an iterator over the values produced.
  ///
  /// - Returns: An iterator that stops observing when it is released.
  public func makeAsyncIterator() -> AsyncIterator {
    let value = self.value
    let storage = self.storage
    // A fetch property holds one value, so a consumer that falls behind wants the current one
    // rather than the queue of values it was too slow to take.
    let stream = AsyncStream<Element>(bufferingPolicy: .bufferingNewest(1)) { continuation in
      // Observing before yielding is what makes the first element the value the observation
      // produces, rather than whatever the property held before it started.
      let observation = storage.addObserver { continuation.yield(value()) }
      continuation.yield(value())
      continuation.onTermination = { _ in observation.cancel() }
    }
    return AsyncIterator(base: stream.makeAsyncIterator())
  }

  /// An iterator over the values one observation produces.
  ///
  /// Observation stops once the iterator is released.
  public struct AsyncIterator: AsyncIteratorProtocol {
    private var base: AsyncStream<Element>.AsyncIterator

    fileprivate init(base: AsyncStream<Element>.AsyncIterator) {
      self.base = base
    }

    /// Returns the next value, waiting for one when the value has not changed.
    ///
    /// - Returns: The next value, or `nil` once the iterating task is cancelled.
    public mutating func next() async -> Element? {
      await self.base.next()
    }

    /// Returns the next value, resuming on `actor`.
    ///
    /// - Parameter actor: The actor to resume on.
    /// - Returns: The next value, or `nil` once the iterating task is cancelled.
    @available(iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2, *)
    public mutating func next(isolation actor: isolated (any Actor)?) async -> Element? {
      await self.base.next(isolation: actor)
    }
  }
}
