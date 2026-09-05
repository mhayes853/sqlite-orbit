/// Controls where a value observation delivers its callbacks.
///
/// Use one of the built-in schedulers — ``OrbitValueObservationScheduler/immediate``,
/// ``OrbitValueObservationScheduler/async(priority:)``,
/// ``OrbitValueObservationScheduler/async(on:priority:)``, or
/// ``OrbitValueObservationScheduler/mainActor`` — unless you need delivery somewhere none of them
/// reaches.
///
/// ```swift
/// try OrbitValueObservation
///   .tracking { try $0.fetchCount(Reminder.all) }
///   .subscribe(to: database, scheduling: .mainActor) { _ in } onChange: { change in
///     reminderCount = change.value
///   }
/// ```
public protocol OrbitValueObservationScheduler: Sendable {
  /// Returns whether an observation started from `isolation` should fetch and deliver its initial
  /// value before subscription returns.
  ///
  /// Answering `true` makes subscription perform a blocking read, so only answer it where the
  /// scheduler can deliver the value synchronously on the caller's isolation.
  ///
  /// - Parameter isolation: The actor subscription was started from, if any.
  /// - Returns: Whether the initial value should be produced before subscription returns.
  func immediateInitialValue(
    from isolation: isolated (any Actor)?
  ) -> Bool

  /// Delivers an observation callback from `isolation`.
  ///
  /// Callbacks scheduled from the same context must run in the order they were scheduled.
  ///
  /// - Parameters:
  ///   - isolation: The actor the observation is publishing from, if any.
  ///   - action: The callback to run.
  func schedule(
    from isolation: isolated (any Actor)?,
    _ action: @escaping @Sendable () -> Void
  )
}

/// A scheduler that introduces no additional isolation or scheduling boundary.
///
/// The initial value arrives before subscription returns, which makes this the scheduler to reach
/// for in tests and in synchronous setup code. Since later callbacks run directly from the
/// observation's serialized publication context, they must not perform a blocking access that
/// reenters the same database connection.
///
/// ```swift
/// let counts = Mutex([Int]())
/// let subscription = try OrbitValueObservation
///   .tracking { try $0.fetchCount(Reminder.all) }
///   .subscribe(to: database, scheduling: .immediate) { _ in } onChange: { change in
///     counts.withLock { $0.append(change.value) }
///   }
/// // `counts` already holds the initial value here.
/// ```
public struct OrbitImmediateValueObservationScheduler: OrbitValueObservationScheduler {
  /// Creates an immediate scheduler.
  public init() {}

  /// Always reports that the initial value should be delivered before subscription returns.
  ///
  /// - Parameter isolation: The actor subscription was started from, if any.
  /// - Returns: `true`.
  public func immediateInitialValue(
    from isolation: isolated (any Actor)?
  ) -> Bool {
    true
  }

  /// Runs `action` inline.
  ///
  /// - Parameters:
  ///   - isolation: The actor the observation is publishing from, if any.
  ///   - action: The callback to run.
  public func schedule(
    from isolation: isolated (any Actor)?,
    _ action: @escaping @Sendable () -> Void
  ) {
    action()
  }
}

extension OrbitValueObservationScheduler where Self == OrbitImmediateValueObservationScheduler {
  /// Delivers the initial value before subscription returns and introduces no scheduling boundary
  /// for later callbacks.
  ///
  /// A callback must not perform a blocking access that reenters the same database connection.
  ///
  /// ```swift
  /// try observation.subscribe(to: database, scheduling: .immediate, onError: log, onChange: apply)
  /// ```
  public static var immediate: Self { Self() }
}

/// A scheduler that delivers callbacks on a selected isolation.
///
/// With no isolation, callbacks run on Swift's cooperative executor in the order they were
/// produced. With one, callbacks run on that actor, and run inline whenever the observation is
/// already publishing from it.
///
/// ```swift
/// actor RemindersCache { var count = 0 }
///
/// let cache = RemindersCache()
/// try OrbitValueObservation
///   .tracking { try $0.fetchCount(Reminder.all) }
///   .subscribe(to: database, scheduling: .async(on: cache)) { _ in } onChange: { change in
///     cache.assumeIsolated { $0.count = change.value }
///   }
/// ```
public struct OrbitAsyncValueObservationScheduler: OrbitValueObservationScheduler {
  private let isolation: (any Actor)?
  private let drain: OrbitValueObservationSchedulerDrain

  fileprivate init(
    isolation: (any Actor)?,
    priority: TaskPriority?
  ) {
    self.isolation = isolation
    self.drain = OrbitValueObservationSchedulerDrain(isolation: isolation, priority: priority)
  }

  /// Reports that the initial value is immediate only when the caller is already isolated to this
  /// scheduler's actor.
  ///
  /// - Parameter isolation: The actor subscription was started from, if any.
  /// - Returns: Whether the initial value should be produced before subscription returns.
  public func immediateInitialValue(
    from isolation: isolated (any Actor)?
  ) -> Bool {
    self.isolation != nil && self.isolation === isolation
  }

  /// Runs `action` inline when already on this scheduler's actor, and otherwise queues it.
  ///
  /// - Parameters:
  ///   - isolation: The actor the observation is publishing from, if any.
  ///   - action: The callback to run.
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

extension OrbitValueObservationScheduler where Self == OrbitAsyncValueObservationScheduler {
  /// Delivers callbacks asynchronously on Swift's cooperative executor.
  ///
  /// This is the scheduler ``OrbitValueObservation/subscribe(to:isolation:onError:onChange:)``
  /// uses.
  ///
  /// ```swift
  /// try observation.subscribe(
  ///   to: database, scheduling: .async(priority: .utility), onError: log, onChange: apply
  /// )
  /// ```
  ///
  /// - Parameter priority: The priority of the task that drains the callback queue.
  /// - Returns: A scheduler with no actor isolation.
  public static func async(
    priority: TaskPriority? = nil
  ) -> Self {
    Self(isolation: nil, priority: priority)
  }

  /// Delivers callbacks on `isolation`, immediately when already isolated there.
  ///
  /// ```swift
  /// try observation.subscribe(
  ///   to: database, scheduling: .async(on: cache), onError: log, onChange: apply
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - isolation: The actor callbacks run on.
  ///   - priority: The priority of the task that drains the callback queue.
  /// - Returns: A scheduler isolated to `isolation`.
  public static func async(
    on isolation: any Actor,
    priority: TaskPriority? = nil
  ) -> Self {
    Self(isolation: isolation, priority: priority)
  }
}

/// A scheduler whose callbacks are guaranteed to run on the main actor.
///
/// Conforming lets a scheduler be used with
/// ``OrbitValueObservation/subscribe(to:scheduling:onError:onChange:)``, whose callbacks are
/// main-actor isolated.
///
/// ```swift
/// try observation.subscribe(to: database, scheduling: .mainActor) { _ in } onChange: { change in
///   reminderCount = change.value  // already on the main actor
/// }
/// ```
public protocol OrbitValueObservationMainActorScheduler: OrbitValueObservationScheduler {}

/// A scheduler that delivers callbacks on the main actor.
///
/// Its initial value is immediate when subscription starts on the main actor. Starting elsewhere
/// introduces an asynchronous hop to the main actor.
///
/// ```swift
/// @MainActor var reminderCount = 0
///
/// try OrbitValueObservation
///   .tracking { try $0.fetchCount(Reminder.all) }
///   .subscribe(to: database, scheduling: .mainActor) { _ in } onChange: { change in
///     reminderCount = change.value
///   }
/// ```
public struct OrbitMainActorValueObservationScheduler: OrbitValueObservationMainActorScheduler {
  private let drain = OrbitValueObservationSchedulerDrain(
    isolation: MainActor.shared,
    priority: nil
  )

  fileprivate init() {}

  /// Reports that the initial value is immediate only when subscription started on the main actor.
  ///
  /// - Parameter isolation: The actor subscription was started from, if any.
  /// - Returns: Whether the initial value should be produced before subscription returns.
  public func immediateInitialValue(
    from isolation: isolated (any Actor)?
  ) -> Bool {
    isolation === MainActor.shared
  }

  /// Runs `action` inline when already on the main actor, and otherwise queues it for one.
  ///
  /// - Parameters:
  ///   - isolation: The actor the observation is publishing from, if any.
  ///   - action: The callback to run.
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

extension OrbitValueObservationScheduler where Self == OrbitMainActorValueObservationScheduler {
  /// Delivers callbacks on the main actor, immediately when already isolated there.
  ///
  /// ```swift
  /// try observation.subscribe(to: database, scheduling: .mainActor, onError: log, onChange: apply)
  /// ```
  public static var mainActor: Self {
    Self()
  }
}

private final class OrbitValueObservationSchedulerDrain: Sendable {
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
    Task(priority: priority) { [self] in await drainActions(on: isolation) }
  }

  /// Runs every queued action on `isolation`, hopping to it through the isolated parameter.
  private func drainActions(on isolation: isolated (any Actor)?) {
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
