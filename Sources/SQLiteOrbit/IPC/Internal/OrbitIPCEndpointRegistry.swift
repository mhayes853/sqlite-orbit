#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation

  struct OrbitIPCPeer: Hashable, Sendable {
    let endpointName: String
    let socketPath: String
  }

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

    func register(databaseIdentifier: OrbitDatabaseIdentifier) throws {
      let directory = self.databaseDirectory(for: databaseIdentifier)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try UnixSystem.createFileIfAbsent(atPath: self.markerURL(in: directory).path)
    }

    func unregister(databaseIdentifier: OrbitDatabaseIdentifier) throws {
      try Self.remove(self.markerURL(in: self.databaseDirectory(for: databaseIdentifier)))
    }

    func peers(databaseIdentifier: OrbitDatabaseIdentifier) throws -> [OrbitIPCPeer] {
      let directory = self.databaseDirectory(for: databaseIdentifier)
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      } catch CocoaError.fileReadNoSuchFile {
        return []
      }
      return names.map { endpointName in
        OrbitIPCPeer(
          endpointName: endpointName,
          socketPath: self.socketsDirectory.appending(path: "\(endpointName).sock").path
        )
      }
    }

    /// Removes a dead peer's socket path and its markers for the databases it was found under.
    ///
    /// - Parameters:
    ///   - peer: The peer that turned out to be dead.
    ///   - coordinationKeys: The databases it was found advertising.
    func remove(_ peer: OrbitIPCPeer, coordinationKeys: some Sequence<String>) throws {
      try Self.remove(URL(fileURLWithPath: peer.socketPath))
      for coordinationKey in coordinationKeys {
        try Self.remove(
          self.databasesDirectory
            .appending(path: coordinationKey, directoryHint: .isDirectory)
            .appending(path: peer.endpointName)
        )
      }
    }

    private static func remove(_ url: URL) throws {
      do {
        try FileManager.default.removeItem(at: url)
      } catch CocoaError.fileNoSuchFile {
      }
    }

    private func databaseDirectory(
      for databaseIdentifier: OrbitDatabaseIdentifier
    ) -> URL {
      self.databasesDirectory.appending(
        path: databaseIdentifier.coordinationKey,
        directoryHint: .isDirectory
      )
    }

    private func markerURL(in directory: URL) -> URL {
      directory.appending(path: self.endpointName)
    }
  }
#endif
