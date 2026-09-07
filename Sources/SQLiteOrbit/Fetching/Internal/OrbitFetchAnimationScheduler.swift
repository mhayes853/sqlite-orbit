#if canImport(SwiftUI)
  import SwiftUI

  /// Delivers a fetch property's values on the main actor, inside an animation.
  ///
  /// This is what the `animation:` argument of a fetch property selects. Unlike
  /// ``OrbitImmediateValueObservationScheduler``, it never asks for a blocking initial read: its
  /// values can only be delivered on the main actor, so reading the property cannot produce one
  /// synchronously anyway, and blocking the thread that is about to render for a value it will not
  /// see helps nobody.
  struct OrbitFetchAnimationScheduler: OrbitValueObservationMainActorScheduler {
    // `Animation` predates the concurrency annotations this package builds under, and one is only
    // ever read on the main actor.
    private struct AnimationBox: @unchecked Sendable {
      let value: Animation?
    }

    private let animation: AnimationBox
    private let base = OrbitMainActorValueObservationScheduler.mainActor

    init(animation: Animation?) {
      self.animation = AnimationBox(value: animation)
    }

    func immediateInitialValue(from isolation: isolated (any Actor)?) -> Bool {
      false
    }

    func schedule(
      from isolation: isolated (any Actor)?,
      _ action: @escaping @Sendable () -> Void
    ) {
      let animation = self.animation
      base.schedule(from: isolation) {
        MainActor.assumeIsolated {
          withAnimation(animation.value) {
            action()
          }
        }
      }
    }
  }
#endif
