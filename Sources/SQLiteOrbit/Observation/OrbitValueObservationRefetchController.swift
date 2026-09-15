/// A strategy that decides when an invalidated value observation fetches and publishes again.
///
/// A controller must keep fetching after ``OrbitValueObservationFetchResult/superseded`` until it
/// receives a conclusive result. The built-in ``immediate`` controller is the default.
public protocol OrbitValueObservationRefetchController: Sendable {
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

/// Runtime state available to a refetch controller.
public struct OrbitValueObservationRefetchSnapshot: Sendable {
  /// Whether at least one writer in the commit's finite concurrent cohort is still active.
  public let hasActiveWriters: Bool

  /// The union of database regions that prompted this refetch, or `nil` for observable-only work.
  public let affectedRegion: OrbitDatabaseRegion?

  /// The database region read by the last accepted fetch, when one has completed.
  public let trackedRegion: OrbitDatabaseRegion?

  /// The reasons accumulated since the last accepted fetch.
  public let reasons: Set<OrbitValueObservationRefetchReason>

  /// The commits that invalidated the observation since the last accepted fetch, oldest first.
  ///
  /// Each says where it was performed, ``OrbitDatabaseTransactionOrigin/local`` for this process
  /// and ``OrbitDatabaseTransactionOrigin/external`` for a write another process announced, along
  /// with the part of the database it changed that the observation tracks. ``affectedRegion`` is
  /// the union of those regions and ``reasons`` says only which kinds arrived, so this is what a
  /// controller reads to treat the two sources differently: to know whether this process's own
  /// write is waiting on it, or which source touched what.
  ///
  /// A controller that lets this process's writes through at once, but waits out a burst of other
  /// processes' writes so it costs one fetch, looks like this:
  ///
  /// ```swift
  /// struct DebouncingExternalRefetchController: OrbitValueObservationRefetchController {
  ///   var delay = Duration.milliseconds(250)
  ///
  ///   func refetch(using context: consuming OrbitValueObservationRefetchContext) async {
  ///     var context = context
  ///     let commits = context.snapshot().commits
  ///     if !commits.isEmpty, commits.allSatisfy({ $0.origin == .external }) {
  ///       try? await Task.sleep(for: delay)
  ///     }
  ///     while await context.fetch(publishing: .ifCurrent) == .superseded {}
  ///   }
  /// }
  /// ```
  ///
  /// A write made inside a transaction through the handle the observation subscribed to is
  /// usually answered by a fetch taken just before it commits, so it never reaches a controller.
  /// The local commits listed here are the rest: writes by another handle on the same database in
  /// this process, and writes made outside a transaction. A change to an observable value is not a
  /// commit and is listed only in ``reasons``.
  public let commits: [OrbitDatabaseCommit]
}

/// Whether a completed fetch may publish after another invalidation arrives.
public enum OrbitValueObservationPublicationBehavior: Hashable, Sendable {
  /// Publish only when no newer invalidation superseded the fetch.
  case ifCurrent

  /// Publish the fetched value even when it may already be stale.
  case force
}

/// The outcome of a refetch controller's fetch attempt.
public enum OrbitValueObservationFetchResult: Hashable, Sendable {
  /// The result was accepted, whether or not downstream operators emitted its value.
  case published

  /// A newer invalidation arrived before the result could be accepted.
  case superseded

  /// The observation stopped or no longer had work for this controller invocation.
  case cancelled
}

/// Scoped access to an invalidated observation's state and fetch operation.
///
/// The context cannot be copied or escape the controller invocation. Its primitive operations
/// support controllers that wait, inspect newly accumulated invalidations, and retry their own
/// fetches.
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
  /// conditional fetch is superseded and the controller can decide whether to wait again.
  public borrowing func waitForActiveWriters() async {
    await operation.waitForActiveWriters()
  }

  /// Fetches the observation and attempts to publish the result.
  @discardableResult
  @_lifetime(self: copy self)
  public mutating func fetch(
    publishing behavior: OrbitValueObservationPublicationBehavior
  ) async -> OrbitValueObservationFetchResult {
    await operation.fetch(publishing: behavior)
  }
}

/// The default controller, which retries immediately until it publishes a current value.
public struct OrbitImmediateValueObservationRefetchController:
  OrbitValueObservationRefetchController
{
  fileprivate init() {}

  public func refetch(using context: consuming OrbitValueObservationRefetchContext) async {
    var context = context
    while await context.fetch(publishing: .ifCurrent) == .superseded {}
  }
}

/// A controller that waits only for writers active alongside the commit before fetching.
public struct OrbitCoalescedValueObservationRefetchController:
  OrbitValueObservationRefetchController
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

/// A controller that performs one fetch and publishes it even if a newer invalidation made it stale.
///
/// If an observable dependency invalidates its one-shot registration during that fetch, the
/// runtime schedules separate work to restore observation of that dependency.
public struct OrbitOnceValueObservationRefetchController: OrbitValueObservationRefetchController {
  fileprivate init() {}

  public func refetch(using context: consuming OrbitValueObservationRefetchContext) async {
    var context = context
    await context.fetch(publishing: .force)
  }
}

extension OrbitValueObservationRefetchController
where Self == OrbitImmediateValueObservationRefetchController {
  /// Refetches immediately and retries until the fetched value is current.
  public static var immediate: Self { Self() }
}

extension OrbitValueObservationRefetchController
where Self == OrbitCoalescedValueObservationRefetchController {
  /// Waits for an active writer cohort before refetching, without delaying isolated commits.
  public static var coalesced: Self { Self() }
}

extension OrbitValueObservationRefetchController
where Self == OrbitOnceValueObservationRefetchController {
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
