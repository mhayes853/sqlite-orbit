#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct OrbitIPCAdvertisementCacheTests {
    private let database = OrbitDatabaseIdentifier(rawValue: "advertised")
    private let items = OrbitDatabaseRegion(table: "items")
    private let lists = OrbitDatabaseRegion(table: "lists")

    @Test(arguments: [true, false])
    func picksUpPeersAppearingChangingAndDisappearing(watchesDirectories: Bool) throws {
      let directory = try makeShortTemporaryDirectory("adcache")
      defer { try? FileManager.default.removeItem(at: directory) }
      let sender = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "sender")
      let cache = OrbitIPCAdvertisementCache(
        registry: sender,
        watchesDirectories: watchesDirectories
      )
      let first = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "first")
      let second = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "second")
      let key = self.database.coordinationKey

      #expect(try cache.advertisements(for: self.database).isEmpty)

      try first.register(coordinationKey: key, region: self.items)
      #expect(try cache.advertisements(for: self.database) == ["first": self.items])

      try second.register(coordinationKey: key, region: self.lists)
      try first.register(coordinationKey: key, region: self.items.union(self.lists))
      #expect(
        try cache.advertisements(for: self.database) == [
          "first": self.items.union(self.lists), "second": self.lists
        ]
      )

      try first.unregister(coordinationKey: key)
      #expect(try cache.advertisements(for: self.database) == ["second": self.lists])

      try second.remove(second.peer(named: "second"), coordinationKeys: [key])
      #expect(try cache.advertisements(for: self.database).isEmpty)
    }

    @Test
    func keepsWhatItReadUntilTheDirectoryChanges() throws {
      let directory = try makeShortTemporaryDirectory("adcache")
      defer { try? FileManager.default.removeItem(at: directory) }
      let sender = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "sender")
      let cache = OrbitIPCAdvertisementCache(registry: sender)
      let peer = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "peer")
      let key = self.database.coordinationKey
      try peer.register(coordinationKey: key, region: self.items)
      #expect(try cache.advertisements(for: self.database) == ["peer": self.items])

      // Written in place, which no endpoint does, so no entry of the directory changes and the
      // cache has no reason to read it again.
      let marker = try sender.createDatabaseDirectory(coordinationKey: key).appending(path: "peer")

      try Data(OrbitIPCWireProtocol.encodeMarker(self.lists)).write(to: marker)

      #expect(try cache.advertisements(for: self.database) == ["peer": self.items])
    }

    @Test
    func unreadableMarkersAdvertiseTheFullDatabaseAndTemporaryOnesNothing() throws {
      let directory = try makeShortTemporaryDirectory("adcache")
      defer { try? FileManager.default.removeItem(at: directory) }
      let sender = try OrbitIPCEndpointRegistry(directory: directory, endpointName: "sender")
      let cache = OrbitIPCAdvertisementCache(registry: sender)
      let markers = try sender.createDatabaseDirectory(
        coordinationKey: self.database.coordinationKey
      )

      let corrupt: [String: [UInt8]] = ["empty": [], "short": [0xff], "truncated": [0, 1, 0]]
      for (name, contents) in corrupt {
        try Data(contents).write(to: markers.appending(path: name))
      }
      try Data().write(to: markers.appending(path: ".peer.tmp"))

      #expect(
        try cache.advertisements(for: self.database) == corrupt.mapValues { _ in .fullDatabase }
      )
    }
  }
#endif
