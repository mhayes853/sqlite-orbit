#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation

  struct OrbitIPCPeer: Hashable, Sendable {
    let endpointName: String
    let socketPath: String
  }

  /// The coordination directory endpoints find each other through.
  ///
  /// Every endpoint binds a socket in `v1/s/`, and advertises its interest in a database with a
  /// marker in `v1/d/<coordination key>/`, named after the endpoint. A marker holds the region the
  /// endpoint's subscriptions for that database cover. Markers are replaced whole by renaming a
  /// temporary file over them, and a temporary file's name starts with a dot, which no endpoint
  /// name does, so a listing never mistakes one for a marker.
  struct OrbitIPCEndpointRegistry: Sendable {
    let endpointName: String
    let socketPath: String
    private let socketsDirectory: URL
    private let databasesDirectory: URL

    init(directory: URL, endpointName: String) throws {
      let versionDirectory = directory.appending(path: "v1", directoryHint: .isDirectory)
      let socketsDirectory = versionDirectory.appending(path: "s", directoryHint: .isDirectory)
      let databasesDirectory = versionDirectory.appending(path: "d", directoryHint: .isDirectory)
      for directory in [socketsDirectory, databasesDirectory] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      self.endpointName = endpointName
      self.socketPath = socketsDirectory.appending(path: "\(endpointName).sock").path
      self.socketsDirectory = socketsDirectory
      self.databasesDirectory = databasesDirectory
    }

    /// Advertises `region` for a database, replacing whatever this endpoint advertised for it.
    ///
    /// When this returns, a peer that lists the database's directory finds the new region.
    func register(coordinationKey: String, region: OrbitDatabaseRegion) throws {
      let directory = try self.createDatabaseDirectory(coordinationKey: coordinationKey)
      let temporary = directory.appending(path: ".\(self.endpointName).tmp")
      try Data(OrbitIPCWireProtocol.encodeMarker(region)).write(to: temporary)
      try UnixSystem.renameFile(
        atPath: temporary.path,
        toPath: directory.appending(path: self.endpointName).path
      )
    }

    func unregister(coordinationKey: String) throws {
      try Self.remove(self.databaseDirectory(coordinationKey).appending(path: self.endpointName))
    }

    /// Creates the directory a database's markers go in, if it is not there yet.
    ///
    /// - Returns: The directory.
    @discardableResult
    func createDatabaseDirectory(coordinationKey: String) throws -> URL {
      let directory = self.databaseDirectory(coordinationKey)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    }

    func peers(databaseIdentifier: OrbitDatabaseIdentifier) throws -> [OrbitIPCPeer] {
      try self.advertisements(coordinationKey: databaseIdentifier.coordinationKey).keys
        .map(self.peer(named:))
    }

    /// Reads every marker for a database.
    ///
    /// A marker that cannot be read or decoded, or that is empty, advertises the full database,
    /// which is never wrong: it only costs its endpoint messages it ignores.
    ///
    /// - Returns: The region each advertising endpoint's subscriptions cover, by endpoint name.
    func advertisements(coordinationKey: String) throws -> [String: OrbitDatabaseRegion] {
      let directory = self.databaseDirectory(coordinationKey)
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      } catch CocoaError.fileReadNoSuchFile {
        return [:]
      }
      var advertisements: [String: OrbitDatabaseRegion] = [:]
      for name in names where !name.hasPrefix(".") {
        let marker: Data
        do {
          marker = try Data(contentsOf: directory.appending(path: name))
        } catch CocoaError.fileReadNoSuchFile {
          // Removed since the listing, by an endpoint that stopped advertising.
          continue
        } catch {
          marker = Data()
        }
        advertisements[name] =
          (try? [UInt8](marker)
            .withUnsafeBufferPointer {
              try OrbitIPCWireProtocol.decodeMarker(Span(_unsafeElements: $0))
            }) ?? .fullDatabase
      }
      return advertisements
    }

    func peer(named endpointName: String) -> OrbitIPCPeer {
      OrbitIPCPeer(
        endpointName: endpointName,
        socketPath: self.socketsDirectory.appending(path: "\(endpointName).sock").path
      )
    }

    /// Removes a dead peer's socket path and its markers for the databases it was found under.
    ///
    /// - Parameters:
    ///   - peer: The peer that turned out to be dead.
    ///   - coordinationKeys: The databases it was found advertising.
    func remove(_ peer: OrbitIPCPeer, coordinationKeys: some Sequence<String>) throws {
      try Self.remove(URL(fileURLWithPath: peer.socketPath))
      for coordinationKey in coordinationKeys {
        let directory = self.databaseDirectory(coordinationKey)
        try Self.remove(directory.appending(path: peer.endpointName))
        // Left behind if the peer died between writing a marker and renaming it into place.
        try Self.remove(directory.appending(path: ".\(peer.endpointName).tmp"))
      }
    }

    private static func remove(_ url: URL) throws {
      do {
        try FileManager.default.removeItem(at: url)
      } catch CocoaError.fileNoSuchFile {
      }
    }

    private func databaseDirectory(_ coordinationKey: String) -> URL {
      self.databasesDirectory.appending(path: coordinationKey, directoryHint: .isDirectory)
    }
  }
#endif
