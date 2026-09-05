#if canImport(SwiftUI)
  import SwiftUI

  /// A main-actor observation scheduler that delivers scheduled callbacks inside a SwiftUI
  /// transaction.
  ///
  /// ```swift
  /// try ValueObservation
  ///   .tracking { try $0.fetchAll(Reminder.all) }
  ///   .subscribe(to: database, scheduling: .mainActor.animation(.default)) { _ in
  ///   } onChange: { change in reminders = change.value }
  /// ```
  public struct TransactionValueObservationScheduler<
    Base: ValueObservationMainActorScheduler
  >: ValueObservationMainActorScheduler {
    @MainActor
    private final class Storage {
      let transaction: Transaction

      init(transaction: Transaction) {
        self.transaction = transaction
      }
    }

    private let base: Base
    private let storage: Storage

    /// Wraps `base` so that the callbacks it schedules run inside `transaction`.
    ///
    /// - Parameters:
    ///   - base: The main-actor scheduler that decides where callbacks run.
    ///   - transaction: The SwiftUI transaction each scheduled callback runs inside.
    @MainActor
    public init(base: Base, transaction: Transaction) {
      self.base = base
      self.storage = Storage(transaction: transaction)
    }

    /// Defers to the base scheduler.
    ///
    /// - Parameter isolation: The actor subscription was started from, if any.
    /// - Returns: Whether the initial value should be produced before subscription returns.
    public func immediateInitialValue(
      from isolation: isolated (any Actor)?
    ) -> Bool {
      base.immediateInitialValue(from: isolation)
    }

    /// Runs `action` inside this scheduler's transaction, wherever the base scheduler runs it.
    ///
    /// - Parameters:
    ///   - isolation: The actor the observation is publishing from, if any.
    ///   - action: The callback to run.
    public func schedule(
      from isolation: isolated (any Actor)?,
      _ action: @escaping @Sendable () -> Void
    ) {
      base.schedule(from: isolation) { [storage] in
        MainActor.assumeIsolated {
          withTransaction(storage.transaction) {
            action()
          }
        }
      }
    }
  }

  extension ValueObservationMainActorScheduler {
    /// Delivers scheduled callbacks inside `transaction`.
    ///
    /// An immediate initial callback bypasses the transaction.
    ///
    /// ```swift
    /// let scheduler = MainActorValueObservationScheduler.mainActor
    ///   .transaction(Transaction(animation: .easeInOut))
    /// ```
    ///
    /// - Parameter transaction: The SwiftUI transaction each scheduled callback runs inside.
    /// - Returns: A scheduler that wraps this one's deliveries in `transaction`.
    @MainActor
    public func transaction(
      _ transaction: Transaction
    ) -> TransactionValueObservationScheduler<Self> {
      TransactionValueObservationScheduler(base: self, transaction: transaction)
    }

    /// Delivers scheduled callbacks with `animation`.
    ///
    /// An immediate initial callback is not animated.
    ///
    /// ```swift
    /// try observation.subscribe(to: database, scheduling: .mainActor.animation()) { _ in
    /// } onChange: { change in reminders = change.value }
    /// ```
    ///
    /// - Parameter animation: The animation applied to each scheduled callback.
    /// - Returns: A scheduler that animates this one's deliveries.
    @MainActor
    public func animation(
      _ animation: Animation? = .default
    ) -> TransactionValueObservationScheduler<Self> {
      transaction(Transaction(animation: animation))
    }
  }
#endif
