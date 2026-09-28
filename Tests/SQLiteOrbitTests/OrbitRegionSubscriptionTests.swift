import Testing

@testable import SQLiteOrbit

@Suite
struct OrbitRegionSubscriptionTests {
  private struct UpdateFailure: Error {}

  private let items = OrbitDatabaseRegion(table: "items")
  private let lists = OrbitDatabaseRegion(table: "lists")

  @Test
  func updateRecordsOnlyRegionsItApplied() throws {
    let applied = Lock([OrbitDatabaseRegion]())
    let fails = Lock(false)
    let subscription = OrbitRegionSubscription(region: items) { region in
      if fails.withLock({ $0 }) { throw UpdateFailure() }
      applied.withLock { $0.append(region) }
    } onCancel: {
    }
    let unfiltered = OrbitRegionSubscription(region: .fullDatabase) {}

    try subscription.updateRegion(items)
    try subscription.updateRegion(lists)
    fails.withLock { $0 = true }
    #expect(throws: UpdateFailure.self) { try subscription.updateRegion(.fullDatabase) }
    try unfiltered.updateRegion(items)

    // Updating to the region it already has is not passed on.
    #expect(applied.withLock { $0 } == [lists])
    #expect(subscription.region == lists)
    #expect(subscription.filtersByRegion)
    #expect(unfiltered.region == items)
    #expect(!unfiltered.filtersByRegion)
  }

  @Test
  func cancelRunsOnceAndStopsUpdates() throws {
    let updateCount = Lock(0)
    let cancellationCount = Lock(0)
    let subscription = OrbitRegionSubscription(region: .empty) { _ in
      updateCount.withLock { $0 += 1 }
    } onCancel: {
      cancellationCount.withLock { $0 += 1 }
    }
    let copy = subscription

    subscription.cancel()
    copy.cancel()
    try copy.updateRegion(.fullDatabase)

    #expect(cancellationCount.withLock { $0 } == 1)
    #expect(updateCount.withLock { $0 } == 0)
    #expect(subscription.region == .empty)
  }

  @Test
  func releasingTheFinalCopyCancels() {
    let cancellationCount = Lock(0)

    do {
      let subscription = OrbitRegionSubscription(region: .fullDatabase) {
        cancellationCount.withLock { $0 += 1 }
      }
      let copy = subscription
      _ = copy
    }

    #expect(cancellationCount.withLock { $0 } == 1)
  }

  @Test
  func concurrentUpdatesLeaveTheLastAppliedRegionRecorded() async throws {
    let applied = Lock<OrbitDatabaseRegion?>(nil)
    let subscription = OrbitRegionSubscription(region: .empty) { region in
      applied.withLock { $0 = region }
    } onCancel: {
    }

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<100 {
        group.addTask {
          try? subscription.updateRegion(OrbitDatabaseRegion(table: "table\(index)"))
        }
      }
    }

    #expect(applied.withLock { $0 } == subscription.region)
  }

  @Test
  func fullDatabaseRegistrationAdmitsEvenEmptyCommits() {
    #expect(OrbitDatabaseRegion.fullDatabase.admits(.empty))
    #expect(OrbitDatabaseRegion.fullDatabase.admits(items))
    #expect(items.admits(OrbitDatabaseRegion(column: "title", in: "items")))
    #expect(!items.admits(.empty))
    #expect(!items.admits(lists))
  }

  @Test
  func advertisementNarrowsAtOnceButWidensOnlyOnceApplied() {
    var advertisement = OrbitValueObservationAdvertisement(region: .fullDatabase)
    let beforeNarrowing = advertisement.beginFetch()

    let narrowing = advertisement.beginUpdate(to: items)
    let narrowedRegion = advertisement.region
    advertisement.finishUpdate(to: items)
    let beforeWidening = advertisement.beginFetch()
    let widening = advertisement.beginUpdate(to: items.union(lists))
    let regionWhileWidening = advertisement.region
    advertisement.finishUpdate(to: items.union(lists))
    let repeated = advertisement.beginUpdate(to: items.union(lists))

    #expect(narrowing == items)
    #expect(narrowedRegion == items)
    #expect(advertisement.endFetch(beforeNarrowing) == items)
    #expect(widening == items.union(lists))
    #expect(regionWhileWidening == items)
    #expect(advertisement.endFetch(beforeWidening) == items)
    #expect(advertisement.region == items.union(lists))
    #expect(repeated == nil)
  }
}
