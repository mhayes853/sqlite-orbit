import Synchronization

/// A cancellable registration with an interprocess transport.
///
/// Copies share the same cancellation state. The cancellation closure runs at most once, either
/// when ``cancel()`` is first called or when the final copy is released.
public struct SQLiteCrossSubscription: Sendable {
  private let storage: Storage

  /// Creates a subscription that invokes `onCancel` when cancelled.
  public init(onCancel: @escaping @Sendable () -> Void) {
    self.storage = Storage(onCancel: onCancel)
  }

  /// Cancels the subscription. Subsequent calls have no effect.
  public func cancel() {
    self.storage.cancel()
  }

  private final class Storage: Sendable {
    private let onCancel: Mutex<(@Sendable () -> Void)?>

    init(onCancel: @escaping @Sendable () -> Void) {
      self.onCancel = Mutex(onCancel)
    }

    deinit { self.cancel() }

    func cancel() {
      let action = self.onCancel.withLock { action in
        defer { action = nil }
        return action
      }
      action?()
    }
  }
}
