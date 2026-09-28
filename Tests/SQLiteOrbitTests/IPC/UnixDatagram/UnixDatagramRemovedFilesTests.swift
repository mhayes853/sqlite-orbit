#if canImport(Darwin) || os(Linux) || os(Android)
  import Dispatch
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  /// What becomes of a live endpoint whose files are removed from under it, as macOS removes
  /// temporary files nobody has used for three days.
  ///
  /// The removal is done by hand, the way the system's cleaner does it: the socket's file and the
  /// marker go, then every directory they leave empty. Nothing here depends on the platform, so
  /// the same scenario runs on Linux and Darwin alike.
  @Suite
  struct UnixDatagramRemovedFilesTests {
    private let database = OrbitDatabaseIdentifier(rawValue: "cleaned")
    private let items = OrbitDatabaseRegion(table: "items")

    @Test
    func anIdleEndpointWhoseFilesTheCleanerRemovesPutsThemBackAndKeepsReceiving() async throws {
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try removedFilesTransport(directory)
      let recorder = IPCMessageRecorder()
      let subscription = try receiver.subscribe(
        to: self.database,
        region: self.items,
        onMessage: recorder.append
      )
      let sender = try removedFilesTransport(directory)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)
      // Connected to the receiver's socket before it is replaced, so the sender has to find out
      // it is gone and connect to the new one.
      try await sender.send(removedFilesCommit(self.database, column: 0))
      try await recorder.waitForCount(1)

      files.removeAsTheCleanerWould()

      // Under the same name, so at the same paths.
      try await waitUntil { files.isRestored(advertising: self.items) }
      try await sender.send(removedFilesCommit(self.database, column: 1))
      try await recorder.waitForCount(2)
      #expect(
        recorder.values == [
          removedFilesCommit(self.database, column: 0),
          removedFilesCommit(self.database, column: 1)
        ]
      )
      _ = subscription
    }

    @Test
    func anEndpointWhoseFilesAreRemovedTwiceClosesItsFirstSocketAndItsPeersFollowIt() async throws {
      // The socket a repair replaces is still read, for the peers connected to it, until the next
      // repair closes it. A peer connected to it then finds it gone and connects to the path.
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try removedFilesTransport(directory)
      let recorder = IPCMessageRecorder()
      let subscription = try receiver.subscribe(to: self.database, onMessage: recorder.append)
      let sender = try removedFilesTransport(directory)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)
      try await sender.send(removedFilesCommit(self.database, column: 0))
      try await recorder.waitForCount(1)
      // Connected to the first socket as the sender is, to tell when it closes. What it sends is
      // too short to decode, which the receiver drops.
      guard let first = try UnixDatagramSocket.connect(to: files.socketPath) else {
        Issue.record("Nothing is bound at \(files.socketPath)")
        return
      }

      files.removeAsTheCleanerWould()
      try await waitUntil { files.isRestored(advertising: .fullDatabase) }
      #expect(first.send([0]) == .sent)
      try await sender.send(removedFilesCommit(self.database, column: 1))
      try await recorder.waitForCount(2)

      files.removeAsTheCleanerWould()
      try await waitUntil { files.isRestored(advertising: .fullDatabase) }
      try await waitUntil { first.send([0]) == .peerGone }
      try await sender.send(removedFilesCommit(self.database, column: 2))
      try await recorder.waitForCount(3)

      #expect(recorder.values == (0..<3).map { removedFilesCommit(self.database, column: $0) })
      _ = subscription
    }

    @Test
    func aSuspendedEndpointOwedRegionsPutsItsFilesBackAndIsSentWhatItMissed() async throws {
      // The receiver's thread is held in its handler, as a suspended process's is, so it can do
      // nothing about its files until it runs again, and the sender owes it what did not fit.
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try HeldReceiver(directory: directory, database: self.database)
      let sender = try removedFilesTransport(directory)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)

      var queued: [OrbitIPCMessage] = []
      while sender.owedRegions.isEmpty {
        guard queued.count < 10_000 else { throw TestTimeout() }
        let message = removedFilesCommit(self.database, column: queued.count)
        try await sender.send(message)
        queued.append(message)
      }
      var owed = removedFilesColumn(queued.count - 1)
      queued.removeLast()
      for index in 10_000..<10_003 {
        try await sender.send(removedFilesCommit(self.database, column: index))
        owed.formUnion(removedFilesColumn(index))
      }
      #expect(Array(sender.owedRegions.values) == [[self.database: owed]])

      files.removeAsTheCleanerWould()
      receiver.resume()

      try await waitUntil { files.isRestored(advertising: .fullDatabase) }
      try await waitUntil { sender.owedRegions.isEmpty }
      try await receiver.recorder.waitForCount(queued.count + 1)
      // Everything its queue held, then the union of every region it missed, as one commit.
      let missed = OrbitIPCMessage.transactionDidCommit(
        .init(databaseIdentifier: self.database, region: owed)
      )
      #expect(receiver.recorder.values == queued + [missed])
      let later = removedFilesCommit(self.database, column: 20_000)
      try await sender.send(later)
      try await receiver.recorder.waitForCount(queued.count + 2)
      #expect(receiver.recorder.values.last == later)
    }

    @Test
    func anEndpointASenderTookForDeadWhileItsSocketWasMissingPutsBackWhatWasPruned() async throws {
      // The receiver's thread is held until the sender has pruned it, so the order is certain.
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try HeldReceiver(directory: directory, database: self.database)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)
      let first = removedFilesCommit(self.database, column: 0)
      try await removedFilesTransport(directory).send(first)
      try await receiver.recorder.waitForCount(1)

      _ = UnixPlatform.removeFile(atPath: files.socketPath)
      // It has never connected to the receiver, so it finds nothing at the path and prunes it.
      let sender = try removedFilesTransport(directory)
      #expect(try sender.peers(concernedWith: first).count == 1)
      try await sender.send(removedFilesCommit(self.database, column: 1))
      #expect(!FileManager.default.fileExists(atPath: files.marker.path))
      #expect(try sender.peers(concernedWith: first).isEmpty)

      receiver.resume()
      try await waitUntil { files.isRestored(advertising: .fullDatabase) }
      let later = removedFilesCommit(self.database, column: 2)
      try await sender.send(later)
      try await receiver.recorder.waitForCount(2)
      #expect(receiver.recorder.values == [first, later])
    }

    @Test
    func aRepairSettlesRatherThanSettingOffAnother() async throws {
      // A repair's own writes land in the directories it watches. Each file removed is put back
      // once, and the socket bound in its place stays.
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try removedFilesTransport(directory)
      let subscription = try receiver.subscribe(to: self.database, region: self.items) { _ in }
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)
      #expect(receiver.repairCount == 0)

      files.removeAsTheCleanerWould()
      try await waitUntil { files.isRestored(advertising: self.items) }
      let socket = files.socketIdentity
      try await Task.sleep(for: .milliseconds(200))

      #expect(receiver.repairCount == 2)
      #expect(files.socketIdentity == socket)
      _ = subscription
    }
  }

  /// The files one endpoint keeps in a coordination directory: its socket's path, and its marker
  /// for one database, which is the only marker there.
  struct UnixDatagramEndpointFiles {
    let socketPath: String
    let marker: URL
    private let directory: URL

    init(advertising database: OrbitDatabaseIdentifier, in directory: URL) throws {
      let markers = directory.appending(path: "v1/d/\(database.coordinationKey)")
      let names = try FileManager.default.contentsOfDirectory(atPath: markers.path)
        .filter { !$0.hasPrefix(".") }
      try #require(names.count == 1)
      self.socketPath = directory.appending(path: "v1/s/\(names[0]).sock").path
      self.marker = markers.appending(path: names[0])
      self.directory = directory
    }

    var socketIdentity: UnixFileIdentity? {
      UnixPlatform.fileIdentity(atPath: self.socketPath)
    }

    /// Removes the socket's file and the marker, then every directory that leaves empty, up to the
    /// coordination directory, as macOS's cleaner of temporary files does.
    ///
    /// The endpoint may be putting them back meanwhile, so what is not there, or not empty, is
    /// left as it is.
    func removeAsTheCleanerWould() {
      let root = self.directory.standardizedFileURL.path
      for file in [self.socketPath, self.marker.path] {
        _ = UnixPlatform.removeFile(atPath: file)
        var parent = URL(fileURLWithPath: file).deletingLastPathComponent().standardizedFileURL
        while parent.path.hasPrefix(root + "/"),
          UnixPlatform.removeDirectory(atPath: parent.path)
        {
          parent = parent.deletingLastPathComponent().standardizedFileURL
        }
      }
    }

    /// Whether a socket is bound at the socket's path again, and the marker advertises `region`.
    func isRestored(advertising region: OrbitDatabaseRegion) -> Bool {
      guard UnixDatagramSocket.probe(self.socketPath) == .alive,
        let marker = try? [UInt8](Data(contentsOf: self.marker))
      else { return false }
      let advertised = try? marker.withUnsafeBufferPointer {
        try UnixDatagramWireProtocol.decodeMarker(Span(_unsafeElements: $0))
      }
      return advertised == region
    }
  }

  /// A receiver whose handler holds the transport's thread at the first message until
  /// ``resume()``, as a suspended process holds it, so its queue fills and it repairs nothing.
  private final class HeldReceiver: Sendable {
    let recorder = IPCMessageRecorder()
    private let gate = DispatchSemaphore(value: 0)
    private let transport: UnixDatagramIPCTransport
    private let subscription: OrbitRegionSubscription

    init(directory: URL, database: OrbitDatabaseIdentifier) throws {
      let recorder = self.recorder
      let gate = self.gate
      let isHeld = Lock(true)
      self.transport = try removedFilesTransport(directory)
      self.subscription = try self.transport.subscribe(to: database) { message in
        recorder.append(message)
        let holds = isHeld.withLock { isHeld in
          defer { isHeld = false }
          return isHeld
        }
        if holds { gate.blockingWait() }
      }
    }

    deinit {
      // A test that fails before resuming must not leave the transport's thread held for good.
      self.gate.signal()
    }

    func resume() { self.gate.signal() }
  }

  private func removedFilesTransport(_ directory: URL) throws -> UnixDatagramIPCTransport {
    try .init(configuration: .init(directory: directory))
  }

  /// A commit to a column no other index writes, so the order commits arrive in shows.
  private func removedFilesCommit(
    _ database: OrbitDatabaseIdentifier,
    column index: Int
  ) -> OrbitIPCMessage {
    .transactionDidCommit(.init(databaseIdentifier: database, region: removedFilesColumn(index)))
  }

  private func removedFilesColumn(_ index: Int) -> OrbitDatabaseRegion {
    OrbitDatabaseRegion(column: "c\(index)", in: "items")
  }
#endif
