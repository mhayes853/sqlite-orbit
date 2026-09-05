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

      #expect(transactionScheduler.immediateInitialValue(from: MainActor.shared))
      #expect(animationScheduler.immediateInitialValue(from: MainActor.shared))
    }
  }
#endif
