import Synchronization
import Testing

@testable import SQLiteOrbit

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

@Suite
struct HandlerRegistryTests {
  @Test
  func identifiersAreNotReusedAndRemovalIsReportedOnce() {
    var registry = IdentifiedRegistry<Int>()
    let first = registry.insert(1)
    let second = registry.insert(2)
    let didRemove = registry.remove(first)
    let didRemoveAgain = registry.remove(first)
    let remaining = registry.removeAll()

    #expect(first != second)
    #expect(didRemove)
    #expect(!didRemoveAgain)
    #expect(remaining == [2])
    #expect(registry.isEmpty)
  }

  @Test
  func keyedRegistryReportsTheFirstAndLastHandlerOfEachKey() {
    var registry = KeyedHandlerRegistry<String, Int>()
    let first = registry.insert(1, for: "a")
    let second = registry.insert(2, for: "a")
    let other = registry.insert(3, for: "b")
    let handlers = registry.handlers(for: "a").sorted()
    let afterFirst = registry.remove(first.identifier, for: "a")
    let afterSecond = registry.remove(second.identifier, for: "a")
    let afterRepeat = registry.remove(second.identifier, for: "a")
    let stillRegistered = registry.contains("a")
    let remaining = registry.removeAll()

    #expect(first.isFirstForKey)
    #expect(!second.isFirstForKey)
    #expect(other.isFirstForKey)
    // Identifiers are unique across keys, so one key's removal cannot disturb another's.
    #expect(first.identifier != other.identifier)
    #expect(handlers == [1, 2])
    #expect(!afterFirst)
    #expect(afterSecond)
    // A removal that finds nothing never reports the key as newly emptied.
    #expect(!afterRepeat)
    #expect(!stillRegistered)
    #expect(remaining == ["b"])
  }
}
