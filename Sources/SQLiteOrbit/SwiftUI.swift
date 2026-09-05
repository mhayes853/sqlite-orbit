#if canImport(SwiftUI)
  import SwiftUI

  /// A main-actor observation scheduler that delivers scheduled callbacks inside a SwiftUI
  /// transaction.
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

    @MainActor
    public init(base: Base, transaction: Transaction) {
      self.base = base
      self.storage = Storage(transaction: transaction)
    }

    public func immediateInitialValue(
      from isolation: isolated (any Actor)?
    ) -> Bool {
      base.immediateInitialValue(from: isolation)
    }

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
    @MainActor
    public func transaction(
      _ transaction: Transaction
    ) -> TransactionValueObservationScheduler<Self> {
      TransactionValueObservationScheduler(base: self, transaction: transaction)
    }

    /// Delivers scheduled callbacks with `animation`.
    ///
    /// An immediate initial callback is not animated.
    @MainActor
    public func animation(
      _ animation: Animation? = .default
    ) -> TransactionValueObservationScheduler<Self> {
      transaction(Transaction(animation: animation))
    }
  }
#endif
