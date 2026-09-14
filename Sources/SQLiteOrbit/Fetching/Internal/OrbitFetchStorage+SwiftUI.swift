#if canImport(SwiftUI)
  import SwiftUI

  extension OrbitFetchStorage {
    /// Reconciles the storage a SwiftUI view kept with the property it was rebuilt with.
    ///
    /// Every fetch property's `DynamicProperty.update()` is this, because a property wrapper only
    /// differs from its neighbours in what it projects, never in how SwiftUI keeps it alive.
    ///
    /// - Parameters:
    ///   - declared: The storage of the property SwiftUI built for this render.
    ///   - generation: A counter stored in the view, bumped once per change.
    func update(declared: OrbitFetchStorage<Value>, generation: SwiftUI.State<Int>) {
      if self !== declared {
        adoptIfNeeded(from: declared)
      }
      observeForSwiftUI(generation: generation)
    }

    /// Redraws a SwiftUI view whose platform has no Observation framework to do it.
    ///
    /// Where Observation exists, reading the value from a view body is enough, and this does
    /// nothing.
    ///
    /// - Parameter generation: A counter stored in the view, bumped once per change.
    private func observeForSwiftUI(generation: SwiftUI.State<Int>) {
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
