#if canImport(Darwin) || os(Linux) || os(Android)
  /// The socket a transport receives on, the sockets it sends to each peer on, and the thread that
  /// waits on them.
  ///
  /// When the transport suspends, a message a peer's full receive queue refuses waits for that
  /// peer, and later messages to it wait behind it rather than overtake it. Once the peer has room,
  /// which Linux reports and Darwin is polled for on a backoff, the thread sends what waits in as
  /// few datagrams as fit it. Each message's sender waits for its own outcome at every peer, up to
  /// its deadline.
  ///
  /// The receive thread keeps the endpoint alive for as long as it runs, and ``stop()`` is what
  /// ends it. Whichever of the transport and the thread lets go of the endpoint last closes its
  /// descriptors, so nothing is still waiting on one when it closes, and a transport released on
  /// the receive thread itself has nothing to wait for.
  final class UnixDatagramEndpoint: Sendable {
    /// How many peers took a message, and how many live ones did not.
    struct Delivery: Sendable {
      var delivered = 0
      var failed = 0
    }

    private let registry: UnixDatagramEndpointRegistry
    private let maximumDatagramByteCount: Int
    private let socket: UnixDatagramSocket
    private let queue: UnixEventQueue
    private let state = Lock(State())

    /// Binds a socket at `registry`'s socket path.
    ///
    /// - Parameters:
    ///   - registry: Where peers find this endpoint, and where dead ones are pruned from.
    ///   - maximumDatagramByteCount: The longest datagram to send or accept.
    ///   - receiveBufferByteCount: The size of the socket's receive buffer.
    /// - Throws: A ``UnixSystemError`` if the socket cannot be created and bound.
    init(
      registry: UnixDatagramEndpointRegistry,
      maximumDatagramByteCount: Int,
      receiveBufferByteCount: Int
    ) throws {
      let socket = try UnixDatagramSocket.bind(
        path: registry.socketPath,
        receiveBufferByteCount: receiveBufferByteCount
      )
      let queue: UnixEventQueue
      do {
        queue = try UnixEventQueue()
        try queue.watchReadable(socket.descriptor.rawValue)
      } catch {
        _ = UnixPlatform.removeFile(atPath: registry.socketPath)
        throw error
      }
      self.registry = registry
      self.maximumDatagramByteCount = maximumDatagramByteCount
      self.socket = socket
      self.queue = queue
    }

    /// Starts the thread that receives on this endpoint, which runs until ``stop()``.
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

    /// Removes the socket's path, which is what a peer finds this endpoint by, while leaving the
    /// socket itself open to whatever is still reading from it.
    func removePath() {
      _ = UnixPlatform.removeFile(atPath: self.registry.socketPath)
    }

    /// How many messages wait for peers, across every peer.
    var pendingMessageCount: Int {
      self.state.withLock { $0.peers.values.reduce(0) { $0 + $1.pending.count } }
    }

    /// Sends `entry` to every peer in `peers`, on the connected socket kept for each.
    ///
    /// A peer that turns out to be dead is pruned from the registry rather than counted.
    ///
    /// - Parameters:
    ///   - entry: The message to send.
    ///   - peers: The peers to send it to.
    ///   - advertisers: Every endpoint advertising the message's database now, by name, whether or
    ///     not the message concerns it. The sockets kept for any others that were seen with the
    ///     database are closed.
    ///   - suspension: How long to wait for a peer whose receive queue is full, or `nil` to count
    ///     it as failed at once.
    /// - Returns: How many peers took the message, and how many did not.
    /// - Throws: `CancellationError` if the task is cancelled while waiting for a peer, in which
    ///   case the message is withdrawn from every peer that has not taken it.
    func send(
      _ entry: UnixDatagramWireEntry,
      to peers: [UnixDatagramPeer],
      advertisedBy advertisers: some Collection<String>,
      suspendingUpTo suspension: Duration?
    ) async throws -> Delivery {
      let coordinationKey = entry.message.databaseIdentifier.coordinationKey
      var single = UnixDatagramWireBatch()
      single.append(entry)
      let datagram = single.encoded()
      let deadline = suspension.map { ContinuousClock.now.advanced(by: $0) }

      let (sendID, delivery, stale) = self.state.withLock { state in
        self.retain(advertisers, advertising: coordinationKey, in: &state)
        var stale: [StalePeer] = []
        let sendID = state.nextSendID
        state.nextSendID += 1
        var delivery = Delivery()
        var pendingCount = 0
        for peer in peers {
          switch self.offer(
            datagram,
            entry,
            to: peer,
            coordinationKey: coordinationKey,
            sendID: deadline == nil ? nil : sendID,
            in: &state
          ) {
          case .delivered: delivery.delivered += 1
          case .failed: delivery.failed += 1
          case .pending: pendingCount += 1
          case .stale(let peer): stale.append(peer)
          }
        }
        guard let deadline, pendingCount > 0 else { return (UInt64?.none, delivery, stale) }
        state.sends[sendID] = PendingSend(
          deadline: deadline,
          remaining: pendingCount,
          delivery: delivery
        )
        return (sendID, delivery, stale)
      }
      self.prune(stale)
      guard let sendID else { return delivery }

      // The thread waits on a deadline it worked out before this send existed.
      self.queue.wake()
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          self.attach(continuation, to: sendID)
        }
      } onCancel: {
        self.cancel(sendID)
      }
    }

    // MARK: - Sending

    private enum Offer {
      case delivered
      case failed
      case pending
      case stale(StalePeer)
    }

    private func offer(
      _ datagram: [UInt8],
      _ entry: UnixDatagramWireEntry,
      to peer: UnixDatagramPeer,
      coordinationKey: String,
      sendID: UInt64?,
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

      // A message never overtakes one already waiting for the same peer.
      let startsWaiting = state.peers[name]!.pending.isEmpty
      if startsWaiting {
        switch state.peers[name]!.socket.send(datagram) {
        case .sent:
          return .delivered
        case .full:
          break
        case .peerGone:
          var completions: [Completion] = []
          let stale = self.forget(name, in: &state, completions: &completions)
          assert(completions.isEmpty, "A peer with nothing pending completes no send")
          return .stale(stale)
        case .failed:
          return .failed
        }
      }
      guard let sendID else { return .failed }
      state.peers[name]!.pending.append(Pending(entry: entry, sendID: sendID))
      if startsWaiting {
        state.peers[name]!.isWatched = self.queue.watchWritable(
          state.peers[name]!.socket.descriptor.rawValue
        )
        state.peers[name]!.backOff()
      }
      return .pending
    }

    /// Sends what waits for a peer, as many messages to a datagram as fit, until the peer has no
    /// room or nothing is left.
    private func flush(
      _ name: String,
      in state: inout State,
      completions: inout [Completion],
      stale: inout [StalePeer]
    ) {
      guard let socket = state.peers[name]?.socket else { return }
      while !state.peers[name]!.pending.isEmpty {
        // The longest run from the front that fits, which always holds at least the first.
        var batch = UnixDatagramWireBatch()
        for pending in state.peers[name]!.pending {
          guard batch.byteCount(appending: pending.entry) <= self.maximumDatagramByteCount
          else { break }
          batch.append(pending.entry)
        }

        let outcome: Outcome
        switch socket.send(batch.encoded()) {
        case .sent:
          outcome = .delivered
        case .full:
          state.peers[name]!.backOff()
          return
        case .peerGone:
          stale.append(self.forget(name, in: &state, completions: &completions))
          return
        case .failed:
          outcome = .failed
        }
        state.peers[name]!.retryDelay = .milliseconds(1)
        for pending in state.peers[name]!.pending.prefix(batch.entries.count) {
          self.resolve(pending.sendID, outcome, in: &state, completions: &completions)
        }
        state.peers[name]!.pending.removeFirst(batch.entries.count)
      }
      self.unwatch(name, in: &state)
    }

    /// Withdraws a send from every peer it is still waiting for.
    ///
    /// - Returns: How many peers it was withdrawn from.
    private func withdraw(_ sendID: UInt64, in state: inout State) -> Int {
      var count = 0
      for name in state.peers.keys {
        guard let index = state.peers[name]!.pending.firstIndex(where: { $0.sendID == sendID })
        else { continue }
        state.peers[name]!.pending.remove(at: index)
        count += 1
        if state.peers[name]!.pending.isEmpty {
          self.unwatch(name, in: &state)
        }
      }
      return count
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

    /// Closes the socket kept for a peer, and settles whatever was waiting for it.
    private func forget(
      _ name: String,
      in state: inout State,
      completions: inout [Completion]
    ) -> StalePeer {
      self.unwatch(name, in: &state)
      // Its socket closes when this goes, at the end of the call.
      let peer = state.peers.removeValue(forKey: name)!
      for pending in peer.pending {
        self.resolve(pending.sendID, .pruned, in: &state, completions: &completions)
      }
      return StalePeer(peer: peer.peer, coordinationKeys: peer.coordinationKeys)
    }

    /// Closes the sockets kept for peers that stopped advertising `coordinationKey` and advertise
    /// nothing else this endpoint has seen them with, unless something still waits for them.
    private func retain(
      _ advertisers: some Collection<String>,
      advertising coordinationKey: String,
      in state: inout State
    ) {
      let advertised = Set(advertisers)
      // A peer something still waits for keeps what it was seen with until the next look.
      for (name, peer) in state.peers
      where peer.pending.isEmpty && peer.coordinationKeys.contains(coordinationKey)
        && !advertised.contains(name)
      {
        state.peers[name]!.coordinationKeys.remove(coordinationKey)
        guard state.peers[name]!.coordinationKeys.isEmpty else { continue }
        // Nothing of it is pruned from the registry: it withdrew its own advertisements.
        var completions: [Completion] = []
        _ = self.forget(name, in: &state, completions: &completions)
      }
    }

    private func prune(_ stale: [StalePeer]) {
      for stale in stale {
        try? self.registry.remove(stale.peer, coordinationKeys: stale.coordinationKeys)
      }
    }

    // MARK: - Waiting Senders

    private enum Outcome {
      case delivered
      case failed
      case pruned
    }

    private typealias Completion = (
      continuation: CheckedContinuation<Delivery, any Error>,
      result: Result<Delivery, any Error>
    )

    private func resolve(
      _ sendID: UInt64,
      _ outcome: Outcome,
      in state: inout State,
      completions: inout [Completion]
    ) {
      guard state.sends[sendID] != nil else { return }
      switch outcome {
      case .delivered: state.sends[sendID]!.delivery.delivered += 1
      case .failed: state.sends[sendID]!.delivery.failed += 1
      case .pruned: break
      }
      state.sends[sendID]!.remaining -= 1
      guard state.sends[sendID]!.remaining == 0,
        let continuation = state.sends[sendID]!.continuation
      else { return }
      // A send that has not attached its continuation yet finds itself finished when it does.
      completions.append((continuation, .success(state.sends[sendID]!.delivery)))
      state.sends[sendID] = nil
    }

    private func attach(
      _ continuation: CheckedContinuation<Delivery, any Error>,
      to sendID: UInt64
    ) {
      let result = self.state.withLock { state -> Result<Delivery, any Error>? in
        let send = state.sends[sendID]!
        if send.isCancelled {
          state.sends[sendID] = nil
          return .failure(CancellationError())
        }
        if send.remaining == 0 {
          state.sends[sendID] = nil
          return .success(send.delivery)
        }
        state.sends[sendID]!.continuation = continuation
        return nil
      }
      if let result {
        continuation.resume(with: result)
      }
    }

    private func cancel(_ sendID: UInt64) {
      let continuation = self.state.withLock { state -> CheckedContinuation<Delivery, any Error>? in
        guard let send = state.sends[sendID], send.remaining > 0 else { return nil }
        _ = self.withdraw(sendID, in: &state)
        guard let continuation = send.continuation else {
          state.sends[sendID]!.remaining = 0
          state.sends[sendID]!.isCancelled = true
          return nil
        }
        state.sends[sendID] = nil
        return continuation
      }
      continuation?.resume(throwing: CancellationError())
    }

    // MARK: - The Thread

    private func run(receive: (Span<UInt8>) -> Void) {
      // Every datagram lands in this one buffer, which only this thread touches. It is a byte
      // longer than any datagram the transport accepts, so one that fills it was too long.
      let capacity = self.maximumDatagramByteCount + 1
      let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: capacity)
      defer { buffer.deallocate() }
      while true {
        let (isStopped, deadline) = self.state.withLock { ($0.isStopped, $0.nextDeadline) }
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
        var completions: [Completion] = []
        let stale = self.state.withLock { state in
          self.service(writable, in: &state, completions: &completions)
        }
        self.prune(stale)
        for completion in completions {
          completion.continuation.resume(with: completion.result)
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

    /// Flushes the peers that have room or are due a retry, then fails every send whose deadline
    /// has passed at the peers still holding it.
    private func service(
      _ writable: [Int32],
      in state: inout State,
      completions: inout [Completion]
    ) -> [StalePeer] {
      var stale: [StalePeer] = []
      let now = ContinuousClock.now
      // An event for a socket closed since can name a new one given the same number, which at
      // worst sends that peer what waits for it a little early.
      for (name, peer) in state.peers where writable.contains(peer.socket.descriptor.rawValue) {
        self.flush(name, in: &state, completions: &completions, stale: &stale)
      }
      for (name, peer) in state.peers where peer.retryAt.map({ $0 <= now }) == true {
        self.flush(name, in: &state, completions: &completions, stale: &stale)
      }

      let expired = state.sends.filter { $0.value.remaining > 0 && $0.value.deadline <= now }
      guard !expired.isEmpty else { return stale }
      // The attempt that lands on the deadline still happens: the budget is time spent waiting.
      for (name, peer) in state.peers where !peer.pending.isEmpty {
        self.flush(name, in: &state, completions: &completions, stale: &stale)
      }
      for sendID in expired.keys {
        for _ in 0..<self.withdraw(sendID, in: &state) {
          self.resolve(sendID, .failed, in: &state, completions: &completions)
        }
      }
      return stale
    }

    // MARK: - State

    private struct StalePeer {
      let peer: UnixDatagramPeer
      let coordinationKeys: Set<String>
    }

    private struct PendingSend {
      let deadline: ContinuousClock.Instant
      /// How many peers have yet to take or refuse the message.
      var remaining: Int
      var delivery: Delivery
      var continuation: CheckedContinuation<Delivery, any Error>?
      var isCancelled = false
    }

    private struct Pending {
      let entry: UnixDatagramWireEntry
      let sendID: UInt64
    }

    private struct Peer {
      let peer: UnixDatagramPeer
      let socket: UnixDatagramSocket
      /// The databases this peer was last seen advertising, by coordination key.
      var coordinationKeys: Set<String> = []
      /// The messages waiting for this peer, in the order they were sent.
      var pending: [Pending] = []
      var isWatched = false
      var retryAt: ContinuousClock.Instant?
      var retryDelay = Duration.milliseconds(1)

      /// Schedules the next attempt at a peer the queue cannot say has room.
      mutating func backOff() {
        guard !self.isWatched else { return }
        self.retryAt = .now.advanced(by: self.retryDelay)
        self.retryDelay = min(self.retryDelay * 2, .milliseconds(16))
      }
    }

    private struct State {
      var isStopped = false
      var peers: [String: Peer] = [:]
      var sends: [UInt64: PendingSend] = [:]

      var nextSendID: UInt64 = 0

      /// When the thread next has something to do without being woken.
      var nextDeadline: ContinuousClock.Instant? {
        let retry = self.peers.values.lazy.compactMap(\.retryAt).min()
        let expiry = self.sends.values.lazy.filter { $0.remaining > 0 }.map(\.deadline).min()
        guard let retry, let expiry else { return retry ?? expiry }
        return min(retry, expiry)
      }
    }
  }
#endif
