#if canImport(SwiftUI)
  import SwiftUI
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SwiftUISchedulerTests {
    @MainActor
    @Test
    func transactionAndAnimationPreserveMainActorScheduling() {
      let transactionScheduler = OrbitMainActorValueObservationScheduler.mainActor.transaction(
        Transaction(animation: nil)
      )
      let animationScheduler = OrbitMainActorValueObservationScheduler.mainActor.animation(.default)

      // Read outside the macro: `#expect` takes the call apart into a closure, and the isolated
      // argument stops being the actor the caller is on.
      let transactionIsImmediate =
        transactionScheduler.immediateInitialValue(from: MainActor.shared)
      let animationIsImmediate =
        animationScheduler.immediateInitialValue(from: MainActor.shared)

      #expect(transactionIsImmediate)
      #expect(animationIsImmediate)
    }
  }
#endif
