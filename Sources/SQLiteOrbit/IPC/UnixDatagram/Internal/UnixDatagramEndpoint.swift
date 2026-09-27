#if canImport(Darwin) || os(Linux) || os(Android)
  /// The socket a transport receives on, the sockets it sends to each peer on, and the thread that
  /// waits on them.
  ///
  /// A send never waits. A peer whose receive queue is full is owed the message's region instead:
  /// the regions of every commit it could not take are merged, one region per database, and a
  /// later commit to a peer that is owed anything joins what it is owed without being attempted,
  /// so nothing reaches the peer ahead of what it missed. Once the peer has room, which Linux
  /// reports and Darwin is polled for on a backoff, the thread sends it one commit per database it
  /// is owed, in as few datagrams as fit them. What a peer is owed has no deadline. It goes when it
  /// is sent, when the peer turns out to be dead, or when the peer stops advertising the database.
  ///
  /// The endpoint knows nothing of the coordination directory: it is told which peers to send to,
  /// and reports the ones a send finds dead rather than removing anything of theirs. One the thread
  /// finds dead is only dropped, and the next send to it finds it dead in turn.
  ///
  /// The receive thread keeps the endpoint alive for as long as it runs, and ``stop()`` is what
  /// ends it. Whichever of its owner and the thread lets go of the endpoint last closes its
  /// descriptors, so nothing is still waiting on one when it closes, and an owner released on the
  /// receive thread itself has nothing to wait for.
  final class UnixDatagramEndpoint: Sendable {
    /// What became of a message at the peers it was sent to.
    struct Delivery: Sendable {
      /// How many peers the message was sent to.
      var peerCount = 0

      /// How many peers took the message.
      var delivered = 0

      /// How many peers had no room for the message, and are owed its region instead.
      var deferred = 0

      /// How many live peers the message could not be sent to at all.
      var failed = 0

      /// The peers that turned out to be dead, which are counted in none of the above.
      var stale: [StalePeer] = []
    }

    /// A peer that turned out to be dead, and the databases this endpoint had seen it advertise.
    struct StalePeer: Sendable {
      let peer: UnixDatagramPeer
      let coordinationKeys: Set<String>
    }

    /// The longest a peer the queue cannot say has room waits between attempts.
    ///
    /// A peer may be owed something for as long as it does not read, as a suspended app does not,
    /// so the attempts back off until they cost next to nothing.
    static let maximumRetryDelay = Duration.seconds(1)

    private let maximumDatagramByteCount: Int
    private let socket: UnixDatagramSocket
    private let queue: UnixEventQueue
    private let state = Lock(State())

    /// Binds a socket at `socketPath`.
    ///
    /// - Parameters:
    ///   - socketPath: Where to bind the socket, which is where peers send to.
    ///   - maximumDatagramByteCount: The longest datagram to send or accept.
    ///   - receiveBufferByteCount: The size of the socket's receive buffer.
    /// - Throws: A ``UnixSystemError`` if the socket cannot be created and bound.
    init(
      socketPath: String,
      maximumDatagramByteCount: Int,
      receiveBufferByteCount: Int
    ) throws {
      let socket = try UnixDatagramSocket.bind(
        path: socketPath,
        receiveBufferByteCount: receiveBufferByteCount
      )
      let queue: UnixEventQueue
      do {
        queue = try UnixEventQueue()
        try queue.watchReadable(socket.descriptor.rawValue)
      } catch {
        _ = UnixPlatform.removeFile(atPath: socketPath)
        throw error
      }
      self.maximumDatagramByteCount = maximumDatagramByteCount
      self.socket = socket
      self.queue = queue
    }

    /// Starts the thread that receives on this endpoint and sends peers what they are owed, which
    /// runs until ``stop()``.
    ///
    /// - Parameter receive: Receives each datagram no longer than the maximum, on the endpoint's
    ///   thread. The bytes are only valid for the duration of the call.
    func start(receive: @escaping @Sendable (Span<UInt8>) -> Void) {
      DetachedThread.spawn(name: "Orbit IPC") {
        self.run(receive: receive)
      }
    }

    /// Ends the receive thread, which lets go of the endpoint once it has woken.
    ///
    /// This does not wait for the thread, so it is safe to call from the thread itself.
    func stop() {
      self.state.withLock { $0.isStopped = true }
      self.queue.wake()
    }

    /// What each peer is owed, by endpoint name, leaving out the peers that are owed nothing.
    var owedRegions: [String: [OrbitDatabaseIdentifier: OrbitDatabaseRegion]] {
      self.state.withLock { state in
        state.peers.compactMapValues { $0.owed.isEmpty ? nil : $0.owed }
      }
    }

    /// Sends `entry` to every peer in `peers`, on the connected socket kept for each.
    ///
    /// - Parameters:
    ///   - entry: The message to send.
    ///   - peers: The peers to send it to.
    ///   - advertisers: Every endpoint advertising the message's database now, by name, whether or
    ///     not the message concerns it. What any others that were seen with the database are owed
    ///     for it is dropped, and the sockets kept for those that advertise nothing else this
    ///     endpoint has seen them with are closed.
    /// - Returns: How many peers took the message, how many are owed it, how many it could not be
    ///   sent to at all, and which were dead.
    func send(
      _ entry: UnixDatagramWireEntry,
      to peers: [UnixDatagramPeer],
      advertisedBy advertisers: some Collection<String>
    ) -> Delivery {
      let coordinationKey = entry.message.databaseIdentifier.coordinationKey
      var single = UnixDatagramWireBatch()
      single.append(entry)
      let datagram = single.encoded()

      let (delivery, startedOwing) = self.state.withLock { state in
        self.retain(advertisers, advertising: coordinationKey, in: &state)
        var delivery = Delivery(peerCount: peers.count)
        var startedOwing = false
        for peer in peers {
          switch self.offer(datagram, entry, to: peer, coordinationKey: coordinationKey, in: &state)
          {
          case .delivered:
            delivery.delivered += 1
          case .deferred(let startsOwing):
            delivery.deferred += 1
            startedOwing = startedOwing || startsOwing
          case .failed:
            delivery.failed += 1
          case .stale(let peer):
            delivery.stale.append(peer)
          }
        }
        return (delivery, startedOwing)
      }
      if startedOwing {
        // The thread waits on a deadline it worked out before this peer owed anything.
        self.queue.wake()
      }
      return delivery
    }

    // MARK: - Sending

    private enum Offer {
      case delivered
      /// The peer is owed the message's region, and the payload says whether it owed nothing
      /// before.
      case deferred(Bool)
      case failed
      case stale(StalePeer)
    }

    private func offer(
      _ datagram: [UInt8],
      _ entry: UnixDatagramWireEntry,
      to peer: UnixDatagramPeer,
      coordinationKey: String,
      in state: inout State
    ) -> Offer {
      let name = peer.endpointName
      if state.peers[name] == nil {
        do {
          guard let socket = try UnixDatagramSocket.connect(to: peer.socketPath) else {
            return .stale(StalePeer(peer: peer, coordinationKeys: [coordinationKey]))
          }
          state.peers[name] = Peer(peer: peer, socket: socket)
        } catch {
          return .failed
        }
      }
      state.peers[name]!.coordinationKeys.insert(coordinationKey)

      // A peer that is owed anything is not sent to until it has taken what it is owed, so the
      // message joins that rather than overtaking it.
      let startsOwing = state.peers[name]!.owed.isEmpty
      if startsOwing {
        switch state.peers[name]!.socket.send(datagram) {
        case .sent:
          return .delivered
        case .full:
          break
        case .peerGone:
          return .stale(self.forget(name, in: &state))
        case .failed:
          return .failed
        }
      }
      switch entry.message {
      case .transactionDidCommit(let commit):
        state.peers[name]!.owed[commit.databaseIdentifier, default: .empty]
          .formUnion(commit.region)
      }
      if startsOwing {
        state.peers[name]!.isWatched = self.queue.watchWritable(
          state.peers[name]!.socket.descriptor.rawValue
        )
        state.peers[name]!.backOff()
      }
      return .deferred(startsOwing)
    }

    /// Sends a peer what it is owed, one commit per database in as few datagrams as fit them, until
    /// the peer has no room or is owed nothing.
    ///
    /// A peer this finds dead is dropped, along with what it was owed.
    private func flush(_ name: String, in state: inout State) {
      guard let peer = state.peers[name], !peer.owed.isEmpty else { return }
      let owed = peer.owed
        .sorted { $0.key.rawValue < $1.key.rawValue }
        .compactMap { database, region in
          // A region too large for a datagram of its own is broadened to the full database, which
          // always fits: the commit that made the peer owe anything fitted, and its region was no
          // smaller.
          try? UnixDatagramWireEntry(
            .transactionDidCommit(.init(databaseIdentifier: database, region: region)),
            fittingIn: self.maximumDatagramByteCount
          )
        }
      var entries = owed[...]
      while !entries.isEmpty {
        // The longest run from the front that fits, which always holds at least the first.
        var batch = UnixDatagramWireBatch()
        for entry in entries {
          guard batch.byteCount(appending: entry) <= self.maximumDatagramByteCount else { break }
          batch.append(entry)
        }

        switch peer.socket.send(batch.encoded()) {
        case .sent:
          state.peers[name]!.retryDelay = .milliseconds(1)
        case .full:
          state.peers[name]!.backOff()
          return
        case .peerGone:
          _ = self.forget(name, in: &state)
          return
        case .failed:
          // Nothing about a datagram that failed this way changes on another attempt, so what it
          // held is dropped rather than attempted forever.
          break
        }
        for entry in batch.entries {
          state.peers[name]!.owed[entry.message.databaseIdentifier] = nil
        }
        entries.removeFirst(batch.entries.count)
      }
      state.peers[name]!.owed.removeAll()
      self.unwatch(name, in: &state)
    }

    private func unwatch(_ name: String, in state: inout State) {
      guard let peer = state.peers[name] else { return }
      if peer.isWatched {
        self.queue.unwatchWritable(peer.socket.descriptor.rawValue)
      }
      state.peers[name]!.isWatched = false
      state.peers[name]!.retryAt = nil
      state.peers[name]!.retryDelay = .milliseconds(1)
    }

    /// Closes the socket kept for a peer, and drops what it is owed.
    ///
    /// - Returns: The peer, with the databases it was seen advertising.
    private func forget(_ name: String, in state: inout State) -> StalePeer {
      self.unwatch(name, in: &state)
      // Its socket closes when this goes, at the end of the call.
      let peer = state.peers.removeValue(forKey: name)!
      return StalePeer(peer: peer.peer, coordinationKeys: peer.coordinationKeys)
    }

    /// Drops what the peers that stopped advertising `coordinationKey` are owed for it, and closes
    /// the sockets kept for those that advertise nothing else this endpoint has seen them with.
    private func retain(
      _ advertisers: some Collection<String>,
      advertising coordinationKey: String,
      in state: inout State
    ) {
      let advertised = Set(advertisers)
      for (name, peer) in state.peers
      where peer.coordinationKeys.contains(coordinationKey) && !advertised.contains(name) {
        state.peers[name]!.coordinationKeys.remove(coordinationKey)
        state.peers[name]!.owed = peer.owed.filter { $0.key.coordinationKey != coordinationKey }
        if state.peers[name]!.coordinationKeys.isEmpty {
          // Not reported as dead: it withdrew its own advertisements.
          _ = self.forget(name, in: &state)
        } else if state.peers[name]!.owed.isEmpty {
          self.unwatch(name, in: &state)
        }
      }
    }

    // MARK: - The Thread

    private func run(receive: (Span<UInt8>) -> Void) {
      // Every datagram lands in this one buffer, which only this thread touches. It is a byte
      // longer than any datagram the transport accepts, so one that fills it was too long.
      let capacity = self.maximumDatagramByteCount + 1
      let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: capacity)
      defer { buffer.deallocate() }
      while true {
        let (isStopped, deadline) = self.state.withLock { ($0.isStopped, $0.nextRetry) }
        guard !isStopped else { return }
        var writable: [Int32] = []
        self.queue.wait(until: deadline) { event in
          switch event {
          case .readable:
            self.drain(into: buffer, receive: receive)
          case .writable(let descriptor):
            writable.append(descriptor)
          }
        }
        self.state.withLock { state in
          self.service(writable, in: &state)
        }
      }
    }

    private func drain(
      into buffer: UnsafeMutableBufferPointer<UInt8>,
      receive: (Span<UInt8>) -> Void
    ) {
      while !self.state.withLock({ $0.isStopped }),
        let count = self.socket.receive(into: buffer)
      {
        guard count <= self.maximumDatagramByteCount else { continue }
        receive(Span(_unsafeElements: UnsafeBufferPointer(rebasing: buffer[..<count])))
      }
    }

    /// Flushes the peers that have room or are due another attempt.
    private func service(_ writable: [Int32], in state: inout State) {
      let now = ContinuousClock.now
      // An event for a socket closed since can name a new one given the same number, which at
      // worst attempts that peer a little early.
      for (name, peer) in state.peers
      where writable.contains(peer.socket.descriptor.rawValue)
        || peer.retryAt.map({ $0 <= now }) == true
      {
        self.flush(name, in: &state)
      }
    }

    // MARK: - State

    private struct Peer {
      let peer: UnixDatagramPeer
      let socket: UnixDatagramSocket
      /// The databases this peer was last seen advertising, by coordination key.
      var coordinationKeys: Set<String> = []
      /// The union of the regions of every commit this peer has not taken yet, by database.
      var owed: [OrbitDatabaseIdentifier: OrbitDatabaseRegion] = [:]
      var isWatched = false
      var retryAt: ContinuousClock.Instant?
      var retryDelay = Duration.milliseconds(1)

      /// Schedules the next attempt at a peer the queue cannot say has room.
      mutating func backOff() {
        guard !self.isWatched else { return }
        self.retryAt = .now.advanced(by: self.retryDelay)
        self.retryDelay = min(self.retryDelay * 2, UnixDatagramEndpoint.maximumRetryDelay)
      }
    }

    private struct State {
      var isStopped = false
      var peers: [String: Peer] = [:]

      /// When the thread next has something to do without being woken.
      var nextRetry: ContinuousClock.Instant? {
        self.peers.values.lazy.compactMap(\.retryAt).min()
      }
    }
  }
#endif
