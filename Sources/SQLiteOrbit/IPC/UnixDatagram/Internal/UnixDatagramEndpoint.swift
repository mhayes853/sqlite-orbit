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
  /// A peer is dead once nothing is bound at its socket's path. A connected socket that reports its
  /// peer gone only shows that the socket it was connected to closed, and the peer may have bound a
  /// new one at the same path since, so the path is connected to again before the peer is taken
  /// for dead. If that connects, the new socket replaces the old one, the peer keeps everything it
  /// is owed, and what was being sent is sent on the new socket, once.
  ///
  /// The endpoint knows nothing of the coordination directory: it is told which peers to send to,
  /// and reports the ones it finds dead rather than removing anything of theirs, those a send finds
  /// to the send's caller and those its thread finds to the callback it was started with. Its
  /// thread also waits on a descriptor its owner gives it, which says that something its owner
  /// watches has changed, and calls its owner back, so its owner can repair its files on a thread
  /// that is waiting anyway rather than one of its own. Its owner can ask to be called back all
  /// the same, to finish on that thread what it did on another.
  ///
  /// The socket can be bound again at the same path, if its file is removed from under it. The
  /// new socket takes the old one's place at the path, where every peer that connects from then
  /// on finds it, and the old one is still read, for the peers connected to it, until the socket
  /// is bound again or the endpoint stops. Closing it at once would lose any datagram a peer sent
  /// it between the thread reading it for the last time and closing it. Kept, it loses nothing,
  /// and costs one descriptor. A socket replaced a second time is read to the end and closed, and
  /// a peer still connected to it finds it gone, connects to the path again, and keeps what it is
  /// owed.
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

    private let socketPath: String
    private let maximumDatagramByteCount: Int
    private let receiveBufferByteCount: Int
    private let queue: UnixEventQueue
    private let state: Lock<State>

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
        FileSystem.removeFile(atPath: FilePath(socketPath))
        throw error
      }
      self.socketPath = socketPath
      self.maximumDatagramByteCount = maximumDatagramByteCount
      self.receiveBufferByteCount = receiveBufferByteCount
      self.queue = queue
      self.state = Lock(State(socket: BoundSocket(socket)))
    }

    /// Starts the thread that receives on this endpoint and sends peers what they are owed, which
    /// runs until ``stop()``.
    ///
    /// - Parameters:
    ///   - receive: Receives each datagram no longer than the maximum, on the endpoint's thread.
    ///     The bytes are only valid for the duration of the call.
    ///   - onStalePeer: Receives each peer the thread finds dead while sending it what it is owed,
    ///     once the endpoint has forgotten it, on the endpoint's thread and without its lock held.
    ///   - onChange: Called on the endpoint's thread, without its lock held, whenever the
    ///     descriptor given to ``waitForChanges(on:)`` is readable, and once after each
    ///     ``requestChange()``. It is what drains that descriptor.
    func start(
      receive: @escaping @Sendable (Span<UInt8>) -> Void,
      onStalePeer: @escaping @Sendable (UnixDatagramPeer) -> Void,
      onChange: @escaping @Sendable () -> Void
    ) {
      DetachedThread.spawn(name: "Orbit IPC") {
        self.run(receive: receive, onStalePeer: onStalePeer, onChange: onChange)
      }
    }

    /// Makes the thread wait on `descriptor` too, in place of whatever descriptor it waited on
    /// before, and call the `onChange` it was started with whenever it is readable.
    ///
    /// - Parameter descriptor: The descriptor to wait on, which must stay open until another one
    ///   replaces it, or `nil` to wait on none.
    /// - Throws: A ``UnixSystemError`` if the thread cannot wait on `descriptor`, in which case it
    ///   still waits on the one it waited on before.
    func waitForChanges(on descriptor: Int32?) throws {
      if let descriptor {
        try self.queue.watchReadable(descriptor)
      }
      let previous = self.state.withLock { state in
        defer { state.changeDescriptor = descriptor }
        return state.changeDescriptor
      }
      if let previous {
        self.queue.unwatchReadable(previous)
      }
    }

    /// Has the thread call the `onChange` it was started with once more, soon, whether or not the
    /// descriptor given to ``waitForChanges(on:)`` is readable.
    ///
    /// This does not wait for the thread, so it is safe to call from any thread, the endpoint's
    /// own included.
    func requestChange() {
      self.state.withLock { $0.isChangeRequested = true }
      self.queue.wake()
    }

    /// The file the socket was bound to, which the socket's path names for as long as nothing
    /// removes or replaces it.
    var boundFile: UnixFileIdentity? {
      self.state.withLock { $0.socket.socket.boundFile }
    }

    /// Binds a new socket at the path the endpoint's socket was bound to, in place of the old
    /// one, which is still read for the peers connected to it until the next time this is called.
    /// The one it replaced before that closes once the thread has read what is queued on it.
    ///
    /// - Throws: A ``UnixSystemError`` if the new socket cannot be created, bound or waited on, in
    ///   which case the endpoint keeps receiving on the old one.
    func rebind() throws {
      let socket = BoundSocket(
        try UnixDatagramSocket.bind(
          path: self.socketPath,
          receiveBufferByteCount: self.receiveBufferByteCount
        )
      )
      try self.queue.watchReadable(socket.socket.descriptor.rawValue)
      let retired = self.state.withLock { state in
        let retired = state.replaced
        state.replaced = state.socket
        state.socket = socket
        if let retired {
          state.retired.append(retired)
        }
        return retired
      }
      guard let retired else { return }
      self.queue.unwatchReadable(retired.socket.descriptor.rawValue)
      // So the thread reads the retired socket to the end, and closes it, without waiting for
      // anything else to wake it.
      self.queue.wake()
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
      return self.state.withLock { state in
        self.retain(advertisers, advertising: coordinationKey, in: &state)
        var delivery = Delivery(peerCount: peers.count)
        for peer in peers {
          let name = peer.endpointName
          // A socket connected just now has already shown that something is bound at the path.
          let isNew = state.peers[name] == nil
          if isNew {
            do {
              guard let socket = try UnixDatagramSocket.connect(to: peer.socketPath) else {
                delivery.stale.append(peer)
                continue
              }
              state.peers[name] = Peer(peer: peer, socket: socket)
            } catch {
              delivery.failed += 1
              continue
            }
          }
          let known = state.peers[name]!
          known.coordinationKeys.insert(coordinationKey)

          // A peer that is owed anything is not sent to until it has taken what it is owed, so the
          // message joins that rather than overtaking it. One that is owed nothing is sent the
          // message as what it is owed, which it is owed still if it has no room.
          let isOwed = !known.owed.isEmpty
          known.addToOwed(entry.message)
          guard !isOwed else {
            delivery.deferred += 1
            continue
          }
          switch self.flush(known, [entry], mayReconnect: !isNew) {
          case .sent:
            delivery.delivered += 1
          case .full:
            delivery.deferred += 1
            // The thread waits on a deadline it worked out before this peer owed anything.
            self.queue.wake()
          case .peerGone:
            delivery.stale.append(self.forget(name, in: &state))
          case .failed:
            delivery.failed += 1
          }
        }
        return delivery
      }
    }

    // MARK: - Sending

    /// Sends a peer `entries`, which is what it is owed, in as few datagrams as fit them, until the
    /// peer has no room or is owed nothing.
    ///
    /// A peer with no room starts waiting for room: the queue reports it where it can, and it is
    /// attempted again on a backoff where it cannot.
    ///
    /// - Parameters:
    ///   - peer: The peer.
    ///   - entries: One commit per database the peer is owed, in the order to send them.
    ///   - mayReconnect: Whether the peer's path may be connected to again if its socket reports
    ///     it gone.
    /// - Returns: What became of the last datagram sent. A peer this finds gone is left for the
    ///   caller to forget.
    private func flush(
      _ peer: Peer,
      _ entries: [UnixDatagramWireEntry],
      mayReconnect: Bool
    ) -> UnixDatagramSocket.SendOutcome {
      var entries = entries[...]
      var mayReconnect = mayReconnect
      var outcome = UnixDatagramSocket.SendOutcome.sent
      while !entries.isEmpty {
        // The longest run from the front that fits, which always holds at least the first.
        var batch = UnixDatagramWireBatch()
        for entry in entries {
          guard batch.byteCount(appending: entry) <= self.maximumDatagramByteCount else { break }
          batch.append(entry)
        }

        outcome = self.send(batch.encoded(), to: peer, mayReconnect: &mayReconnect)
        switch outcome {
        case .sent:
          peer.retryDelay = .milliseconds(1)
        case .full:
          if !peer.isWatched {
            peer.isWatched = self.queue.watchWritable(peer.socket.descriptor.rawValue)
          }
          peer.backOff()
          return outcome
        case .peerGone:
          return outcome
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
      return outcome
    }

    /// One commit per database a peer is owed, in the order of their databases' identifiers.
    private func entries(owedTo peer: Peer) -> [UnixDatagramWireEntry] {
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
        }
    }

    /// Sends `datagram` on the socket kept for `peer`, and if that socket reports the peer gone,
    /// replaces it with a new one connected to the peer's path and sends `datagram` on that.
    ///
    /// - Parameters:
    ///   - datagram: The datagram to send.
    ///   - peer: The peer to send it to.
    ///   - mayReconnect: Whether the peer's path may be connected to again, which this clears once
    ///     it has been, so a send or a flush connects to it at most once.
    /// - Returns: What became of `datagram`. A peer is only gone if nothing is bound at its path,
    ///   or the new socket connected to what is reports it gone too.
    private func send(
      _ datagram: [UInt8],
      to peer: Peer,
      mayReconnect: inout Bool
    ) -> UnixDatagramSocket.SendOutcome {
      let outcome = peer.socket.send(datagram)
      guard outcome == .peerGone, mayReconnect else { return outcome }
      mayReconnect = false
      do {
        guard let socket = try UnixDatagramSocket.connect(to: peer.peer.socketPath) else {
          return .peerGone
        }
        // The queue lets go of the old socket before it closes, and a peer waiting for room
        // waits on the new one instead.
        if peer.isWatched {
          self.queue.unwatchWritable(peer.socket.descriptor.rawValue)
        }
        peer.socket = socket
        if peer.isWatched {
          peer.isWatched = self.queue.watchWritable(peer.socket.descriptor.rawValue)
        }
      } catch let error as UnixSystemError {
        return .failed(error)
      } catch {
        return .failed(.last("connect"))
      }
      return peer.socket.send(datagram)
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

    private func run(
      receive: (Span<UInt8>) -> Void,
      onStalePeer: (UnixDatagramPeer) -> Void,
      onChange: () -> Void
    ) {
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
        var changed = false
        self.queue.wait(until: deadline) { event in
          switch event {
          case .readable(let descriptor):
            // Looked up for each event, since a socket can be bound again while the thread waits.
            // An event for a descriptor no longer waited on at worst drains a socket early.
            let socket = self.state.withLock { state -> BoundSocket? in
              guard state.changeDescriptor != descriptor else { return nil }
              if let replaced = state.replaced, replaced.socket.descriptor.rawValue == descriptor {
                return replaced
              }
              return state.socket
            }
            if let socket {
              self.drain(socket, into: buffer, receive: receive)
            } else {
              changed = true
            }
          case .writable(let descriptor):
            writable.append(descriptor)
          }
        }
        // Taken after the wait, which a request made at any point before it cuts short. A socket
        // retired since the last pass may still have datagrams queued, so it is read to the end
        // before it closes here, and one retired by `onChange` is read on the pass its wake starts.
        let (isChangeRequested, retired) = self.state.withLock { state in
          defer {
            state.isChangeRequested = false
            state.retired.removeAll()
          }
          return (state.isChangeRequested, state.retired)
        }
        if changed || isChangeRequested {
          onChange()
        }
        for socket in retired {
          self.drain(socket, into: buffer, receive: receive)
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
          return due.compactMap { name, peer in
            let outcome = self.flush(peer, self.entries(owedTo: peer), mayReconnect: true)
            return outcome == .peerGone ? self.forget(name, in: &state) : nil
          }
        }
        for peer in stale {
          onStalePeer(peer)
        }
      }
    }

    private func drain(
      _ socket: BoundSocket,
      into buffer: UnsafeMutableBufferPointer<UInt8>,
      receive: (Span<UInt8>) -> Void
    ) {
      while !self.state.withLock({ $0.isStopped }),
        let count = socket.socket.receive(into: buffer)
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
      /// The socket connected to the peer's path, which a new one replaces when it reports the
      /// peer gone and something is bound at the path all the same.
      var socket: UnixDatagramSocket
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

      /// Adds `message`'s region to what the peer is owed for its database.
      func addToOwed(_ message: OrbitIPCMessage) {
        switch message {
        case .transactionDidCommit(let commit):
          self.owed[commit.databaseIdentifier, default: .empty].formUnion(commit.region)
        }
      }

      /// Schedules the next attempt at a peer the queue cannot say has room.
      func backOff() {
        guard !self.isWatched else { return }
        self.retryAt = .now.advanced(by: self.retryDelay)
        self.retryDelay = min(self.retryDelay * 2, UnixDatagramEndpoint.maximumRetryDelay)
      }
    }

    /// A socket the endpoint receives on.
    ///
    /// It is a class so the thread can go on reading one that ``rebind()`` retired, without the
    /// endpoint's lock, until it has read everything queued on it. It closes once nothing holds it.
    private final class BoundSocket: Sendable {
      let socket: UnixDatagramSocket

      init(_ socket: consuming UnixDatagramSocket) {
        self.socket = socket
      }
    }

    private struct State {
      var isStopped = false
      var peers: [String: Peer] = [:]
      /// The socket bound at the path, which peers that connect from now on send to.
      var socket: BoundSocket
      /// The socket ``rebind()`` last replaced, which peers connected to it still send to.
      var replaced: BoundSocket?
      /// The sockets ``rebind()`` retired, which the thread reads to the end and then closes.
      var retired: [BoundSocket] = []
      /// The descriptor given to ``waitForChanges(on:)``, if any.
      var changeDescriptor: Int32?
      /// Whether ``requestChange()`` was called since the thread last called `onChange`.
      var isChangeRequested = false
    }
  }
#endif
