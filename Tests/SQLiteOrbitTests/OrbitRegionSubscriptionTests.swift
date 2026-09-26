import Testing

@testable import SQLiteOrbit

@Suite
struct OrbitRegionSubscriptionTests {
  private struct UpdateFailure: Error {}

  @Test
  func updateAppliesAndRecordsANewRegion() throws {
    let applied = Lock([OrbitDatabaseRegion]())
    let items = OrbitDatabaseRegion(table: "items")
    let lists = OrbitDatabaseRegion(table: "lists")
    let subscription = OrbitRegionSubscription(region: items) { region in
      applied.withLock { $0.append(region) }
    } onCancel: {
    }

    try subscription.updateRegion(items)
    try subscription.updateRegion(lists)

    // Updating to the region it already has is not passed on.
    #expect(applied.withLock { $0 } == [lists])
    #expect(subscription.region == lists)
    #expect(subscription.filtersByRegion)
  }

  @Test
  func failedUpdateLeavesTheRegionUnchanged() {
    let items = OrbitDatabaseRegion(table: "items")
    let subscription = OrbitRegionSubscription(region: items) { _ in
      throw UpdateFailure()
    } onCancel: {
    }

    #expect(throws: UpdateFailure.self) {
      try subscription.updateRegion(.fullDatabase)
    }
    #expect(subscription.region == items)
  }

  @Test
  func subscriptionWithoutAnUpdateOnlyRecordsItsRegion() throws {
    let subscription = OrbitRegionSubscription(region: .fullDatabase) {}

    try subscription.updateRegion(OrbitDatabaseRegion(table: "items"))

    #expect(subscription.region == OrbitDatabaseRegion(table: "items"))
    #expect(!subscription.filtersByRegion)
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
    let items = OrbitDatabaseRegion(table: "items")

    #expect(OrbitDatabaseRegion.fullDatabase.admits(.empty))
    #expect(OrbitDatabaseRegion.fullDatabase.admits(items))
    #expect(items.admits(OrbitDatabaseRegion(column: "title", in: "items")))
    #expect(!items.admits(.empty))
    #expect(!items.admits(OrbitDatabaseRegion(table: "lists")))
  }
}

@Suite
struct OrbitValueObservationAdvertisementTests {
  private let items = OrbitDatabaseRegion(table: "items")
  private let lists = OrbitDatabaseRegion(table: "lists")

  @Test
  func narrowingCountsAtOnceForFetchesInFlight() {
    var advertisement = OrbitValueObservationAdvertisement(region: .fullDatabase)
    let fetch = advertisement.beginFetch()

    let update = advertisement.beginUpdate(observing: items)

    #expect(update == items)
    #expect(advertisement.region == items)
    #expect(advertisement.endFetch(fetch) == items)
  }

  @Test
  func wideningCountsOnlyOnceApplied() {
    var advertisement = OrbitValueObservationAdvertisement(region: items)
    let fetch = advertisement.beginFetch()

    let update = advertisement.beginUpdate(observing: items.union(lists))

    // A fetch in flight while the update is applied cannot rely on it.
    #expect(update == items.union(lists))
    #expect(advertisement.region == items)
    advertisement.finishUpdate(to: items.union(lists))
    #expect(advertisement.region == items.union(lists))
    #expect(advertisement.endFetch(fetch) == items)
  }

  @Test
  func uncoveredAcceptedFetchIsOwedAFetchOnceTheRegionCoversIt() {
    var advertisement = OrbitValueObservationAdvertisement(region: items)
    let fetch = advertisement.beginFetch()
    let read = items.union(lists)

    advertisement.accept(read: read, floor: advertisement.endFetch(fetch))

    let isOwedBeforeWidening = advertisement.takeCoveringFetch(observing: read)
    let update = advertisement.beginUpdate(observing: read)
    advertisement.finishUpdate(to: read)
    let isOwedAfterWidening = advertisement.takeCoveringFetch(observing: read)
    let isOwedAgain = advertisement.takeCoveringFetch(observing: read)

    #expect(!isOwedBeforeWidening)
    #expect(update == read)
    #expect(isOwedAfterWidening)
    #expect(!isOwedAgain)
  }

  @Test
  func withheldFetchKeepsItsRegionRegisteredUntilAFetchIsAccepted() {
    var advertisement = OrbitValueObservationAdvertisement(region: items)

    advertisement.withhold(read: lists)

    #expect(advertisement.beginUpdate(observing: items) == items.union(lists))
    advertisement.finishUpdate(to: items.union(lists))
    advertisement.accept(read: items, floor: items.union(lists))
    #expect(advertisement.beginUpdate(observing: items) == items)
  }

  @Test
  func unfilteredDatabaseCoversEveryFetch() {
    var advertisement = OrbitValueObservationAdvertisement(region: .fullDatabase)
    advertisement.stopFiltering()
    let fetch = advertisement.beginFetch()

    #expect(advertisement.beginUpdate(observing: items) == nil)
    #expect(advertisement.endFetch(fetch) == .fullDatabase)
  }
}
