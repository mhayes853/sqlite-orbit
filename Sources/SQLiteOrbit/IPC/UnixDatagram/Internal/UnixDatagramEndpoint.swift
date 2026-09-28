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
  /// and reports the ones it finds dead rather than removing anything of theirs, those a send finds
  /// to the send's caller and those its thread finds to the callback it was started with.
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
      var stale: [UnixDatagramPeer] = []
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
    /// - Parameters:
    ///   - receive: Receives each datagram no longer than the maximum, on the endpoint's thread.
    ///     The bytes are only valid for the duration of the call.
    ///   - onStalePeer: Receives each peer the thread finds dead while sending it what it is owed,
    ///     once the endpoint has forgotten it, on the endpoint's thread and without its lock held.
    func start(
      receive: @escaping @Sendable (Span<UInt8>) -> Void,
      onStalePeer: @escaping @Sendable (UnixDatagramPeer) -> Void
    ) {
      DetachedThread.spawn(name: "Orbit IPC") {
        self.run(receive: receive, onStalePeer: onStalePeer)
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

      return self.state.withLock { state in
        self.retain(advertisers, advertising: coordinationKey, in: &state)
        var delivery = Delivery(peerCount: peers.count)
        for peer in peers {
          self.offer(
            datagram,
            entry,
            to: peer,
            coordinationKey: coordinationKey,
            in: &state,
            counting: &delivery
          )
        }
        return delivery
      }
    }

    // MARK: - Sending

    /// Sends `datagram` to a peer, or makes it owe `entry`'s region, and counts which in
    /// `delivery`.
    private func offer(
      _ datagram: [UInt8],
      _ entry: UnixDatagramWireEntry,
      to peer: UnixDatagramPeer,
      coordinationKey: String,
      in state: inout State,
      counting delivery: inout Delivery
    ) {
      let name = peer.endpointName
      let known: Peer
      if let existing = state.peers[name] {
        known = existing
      } else {
        do {
          guard let socket = try UnixDatagramSocket.connect(to: peer.socketPath) else {
            delivery.stale.append(peer)
            return
          }
          known = Peer(peer: peer, socket: socket)
          state.peers[name] = known
        } catch {
          delivery.failed += 1
          return
        }
      }
      known.coordinationKeys.insert(coordinationKey)

      // A peer that is owed anything is not sent to until it has taken what it is owed, so the
      // message joins that rather than overtaking it.
      if known.owed.isEmpty {
        switch known.socket.send(datagram) {
        case .sent:
          delivery.delivered += 1
          return
        case .full:
          known.isWatched = self.queue.watchWritable(known.socket.descriptor.rawValue)
          known.backOff()
          // The thread waits on a deadline it worked out before this peer owed anything.
          self.queue.wake()
        case .peerGone:
          delivery.stale.append(self.forget(name, in: &state))
          return
        case .failed:
          delivery.failed += 1
          return
        }
      }
      switch entry.message {
      case .transactionDidCommit(let commit):
        known.owed[commit.databaseIdentifier, default: .empty].formUnion(commit.region)
      }
      delivery.deferred += 1
    }

    /// Sends a peer what it is owed, one commit per database in as few datagrams as fit them, until
    /// the peer has no room or is owed nothing.
    ///
    /// A peer this finds dead is forgotten, along with what it was owed.
    ///
    /// - Returns: The peer, if this found it dead.
    private func flush(_ name: String, in state: inout State) -> UnixDatagramPeer? {
      guard let peer = state.peers[name], !peer.owed.isEmpty else { return nil }
      var entries =
        peer.owed
        .sorted { $0.key.rawValue < $1.key.rawValue }
        .compactMap { database, region in
          // A region too large for a datagram of its own is broadened to the full database, which
          // always fits: the commit that made the peer owe anything fitted, and its region was no
          // smaller.
          try? UnixDatagramWireEntry(
            .transactionDidCommit(.init(databaseIdentifier: database, region: region)),
            fittingIn: self.maximumDatagramByteCount
          )
        }[...]
      while !entries.isEmpty {
        // The longest run from the front that fits, which always holds at least the first.
        var batch = UnixDatagramWireBatch()
        for entry in entries {
          guard batch.byteCount(appending: entry) <= self.maximumDatagramByteCount else { break }
          batch.append(entry)
        }

        switch peer.socket.send(batch.encoded()) {
        case .sent:
          peer.retryDelay = .milliseconds(1)
        case .full:
          peer.backOff()
          return nil
        case .peerGone:
          return self.forget(name, in: &state)
        case .failed:
          // Nothing about a datagram that failed this way changes on another attempt, so what it
          // held is dropped rather than attempted forever.
          break
        }
        for entry in batch.entries {
          peer.owed[entry.message.databaseIdentifier] = nil
        }
        entries.removeFirst(batch.entries.count)
      }
      peer.owed.removeAll()
      self.unwatch(peer)
      return nil
    }

    private func unwatch(_ peer: Peer) {
      if peer.isWatched {
        self.queue.unwatchWritable(peer.socket.descriptor.rawValue)
      }
      peer.isWatched = false
      peer.retryAt = nil
      peer.retryDelay = .milliseconds(1)
    }

    /// Closes the socket kept for a peer, and drops what it is owed.
    ///
    /// - Returns: The peer.
    private func forget(_ name: String, in state: inout State) -> UnixDatagramPeer {
      // Its socket closes once nothing holds the peer any more, which is before the lock is let go.
      let peer = state.peers.removeValue(forKey: name)!
      self.unwatch(peer)
      return peer.peer
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
        peer.coordinationKeys.remove(coordinationKey)
        peer.owed = peer.owed.filter { $0.key.coordinationKey != coordinationKey }
        if peer.coordinationKeys.isEmpty {
          // Not reported as dead: it withdrew its own advertisements.
          _ = self.forget(name, in: &state)
        } else if peer.owed.isEmpty {
          self.unwatch(peer)
        }
      }
    }

    // MARK: - The Thread

    private func run(receive: (Span<UInt8>) -> Void, onStalePeer: (UnixDatagramPeer) -> Void) {
      // Every datagram lands in this one buffer, which only this thread touches. It is a byte
      // longer than any datagram the transport accepts, so one that fills it was too long.
      let buffer = UnsafeMutableBufferPointer<UInt8>
        .allocate(
          capacity: self.maximumDatagramByteCount + 1
        )
      defer { buffer.deallocate() }
      while true {
        let (isStopped, deadline) = self.state.withLock {
          ($0.isStopped, $0.peers.values.lazy.compactMap(\.retryAt).min())
        }
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
        // Flushes the peers that have room or are due another attempt. An event for a socket
        // closed since can name a new one given the same number, which at worst attempts that
        // peer a little early.
        let stale = self.state.withLock { state in
          let now = ContinuousClock.now
          let due = state.peers.filter { _, peer in
            writable.contains(peer.socket.descriptor.rawValue)
              || peer.retryAt.map({ $0 <= now }) == true
          }
          return due.keys.compactMap { self.flush($0, in: &state) }
        }
        for peer in stale {
          onStalePeer(peer)
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

    // MARK: - State

    /// A peer this endpoint keeps a connected socket for.
    ///
    /// It is a class because its socket cannot be copied, and a dictionary holds only values that
    /// can. It is only touched while holding the endpoint's lock, which is what makes it safe to
    /// send.
    private final class Peer: @unchecked Sendable {
      let peer: UnixDatagramPeer
      let socket: UnixDatagramSocket
      /// The databases this peer was last seen advertising, by coordination key.
      var coordinationKeys: Set<String> = []
      /// The union of the regions of every commit this peer has not taken yet, by database.
      var owed: [OrbitDatabaseIdentifier: OrbitDatabaseRegion] = [:]
      var isWatched = false
      var retryAt: ContinuousClock.Instant?
      var retryDelay = Duration.milliseconds(1)

      init(peer: UnixDatagramPeer, socket: consuming UnixDatagramSocket) {
        self.peer = peer
        self.socket = socket
      }

      /// Schedules the next attempt at a peer the queue cannot say has room.
      func backOff() {
        guard !self.isWatched else { return }
        self.retryAt = .now.advanced(by: self.retryDelay)
        self.retryDelay = min(self.retryDelay * 2, UnixDatagramEndpoint.maximumRetryDelay)
      }
    }

    private struct State {
      var isStopped = false
      var peers: [String: Peer] = [:]
    }
  }
#endif
