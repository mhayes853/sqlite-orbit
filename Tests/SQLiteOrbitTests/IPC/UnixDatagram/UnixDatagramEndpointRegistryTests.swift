#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct UnixDatagramEndpointRegistryTests {
    private let database = OrbitDatabaseIdentifier(rawValue: "advertised")
    private let items = OrbitDatabaseRegion(table: "items")
    private let lists = OrbitDatabaseRegion(table: "lists")

    @Test(arguments: [true, false])
    func picksUpPeersAppearingChangingAndDisappearing(watchesDirectories: Bool) throws {
      try withTemporaryDirectory("registry") { directory in
        let sender = try unixDatagramRegistry(
          directory,
          endpointName: "sender",
          watchesDirectories: watchesDirectories
        )
        let first = try unixDatagramRegistry(directory, endpointName: "first")
        let second = try unixDatagramRegistry(directory, endpointName: "second")
        let key = self.database.coordinationKey

        #expect(try sender.peerRegions(for: self.database).isEmpty)

        try first.advertise(self.items, coordinationKey: key)
        #expect(try sender.peerRegions(for: self.database) == ["first": self.items])

        try second.advertise(self.lists, coordinationKey: key)
        try first.advertise(self.items.union(self.lists), coordinationKey: key)
        #expect(
          try sender.peerRegions(for: self.database) == [
            "first": self.items.union(self.lists), "second": self.lists
          ]
        )

        try first.withdraw(coordinationKey: key)
        #expect(try sender.peerRegions(for: self.database) == ["second": self.lists])

        second.prune(second.peer(named: "second"))
        #expect(try sender.peerRegions(for: self.database).isEmpty)
      }
    }

    @Test
    func keepsWhatItReadUntilTheDirectoryChanges() throws {
      try withTemporaryDirectory("registry") { directory in
        let sender = try unixDatagramRegistry(directory, endpointName: "sender")
        let peer = try unixDatagramRegistry(directory, endpointName: "peer")
        let key = self.database.coordinationKey
        try peer.advertise(self.items, coordinationKey: key)
        #expect(try sender.peerRegions(for: self.database) == ["peer": self.items])

        // Written in place, which no endpoint does, so no entry of the directory changes and the
        // registry has no reason to read it again.
        let marker = URL(
          fileURLWithPath: try sender.createDatabaseDirectory(coordinationKey: key)
        )
        .appending(path: "peer")

        try Data(UnixDatagramWireProtocol.encodeMarker(self.lists)).write(to: marker)

        #expect(try sender.peerRegions(for: self.database) == ["peer": self.items])
      }
    }

    @Test
    func unreadableMarkersAdvertiseTheFullDatabaseAndTemporaryOnesNothing() throws {
      try withTemporaryDirectory("registry") { directory in
        let sender = try unixDatagramRegistry(directory, endpointName: "sender")
        let markers = URL(
          fileURLWithPath: try sender.createDatabaseDirectory(
            coordinationKey: self.database.coordinationKey
          )
        )

        let corrupt: [String: [UInt8]] = ["empty": [], "short": [0xff], "truncated": [0, 1, 0]]
        for (name, contents) in corrupt {
          try Data(contents).write(to: markers.appending(path: name))
        }
        try Data().write(to: markers.appending(path: ".peer.tmp"))

        #expect(
          try sender.peerRegions(for: self.database) == corrupt.mapValues { _ in .fullDatabase }
        )
      }
    }

    @Test
    func oneSendPrunesADeadPeerFromEveryDatabase() throws {
      try withTemporaryDirectory("registry") { directory in
        let sender = try unixDatagramRegistry(directory, endpointName: "sender")
        let unsent = OrbitDatabaseIdentifier(rawValue: "unsent")
        var crashed: UnixDatagramEndpointRegistry? = try unixDatagramRegistry(
          directory,
          endpointName: "crashed"
        )
        try crashed?.advertise(self.items, coordinationKey: self.database.coordinationKey)
        try crashed?.advertise(self.items, coordinationKey: unsent.coordinationKey)
        let socketPath = try #require(crashed?.socketPath)
        // What a peer leaves if it dies between writing a marker and renaming it into place.
        let interrupted = URL(
          fileURLWithPath: try sender.createDatabaseDirectory(coordinationKey: "interrupted")
        )
        try Data().write(to: interrupted.appending(path: ".crashed.tmp"))

        // Released without being shut down, which closes its socket and leaves everything else, as
        // a process that dies does.
        crashed = nil
        waitUntilNothingIsBound(at: socketPath)
        #expect(FileManager.default.fileExists(atPath: socketPath))
        let delivery = try sender.send(
          UnixDatagramWireEntry(commit(self.database, region: self.items), fittingIn: 1_024)
        )

        #expect(delivery.stale.map(\.endpointName) == ["crashed"])
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(try sender.peerRegions(for: self.database).isEmpty)
        #expect(try sender.peerRegions(for: unsent).isEmpty)
        // Reclaimed once nothing is left in it.
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
      }
    }

    @Test(arguments: [true, false])
    func aDatabaseWhoseDirectoryIsRemovedIsSentToAndAdvertisedAgain(
      watchesDirectories: Bool
    ) throws {
      try withTemporaryDirectory("registry") { directory in
        let sender = try unixDatagramRegistry(
          directory,
          endpointName: "sender",
          watchesDirectories: watchesDirectories
        )
        let peer = try unixDatagramRegistry(directory, endpointName: "peer")
        let key = self.database.coordinationKey
        let databaseDirectory = directory.appending(path: "v1/d/\(key)")
        // As an endpoint that removes the last marker from a database's directory reclaims it.
        func reclaim() throws {
          #expect(try FileManager.default.contentsOfDirectory(atPath: databaseDirectory.path) == [])
          try FileManager.default.removeItem(at: databaseDirectory)
        }
        func send() throws -> UnixDatagramEndpoint.Delivery {
          try sender.send(
            UnixDatagramWireEntry(commit(self.database, region: self.items), fittingIn: 1_024)
          )
        }
        try peer.advertise(self.items, coordinationKey: key)
        #expect(try send().delivered == 1)

        // Gone from under what the sender read and watched, reclaimed by the peer as it withdrew.
        try peer.withdraw(coordinationKey: key)
        #expect(!FileManager.default.fileExists(atPath: databaseDirectory.path))
        #expect(try send().peerCount == 0)

        // Gone from under the advertiser.
        try reclaim()
        try peer.advertise(self.items, coordinationKey: key)
        #expect(try send().delivered == 1)
      }
    }

    @Test
    func aDatabasesDirectoryIsReclaimedOnceItsLastMarkerIsWithdrawn() throws {
      try withTemporaryDirectory("registry") { directory in
        let first = try unixDatagramRegistry(directory, endpointName: "first")
        let second = try unixDatagramRegistry(directory, endpointName: "second")
        let key = self.database.coordinationKey
        let databaseDirectory = directory.appending(path: "v1/d/\(key)").path
        try first.advertise(self.items, coordinationKey: key)
        try second.advertise(self.lists, coordinationKey: key)

        // Kept while it holds another endpoint's marker.
        try first.withdraw(coordinationKey: key)
        #expect(
          try FileManager.default.contentsOfDirectory(atPath: databaseDirectory) == ["second"]
        )

        try second.withdraw(coordinationKey: key)
        #expect(!FileManager.default.fileExists(atPath: databaseDirectory))

        // Created again by the next endpoint that advertises the database.
        try first.advertise(self.items, coordinationKey: key)
        #expect(try second.peerRegions(for: self.database) == ["first": self.items])
      }
    }

    @Test
    func keepsTrackOfItsOwnMarkersAcrossChangesToOthers() throws {
      try withTemporaryDirectory("registry") { directory in
        let endpoint = try unixDatagramRegistry(directory, endpointName: "endpoint")
        let peer = try unixDatagramRegistry(directory, endpointName: "peer")
        let key = self.database.coordinationKey
        try endpoint.advertise(self.items, coordinationKey: key)
        _ = try endpoint.peerRegions(for: self.database)

        // Read after the watch reports the peer's marker, which forgets what was read before.
        try peer.advertise(self.lists, coordinationKey: key)
        #expect(try endpoint.peerRegions(for: self.database).keys.sorted() == ["endpoint", "peer"])
        endpoint.shutdown()

        #expect(try peer.peerRegions(for: self.database) == ["peer": self.lists])
      }
    }
  }

  /// A registry for an endpoint that is never started, which tests use to write markers and to
  /// read what peers advertise.
  func unixDatagramRegistry(
    _ directory: URL,
    endpointName: String,
    watchesDirectories: Bool = true
  ) throws -> UnixDatagramEndpointRegistry {
    try UnixDatagramEndpointRegistry(
      directoryPath: directory.path,
      endpointName: endpointName,
      maximumDatagramByteCount: 60 * 1024,
      receiveBufferByteCount: 256 * 1024,
      watchesDirectories: watchesDirectories
    )
  }

  extension UnixDatagramEndpointRegistry {
    /// Every endpoint advertising a database now, this one included.
    func peers(databaseIdentifier: OrbitDatabaseIdentifier) throws -> [UnixDatagramPeer] {
      try self.peerRegions(for: databaseIdentifier).keys.map(self.peer(named:))
    }
  }
#endif
