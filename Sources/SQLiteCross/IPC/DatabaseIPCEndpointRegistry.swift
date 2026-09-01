#if canImport(Darwin) || canImport(Glibc)
  import Foundation

  struct DatabaseIPCPeer: Hashable, Sendable {
    let endpointName: String
    let socketPath: String
  }

  /// Uses only atomic directory creation, rename, and unlink operations, so no file lock is needed.
  struct DatabaseIPCEndpointRegistry: Sendable {
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

    func register(databaseIdentifier: DatabaseIdentifier) throws {
      let directory = self.databaseDirectory(for: databaseIdentifier)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data().write(to: self.markerURL(in: directory), options: .atomic)
    }

    func unregister(databaseIdentifier: DatabaseIdentifier) throws {
      try Self.remove(self.markerURL(in: self.databaseDirectory(for: databaseIdentifier)))
    }

    func peers(databaseIdentifier: DatabaseIdentifier) throws -> [DatabaseIPCPeer] {
      let directory = self.databaseDirectory(for: databaseIdentifier)
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      } catch CocoaError.fileReadNoSuchFile {
        return []
      }
      return names.map { endpointName in
        DatabaseIPCPeer(
          endpointName: endpointName,
          socketPath: self.socketsDirectory.appending(path: "\(endpointName).sock").path
        )
      }
    }

    func remove(_ peer: DatabaseIPCPeer, databaseIdentifier: DatabaseIdentifier) throws {
      let marker = self.databaseDirectory(for: databaseIdentifier)
        .appending(path: peer.endpointName)
      try Self.remove(marker)
    }

    private static func remove(_ marker: URL) throws {
      do {
        try FileManager.default.removeItem(at: marker)
      } catch CocoaError.fileNoSuchFile {
      }
    }

    func registrationKey(for databaseIdentifier: DatabaseIdentifier) -> String {
      databaseIdentifier.coordinationKey
    }

    private func databaseDirectory(
      for databaseIdentifier: DatabaseIdentifier
    ) -> URL {
      self.databasesDirectory.appending(
        path: self.registrationKey(for: databaseIdentifier),
        directoryHint: .isDirectory
      )
    }

    private func markerURL(in directory: URL) -> URL {
      directory.appending(path: self.endpointName)
    }
  }
#endif
