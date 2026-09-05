/// Controls where a value observation delivers its callbacks.
public protocol ValueObservationScheduler: Sendable {
  /// Returns whether an observation started from `isolation` should fetch and deliver its initial
  /// value before subscription returns.
  func immediateInitialValue(
    from isolation: isolated (any Actor)?
  ) -> Bool

  /// Delivers an observation callback from `isolation`.
  func schedule(
    from isolation: isolated (any Actor)?,
    _ action: @escaping @Sendable () -> Void
  )
}

/// A scheduler that introduces no additional isolation or scheduling boundary.
///
/// Since later callbacks run directly from the observation's serialized publication context, they
/// must not perform a blocking access that reenters the same database connection.
public struct ImmediateValueObservationScheduler: ValueObservationScheduler {
  public init() {}

  public func immediateInitialValue(
    from isolation: isolated (any Actor)?
  ) -> Bool {
    true
  }

  public func schedule(
    from isolation: isolated (any Actor)?,
    _ action: @escaping @Sendable () -> Void
  ) {
    action()
  }
}

extension ValueObservationScheduler where Self == ImmediateValueObservationScheduler {
  /// Delivers the initial value before subscription returns and introduces no scheduling boundary
  /// for later callbacks.
  ///
  /// A callback must not perform a blocking access that reenters the same database connection.
  public static var immediate: Self { Self() }
}

/// A scheduler that delivers callbacks on a selected isolation.
public struct AsyncValueObservationScheduler: ValueObservationScheduler {
  private let isolation: (any Actor)?
  private let drain: ValueObservationSchedulerDrain

  fileprivate init(
    isolation: (any Actor)?,
    priority: TaskPriority?
  ) {
    self.isolation = isolation
    self.drain = ValueObservationSchedulerDrain(isolation: isolation, priority: priority)
  }

  public func immediateInitialValue(
    from isolation: isolated (any Actor)?
  ) -> Bool {
    self.isolation != nil && self.isolation === isolation
  }

  public func schedule(
    from isolation: isolated (any Actor)?,
    _ action: @escaping @Sendable () -> Void
  ) {
    if self.isolation != nil && self.isolation === isolation {
      action()
    } else {
      drain.enqueue(action)
    }
  }
}

extension ValueObservationScheduler where Self == AsyncValueObservationScheduler {
  /// Delivers callbacks asynchronously on Swift's cooperative executor.
  public static func async(
    priority: TaskPriority? = nil
  ) -> Self {
    Self(isolation: nil, priority: priority)
  }

  /// Delivers callbacks on `isolation`, immediately when already isolated there.
  public static func async(
    on isolation: any Actor,
    priority: TaskPriority? = nil
  ) -> Self {
    Self(isolation: isolation, priority: priority)
  }
}

/// A scheduler whose callbacks are guaranteed to run on the main actor.
public protocol ValueObservationMainActorScheduler: ValueObservationScheduler {}

/// A scheduler that delivers callbacks on the main actor.
///
/// Its initial value is immediate when subscription starts on the main actor. Starting elsewhere
/// introduces an asynchronous hop to the main actor.
public struct MainActorValueObservationScheduler: ValueObservationMainActorScheduler {
  private let drain: ValueObservationSchedulerDrain

  fileprivate init(priority: TaskPriority?) {
    self.drain = ValueObservationSchedulerDrain(
      isolation: MainActor.shared,
      priority: priority
    )
  }

  public func immediateInitialValue(
    from isolation: isolated (any Actor)?
  ) -> Bool {
    isolation === MainActor.shared
  }

  public func schedule(
    from isolation: isolated (any Actor)?,
    _ action: @escaping @Sendable () -> Void
  ) {
    if isolation === MainActor.shared {
      action()
    } else {
      drain.enqueue(action)
    }
  }
}

extension ValueObservationScheduler where Self == MainActorValueObservationScheduler {
  /// Delivers callbacks on the main actor, immediately when already isolated there.
  public static var mainActor: Self {
    Self(priority: nil)
  }

  /// Delivers callbacks on the main actor, immediately when already isolated there.
  public static func async(
    on isolation: MainActor,
    priority: TaskPriority? = nil
  ) -> Self {
    Self(priority: priority)
  }
}

private final class ValueObservationSchedulerDrain: Sendable {
  private struct State: Sendable {
    var actions = [@Sendable () -> Void]()
    var isDraining = false
  }

  private let isolation: (any Actor)?
  private let priority: TaskPriority?
  private let state = Lock(State())

  init(isolation: (any Actor)?, priority: TaskPriority?) {
    self.isolation = isolation
    self.priority = priority
  }

  func enqueue(_ action: @escaping @Sendable () -> Void) {
    let shouldStart = state.withLock { state in
      state.actions.append(action)
      guard !state.isDraining else { return false }
      state.isDraining = true
      return true
    }
    guard shouldStart else { return }
    Task(priority: priority) { [self] in await drain() }
  }

  private func drain() async {
    if isolation == nil {
      drainActions()
    } else {
      await perform(on: isolation) { [self] in drainActions() }
    }
  }

  private func drainActions() {
    while let action = state.withLock({ state -> (@Sendable () -> Void)? in
      guard !state.actions.isEmpty else {
        state.isDraining = false
        return nil
      }
      return state.actions.removeFirst()
    }) {
      action()
    }
  }
}

private func perform(
  on isolation: isolated (any Actor)?,
  _ action: @Sendable () -> Void
) {
  action()
}
