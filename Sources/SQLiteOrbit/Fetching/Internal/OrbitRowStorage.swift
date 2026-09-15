/// The observed value and write state shared by every copy of a mutable row property.
///
/// Fetching remains in `OrbitFetchStorage`, so mutable rows have exactly the same lazy observation,
/// request identity, database resolution, and SwiftUI reconciliation as the read-only properties.
/// This layer adds only state belonging to writes.
final class OrbitRowStorage<Value: Sendable>: Sendable {
  private struct WriteState {
    var savesInFlight = 0
    var saveError: (any Error)?
    var observers = IdentifiedRegistry<@Sendable () -> Void>()
    var swiftUIObservation: OrbitSubscription?
  }

  let fetch: OrbitFetchStorage<Value>

  private let writes = Lock(WriteState())
  private let registrar = OrbitFetchObservationRegistrar()

  init(fetch: OrbitFetchStorage<Value>) {
    self.fetch = fetch
  }

  deinit {
    let observation = writes.withLock { state -> OrbitSubscription? in
      defer { state.swiftUIObservation = nil }
      return state.swiftUIObservation
    }
    observation?.cancel()
  }

  var value: Value { fetch.value }
  var reader: OrbitFetchReader<Value> { OrbitFetchReader(fetch) }
  var isLoading: Bool { fetch.isLoading }
  var loadError: (any Error)? { fetch.loadError }

  var isSaving: Bool {
    registrar.access()
    return writes.withLock { $0.savesInFlight != 0 }
  }

  var saveError: (any Error)? {
    registrar.access()
    return writes.withLock { $0.saveError }
  }

  func load() async throws {
    try await fetch.load()
  }

  /// Runs one write against the same database the fetch side resolved.
  func write<Result: Sendable>(
    _ operation:
      sending @escaping @Sendable (
        any OrbitObservableDatabase
      ) async throws -> sending Result
  ) async throws -> Result {
    guard let database = fetch.databaseForWriting() else {
      let error = OrbitMissingDefaultDatabaseError()
      finishWrite(.failure(error), didStart: false)
      throw error
    }

    beginWrite()
    do {
      let result = try await operation(database)
      finishWrite(.success(()), didStart: true)
      return result
    } catch {
      finishWrite(.failure(error), didStart: true)
      throw error
    }
  }

  /// Runs one blocking write against the same database the fetch side resolved.
  ///
  /// This exists for synchronous interfaces such as a SwiftUI `Binding` setter. Callers must obey
  /// ``OrbitDatabaseWriter/writeBlocking(_:)``'s requirement not to invoke it from a task.
  func writeBlocking<Result: Sendable>(
    _ operation: (any OrbitObservableDatabase) throws -> Result
  ) throws -> Result {
    guard let database = fetch.databaseForWriting() else {
      let error = OrbitMissingDefaultDatabaseError()
      finishWrite(.failure(error), didStart: false)
      throw error
    }

    beginWrite()
    do {
      let result = try operation(database)
      finishWrite(.success(()), didStart: true)
      return result
    } catch {
      finishWrite(.failure(error), didStart: true)
      throw error
    }
  }

  private func beginWrite() {
    registrar.withMutation {
      writes.withLock {
        $0.savesInFlight += 1
        $0.saveError = nil
      }
    }
    notifyObservers()
  }

  private func finishWrite(_ result: Result<Void, any Error>, didStart: Bool) {
    registrar.withMutation {
      writes.withLock {
        if didStart { $0.savesInFlight -= 1 }
        if case .failure(let error) = result {
          $0.saveError = error
        }
      }
    }
    notifyObservers()
  }

  func addWriteObserver(_ handler: @escaping @Sendable () -> Void) -> OrbitSubscription {
    let identifier = writes.withLock { $0.observers.insert(handler) }
    return OrbitSubscription { [weak self] in
      _ = self?.writes.withLock { $0.observers.remove(identifier) }
    }
  }

  func setSwiftUIObservation(_ observation: OrbitSubscription?) {
    let previous = writes.withLock { state -> OrbitSubscription? in
      defer { state.swiftUIObservation = observation }
      return state.swiftUIObservation
    }
    previous?.cancel()
  }

  private func notifyObservers() {
    for observer in writes.withLock({ $0.observers.all }) {
      observer()
    }
  }
}
