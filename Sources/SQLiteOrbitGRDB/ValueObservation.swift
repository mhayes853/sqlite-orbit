#if canImport(Foundation) && canImport(Dispatch)
  import Dispatch
  import Foundation
  @_spi(GRDB) import SQLiteOrbit

  public protocol DatabaseCancellable: Sendable { func cancel() }
  public final class AnyDatabaseCancellable: DatabaseCancellable {
    private let subscription: OrbitSubscription
    public init(_ cancel: @escaping @Sendable () -> Void) {
      subscription = OrbitSubscription(onCancel: cancel)
    }
    init(_ subscription: OrbitSubscription) { self.subscription = subscription }
    public func cancel() { subscription.cancel() }
  }

  public protocol ValueReducer: Sendable { associatedtype Value: Sendable }
  public enum ValueReducers {
    public struct Fetch<Value: Sendable>: ValueReducer {}
    public struct Map<Base: ValueReducer, Value: Sendable>: ValueReducer {}
    public struct RemoveDuplicates<Base: ValueReducer>: ValueReducer {
      public typealias Value = Base.Value
    }
    public struct Trace<Base: ValueReducer>: ValueReducer { public typealias Value = Base.Value }
  }

  public protocol ValueObservationScheduler: OrbitValueObservationScheduler {}
  public protocol ValueObservationMainActorScheduler: ValueObservationScheduler {}
  public struct AsyncValueObservationScheduler: ValueObservationScheduler {
    private let queue: DispatchQueue
    fileprivate init(queue: DispatchQueue) {
      self.queue = DispatchQueue(label: "sqlite-orbit-grdb.observation", target: queue)
    }
    public func immediateInitialValue(from isolation: isolated (any Actor)?) -> Bool { false }
    public func schedule(
      from isolation: isolated (any Actor)?,
      _ action: @escaping @Sendable () -> Void
    ) { queue.async(execute: action) }
  }
  public struct MainActorValueObservationScheduler: ValueObservationMainActorScheduler {
    private let immediate: Bool
    fileprivate init(immediate: Bool) { self.immediate = immediate }
    public func immediateInitialValue(from isolation: isolated (any Actor)?) -> Bool { immediate }
    public func schedule(
      from isolation: isolated (any Actor)?,
      _ action: @escaping @Sendable () -> Void
    ) {
      if immediate && (isolation === MainActor.shared || Thread.isMainThread) {
        action()
      } else {
        DispatchQueue.main.async(execute: action)
      }
    }
  }
  extension ValueObservationScheduler where Self == AsyncValueObservationScheduler {
    public static func async(onQueue queue: DispatchQueue) -> Self { Self(queue: queue) }
  }
  extension ValueObservationMainActorScheduler where Self == MainActorValueObservationScheduler {
    public static var immediate: Self { Self(immediate: true) }
    public static var mainActor: Self { Self(immediate: false) }
  }

  public struct DatabaseRegion: Hashable, Sendable, DatabaseRegionConvertible {
    let native: OrbitDatabaseRegion
    public init() { native = .empty }
    init(_ native: OrbitDatabaseRegion) { self.native = native }
    public init(table: String, columns: [String]? = nil) {
      native =
        columns.map { OrbitDatabaseRegion(columns: $0, in: table) }
        ?? OrbitDatabaseRegion(table: table)
    }
    public static let fullDatabase = Self(.fullDatabase)
    public var isEmpty: Bool { native.isEmpty }
    public func databaseRegion(_ db: Database) throws -> Self { self }
    public func union(_ other: Self) -> Self { Self(native.union(other.native)) }
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
      let sql = try sql(in: db)
      return try SQLRequest<Row>(literal: sql).databaseRegion(db)
    }
  }

  public struct ValueObservation<Reducer: ValueReducer>: Sendable {
    let native: OrbitValueObservation<Reducer.Value>
    init(_ native: OrbitValueObservation<Reducer.Value>) { self.native = native }
    public static func tracking<Value: Sendable>(
      _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
      Self(
        OrbitValueObservation.tracking { transaction in
          try translate { try transaction.withGRDBAccess { try fetch(Database($0)) } }
        }
      )
    }
    public static func trackingConstantRegion<Value: Sendable>(
      _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
      Self(
        OrbitValueObservation.trackingConstantRegion { transaction in
          try translate { try transaction.withGRDBAccess { try fetch(Database($0)) } }
        }
      )
    }
    public static func trackingConstantRegion<Value: Sendable>(
      _ regions: any DatabaseRegionConvertible...,
      fetch: @escaping @Sendable (Database) throws -> Value
    ) -> Self where Reducer == ValueReducers.Fetch<Value> {
      Self(
        OrbitValueObservation.trackingConstantRegion(
          region: { transaction in
            try transaction.withGRDBAccess { access in
              let db = Database(access)
              return try regions.reduce(DatabaseRegion()) { try $0.union($1.databaseRegion(db)) }
                .native
            }
          },
          { transaction in
            try translate { try transaction.withGRDBAccess { try fetch(Database($0)) } }
          }
        )
      )
    }

    @MainActor
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
          try native.independent()
            .subscribe(
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
        return AnyDatabaseCancellable({})
      }
    }
    public func values(in reader: any DatabaseReader) -> DatabaseValueObservationValues<
      Reducer.Value
    > {
      DatabaseValueObservationValues(observation: native, database: reader.orbitDatabase)
    }
    public func map<T: Sendable>(_ transform: @escaping @Sendable (Reducer.Value) throws -> T)
      -> ValueObservation<ValueReducers.Map<Reducer, T>>
    {
      .init(native.map(transform))
    }
    public func removeDuplicates(
      by predicate: @escaping @Sendable (Reducer.Value, Reducer.Value) -> Bool
    ) -> ValueObservation<ValueReducers.RemoveDuplicates<Reducer>> {
      .init(native.removeDuplicates(by: predicate))
    }
    public func handleEvents(
      willStart: (@Sendable () -> Void)? = nil,
      willFetch: (@Sendable () -> Void)? = nil,
      databaseDidChange: (@Sendable () -> Void)? = nil,
      didReceiveValue: (@Sendable (Reducer.Value) -> Void)? = nil,
      didFail: (@Sendable (Error) -> Void)? = nil,
      didCancel: (@Sendable () -> Void)? = nil
    ) -> ValueObservation<ValueReducers.Trace<Reducer>> {
      .init(
        native.handleEvents(
          willStart: willStart,
          willFetch: willFetch,
          databaseDidChange: databaseDidChange,
          didReceiveValue: didReceiveValue,
          didFail: didFail,
          didCancel: didCancel
        )
      )
    }
  }
  extension ValueObservation where Reducer.Value: Equatable {
    public func removeDuplicates() -> ValueObservation<ValueReducers.RemoveDuplicates<Reducer>> {
      removeDuplicates(by: ==)
    }
  }

  public struct DatabaseValueObservationValues<Element: Sendable>: AsyncSequence, Sendable {
    let observation: OrbitValueObservation<Element>
    let database: any OrbitObservableDatabase
    public struct AsyncIterator: AsyncIteratorProtocol {
      fileprivate var iterator: OrbitValueObservationSequence<Element>.AsyncIterator
      private var finished = false
      fileprivate init(iterator: OrbitValueObservationSequence<Element>.AsyncIterator) {
        self.iterator = iterator
      }
      public mutating func next() async throws -> Element? {
        guard !finished else { return nil }
        do {
          let value = try await iterator.next()
          if value == nil { finished = true }
          return value
        } catch {
          finished = true
          if let error = error as? SQLiteError { throw DatabaseError(error) }
          throw error
        }
      }
    }
    public func makeAsyncIterator() -> AsyncIterator {
      AsyncIterator(iterator: observation.independent().values(in: database).makeAsyncIterator())
    }
  }

#endif
