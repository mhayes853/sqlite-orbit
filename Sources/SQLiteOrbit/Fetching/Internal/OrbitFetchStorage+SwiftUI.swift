#if canImport(SwiftUI)
  import SwiftUI

  extension OrbitFetchStorage {
    /// Redraws a SwiftUI view whose platform has no Observation framework to do it.
    ///
    /// Where Observation exists, reading the value from a view body is enough, and this does
    /// nothing.
    ///
    /// - Parameter generation: A counter stored in the view, bumped once per change.
    func observeForSwiftUI(generation: SwiftUI.State<Int>) {
      guard #unavailable(iOS 17, macOS 14, tvOS 17, watchOS 10) else { return }
      // Reading the state is what enrolls the view in its changes.
      _ = generation.wrappedValue
      let generation = OrbitFetchUncheckedBox(generation)
      setSwiftUIObservation(
        addObserver {
          Task { @MainActor in generation.value.wrappedValue &+= 1 }
        }
      )
    }
  }

  /// Carries a SwiftUI value that predates the concurrency annotations this package builds under
  /// to the main actor, where it is read.
  struct OrbitFetchUncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
      self.value = value
    }
  }
#endif
