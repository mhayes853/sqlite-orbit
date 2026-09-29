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
        owed.formUnion(itemsColumn(index))
      }
      #expect(try harness.send(self.other, column: 0).deferred == 1)

      #expect(
        harness.sender.owedRegions == ["peer": [self.database: owed, self.other: itemsColumn(0)]]
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
      #expect(
        harness.sender.owedRegions == ["peer": [self.database: owed.union(itemsColumn(10_000))]]
      )
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
          [commit(self.database, region: owed), commit(self.other, region: itemsColumn(0))]
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
      #expect(harness.sender.owedRegions == ["peer": [self.other: itemsColumn(0)]])

      try harness.withdraw(self.other)
      #expect(try harness.send(self.other, column: 1).peerCount == 0)
      #expect(harness.sender.owedRegions.isEmpty)
    }

    @Test
    func aPeerTheThreadFindsDeadIsPrunedFromEveryDatabaseWithoutAnotherSend() async throws {
      let harness = try OwedPeerHarness(advertising: [self.database, self.other])
      defer { harness.cleanup() }
      _ = try harness.fill(self.database)

      harness.closePeer()
      harness.sender.start { _ in }

      // Nothing is bound at its path any more, so the thread takes it for dead as soon as it
      // tries to send it what it is owed, and prunes it, even from the database it owed nothing.
      try await waitUntil {
        !harness.hasSocketPath && !harness.isAdvertising(self.database)
          && !harness.isAdvertising(self.other)
      }
      #expect(harness.sender.owedRegions.isEmpty)
    }

    @Test
    func aPeerWhoseSocketIsBoundAgainAtItsPathKeepsReceiving() throws {
      let harness = try OwedPeerHarness(advertising: [self.database])
      defer { harness.cleanup() }
      #expect(try harness.send(self.database, column: 0).delivered == 1)
      #expect(try harness.drain().count == 1)

      // The socket the sender keeps for the peer reports it gone, but something is bound at its
      // path, so the sender connects to that and sends the commit there.
      try harness.rebindPeer()
      let delivery = try harness.send(self.database, column: 1)

      #expect(delivery.delivered == 1)
      #expect(delivery.stale.isEmpty)
      #expect(try harness.drain() == [[commit(self.database, region: itemsColumn(1))]])
      #expect(harness.hasSocketPath && harness.isAdvertising(self.database))
    }

    @Test
    func aPeerWhoseSocketIsBoundAgainWhileOwedIsSentWhatItIsOwedThere() async throws {
      let harness = try OwedPeerHarness(advertising: [self.database])
      defer { harness.cleanup() }
      let owed = try harness.fill(self.database)

      // Whatever the old socket's queue held went with it, but what the peer is owed does not.
      try harness.rebindPeer()
      harness.sender.start { _ in }
      try await waitUntil { harness.sender.owedRegions.isEmpty }

      #expect(try harness.drain() == [[commit(self.database, region: owed)]])
      #expect(harness.hasSocketPath && harness.isAdvertising(self.database))
      #expect(try harness.send(self.database, column: 10_000).delivered == 1)
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
        directoryPath: self.directory.path,
        endpointName: "sender",
        maximumDatagramByteCount: maximumDatagramByteCount,
        receiveBufferByteCount: 4_096
      )
      self.peer = try UnixDatagramSocket.bind(
        path: self.sender.peer(named: "peer").socketPath,
        receiveBufferByteCount: 4_096
      )
      for database in databases {
        _ = try self.sender.createDatabaseDirectory(coordinationKey: database.coordinationKey)
        try Data(UnixDatagramWireProtocol.encodeMarker(.fullDatabase))
          .write(to: self.marker(database))
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
          commit(database, region: itemsColumn(index)),
          fittingIn: self.maximumDatagramByteCount
        )
      )
    }

    /// Sends commits, each to a column of its own, until the peer has no room for one.
    ///
    /// - Returns: The region of that commit, which the peer is now owed.
    func fill(_ database: OrbitDatabaseIdentifier) throws -> OrbitDatabaseRegion {
      for index in 0..<10_000 {
        if try self.send(database, column: index).deferred == 1 { return itemsColumn(index) }
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
      waitUntilNothingIsBound(at: self.socketPath)
    }

    /// Closes the peer's socket and binds a new one at its path, leaving its markers as they are,
    /// as an endpoint does that binds its socket again.
    func rebindPeer() throws {
      self.closePeer()
      _ = UnixPlatform.removeFile(atPath: self.socketPath)
      self.peer = try UnixDatagramSocket.bind(path: self.socketPath, receiveBufferByteCount: 4_096)
    }

    func withdraw(_ database: OrbitDatabaseIdentifier) throws {
      try FileManager.default.removeItem(at: self.marker(database))
    }

    func isAdvertising(_ database: OrbitDatabaseIdentifier) -> Bool {
      FileManager.default.fileExists(atPath: self.marker(database).path)
    }

    var hasSocketPath: Bool {
      FileManager.default.fileExists(atPath: self.socketPath)
    }

    private var socketPath: String {
      self.sender.peer(named: "peer").socketPath
    }

    private func marker(_ database: OrbitDatabaseIdentifier) -> URL {
      self.directory.appending(path: "v1/d/\(database.coordinationKey)/peer")
    }
  }
#endif
