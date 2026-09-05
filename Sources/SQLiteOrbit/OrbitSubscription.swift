import Synchronization

/// A cancellable registration with an interprocess transport.
///
/// Copies share the same cancellation state. The cancellation closure runs at most once, either
/// when ``cancel()`` is first called or when the final copy is released — so holding onto the
/// value returned by a `subscribe` method is what keeps the registration alive.
///
/// ```swift
/// let subscription = try OrbitValueObservation
///   .tracking { try $0.fetchCount(Reminder.all) }
///   .subscribe(to: database, onError: log) { change in counts.append(change.value) }
/// // ...
/// subscription.cancel()
/// ```
public struct OrbitSubscription: Sendable {
  private let storage: Storage

  /// Creates a subscription that invokes `onCancel` when cancelled.
  ///
  /// ```swift
  /// func subscribe(to identifier: OrbitDatabaseIdentifier) -> OrbitSubscription {
  ///   let token = register(identifier)
  ///   return OrbitSubscription { unregister(token) }
  /// }
  /// ```
  ///
  /// - Parameter onCancel: Runs once, when the subscription is cancelled or fully released.
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

// Values registered under identifiers the registry hands out.
//
// The four handler registries in this package — transaction observers, observation subscribers,
// in-process commit listeners, and IPC message handlers — all need the same identifier
// bookkeeping, and get it from here rather than each keeping its own counter.
struct IdentifiedRegistry<Value: Sendable>: Sendable {
  private var nextIdentifier: UInt64 = 0
  private var values = [UInt64: Value]()

  var isEmpty: Bool { self.values.isEmpty }
  var all: [Value] { Array(self.values.values) }

  // Adds `value` and returns the identifier it is filed under.
  mutating func insert(_ value: Value) -> UInt64 {
    defer { self.nextIdentifier &+= 1 }
    self.values[self.nextIdentifier] = value
    return self.nextIdentifier
  }

  // Removes the value under `identifier`, reporting whether one was there.
  @discardableResult
  mutating func remove(_ identifier: UInt64) -> Bool {
    self.values.removeValue(forKey: identifier) != nil
  }

  // Removes every value and returns them.
  mutating func removeAll() -> [Value] {
    defer { self.values.removeAll() }
    return self.all
  }
}

// Handlers registered per key, under identifiers unique across every key.
struct KeyedHandlerRegistry<Key: Hashable & Sendable, Handler: Sendable>: Sendable {
  private var nextIdentifier: UInt64 = 0
  private var groups = [Key: [UInt64: Handler]]()

  var keys: [Key] { Array(self.groups.keys) }

  func handlers(for key: Key) -> [Handler] {
    self.groups[key].map { Array($0.values) } ?? []
  }

  func contains(_ key: Key) -> Bool { self.groups[key] != nil }

  // Adds `handler` under `key`, reporting whether it is the first handler that key has.
  mutating func insert(
    _ handler: Handler,
    for key: Key
  ) -> (identifier: UInt64, isFirstForKey: Bool) {
    let isFirstForKey = self.groups[key] == nil
    let identifier = self.nextIdentifier
    self.nextIdentifier &+= 1
    self.groups[key, default: [:]][identifier] = handler
    return (identifier, isFirstForKey)
  }

  // Removes the handler under `identifier` and `key`, reporting whether that emptied the key.
  @discardableResult
  mutating func remove(_ identifier: UInt64, for key: Key) -> Bool {
    guard var group = self.groups[key], group.removeValue(forKey: identifier) != nil else {
      return false
    }
    guard group.isEmpty else {
      self.groups[key] = group
      return false
    }
    self.groups.removeValue(forKey: key)
    return true
  }

  // Removes every handler and returns the keys that had them.
  mutating func removeAll() -> [Key] {
    defer { self.groups.removeAll() }
    return self.keys
  }
}
