#if canImport(SwiftUI)
  import SwiftUI
#endif

@propertyWrapper
struct OrbitFetchState<Value: Sendable>: Sendable {
  #if canImport(SwiftUI)
    private let declared: OrbitFetchStorage<Value>
    @State private var storage: OrbitFetchStorage<Value>
    @State private var generation = 0
    @Environment(\.orbitDatabase) private var environmentDatabase
    private var defaultDatabase = OrbitDefaultDatabaseSource()

    var wrappedValue: OrbitFetchStorage<Value> { storage }
  #else
    let wrappedValue: OrbitFetchStorage<Value>
  #endif

  init(wrappedValue: OrbitFetchStorage<Value>) {
    #if canImport(SwiftUI)
      declared = wrappedValue
      _storage = State(wrappedValue: wrappedValue)
    #else
      self.wrappedValue = wrappedValue
    #endif
  }
}

#if canImport(SwiftUI)
  extension OrbitFetchState: DynamicProperty {
    func reconcile() {
      storage.update(
        declared: declared,
        database: environmentDatabase ?? defaultDatabase.currentIfConfigured,
        generation: _generation
      )
    }
  }
#endif
