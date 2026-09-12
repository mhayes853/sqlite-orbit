/// A strategy that decides when an invalidated value observation fetches and publishes again.
///
/// A policy invocation must keep fetching after ``OrbitValueObservationFetchResult/superseded``
/// until it receives a conclusive result. The built-in ``immediate`` policy is the default.
public protocol OrbitValueObservationRefetchPolicy: Sendable {
  /// Handles one or more invalidations accumulated by a running observation.
  func refetch(using context: consuming OrbitValueObservationRefetchContext) async
}

/// Why a running observation needs another fetch.
public enum OrbitValueObservationRefetchReason: Hashable, Sendable {
  /// A transaction committed through the observed database in this process.
  case databaseChange

  /// An observable value read by the fetch closure changed.
  case observableChange

  /// Another process announced a committed transaction.
  case externalProcessChange
}

/// Runtime state available to a refetch policy.
public struct OrbitValueObservationRefetchSnapshot: Sendable {
  /// Whether at least one writer in the commit's finite concurrent cohort is still active.
  public let hasActiveWriters: Bool

  /// The union of database regions that prompted this refetch, or `nil` for observable-only work.
  public let affectedRegion: OrbitDatabaseRegion?

  /// The database region read by the last accepted fetch, when one has completed.
  public let trackedRegion: OrbitDatabaseRegion?

  /// The reasons accumulated since the last accepted fetch.
  public let reasons: Set<OrbitValueObservationRefetchReason>
}

/// Whether a completed fetch may publish after another invalidation arrives.
public enum OrbitValueObservationPublicationBehavior: Hashable, Sendable {
  /// Publish only when no newer invalidation superseded the fetch.
  case ifCurrent

  /// Publish the fetched value even when it may already be stale.
  case force
}

/// The outcome of a refetch policy's fetch attempt.
public enum OrbitValueObservationFetchResult: Hashable, Sendable {
  /// The result was accepted, whether or not downstream operators emitted its value.
  case published

  /// A newer invalidation arrived before the result could be accepted.
  case superseded

  /// The observation stopped or no longer had work for this policy invocation.
  case cancelled
}

/// Scoped access to an invalidated observation's state and fetch operation.
///
/// The context cannot be copied or escape the policy invocation. Its primitive operations support
/// policies that wait, inspect newly accumulated invalidations, and retry their own fetches.
public struct OrbitValueObservationRefetchContext: ~Copyable, ~Escapable, Sendable {
  private let operation: OrbitValueObservationRefetchOperation

  @_lifetime(borrow operation)
  init(operation: borrowing OrbitValueObservationRefetchOperation) {
    self.operation = copy operation
  }

  /// Returns the observation's current invalidation state.
  public borrowing func snapshot() -> OrbitValueObservationRefetchSnapshot {
    operation.snapshot()
  }

  /// Waits for the finite cohort of writers currently represented by ``snapshot()``.
  ///
  /// Writers that begin later do not extend this wait. If their commits matter, a subsequent
  /// conditional fetch is superseded and the policy can decide whether to wait again.
  public borrowing func waitForActiveWriters() async {
    await operation.waitForActiveWriters()
  }

  /// Fetches the observation and attempts to publish the result.
  @discardableResult
  public mutating func fetch(
    publishing behavior: OrbitValueObservationPublicationBehavior
  ) async -> OrbitValueObservationFetchResult {
    await operation.fetch(publishing: behavior)
  }
}

/// The default policy, which retries immediately until it publishes a current value.
public struct OrbitImmediateValueObservationRefetchPolicy:
  OrbitValueObservationRefetchPolicy
{
  fileprivate init() {}

  public func refetch(using context: consuming OrbitValueObservationRefetchContext) async {
    var context = context
    while await context.fetch(publishing: .ifCurrent) == .superseded {}
  }
}

/// A policy that waits only for writers active alongside the commit, then publishes a current value.
public struct OrbitCoalescedValueObservationRefetchPolicy:
  OrbitValueObservationRefetchPolicy
{
  fileprivate init() {}

  public func refetch(using context: consuming OrbitValueObservationRefetchContext) async {
    var context = context
    while true {
      if context.snapshot().hasActiveWriters {
        await context.waitForActiveWriters()
      }
      guard await context.fetch(publishing: .ifCurrent) == .superseded else { return }
    }
  }
}

/// A policy that performs one fetch and publishes it even if a newer invalidation made it stale.
///
/// If an observable dependency invalidates its one-shot registration during that fetch, the
/// runtime schedules separate work to restore observation of that dependency.
public struct OrbitOnceValueObservationRefetchPolicy: OrbitValueObservationRefetchPolicy {
  fileprivate init() {}

  public func refetch(using context: consuming OrbitValueObservationRefetchContext) async {
    var context = context
    await context.fetch(publishing: .force)
  }
}

extension OrbitValueObservationRefetchPolicy
where Self == OrbitImmediateValueObservationRefetchPolicy {
  /// Refetches immediately and retries until the fetched value is current.
  public static var immediate: Self { Self() }
}

extension OrbitValueObservationRefetchPolicy
where Self == OrbitCoalescedValueObservationRefetchPolicy {
  /// Waits for an active writer cohort before refetching, without delaying isolated commits.
  public static var coalesced: Self { Self() }
}

extension OrbitValueObservationRefetchPolicy
where Self == OrbitOnceValueObservationRefetchPolicy {
  /// Refetches once and permits publishing a stale value.
  public static var once: Self { Self() }
}

final class OrbitValueObservationRefetchOperation: Sendable {
  private let makeSnapshot: @Sendable () -> OrbitValueObservationRefetchSnapshot
  private let wait: @Sendable () async -> Void
  private let performFetch:
    @Sendable (OrbitValueObservationPublicationBehavior) async -> OrbitValueObservationFetchResult
  private let conclusion = Lock(false)

  init(
    snapshot: @escaping @Sendable () -> OrbitValueObservationRefetchSnapshot,
    wait: @escaping @Sendable () async -> Void,
    fetch:
      @escaping @Sendable (
        OrbitValueObservationPublicationBehavior
      ) async -> OrbitValueObservationFetchResult
  ) {
    self.makeSnapshot = snapshot
    self.wait = wait
    self.performFetch = fetch
  }

  var didConclude: Bool { conclusion.withLock { $0 } }

  func snapshot() -> OrbitValueObservationRefetchSnapshot {
    makeSnapshot()
  }

  func waitForActiveWriters() async {
    await wait()
  }

  func fetch(
    publishing behavior: OrbitValueObservationPublicationBehavior
  ) async -> OrbitValueObservationFetchResult {
    let result = await performFetch(behavior)
    if result != .superseded { conclusion.withLock { $0 = true } }
    return result
  }
}
