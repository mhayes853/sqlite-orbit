#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  /// What an endpoint owes a peer whose receive queue is full.
  ///
  /// The peer is a bare socket the test reads by hand, so its queue has room exactly when the test
  /// has drained it, and the sender's thread, which is what sends a peer what it is owed, runs only
  /// once a test starts it.
  @Suite
  struct UnixDatagramEndpointTests {
    private let database = OrbitDatabaseIdentifier(rawValue: "owed")
    private let other = OrbitDatabaseIdentifier(rawValue: "owed-other")

    @Test
    func aFullPeerIsOwedTheUnionOfTheCommitsItHadNoRoomFor() throws {
      let harness = try OwedPeerHarness(advertising: [self.database, self.other])
      defer { harness.cleanup() }

      var owed = try harness.fill(self.database)
      for index in 10_000..<10_003 {
        #expect(try harness.send(self.database, column: index).deferred == 1)
        owed.formUnion(column(index))
      }
      #expect(try harness.send(self.other, column: 0).deferred == 1)

      #expect(
        harness.sender.owedRegions == ["peer": [self.database: owed, self.other: column(0)]]
      )
    }

    @Test
    func aSendToAPeerThatIsOwedJoinsWhatItIsOwedRatherThanOvertakingIt() throws {
      let harness = try OwedPeerHarness(advertising: [self.database])
      defer { harness.cleanup() }
      let owed = try harness.fill(self.database)

      // The peer has room again, but the thread that would send it what it is owed never ran.
      #expect(try !harness.drain().isEmpty)
      let delivery = try harness.send(self.database, column: 10_000)

      #expect(delivery.delivered == 0)
      #expect(delivery.deferred == 1)
      #expect(try harness.drain().isEmpty)
      #expect(harness.sender.owedRegions == ["peer": [self.database: owed.union(column(10_000))]])
    }

    @Test
    func aPeerWithRoomIsSentWhatItIsOwedAsOneCommitPerDatabase() async throws {
      let harness = try OwedPeerHarness(advertising: [self.database, self.other])
      defer { harness.cleanup() }
      let owed = try harness.fill(self.database)
      #expect(try harness.send(self.other, column: 0).deferred == 1)
      _ = try harness.drain()

      harness.sender.start { _ in }
      try await waitUntil { harness.sender.owedRegions.isEmpty }

      // Both fit in one datagram, in the order of their databases' identifiers.
      #expect(
        try harness.drain() == [
          [commit(self.database, region: owed), commit(self.other, region: column(0))]
        ]
      )
    }

    @Test
    func aPeerIsSentWhatItIsOwedInAsFewDatagramsAsFitIt() async throws {
      // Room for one full-database commit a datagram, and not for two.
      let harness = try OwedPeerHarness(
        advertising: [self.database, self.other],
        maximumDatagramByteCount: 40
      )
      defer { harness.cleanup() }
      _ = try harness.fill(self.database)
      #expect(try harness.send(self.other, column: 0).deferred == 1)
      _ = try harness.drain()

      harness.sender.start { _ in }
      try await waitUntil { harness.sender.owedRegions.isEmpty }

      #expect(
        try harness.drain() == [
          [commit(self.database, region: .fullDatabase)],
          [commit(self.other, region: .fullDatabase)]
        ]
      )
    }

    @Test
    func aRegionOwedThatNoLongerFitsADatagramIsSentAsTheFullDatabase() async throws {
      let harness = try OwedPeerHarness(advertising: [self.database])
      defer { harness.cleanup() }
      _ = try harness.fill(self.database)
      for index in 10_000..<10_200 {
        #expect(try harness.send(self.database, column: index).deferred == 1)
      }
      _ = try harness.drain()

      harness.sender.start { _ in }
      try await waitUntil { harness.sender.owedRegions.isEmpty }

      #expect(try harness.drain() == [[commit(self.database, region: .fullDatabase)]])
    }

    @Test
    func aPeerThatStopsAdvertisingADatabaseIsNoLongerOwedIt() throws {
      let harness = try OwedPeerHarness(advertising: [self.database, self.other])
      defer { harness.cleanup() }
      _ = try harness.fill(self.database)
      #expect(try harness.send(self.other, column: 0).deferred == 1)

      try harness.withdraw(self.database)
      #expect(try harness.send(self.database, column: 10_000).peerCount == 0)
      #expect(harness.sender.owedRegions == ["peer": [self.other: column(0)]])

      try harness.withdraw(self.other)
      #expect(try harness.send(self.other, column: 1).peerCount == 0)
      #expect(harness.sender.owedRegions.isEmpty)
    }

    @Test
    func aPeerFoundDeadWhileOwedIsDroppedAndPrunedByTheNextSend() async throws {
      let harness = try OwedPeerHarness(advertising: [self.database])
      defer { harness.cleanup() }
      _ = try harness.fill(self.database)

      harness.closePeer()
      harness.sender.start { _ in }
      try await waitUntil { harness.sender.owedRegions.isEmpty }

      // The thread only drops it. Its marker is left to the next send, which finds it dead too.
      #expect(harness.isAdvertising(self.database))
      let delivery = try harness.send(self.database, column: 10_000)
      #expect(delivery.stale.map(\.peer.endpointName) == ["peer"])
      #expect(!harness.isAdvertising(self.database))
    }
  }

  /// A sender whose one peer is a bare socket, bound where an endpoint named `peer` would be, with
  /// a small receive buffer so that it fills quickly.
  private final class OwedPeerHarness {
    let sender: UnixDatagramEndpointRegistry
    private let directory: URL
    private let maximumDatagramByteCount: Int
    private var peer: UnixDatagramSocket?

    init(advertising databases: [OrbitDatabaseIdentifier], maximumDatagramByteCount: Int = 1_024)
      throws
    {
      self.directory = try makeShortTemporaryDirectory("owed")
      self.maximumDatagramByteCount = maximumDatagramByteCount
      self.sender = try UnixDatagramEndpointRegistry(
        directory: self.directory,
        endpointName: "sender",
        maximumDatagramByteCount: maximumDatagramByteCount,
        receiveBufferByteCount: 4_096
      )
      self.peer = try UnixDatagramSocket.bind(
        path: self.sender.peer(named: "peer").socketPath,
        receiveBufferByteCount: 4_096
      )
      for database in databases {
        try Data(UnixDatagramWireProtocol.encodeMarker(.fullDatabase))
          .write(to: try self.marker(database))
      }
    }

    func cleanup() {
      self.sender.shutdown()
      try? FileManager.default.removeItem(at: self.directory)
    }

    func send(
      _ database: OrbitDatabaseIdentifier,
      column index: Int
    ) throws -> UnixDatagramEndpoint.Delivery {
      try self.sender.send(
        UnixDatagramWireEntry(
          commit(database, region: column(index)),
          fittingIn: self.maximumDatagramByteCount
        )
      )
    }

    /// Sends commits, each to a column of its own, until the peer has no room for one.
    ///
    /// - Returns: The region of that commit, which the peer is now owed.
    func fill(_ database: OrbitDatabaseIdentifier) throws -> OrbitDatabaseRegion {
      for index in 0..<10_000 {
        if try self.send(database, column: index).deferred == 1 { return column(index) }
      }
      throw TestTimeout()
    }

    /// Reads every datagram waiting in the peer's queue.
    ///
    /// - Returns: The messages in each datagram, in the order they arrived.
    func drain() throws -> [[OrbitIPCMessage]] {
      // A closed peer has nothing to drain, which would pass for an empty queue. The check is
      // spelled apart from the macro, which cannot take a noncopyable operand.
      let isOpen = self.peer != nil
      try #require(isOpen)
      var buffer = [UInt8](repeating: 0, count: 65_536)
      var datagrams: [[OrbitIPCMessage]] = []
      while true {
        let messages = try buffer.withUnsafeMutableBufferPointer { buffer -> [OrbitIPCMessage]? in
          guard let count = self.peer?.receive(into: buffer) else { return nil }
          let datagram = UnsafeBufferPointer(rebasing: buffer[..<count])
          return try UnixDatagramWireProtocol.decode(Span(_unsafeElements: datagram))
        }
        guard let messages else { return datagrams }
        datagrams.append(messages)
      }
    }

    /// Closes the peer's socket, leaving its path and markers behind, as a process that dies does.
    func closePeer() {
      self.peer = nil
    }

    func withdraw(_ database: OrbitDatabaseIdentifier) throws {
      try FileManager.default.removeItem(at: try self.marker(database))
    }

    func isAdvertising(_ database: OrbitDatabaseIdentifier) -> Bool {
      (try? FileManager.default.fileExists(atPath: self.marker(database).path)) == true
    }

    private func marker(_ database: OrbitDatabaseIdentifier) throws -> URL {
      try self.sender.createDatabaseDirectory(coordinationKey: database.coordinationKey)
        .appending(path: "peer")
    }
  }

  private func column(_ index: Int) -> OrbitDatabaseRegion {
    OrbitDatabaseRegion(column: "c\(index)", in: "items")
  }
#endif
