import SQLiteCross
import Synchronization
import Testing

@Test
func sqliteCrossSubscriptionCancelsAtMostOnceAcrossCopies() {
  let cancellationCount = Mutex(0)
  let subscription = SQLiteCrossSubscription {
    cancellationCount.withLock { $0 += 1 }
  }
  let copy = subscription

  subscription.cancel()
  copy.cancel()

  #expect(cancellationCount.withLock { $0 } == 1)
}

@Test
func sqliteCrossSubscriptionCancelsWhenItsStorageIsReleased() {
  let cancellationCount = Mutex(0)

  do {
    _ = SQLiteCrossSubscription {
      cancellationCount.withLock { $0 += 1 }
    }
  }

  #expect(cancellationCount.withLock { $0 } == 1)
}
