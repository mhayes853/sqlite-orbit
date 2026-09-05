import SQLiteOrbit
import Synchronization
import Testing

@Test
func orbitSubscriptionCancelsAtMostOnceAcrossCopies() {
  let cancellationCount = Mutex(0)
  let subscription = OrbitSubscription {
    cancellationCount.withLock { $0 += 1 }
  }
  let copy = subscription

  subscription.cancel()
  copy.cancel()

  #expect(cancellationCount.withLock { $0 } == 1)
}

@Test
func orbitSubscriptionCancelsWhenItsStorageIsReleased() {
  let cancellationCount = Mutex(0)

  do {
    _ = OrbitSubscription {
      cancellationCount.withLock { $0 += 1 }
    }
  }

  #expect(cancellationCount.withLock { $0 } == 1)
}
