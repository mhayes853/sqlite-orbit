import Synchronization
import Testing

@testable import SQLiteOrbit

private struct FetchFailure: Error {}

@Suite
struct ValueObservationReadCoordinatorTests {
  @Test
  func theObservationStartsOnce() {
    var coordinator = ValueObservationReadCoordinator()
    let first = coordinator.takeDidStart()
    let second = coordinator.takeDidStart()
    #expect(first)
    #expect(!second)
  }

  @Test
  func theInitialReadIsIssuedOnce() throws {
    var coordinator = ValueObservationReadCoordinator()
    let issued = coordinator.requireInitialRead()
    let initial = try #require(issued)
    let repeated = coordinator.requireInitialRead()
    #expect(initial.source == .initial)
    #expect(repeated == nil)
  }

  @Test
  func noInitialReadIsIssuedOnceOneHasResolved() {
    var coordinator = ValueObservationReadCoordinator()
    coordinator.completeInitialFetch()
    let request = coordinator.requireInitialRead()
    #expect(request == nil)
  }

  @Test
  func aReadThatRacedNoInvalidationIsCurrentAndFinishesTheWork() throws {
    var coordinator = ValueObservationReadCoordinator()
    let issued = coordinator.requireInitialRead()
    let initial = try #require(issued)
    let isCurrent = coordinator.completeRead(initial)
    let followUp = coordinator.takeRequestIfPossible()
    #expect(isCurrent)
    #expect(followUp == nil)
  }

  @Test
  func aBurstOfInvalidationsCoalescesIntoOneFollowUpRead() throws {
    var coordinator = ValueObservationReadCoordinator()
    let issued = coordinator.requireInitialRead()
    let initial = try #require(issued)

    // Nothing is issued while a read is in flight, however many commits land.
    let duringLocal = coordinator.requireRead(source: .transaction(.local))
    let duringExternal = coordinator.requireRead(source: .transaction(.external))
    let duringSecondExternal = coordinator.requireRead(source: .transaction(.external))
    #expect(duringLocal == nil)
    #expect(duringExternal == nil)
    #expect(duringSecondExternal == nil)

    // The read that was issued before them cannot describe them, so it is dropped and reissued.
    let isCurrent = coordinator.completeRead(initial)
    #expect(!isCurrent)
    let reissued = coordinator.takeRequestIfPossible()
    let followUp = try #require(reissued)
    #expect(followUp.source == .transaction(.external))
    let extra = coordinator.takeRequestIfPossible()
    #expect(extra == nil)
  }

  @Test
  func aLocalFetchSupersedesTheReadItRacedWith() throws {
    var coordinator = ValueObservationReadCoordinator()
    let issued = coordinator.requireInitialRead()
    let initial = try #require(issued)
    let pending = coordinator.requireRead(source: .transaction(.external))
    #expect(pending == nil)

    // A fetch performed inside a committing transaction already covers that external commit.
    coordinator.supersedePendingRead()

    let isCurrent = coordinator.completeRead(initial)
    let followUp = coordinator.takeRequestIfPossible()
    #expect(!isCurrent)
    #expect(followUp == nil)
  }

  @Test
  func discardingAnInFlightReadLeavesItsRequirementStanding() throws {
    var coordinator = ValueObservationReadCoordinator()
    let issued = coordinator.requireInitialRead()
    let initial = try #require(issued)
    let pending = coordinator.requireRead(source: .transaction(.external))
    #expect(pending == nil)

    // Unlike superseding, this only invalidates the read: the commit still needs covering.
    coordinator.discardInFlightRead()

    let isCurrent = coordinator.completeRead(initial)
    let followUp = coordinator.takeRequestIfPossible()
    #expect(!isCurrent)
    #expect(followUp != nil)
  }
}

@Suite
struct ValueObservationSubscriberRegistryTests {
  private func subscriber(
    onChange: @escaping @Sendable (ValueObservationChange<Int>) -> Void = { _ in }
  ) -> ValueObservationSubscriber<Int> {
    ValueObservationSubscriber(
      scheduler: ImmediateValueObservationScheduler(),
      onError: { _ in },
      onChange: onChange
    )
  }

  @Test
  func aSubscriberRegisteringDuringAPublicationIsCaughtUpExactlyOnce() throws {
    var registry = ValueObservationSubscriberRegistry<Int>()
    let early = Mutex([Int]())
    let late = Mutex([Int]())

    let firstRegistration = registry.add(
      subscriber { change in early.withLock { $0.append(change.value) } }
    )
    guard case .success = firstRegistration else {
      Issue.record("the first subscriber was refused")
      return
    }

    let change = ValueObservationChange(value: 1, source: .initial)
    let owed = registry.publish(change)

    // A subscriber that arrives after the publication is captured but before it is delivered is
    // caught up through its registration instead, so it must not also be in `owed`.
    let lateSubscriber = subscriber { change in late.withLock { $0.append(change.value) } }
    let lateRegistration = registry.add(lateSubscriber)
    #expect(owed.count == 1)

    for subscriber in owed { subscriber.receive(.success(change), from: nil) }
    guard case .success(let place) = lateRegistration else {
      Issue.record("the late subscriber was refused")
      return
    }
    lateSubscriber.receive(.success(try #require(place.latest)), from: nil)

    #expect(early.withLock { $0 } == [1])
    #expect(late.withLock { $0 } == [1])
  }

  @Test
  func aSubscriberArrivingBeforeAnyValueIsOwedNothing() {
    var registry = ValueObservationSubscriberRegistry<Int>()
    let registration = registry.add(subscriber())
    guard case .success(let place) = registration else {
      Issue.record("the subscriber was refused")
      return
    }
    #expect(place.latest == nil)
  }

  @Test
  func failingOwesTheCurrentSubscribersAndRefusesLaterOnes() {
    var registry = ValueObservationSubscriberRegistry<Int>()
    let registration = registry.add(subscriber())
    guard case .success = registration else {
      Issue.record("the first subscriber was refused")
      return
    }

    let owed = registry.fail(FetchFailure())
    #expect(owed.count == 1)

    let refused = registry.add(subscriber())
    guard case .failure(let error) = refused else {
      Issue.record("a subscriber was admitted after the observation failed")
      return
    }
    #expect(error is FetchFailure)

    // The failed subscribers were released, so a later publication owes nobody.
    let stillOwed = registry.publish(ValueObservationChange(value: 1, source: .initial))
    #expect(stillOwed.isEmpty)
  }

  @Test
  func removalReportsOnlyTheDepartureThatEmptiesTheRegistry() {
    var registry = ValueObservationSubscriberRegistry<Int>()
    let firstRegistration = registry.add(subscriber())
    let secondRegistration = registry.add(subscriber())
    guard
      case .success(let first) = firstRegistration,
      case .success(let second) = secondRegistration
    else {
      Issue.record("a subscriber was refused")
      return
    }

    let afterFirst = registry.remove(first.identifier)
    let afterSecond = registry.remove(second.identifier)
    // A subscription cancelled twice is still one departure.
    let afterRepeat = registry.remove(second.identifier)
    #expect(!afterFirst)
    #expect(afterSecond)
    #expect(!afterRepeat)
  }
}

@Suite
struct ValueObservationDeliveryQueueTests {
  private func publication(_ value: Int) -> ValueObservationPublication<Int> {
    ValueObservationPublication(
      outcome: .success(ValueObservationChange(value: value, source: .initial)),
      subscribers: []
    )
  }

  private func value(of publication: ValueObservationPublication<Int>?) -> Int? {
    guard case .success(let change) = publication?.outcome else { return nil }
    return change.value
  }

  @Test
  func onlyTheCallerThatFindsTheQueueIdleDrainsIt() {
    var queue = ValueObservationDeliveryQueue<Int>()
    let first = queue.enqueue(publication(1))
    let second = queue.enqueue(publication(2))
    let third = queue.enqueue(publication(3))
    #expect(first)
    #expect(!second)
    #expect(!third)
  }

  @Test
  func theQueueIsDrainedInTheOrderItWasFilled() {
    var queue = ValueObservationDeliveryQueue<Int>()
    _ = queue.enqueue(publication(1))
    _ = queue.enqueue(publication(2))

    let first = value(of: queue.next())
    let second = value(of: queue.next())
    let exhausted = queue.next()
    #expect(first == 1)
    #expect(second == 2)
    #expect(exhausted == nil)
  }

  @Test
  func theNextCallerAfterADrainEndsTakesOverDelivering() {
    var queue = ValueObservationDeliveryQueue<Int>()
    _ = queue.enqueue(publication(1))
    let delivered = value(of: queue.next())
    let exhausted = queue.next()
    let resumed = queue.enqueue(publication(2))
    #expect(delivered == 1)
    #expect(exhausted == nil)
    #expect(resumed)
  }
}
