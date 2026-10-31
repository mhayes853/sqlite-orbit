#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  /// Notifies changes in database regions, after each committed transaction that modifies them.
  ///
  /// The change callback receives the writer connection right after the commit, for transactions
  /// and statements run through the compatibility `Database` (including `write` and
  /// `inTransaction`). Commits made through SQLiteOrbit's native APIs, other connections, or other
  /// processes are not notified.
  public struct DatabaseRegionObservation: Sendable {
    let regions: [any DatabaseRegionConvertible]

    /// Observes the union of the given regions.
    public init(tracking regions: any DatabaseRegionConvertible...) {
      self.regions = regions
    }

    /// Observes the union of the given regions.
    public init(tracking regions: [any DatabaseRegionConvertible]) {
      self.regions = regions
    }

    /// Starts the observation. The observed region is resolved before this method returns.
    public func start(
      in writer: some DatabaseWriter,
      onError: @escaping @Sendable (Error) -> Void,
      onChange: @escaping @Sendable (Database) -> Void
    ) -> AnyDatabaseCancellable {
      do {
        let regions = regions
        let region = try writer.unsafeRead { db in
          try regions.reduce(DatabaseRegion()) { try $0.union($1.databaseRegion(db)) }
        }
        let observer = RegionObserver(region: region.native, onChange: onChange)
        let subscription = try writer.orbitDatabase.subscribe(
          transactionObserver: observer,
          region: region.native
        )
        return AnyDatabaseCancellable {
          observer.cancel()
          subscription.cancel()
        }
      } catch {
        onError((error as? SQLiteError).map { DatabaseError($0) } ?? error)
        return AnyDatabaseCancellable {}
      }
    }
  }

  // Records local commits that touch the observed region. The overlay delivers them to the
  // committing `Database` as soon as the commit returns, on the same thread.
  private final class RegionObserver: OrbitDatabaseTransactionObserver, @unchecked Sendable {
    let region: OrbitDatabaseRegion
    let onChange: @Sendable (Database) -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(region: OrbitDatabaseRegion, onChange: @escaping @Sendable (Database) -> Void) {
      self.region = region
      self.onChange = onChange
    }

    func cancel() {
      lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
      lock.withLock { cancelled }
    }

    func databaseDidCommit(_ commit: OrbitDatabaseCommit) {
      guard commit.origin == .local, region.overlaps(commit.region), !isCancelled else { return }
      PendingRegionChanges.append(self)
    }
  }

  private enum PendingRegionChanges {
    private final class Box {
      var observers: [RegionObserver] = []
    }

    private static let key = "SQLiteOrbitGRDB.PendingRegionChanges"

    private static var box: Box {
      let dictionary = Thread.current.threadDictionary
      if let box = dictionary[key] as? Box { return box }
      let box = Box()
      dictionary[key] = box
      return box
    }

    static func append(_ observer: RegionObserver) {
      box.observers.append(observer)
    }

    static func take() -> [RegionObserver] {
      let box = box
      defer { box.observers = [] }
      return box.observers
    }
  }

  extension Database {
    /// Notifies region observations of commits that just completed on this connection.
    func deliverRegionChanges() {
      for observer in PendingRegionChanges.take() where !observer.isCancelled {
        observer.onChange(self)
      }
    }

    /// Reports changes performed outside of the compatibility API, such as by another
    /// connection, so that observations of the region are notified.
    public func notifyChanges(in region: some DatabaseRegionConvertible) throws {
      let region = try region.databaseRegion(self)
      try translate { try access.notifyChanges(in: region.native) }
      if !isInsideTransaction {
        deliverRegionChanges()
      }
    }
  }
#endif
