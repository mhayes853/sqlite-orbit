#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  /// What becomes of a live endpoint whose files are removed from under it, as macOS removes
  /// temporary files nobody has used for three days, and how an endpoint in use keeps that from
  /// happening.
  ///
  /// The removal is done by hand, the way the system's cleaner does it: the socket's file and the
  /// marker go, then every directory they leave empty. Nothing here depends on the platform, so
  /// the same scenario runs on Linux and Darwin alike.
  ///
  /// An endpoint that puts back any of its files tells its subscribers the database may have
  /// changed entirely, since peers may have left it out of commits made while they were missing.
  @Suite
  struct UnixDatagramRemovedFilesTests {
    private let database = OrbitDatabaseIdentifier(rawValue: "cleaned")
    private let items = OrbitDatabaseRegion(table: "items")

    /// What a repair tells the endpoint's subscribers.
    private var notice: OrbitIPCMessage {
      .transactionDidCommit(.init(databaseIdentifier: self.database, region: .fullDatabase))
    }

    @Test
    func anIdleEndpointWhoseFilesTheCleanerRemovesPutsThemBackAndKeepsReceiving() async throws {
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try ipcTransport(directory)
      let recorder = IPCMessageRecorder()
      let subscription = try receiver.subscribe(
        to: self.database,
        region: self.items,
        onMessage: recorder.append
      )
      let sender = try ipcTransport(directory)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)
      // Connected to the receiver's socket before it is replaced, so the sender has to find out
      // it is gone and connect to the new one.
      try await sender.send(columnCommit(self.database, 0))
      try await recorder.waitForCount(1)

      files.removeAsTheCleanerWould()

      // Under the same name, so at the same paths.
      try await waitUntil { files.isRestored(advertising: self.items) }
      let later = columnCommit(self.database, 1)
      try await sender.send(later)
      try await waitUntil { recorder.values.contains(later) }
      // The cleaner's removals can land on either side of a repair, so it may take more than one,
      // and each tells the subscriber. The last one's notice comes before anything sent after it.
      let values = recorder.values
      #expect(values.first == columnCommit(self.database, 0))
      #expect(values.last == later)
      let notices = values.dropFirst().dropLast()
      #expect(!notices.isEmpty && notices.allSatisfy { $0 == self.notice })
      _ = subscription
    }

    @Test
    func anEndpointWhoseFilesAreRemovedTwiceClosesItsFirstSocketAndItsPeersFollowIt() async throws {
      // The socket a repair replaces is still read, for the peers connected to it, until the next
      // repair closes it. A peer connected to it then finds it gone and connects to the path.
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try ipcTransport(directory)
      let recorder = IPCMessageRecorder()
      let subscription = try receiver.subscribe(to: self.database, onMessage: recorder.append)
      let sender = try ipcTransport(directory)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)
      try await sender.send(columnCommit(self.database, 0))
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
      let second = columnCommit(self.database, 1)
      try await sender.send(second)
      try await waitUntil { recorder.values.contains(second) }

      files.removeAsTheCleanerWould()
      try await waitUntil { files.isRestored(advertising: .fullDatabase) }
      try await waitUntil { first.send([0]) == .peerGone }
      let third = columnCommit(self.database, 2)
      try await sender.send(third)
      try await waitUntil { recorder.values.contains(third) }

      // Each removal told the subscriber at least once, before the commit sent after its repair.
      let values = recorder.values
      #expect(
        values.filter { $0 != self.notice }
          == (0..<3).map { columnCommit(self.database, $0) }
      )
      let secondIndex = try #require(values.firstIndex(of: second))
      #expect(values[1] == self.notice)
      #expect(values[secondIndex + 1] == self.notice)
      #expect(values.last == third)
      _ = subscription
    }

    @Test
    func aSuspendedEndpointOwedRegionsPutsItsFilesBackAndIsSentWhatItMissed() async throws {
      // The receiver's thread is held in its handler, as a suspended process's is, so it can do
      // nothing about its files until it runs again, and the sender owes it what did not fit.
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try HeldReceiver(directory: directory, database: self.database)
      let sender = try ipcTransport(directory)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)

      let (queued, first) = try await receiver.fill(from: sender)
      var owed = first
      for index in 10_000..<10_003 {
        try await sender.send(columnCommit(self.database, index))
        owed.formUnion(itemsColumn(index))
      }
      #expect(Array(sender.owedRegions.values) == [[self.database: owed]])

      files.removeAsTheCleanerWould()
      receiver.resume()

      try await waitUntil { files.isRestored(advertising: .fullDatabase) }
      try await waitUntil { sender.owedRegions.isEmpty }
      // The union of every region it missed, as one commit, which the sender sends to the socket
      // it is connected to, and the notice of the repair, in whichever order they land.
      let missed = OrbitIPCMessage.transactionDidCommit(
        .init(databaseIdentifier: self.database, region: owed)
      )
      try await waitUntil {
        let values = receiver.recorder.values
        return values.contains(missed) && values.contains(self.notice)
      }
      let later = columnCommit(self.database, 20_000)
      try await sender.send(later)
      try await waitUntil { receiver.recorder.values.contains(later) }
      // Everything its queue held first.
      let values = receiver.recorder.values
      #expect(Array(values.prefix(queued.count)) == queued)
      let rest = values.dropFirst(queued.count)
      #expect(rest.filter { $0 != self.notice } == [missed, later])
      #expect(rest.last == later)
    }

    @Test
    func aSuspendedEndpointASenderStoppedOwingWhileItsMarkerWasMissingIsToldItMayHaveChanged()
      async throws
    {
      // A commit made while the receiver's marker is missing finds no one to send to, and the
      // sender drops what it owed the receiver, so the receiver can only learn of either from
      // the notice its repair gives its subscribers.
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try HeldReceiver(directory: directory, database: self.database)
      let sender = try ipcTransport(directory)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)

      // The commit that found the queue full is owed, unless the sender's thread finds room for it
      // before the files go.
      let (queued, owedRegion) = try await receiver.fill(from: sender)
      let owed = commit(self.database, region: owedRegion)

      files.removeAsTheCleanerWould()
      let unseen = columnCommit(self.database, 10_000)
      #expect(try sender.peers(concernedWith: unseen).isEmpty)
      try await sender.send(unseen)
      #expect(sender.owedRegions.isEmpty)

      receiver.resume()
      try await waitUntil { files.isRestored(advertising: .fullDatabase) }
      let later = columnCommit(self.database, 20_000)
      try await sender.send(later)
      try await waitUntil { receiver.recorder.values.contains(later) }
      // Its queue is read to the end before the thread hears its files were removed.
      let values = receiver.recorder.values
      #expect(
        values == queued + [self.notice, later] || values == queued + [owed, self.notice, later]
      )
    }

    @Test
    func anEndpointASenderTookForDeadWhileItsSocketWasMissingPutsBackWhatWasPruned() async throws {
      // The receiver's thread is held until the sender has pruned it, so the order is certain.
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try HeldReceiver(directory: directory, database: self.database)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)
      let first = columnCommit(self.database, 0)
      try await ipcTransport(directory).send(first)
      try await receiver.recorder.waitForCount(1)

      // Started first, so its sweep of the coordination directory runs before anything is missing.
      let sender = try ipcTransport(directory)
      _ = UnixPlatform.removeFile(atPath: files.socketPath)
      // It has never connected to the receiver, so it finds nothing at the path and prunes it.
      #expect(try sender.peers(concernedWith: first).count == 1)
      try await sender.send(columnCommit(self.database, 1))
      #expect(!FileManager.default.fileExists(atPath: files.marker.path))
      #expect(try sender.peers(concernedWith: first).isEmpty)

      receiver.resume()
      try await waitUntil { files.isRestored(advertising: .fullDatabase) }
      let later = columnCommit(self.database, 2)
      try await sender.send(later)
      try await waitUntil { receiver.recorder.values.contains(later) }
      // The commit the sender made while it took the receiver for dead only shows as the notice.
      #expect(receiver.recorder.values == [first, self.notice, later])
    }

    @Test
    func aChangeBesideAnEndpointsFilesTellsItsSubscribersNothing() async throws {
      // Other endpoints' files coming and going in the directories the endpoint watches set off a
      // look at its own, which finds nothing to put back.
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try ipcTransport(directory)
      let recorder = IPCMessageRecorder()
      let subscription = try receiver.subscribe(to: self.database, onMessage: recorder.append)

      // A socket in `v1/s/` and a marker beside the receiver's, which go again once it is released.
      do {
        let other = try ipcTransport(directory)
        let otherSubscription = try other.subscribe(to: self.database) { _ in }
        _ = otherSubscription
      }
      let sender = try ipcTransport(directory)
      try await Task.sleep(for: .milliseconds(200))
      let commit = columnCommit(self.database, 0)
      try await sender.send(commit)
      try await recorder.waitForCount(1)
      try await Task.sleep(for: .milliseconds(200))

      #expect(recorder.values == [commit])
      #expect(receiver.repairCount == 0)
      _ = subscription
    }

    @Test
    func aRepairSettlesRatherThanSettingOffAnother() async throws {
      // A repair's own writes land in the directories it watches. Each file removed is put back
      // once, and the socket bound in its place stays.
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try ipcTransport(directory)
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

    @Test
    func anEndpointInUseTouchesItsFilesSoTheCleanerLeavesThemAlone() async throws {
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try UnixDatagramIPCTransport(
        configuration: .init(directory: directory),
        refreshInterval: .zero
      )
      let recorder = IPCMessageRecorder()
      let subscription = try receiver.subscribe(to: self.database, onMessage: recorder.append)
      let sender = try ipcTransport(directory)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)

      // A send, which has no peer to go to.
      try files.backdate()
      try await receiver.send(columnCommit(self.database, 0))
      #expect(try files.areTouched)

      // A receive.
      try files.backdate()
      try await sender.send(columnCommit(self.database, 1))
      try await recorder.waitForCount(1)
      #expect(try files.areTouched)
      _ = subscription
    }

    @Test
    func anEndpointLeavesItsFilesAloneUntilItsRefreshIntervalHasPassed() async throws {
      let directory = try makeShortTemporaryDirectory("cleaner")
      defer { try? FileManager.default.removeItem(at: directory) }
      let receiver = try ipcTransport(directory)
      let recorder = IPCMessageRecorder()
      let subscription = try receiver.subscribe(to: self.database, onMessage: recorder.append)
      let sender = try ipcTransport(directory)
      let files = try UnixDatagramEndpointFiles(advertising: self.database, in: directory)

      try files.backdate()
      try await receiver.send(columnCommit(self.database, 0))
      try await sender.send(columnCommit(self.database, 1))
      try await recorder.waitForCount(1)

      #expect(try files.areBackdated)
      _ = subscription
    }
  }

  /// The files one endpoint keeps in a coordination directory: its socket's path, and its marker
  /// for one database, which is the only marker there.
  struct UnixDatagramEndpointFiles {
    let socketPath: String
    let marker: URL
    private let directory: URL

    /// How far into the past ``backdate()`` sets each file's modification date.
    private static let age: TimeInterval = 10 * 24 * 60 * 60

    init(advertising database: OrbitDatabaseIdentifier, in directory: URL) throws {
      let markers = directory.appending(path: "v1/d/\(database.coordinationKey)")
      let names = try FileManager.default.contentsOfDirectory(atPath: markers.path)
        .filter { !$0.hasPrefix(".") }
      try #require(names.count == 1)
      self.socketPath = directory.appending(path: "v1/s/\(names[0]).sock").path
      self.marker = markers.appending(path: names[0])
      self.directory = directory
    }

    /// The socket's file and the marker, and the directories they are in.
    private var paths: [String] {
      [
        self.socketPath,
        URL(fileURLWithPath: self.socketPath).deletingLastPathComponent().path,
        self.marker.path,
        self.marker.deletingLastPathComponent().path
      ]
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

    /// Sets every file's modification date well into the past, as though nothing had used them
    /// for days.
    func backdate() throws {
      let date = Date(timeIntervalSinceNow: -Self.age)
      for path in self.paths {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
      }
    }

    /// Whether every file was touched since ``backdate()``.
    var areTouched: Bool {
      get throws {
        try self.modificationDates.allSatisfy { $0 > Date(timeIntervalSinceNow: -60 * 60) }
      }
    }

    /// Whether every file is as old as ``backdate()`` left it.
    var areBackdated: Bool {
      get throws {
        try self.modificationDates.allSatisfy {
          $0 < Date(timeIntervalSinceNow: -Self.age + 60 * 60)
        }
      }
    }

    private var modificationDates: [Date] {
      get throws {
        try self.paths.map { path in
          try #require(
            try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
          )
        }
      }
    }
  }

#endif
