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
      // `State` is not `Sendable`, and the observer that bumps it can be called from anywhere.
      // Bumping it on the main actor is what makes carrying it there safe, which is a fact about
      // this one closure rather than about `State`.
      nonisolated(unsafe) let generation = generation
      setSwiftUIObservation(
        addObserver {
          Task { @MainActor in generation.wrappedValue &+= 1 }
        }
      )
    }
  }
#endif
