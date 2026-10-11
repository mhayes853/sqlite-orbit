#if StructuredQueries
  import StructuredQueriesSQLite

  #if canImport(SwiftUI)
    import struct SwiftUI.State
  #endif

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
          any OrbitObservableDatabaseWriter
        ) async throws -> sending Result
    ) async throws -> Result {
      beginWrite()
      do {
        let database = fetch.databaseForWriting()
        let result = try await operation(database)
        finishWrite()
        return result
      } catch {
        finishWrite(error: error)
        throw error
      }
    }

    /// Runs one blocking write against the same database the fetch side resolved.
    ///
    /// This exists for synchronous interfaces such as a SwiftUI `Binding` setter. Callers must obey
    /// ``OrbitDatabaseWriter/writeBlocking(_:)``'s requirement not to invoke it from a task.
    func writeBlocking<Result: Sendable>(
      _ operation: (any OrbitObservableDatabaseWriter) throws -> Result
    ) throws -> Result {
      beginWrite()
      do {
        let database = fetch.databaseForWriting()
        let result = try operation(database)
        finishWrite()
        return result
      } catch {
        finishWrite(error: error)
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

    private func finishWrite(error: (any Error)? = nil) {
      registrar.withMutation {
        writes.withLock {
          $0.savesInFlight -= 1
          if let error {
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

  #if canImport(SwiftUI)
    extension OrbitRowStorage {
      /// Reconciles the storage a SwiftUI view kept with the row property it was rebuilt with.
      ///
      /// This is the whole of `Row` and `SingleRow`'s `DynamicProperty.update()`, because the two
      /// differ only in the row they read and write, never in how SwiftUI keeps them alive.
      ///
      /// - Parameters:
      ///   - declared: The storage of the property SwiftUI built for this render.
      ///   - database: The database the environment offers this render, if it offers one.
      ///   - fetchGeneration: A counter stored in the view, bumped once per change to the row.
      ///   - writeGeneration: A counter stored in the view, bumped once per change to the saving
      ///     state.
      func update(
        declared: OrbitRowStorage<Value>,
        database: (any OrbitObservableDatabaseWriter)?,
        fetchGeneration: SwiftUI.State<Int>,
        writeGeneration: SwiftUI.State<Int>
      ) {
        fetch.update(declared: declared.fetch, database: database, generation: fetchGeneration)
        observeWritesForSwiftUI(generation: writeGeneration)
      }

      /// Redraws a SwiftUI view whose platform has no Observation framework to do it when the
      /// saving state changes.
      private func observeWritesForSwiftUI(generation: SwiftUI.State<Int>) {
        guard #unavailable(iOS 17, macOS 14, tvOS 17, watchOS 10) else { return }
        _ = generation.wrappedValue
        nonisolated(unsafe) let generation = generation
        setSwiftUIObservation(
          addWriteObserver {
            Task { @MainActor in generation.wrappedValue &+= 1 }
          }
        )
      }
    }
  #endif
#endif
