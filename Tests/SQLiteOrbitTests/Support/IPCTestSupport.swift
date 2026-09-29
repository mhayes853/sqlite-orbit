import Foundation

@testable import SQLiteOrbit

/// Records the messages a transport hands a subscription, as its `onMessage` handler.
typealias IPCMessageRecorder = TestRecorder<OrbitIPCMessage>

/// The message announcing a commit to `region` of `database`.
func commit(
  _ database: OrbitDatabaseIdentifier,
  region: OrbitDatabaseRegion = .fullDatabase
) -> OrbitIPCMessage {
  .transactionDidCommit(.init(databaseIdentifier: database, region: region))
}

/// A commit to a column no other index writes, so the order commits arrive in shows.
func columnCommit(_ database: OrbitDatabaseIdentifier, _ index: Int) -> OrbitIPCMessage {
  commit(database, region: itemsColumn(index))
}

/// A column of `items` of its own for each index.
func itemsColumn(_ index: Int) -> OrbitDatabaseRegion {
  OrbitDatabaseRegion(column: "c\(index)", in: "items")
}

#if canImport(Darwin) || os(Linux) || os(Android)
  /// A transport of this process, coordinating through `directory`.
  func ipcTransport(_ directory: URL) throws -> UnixDatagramIPCTransport {
    try .init(configuration: .init(directoryPath: directory.path))
  }
#endif
