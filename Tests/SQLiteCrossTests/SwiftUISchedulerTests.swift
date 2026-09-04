#if canImport(SwiftUI)
  import SwiftUI
  import Testing

  @testable import SQLiteCross

  @Suite
  struct SwiftUISchedulerTests {
    @MainActor
    @Test
    func transactionAndAnimationPreserveMainActorScheduling() {
      let transactionScheduler = MainActorValueObservationScheduler.mainActor.transaction(
        Transaction(animation: nil)
      )
      let animationScheduler = MainActorValueObservationScheduler.mainActor.animation(.default)

      #expect(transactionScheduler.immediateInitialValue(from: MainActor.shared))
      #expect(animationScheduler.immediateInitialValue(from: MainActor.shared))
    }
  }
#endif
