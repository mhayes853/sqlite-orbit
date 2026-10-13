/// A cancellable registration for the commits that concern a database region, whose region can
/// change while it stays registered.
///
/// The region is a lower bound. A commit that overlaps it is always reported, but a database or
/// transport may also report commits outside it, and may skip them, so a registration for
/// ``OrbitDatabaseRegion/fullDatabase`` is told about every commit. Skipping lets an interprocess
/// transport avoid waking a process that does not care about a commit at all.
///
/// Once ``updateRegion(_:)`` returns, every announcement that starts afterwards honors the new
/// region. An announcement already underway can still be judged by the old one, so after widening
/// the region, a registration that must not miss a commit to the added part reads that part again.
///
/// Like ``OrbitSubscription``, copies share the same state, and the cancellation closure runs at
/// most once, either when ``cancel()`` is first called or when the final copy is released.
///
/// ```swift
/// let subscription = try database.subscribe(
///   transactionObserver: CommitLogger(),
///   region: OrbitDatabaseRegion(table: "reminders")
/// )
/// // Also start logging commits that touch tags.
/// try subscription.updateRegion(subscription.region.union(Tag.databaseRegion))
/// ```
public struct OrbitRegionSubscription: Sendable {
  private let storage: Storage

  /// Creates a subscription for `region` that invokes `onUpdateRegion` when its region changes
  /// and `onCancel` when it is cancelled.
  ///
  /// A database or transport that reports every commit, whatever the region, leaves
  /// `onUpdateRegion` out, and the subscription then only records the regions it is given.
  ///
  /// ```swift
  /// func subscribe(
  ///   to identifier: OrbitDatabaseIdentifier,
  ///   region: OrbitDatabaseRegion
  /// ) -> OrbitRegionSubscription {
  ///   let token = register(identifier, region: region)
  ///   return OrbitRegionSubscription(region: region) { region in
  ///     try advertise(token, region: region)
  ///   } onCancel: {
  ///     unregister(token)
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - region: The region the registration starts with.
  ///   - onUpdateRegion: Applies a new region, returning only once announcements that start
  ///     afterwards honor it, or `nil` if the registration reports every commit whatever its
  ///     region. Calls are serialized, and none is made once cancellation begins, although one
  ///     already running may race with cancellation. If it throws, the registration must still
  ///     report every commit overlapping its previous region; extra commits may also be reported.
  ///   - onCancel: Runs once, when the subscription is cancelled or fully released.
  public init(
    region: OrbitDatabaseRegion,
    onUpdateRegion: (@Sendable (OrbitDatabaseRegion) throws -> Void)? = nil,
    onCancel: @escaping @Sendable () -> Void
  ) {
    self.storage = Storage(region: region, onUpdateRegion: onUpdateRegion, onCancel: onCancel)
  }

  /// The region the registration was last successfully given.
  public var region: OrbitDatabaseRegion {
    self.storage.region
  }

  /// Whether commits outside ``region`` may be skipped.
  ///
  /// When `false`, every commit is reported regardless of the region. When `true`, commits
  /// overlapping the region are reported, and commits outside it may also be reported.
  public var filtersByRegion: Bool {
    self.storage.onUpdateRegion != nil
  }

  /// Changes the region the registration is for.
  ///
  /// When this method returns, every announcement that starts afterwards honors `region`. Updating
  /// to the current region, or updating a cancelled subscription, does nothing.
  ///
  /// ```swift
  /// try subscription.updateRegion(OrbitDatabaseRegion(table: "reminders"))
  /// ```
  ///
  /// - Parameter region: The new region.
  /// - Throws: An error if the database or transport cannot apply the region, in which case
  ///   ``region`` is unchanged.
  public func updateRegion(_ region: OrbitDatabaseRegion) throws {
    try self.storage.updateRegion(region)
  }

  /// Cancels the subscription. Subsequent calls have no effect.
  public func cancel() {
    self.storage.cancel()
  }

  private final class Storage: Sendable {
    let onUpdateRegion: (@Sendable (OrbitDatabaseRegion) throws -> Void)?
    // `onCancel` is cleared once cancellation begins.
    private let state: Lock<(region: OrbitDatabaseRegion, onCancel: (@Sendable () -> Void)?)>
    // Held across an update so that the recorded region is always the one applied last.
    private let updates = Lock(())

    init(
      region: OrbitDatabaseRegion,
      onUpdateRegion: (@Sendable (OrbitDatabaseRegion) throws -> Void)?,
      onCancel: @escaping @Sendable () -> Void
    ) {
      self.onUpdateRegion = onUpdateRegion
      self.state = Lock((region, onCancel))
    }

    deinit { self.cancel() }

    var region: OrbitDatabaseRegion {
      self.state.withLock { $0.region }
    }

    func updateRegion(_ region: OrbitDatabaseRegion) throws {
      try self.updates.withLock { _ in
        let isCurrent = self.state.withLock { $0.onCancel == nil || $0.region == region }
        guard !isCurrent else { return }
        try self.onUpdateRegion?(region)
        self.state.withLock { $0.region = region }
      }
    }

    func cancel() {
      let action = self.state.withLock { state in
        defer { state.onCancel = nil }
        return state.onCancel
      }
      action?()
    }
  }
}

extension OrbitDatabaseRegion {
  /// Whether a registration for this region must be told about a commit that changed `changed`.
  ///
  /// A registration for the full database is told about everything, including commits that
  /// changed nothing, as it would be if regions were never considered.
  func admits(_ changed: OrbitDatabaseRegion) -> Bool {
    self.isFullDatabase || self.overlaps(changed)
  }
}
