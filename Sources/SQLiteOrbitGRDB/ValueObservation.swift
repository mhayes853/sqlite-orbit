#if canImport(Foundation) && canImport(Dispatch)
  import Dispatch
  import Foundation
  import SQLiteOrbit

  public protocol DatabaseCancellable: Sendable {
    func cancel()
  }

  public final class AnyDatabaseCancellable: DatabaseCancellable {
    private let subscription: OrbitSubscription

    /// Creates a cancellable that calls `cancel` once, when cancelled or deinitialized.
    public init(cancel: @escaping @Sendable () -> Void) {
      subscription = OrbitSubscription(onCancel: cancel)
    }

    public convenience init(_ cancel: @escaping @Sendable () -> Void) {
      self.init(cancel: cancel)
    }

    /// Wraps another cancellable.
    public convenience init(_ base: some DatabaseCancellable) {
      self.init(cancel: { base.cancel() })
    }

    init(_ subscription: OrbitSubscription) {
      self.subscription = subscription
    }

    public func cancel() {
      subscription.cancel()
    }
  }

  public protocol ValueReducer: Sendable {
    associatedtype Value: Sendable
  }

  public enum ValueReducers {
    public struct Fetch<Value: Sendable>: ValueReducer {}

    public struct Map<Base: ValueReducer, Value: Sendable>: ValueReducer {}

    public struct RemoveDuplicates<Base: ValueReducer>: ValueReducer {
      public typealias Value = Base.Value
    }

    public struct Trace<Base: ValueReducer>: ValueReducer {
      public typealias Value = Base.Value
    }
  }

  public protocol ValueObservationScheduler: OrbitValueObservationScheduler {}

  extension ValueObservationScheduler {
    /// Whether the initial value is delivered synchronously when observation starts.
    public func immediateInitialValue() -> Bool {
      immediateInitialValue(from: nil)
    }

    /// Schedules an observation callback.
    public func schedule(_ action: @escaping @Sendable () -> Void) {
      schedule(from: nil, action)
    }
  }

  public protocol ValueObservationMainActorScheduler: ValueObservationScheduler {}

  /// Delivers values asynchronously on a dispatch queue.
  public struct AsyncValueObservationScheduler: ValueObservationScheduler {
    private let queue: DispatchQueue

    /// Creates a scheduler that delivers values on `queue`.
    public init(queue: DispatchQueue) {
      self.queue = DispatchQueue(label: "sqlite-orbit-grdb.observation", target: queue)
    }

    public func immediateInitialValue(from isolation: isolated (any Actor)?) -> Bool {
      false
    }

    public func schedule(
      from isolation: isolated (any Actor)?,
      _ action: @escaping @Sendable () -> Void
    ) {
      queue.async(execute: action)
    }
  }

  /// Delivers the initial value synchronously, and later values on the main queue.
  ///
  /// GRDB requires starting such observations on the main thread; SQLiteOrbitGRDB also accepts
  /// other threads, where the initial value is delivered synchronously on the starting thread.
  public struct ImmediateValueObservationScheduler: ValueObservationMainActorScheduler {
    public init() {}

    public func immediateInitialValue(from isolation: isolated (any Actor)?) -> Bool {
      true
    }

    public func schedule(
      from isolation: isolated (any Actor)?,
      _ action: @escaping @Sendable () -> Void
    ) {
      if isolation === MainActor.shared || Thread.isMainThread {
        action()
      } else {
        DispatchQueue.main.async(execute: action)
      }
    }
  }

  /// Delivers all values asynchronously on the main actor.
  public final class DelayedMainActorValueObservationScheduler:
    ValueObservationMainActorScheduler
  {
    public init() {}

    public func immediateInitialValue(from isolation: isolated (any Actor)?) -> Bool {
      false
    }

    public func schedule(
      from isolation: isolated (any Actor)?,
      _ action: @escaping @Sendable () -> Void
    ) {
      DispatchQueue.main.async(execute: action)
    }
  }

  /// Delivers values asynchronously, in order, from a task.
  public final class TaskValueObservationScheduler: ValueObservationScheduler {
    private let continuation: AsyncStream<@Sendable () -> Void>.Continuation
    private let task: Task<Void, Never>

    init(priority: TaskPriority?) {
      let (stream, continuation) = AsyncStream.makeStream(of: (@Sendable () -> Void).self)
      self.continuation = continuation
      task = Task(priority: priority) {
        for await action in stream { action() }
      }
    }

    deinit {
      task.cancel()
    }

    public func immediateInitialValue(from isolation: isolated (any Actor)?) -> Bool {
      false
    }

    public func schedule(
      from isolation: isolated (any Actor)?,
      _ action: @escaping @Sendable () -> Void
    ) {
      continuation.yield(action)
    }
  }

  extension ValueObservationScheduler where Self == AsyncValueObservationScheduler {
    public static func async(onQueue queue: DispatchQueue) -> Self {
      Self(queue: queue)
    }
  }

  // Declared on the base protocol so that `.immediate` also resolves in generic scheduler
  // contexts, as in GRDB.
  extension ValueObservationScheduler where Self == ImmediateValueObservationScheduler {
    public static var immediate: Self { Self() }
  }

  extension ValueObservationScheduler where Self == DelayedMainActorValueObservationScheduler {
    public static var mainActor: Self { Self() }
  }

  extension ValueObservationScheduler where Self == TaskValueObservationScheduler {
    /// A scheduler that delivers values from a task.
    public static var task: Self { Self(priority: nil) }

    /// A scheduler that delivers values from a task with the given priority.
    public static func task(priority: TaskPriority) -> Self { Self(priority: priority) }
  }

  public struct DatabaseRegion: Hashable, Sendable, DatabaseRegionConvertible {
    let native: OrbitDatabaseRegion
    // Rows of tables restricted to some rowids, keyed by lowercased table name. Observation uses
    // the table-level native region; rowids refine descriptions, equality, and intersections.
    let rowIDs: [String: Set<Int64>]

    public init() {
      native = .empty
      rowIDs = [:]
    }

    init(_ native: OrbitDatabaseRegion, rowIDs: [String: Set<Int64>] = [:]) {
      self.native = native
      self.rowIDs = rowIDs
    }

    public init(table: String, columns: [String]? = nil) {
      native =
        columns.map { OrbitDatabaseRegion(columns: $0, in: table) }
        ?? OrbitDatabaseRegion(table: table)
      rowIDs = [:]
    }

    /// The region of some rows of a table.
    public init(table: String, rowIds: Set<Int64>) {
      if rowIds.isEmpty {
        self.init()
      } else {
        self.init(OrbitDatabaseRegion(table: table), rowIDs: [table.lowercased(): rowIds])
      }
    }

    public static let fullDatabase = Self(.fullDatabase)

    public var isEmpty: Bool {
      native.isEmpty
    }

    public func databaseRegion(_ db: Database) throws -> Self {
      self
    }

    // The lowercased names of the main-schema tables of a native region.
    private static func tables(of native: OrbitDatabaseRegion) -> Set<String> {
      Set(
        (RegionDescription(native.serialized())?.tables ?? [])
          .filter { $0.schema == "main" }
          .map { $0.name.lowercased() }
      )
    }

    public func union(_ other: Self) -> Self {
      let native = native.union(other.native)
      if native.isFullDatabase { return Self(native) }
      var rowIDs: [String: Set<Int64>] = [:]
      let lhsTables = Self.tables(of: self.native)
      let rhsTables = Self.tables(of: other.native)
      for table in Self.tables(of: native) {
        let lhs = lhsTables.contains(table) ? (self.rowIDs[table] ?? nil) : Set()
        let rhs = rhsTables.contains(table) ? (other.rowIDs[table] ?? nil) : Set()
        // A side that covers the table without a restriction covers all rows.
        if let lhs, let rhs {
          rowIDs[table] = lhs.union(rhs)
        }
      }
      return Self(native, rowIDs: rowIDs)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.native == rhs.native && lhs.rowIDs == rhs.rowIDs
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(native)
      hasher.combine(rowIDs)
    }

    /// The region common to both regions.
    public func intersection(_ other: Self) -> Self {
      var native = native.intersection(other.native)
      var rowIDs: [String: Set<Int64>] = [:]
      for table in Self.tables(of: native) {
        switch (self.rowIDs[table], other.rowIDs[table]) {
        case (nil, nil): break
        case (let ids?, nil), (nil, let ids?): rowIDs[table] = ids
        case (let lhs?, let rhs?):
          let ids = lhs.intersection(rhs)
          if ids.isEmpty {
            native = native.subtracting(OrbitDatabaseRegion(table: table))
          } else {
            rowIDs[table] = ids
          }
        }
      }
      return Self(native, rowIDs: rowIDs)
    }

    /// Whether a change in `other` affects this region.
    public func isModified(by other: Self) -> Bool {
      native.overlaps(other.native)
    }
  }

  extension DatabaseRegion: CustomStringConvertible {
    /// GRDB's description: `full database`, `empty`, or tables with their columns, such as
    /// `player(id,name),team(*)`. Identifiers are lowercased by SQLiteOrbit.
    public var description: String {
      guard let tables = RegionDescription(native.serialized()) else {
        return native.isFullDatabase ? "full database" : "empty"
      }
      if tables.includesUnspecifiedTables { return "full database" }
      if tables.tables.isEmpty { return "empty" }
      return tables.tables
        .map { table in
          let name = table.schema == "main" ? table.name : table.schema + "." + table.name
          var description =
            table.includesUnspecifiedColumns
            ? name + "(*)" : name + "(" + table.columns.sorted().joined(separator: ",") + ")"
          if table.schema == "main", let ids = rowIDs[table.name.lowercased()] {
            description += "[" + ids.sorted().map(String.init).joined(separator: ",") + "]"
          }
          return description
        }
        .sorted()
        .joined(separator: ",")
    }
  }

  // Reads SQLiteOrbit's documented, versioned binary region format.
  private struct RegionDescription {
    struct Table {
      var schema: String
      var name: String
      var includesUnspecifiedColumns: Bool
      var columns: [String]
    }

    var includesUnspecifiedTables = false
    var tables: [Table] = []

    init?(_ bytes: [UInt8]) {
      var offset = 0
      func byte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
      }
      func count() -> Int? {
        var value = 0
        var shift = 0
        while let byte = byte() {
          value |= Int(byte & 0x7f) << shift
          if byte & 0x80 == 0 { return value }
          shift += 7
          if shift > 56 { return nil }
        }
        return nil
      }
      guard byte() == 0, byte() == 1, let flags = byte(), let stringCount = count() else {
        return nil
      }
      includesUnspecifiedTables = flags & 1 != 0
      var strings: [String] = []
      for _ in 0..<stringCount {
        guard let length = count(), offset + length <= bytes.count else { return nil }
        strings.append(String(decoding: bytes[offset..<(offset + length)], as: UTF8.self))
        offset += length
      }
      func string() -> String? {
        guard let index = count(), index < strings.count else { return nil }
        return strings[index]
      }
      guard let tableCount = count() else { return nil }
      for _ in 0..<tableCount {
        guard let schema = string(), let name = string(), let flags = byte(),
          let columnCount = count()
        else { return nil }
        var columns: [String] = []
        for _ in 0..<columnCount {
          guard let column = string() else { return nil }
          columns.append(column)
        }
        tables.append(
          Table(
            schema: schema,
            name: name,
            includesUnspecifiedColumns: flags & 1 != 0,
            columns: columns
          )
        )
      }
    }
  }

  public protocol DatabaseRegionConvertible: Sendable {
    func databaseRegion(_ db: Database) throws -> DatabaseRegion
  }

  extension SQLRequest: DatabaseRegionConvertible {
    public func databaseRegion(_ db: Database) throws -> DatabaseRegion {
      let sql = try sql(in: db)
      return try translate {
        DatabaseRegion(
          try db.access.region(
            for: SQLiteOrbit.SQL(text: sql.sql, bindings: sql.arguments.values.map(\.orbitValue))
          )
        )
      }
    }
  }

  extension QueryInterfaceRequest: DatabaseRegionConvertible {
    public func databaseRegion(_ db: Database) throws -> DatabaseRegion {
      try makePreparedRequest(db, forSingleResult: false).statement.databaseRegion
    }
  }

  /// A GRDB-shaped observation backed by Orbit's shared observation runtime.
  ///
  /// Subscriptions to the same definition and database share fetches, reducer state, cached values,
  /// and lifecycle hooks. Each subscriber retains its own scheduling and cancellation; each async
  /// iterator has its own buffer. Unlike GRDB's default lifecycle, the runtime stops only when its
  /// last subscriber leaves. Construct a new observation for a separate runtime.
  public struct ValueObservation<Reducer: ValueReducer>: Sendable {
    let native: OrbitValueObservation<Reducer.Value>
    let hooks: ObservationHooks

    /// Whether the observation would fetch with write access. SQLiteOrbit observations always
    /// fetch in read-only transactions, so fetches cannot write even when this is true.
    public var requiresWriteAccess = false

    init(_ native: OrbitValueObservation<Reducer.Value>, hooks: ObservationHooks) {
      self.native = native
      self.hooks = hooks
      requiresWriteAccess = false
    }

    private func derived<R: ValueReducer>(_ native: OrbitValueObservation<R.Value>)
      -> ValueObservation<R>
    {
      var result = ValueObservation<R>(native, hooks: hooks)
      result.requiresWriteAccess = requiresWriteAccess
      return result
    }

    // Fetches with a database that records the region it reads, reported to willTrackRegion.
    private static func recordingFetch<Value>(
      _ fetch: @escaping @Sendable (Database) throws -> Value,
      hooks: ObservationHooks
    ) -> @Sendable (borrowing SQLiteReadTransaction) throws -> Value {
      { transaction in
        try translate {
          try transaction.withScopedAccess { access in
            let db = Database(access)
            db.regionRecorder = DatabaseRegion()
            let value = try fetch(db)
            hooks.didTrack(db.regionRecorder ?? DatabaseRegion())
            return value
          }
        }
      }
    }

    private static func make<Value: Sendable>(
      _ build: (ObservationHooks) -> OrbitValueObservation<Value>
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
      let hooks = ObservationHooks()
      return Self(build(hooks).handleEvents(willStart: { hooks.reset() }), hooks: hooks)
    }

    public static func tracking<Value: Sendable>(
      _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
      make { OrbitValueObservation.tracking(recordingFetch(fetch, hooks: $0)) }
    }

    public static func trackingConstantRegion<Value: Sendable>(
      _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
      make { OrbitValueObservation.trackingConstantRegion(recordingFetch(fetch, hooks: $0)) }
    }

    /// Observes changes in the given regions, which are resolved when observation starts.
    public static func tracking<Value: Sendable>(
      region: any DatabaseRegionConvertible,
      _ otherRegions: any DatabaseRegionConvertible...,
      fetch: @escaping @Sendable (Database) throws -> Value
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
      tracking(regions: [region] + otherRegions, fetch: fetch)
    }

    /// Observes changes in the given regions, which are resolved when observation starts.
    public static func tracking<Value: Sendable>(
      regions: [any DatabaseRegionConvertible],
      fetch: @escaping @Sendable (Database) throws -> Value
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
      constantRegions(regions, fetch: fetch)
    }

    public static func trackingConstantRegion<Value: Sendable>(
      _ regions: any DatabaseRegionConvertible...,
      fetch: @escaping @Sendable (Database) throws -> Value
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
      constantRegions(regions, fetch: fetch)
    }

    private static func constantRegions<Value: Sendable>(
      _ regions: [any DatabaseRegionConvertible],
      fetch: @escaping @Sendable (Database) throws -> Value
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
      make { hooks in
        OrbitValueObservation.tracking(
          region: { transaction in
            try transaction.withScopedAccess { access in
              let db = Database(access)
              let region = try regions.reduce(DatabaseRegion()) {
                try $0.union($1.databaseRegion(db))
              }
              hooks.didTrack(region)
              return region.native
            }
          },
          { transaction in
            try translate { try transaction.withScopedAccess { try fetch(Database($0)) } }
          }
        )
      }
    }

    @preconcurrency @MainActor
    public func start(
      in reader: any DatabaseReader,
      scheduling scheduler: some ValueObservationMainActorScheduler = .mainActor,
      onError: @escaping @MainActor @Sendable (Error) -> Void,
      onChange: @escaping @MainActor @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable {
      startSubscription(
        in: reader,
        scheduling: scheduler,
        isolation: MainActor.shared,
        onError: { error in MainActor.assumeIsolated { onError(error) } },
        onChange: { value in MainActor.assumeIsolated { onChange(value) } }
      )
    }

    public func start(
      in reader: any DatabaseReader,
      scheduling scheduler: some ValueObservationScheduler,
      onError: @escaping @Sendable (Error) -> Void,
      onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable {
      startSubscription(
        in: reader,
        scheduling: scheduler,
        isolation: nil,
        onError: onError,
        onChange: onChange
      )
    }

    private func startSubscription(
      in reader: any DatabaseReader,
      scheduling scheduler: some ValueObservationScheduler,
      isolation: isolated (any Actor)?,
      onError: @escaping @Sendable (Error) -> Void,
      onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable {
      do {
        return AnyDatabaseCancellable(
          try native.subscribe(
            to: reader.orbitDatabase,
            scheduling: scheduler,
            isolation: isolation,
            onError: { error in
              onError((error as? SQLiteError).map { DatabaseError($0) } ?? error)
            },
            onChange: { onChange($0.value) }
          )
        )
      } catch {
        scheduler.schedule(from: isolation) { onError(error) }
        return AnyDatabaseCancellable(cancel: {})
      }
    }

    /// An asynchronous sequence of the observed values.
    ///
    /// With the default `.task` scheduler and buffering policy, subscriptions share SQLiteOrbit's
    /// observation runtime and its buffers; otherwise values are delivered through the
    /// scheduler into an `AsyncThrowingStream` with the given buffering policy.
    public func values(
      in reader: any DatabaseReader,
      scheduling scheduler: some ValueObservationScheduler = .task,
      bufferingPolicy: AsyncValueObservation<Reducer.Value>.BufferingPolicy = .unbounded
    ) -> AsyncValueObservation<Reducer.Value> {
      if scheduler is TaskValueObservationScheduler, case .unbounded = bufferingPolicy {
        return AsyncValueObservation(native: native, database: reader.orbitDatabase)
      }
      return AsyncValueObservation(bufferingPolicy: bufferingPolicy) { onError, onChange in
        self.start(in: reader, scheduling: scheduler, onError: onError, onChange: onChange)
      }
    }

    /// Returns an observation shared by all its subscribers, which fetch once for all.
    public func shared(
      in reader: any DatabaseReader,
      scheduling scheduler: some ValueObservationScheduler = .async(onQueue: .main),
      extent: SharedValueObservationExtent = .whileObserved
    ) -> SharedValueObservation<Reducer.Value> {
      SharedValueObservation(scheduler: scheduler, extent: extent) { onError, onChange in
        self.start(in: reader, scheduling: scheduler, onError: onError, onChange: onChange)
      }
    }

    public func map<T: Sendable>(_ transform: @escaping @Sendable (Reducer.Value) throws -> T)
      -> ValueObservation<ValueReducers.Map<Reducer, T>>
    {
      derived(native.map(transform))
    }

    public func removeDuplicates(
      by predicate: @escaping @Sendable (Reducer.Value, Reducer.Value) -> Bool
    ) -> ValueObservation<ValueReducers.RemoveDuplicates<Reducer>> {
      derived(native.removeDuplicates(by: predicate))
    }

    /// Logs observation events to a stream, or to the standard output.
    public func print(
      _ prefix: String = "",
      to stream: (any TextOutputStream)? = nil
    ) -> ValueObservation<ValueReducers.Trace<Reducer>> {
      let output = LockedOutputStream(stream)
      let prefix = prefix.isEmpty ? "" : "\(prefix): "
      return handleEvents(
        willStart: { output.write("\(prefix)start") },
        willFetch: { output.write("\(prefix)fetch") },
        willTrackRegion: { output.write("\(prefix)tracked region: \($0)") },
        databaseDidChange: { output.write("\(prefix)database did change") },
        didReceiveValue: { output.write("\(prefix)value: \($0)") },
        didFail: { output.write("\(prefix)failure: \($0)") },
        didCancel: { output.write("\(prefix)cancel") }
      )
    }

    /// Performs side effects on observation events.
    ///
    /// `willTrackRegion` reports the region read by fetches performed through the compatibility
    /// `Database`, or the explicit regions of `tracking(regions:fetch:)`, when it changes.
    public func handleEvents(
      willStart: (@Sendable () -> Void)? = nil,
      willFetch: (@Sendable () -> Void)? = nil,
      willTrackRegion: (@Sendable (DatabaseRegion) -> Void)? = nil,
      databaseDidChange: (@Sendable () -> Void)? = nil,
      didReceiveValue: (@Sendable (Reducer.Value) -> Void)? = nil,
      didFail: (@Sendable (Error) -> Void)? = nil,
      didCancel: (@Sendable () -> Void)? = nil
    ) -> ValueObservation<ValueReducers.Trace<Reducer>> {
      if let willTrackRegion {
        hooks.add(willTrackRegion)
      }
      return derived(
        native.handleEvents(
          willStart: willStart,
          willFetch: willFetch,
          databaseDidChange: databaseDidChange,
          didReceiveValue: didReceiveValue,
          didFail: { didFail?(($0 as? SQLiteError).map { DatabaseError($0) } ?? $0) },
          didCancel: didCancel
        )
      )
    }
  }

  // Region tracking callbacks of an observation definition and its derived observations.
  final class ObservationHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var trackRegion: [@Sendable (DatabaseRegion) -> Void] = []
    private var lastRegion: DatabaseRegion?

    func add(_ callback: @escaping @Sendable (DatabaseRegion) -> Void) {
      lock.withLock { trackRegion.append(callback) }
    }

    func reset() {
      lock.withLock { lastRegion = nil }
    }

    func didTrack(_ region: DatabaseRegion) {
      let callbacks: [@Sendable (DatabaseRegion) -> Void] = lock.withLock {
        guard region != lastRegion else { return [] }
        lastRegion = region
        return trackRegion
      }
      for callback in callbacks { callback(region) }
    }
  }

  private final class LockedOutputStream: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: (any TextOutputStream)?

    init(_ stream: (any TextOutputStream)?) {
      self.stream = stream
    }

    func write(_ string: String) {
      lock.withLock {
        if stream != nil {
          stream!.write(string)
        } else {
          Swift.print(string)
        }
      }
    }
  }

  /// An asynchronous sequence of observed values.
  public struct AsyncValueObservation<Element: Sendable>: AsyncSequence, Sendable {
    public typealias BufferingPolicy = AsyncThrowingStream<Element, Error>.Continuation
      .BufferingPolicy
    public typealias AsyncIterator = Iterator

    nonisolated(unsafe) let bufferingPolicy: BufferingPolicy
    let start:
      @Sendable (
        @escaping @Sendable (Error) -> Void, @escaping @Sendable (Element) -> Void
      ) -> AnyDatabaseCancellable
    private let native: (OrbitValueObservation<Element>, any OrbitObservableDatabase)?

    // Iterates SQLiteOrbit's shared observation sequence directly.
    init(native: OrbitValueObservation<Element>, database: any OrbitObservableDatabase) {
      bufferingPolicy = .unbounded
      start = { _, _ in AnyDatabaseCancellable(cancel: {}) }
      self.native = (native, database)
    }

    init(
      bufferingPolicy: BufferingPolicy,
      start:
        @escaping @Sendable (
          @escaping @Sendable (Error) -> Void, @escaping @Sendable (Element) -> Void
        ) -> AnyDatabaseCancellable
    ) {
      self.bufferingPolicy = bufferingPolicy
      self.start = start
      native = nil
    }

    public func makeAsyncIterator() -> Iterator {
      if let (observation, database) = native {
        return Iterator(native: observation.values(in: database).makeAsyncIterator())
      }
      var cancellable: AnyDatabaseCancellable?
      let stream = AsyncThrowingStream(Element.self, bufferingPolicy: bufferingPolicy) {
        continuation in
        let started = start(
          { continuation.finish(throwing: $0) },
          { continuation.yield($0) }
        )
        cancellable = started
        continuation.onTermination = { @Sendable [weak started] _ in started?.cancel() }
      }
      return Iterator(iterator: stream.makeAsyncIterator(), cancellable: cancellable!)
    }

    /// The iterator, which cancels the observation when released.
    public struct Iterator: AsyncIteratorProtocol {
      private var iterator: AsyncThrowingStream<Element, Error>.AsyncIterator?
      private var nativeIterator: OrbitValueObservationSequence<Element>.AsyncIterator?
      private let cancellable: AnyDatabaseCancellable?
      private var finished = false

      init(
        iterator: AsyncThrowingStream<Element, Error>.AsyncIterator,
        cancellable: AnyDatabaseCancellable
      ) {
        self.iterator = iterator
        self.cancellable = cancellable
      }

      init(native: OrbitValueObservationSequence<Element>.AsyncIterator) {
        nativeIterator = native
        cancellable = nil
      }

      public mutating func next() async throws -> Element? {
        if iterator != nil {
          return try await iterator!.next()
        }
        guard !finished else { return nil }
        do {
          let value = try await nativeIterator!.next()
          if value == nil { finished = true }
          return value
        } catch {
          finished = true
          throw (error as? SQLiteError).map { DatabaseError($0) } ?? error
        }
      }
    }
  }

  /// The overlay's former name of `AsyncValueObservation`.
  public typealias DatabaseValueObservationValues<Element: Sendable> =
    AsyncValueObservation<Element>

  /// How long a shared observation keeps observing.
  public enum SharedValueObservationExtent: Sendable {
    /// Until the shared observation is deinitialized.
    case observationLifetime
    /// While it has subscribers.
    case whileObserved
  }

  /// An observation whose subscribers share fetches and values.
  public final class SharedValueObservation<Element: Sendable>: @unchecked Sendable {
    private final class Client: Sendable {
      let onError: @Sendable (Error) -> Void
      let onChange: @Sendable (Element) -> Void

      init(
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Element) -> Void
      ) {
        self.onError = onError
        self.onChange = onChange
      }
    }

    private let scheduler: any ValueObservationScheduler
    private let extent: SharedValueObservationExtent
    private let startObservation:
      (@escaping @Sendable (Error) -> Void, @escaping @Sendable (Element) -> Void) ->
        AnyDatabaseCancellable
    // A recursive lock supports subscriptions started from synchronous notifications.
    private let lock = NSRecursiveLock()
    private var clients: [Client] = []
    private var isObserving = false
    private var cancellable: AnyDatabaseCancellable?
    private var lastResult: Result<Element, Error>?

    init(
      scheduler: some ValueObservationScheduler,
      extent: SharedValueObservationExtent,
      start:
        @escaping (
          @escaping @Sendable (Error) -> Void, @escaping @Sendable (Element) -> Void
        ) -> AnyDatabaseCancellable
    ) {
      self.scheduler = scheduler
      self.extent = extent
      startObservation = start
    }

    /// Starts observing; late subscribers first receive the latest value.
    public func start(
      onError: @escaping @Sendable (Error) -> Void,
      onChange: @escaping @Sendable (Element) -> Void
    ) -> AnyDatabaseCancellable {
      lock.withLock {
        let client = Client(onError: onError, onChange: onChange)
        clients.append(client)
        if !isObserving {
          isObserving = true
          cancellable = startObservation(
            { [weak self] in self?.handleError($0) },
            { [weak self] in self?.handleChange($0) }
          )
        } else if let result = lastResult {
          let deliver: @Sendable () -> Void = {
            switch result {
            case .success(let value): onChange(value)
            case .failure(let error): onError(error)
            }
          }
          if scheduler.immediateInitialValue() {
            deliver()
          } else {
            scheduler.schedule(deliver)
          }
        }
        return AnyDatabaseCancellable(cancel: { self.handleCancel(client) })
      }
    }

    /// An asynchronous sequence of the shared values.
    public func values(
      bufferingPolicy: AsyncValueObservation<Element>.BufferingPolicy = .unbounded
    ) -> AsyncValueObservation<Element> {
      AsyncValueObservation(bufferingPolicy: bufferingPolicy) { onError, onChange in
        self.start(onError: onError, onChange: onChange)
      }
    }

    private func stopIfNeeded() {
      if extent == .whileObserved {
        isObserving = false
        cancellable = nil
        lastResult = nil
      }
    }

    private func handleError(_ error: Error) {
      lock.withLock {
        let notified = clients
        clients = []
        if extent == .whileObserved {
          stopIfNeeded()
        } else {
          lastResult = .failure(error)
        }
        for client in notified { client.onError(error) }
      }
    }

    private func handleChange(_ value: Element) {
      lock.withLock {
        lastResult = .success(value)
        for client in clients { client.onChange(value) }
      }
    }

    private func handleCancel(_ client: Client) {
      lock.withLock {
        clients.removeAll { $0 === client }
        if clients.isEmpty { stopIfNeeded() }
      }
    }
  }

  extension ValueObservation where Reducer.Value: Equatable {
    public func removeDuplicates() -> ValueObservation<ValueReducers.RemoveDuplicates<Reducer>> {
      removeDuplicates(by: ==)
    }
  }

#endif
