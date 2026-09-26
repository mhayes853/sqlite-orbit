#if canImport(Darwin) || os(Linux) || os(Android)
  /// The socket a transport receives on, the sockets it sends to each peer on, and the thread that
  /// waits on them.
  ///
  /// The receive thread keeps the endpoint alive for as long as it runs, and ``stop()`` is what
  /// ends it. Whichever of the transport and the thread lets go of the endpoint last closes its
  /// descriptors, so nothing is still waiting on one when it closes, and a transport released on
  /// the receive thread itself has nothing to wait for.
  final class UnixDatagramEndpoint: Sendable {
    let path: String
    private let descriptor: Int32
    private let queue: UnixEventQueue
    private let state = Lock(State())

    /// Binds a socket at `path`.
    ///
    /// - Parameters:
    ///   - path: Where peers send to this endpoint.
    ///   - receiveBufferByteCount: The size of the socket's receive buffer.
    /// - Throws: An ``OrbitIPCSystemError`` if the socket cannot be created and bound.
    init(path: String, receiveBufferByteCount: Int) throws {
      let descriptor = try UnixSystem.makeBoundDatagramSocket(
        path: path,
        receiveBufferByteCount: receiveBufferByteCount
      )
      do {
        self.queue = try UnixEventQueue(readingFrom: descriptor)
      } catch {
        UnixSystem.closeDescriptor(descriptor)
        UnixSystem.removeFile(atPath: path)
        throw error
      }
      self.path = path
      self.descriptor = descriptor
    }

    deinit {
      self.state.withLock { state in
        for peer in state.peers.values {
          UnixSystem.closeDescriptor(peer.descriptor)
        }
        state.peers.removeAll()
      }
      UnixSystem.closeDescriptor(self.descriptor)
    }

    /// Starts the thread that receives on this endpoint, which runs until ``stop()``.
    ///
    /// - Parameters:
    ///   - maximumDatagramByteCount: The longest datagram to hand to `receive`. Longer ones are
    ///     dropped.
    ///   - receive: Receives each datagram, on the endpoint's thread. The bytes are only valid for
    ///     the duration of the call.
    func start(
      maximumDatagramByteCount: Int,
      receive: @escaping @Sendable (Span<UInt8>) -> Void
    ) {
      DetachedThread.spawn(name: "Orbit IPC") {
        self.run(maximumDatagramByteCount: maximumDatagramByteCount, receive: receive)
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
      UnixSystem.removeFile(atPath: self.path)
    }

    /// Sends a datagram to `peer` on the connected socket kept for it, connecting one first if
    /// there is none.
    ///
    /// - Parameters:
    ///   - bytes: The datagram.
    ///   - peer: The endpoint to send it to.
    ///   - coordinationKey: The database `peer` was found advertising.
    /// - Returns: Whether the peer accepted the datagram, which it does not while its receive
    ///   queue is full.
    /// - Throws: An ``OrbitIPCSystemError``. One that says the peer is stale also discards the
    ///   socket kept for it.
    func send(
      _ bytes: [UInt8],
      to peer: OrbitIPCPeer,
      coordinationKey: String
    ) throws -> Bool {
      try self.state.withLock { state in
        let descriptor = try state.descriptor(for: peer, coordinationKey: coordinationKey)
        do {
          return try bytes.withUnsafeBytes { try UnixSystem.sendDatagram($0, on: descriptor) }
        } catch let error as OrbitIPCSystemError where error.isStalePeer {
          state.forget(peer.endpointName)
          throw error
        }
      }
    }

    /// Closes the sockets kept for peers that stopped advertising `coordinationKey` and advertise
    /// nothing else this endpoint has seen them with.
    ///
    /// - Parameters:
    ///   - peers: Every peer that advertises `coordinationKey` now.
    ///   - coordinationKey: The database the peers were listed for.
    func retainPeers(_ peers: [OrbitIPCPeer], advertising coordinationKey: String) {
      let advertised = Set(peers.map(\.endpointName))
      self.state.withLock { state in
        for (name, peer) in state.peers
        where peer.coordinationKeys.contains(coordinationKey) && !advertised.contains(name) {
          state.peers[name]?.coordinationKeys.remove(coordinationKey)
          if state.peers[name]?.coordinationKeys.isEmpty == true {
            state.forget(name)
          }
        }
      }
    }

    private var isStopped: Bool {
      self.state.withLock { $0.isStopped }
    }

    private func run(
      maximumDatagramByteCount: Int,
      receive: (Span<UInt8>) -> Void
    ) {
      // Every datagram lands in this one buffer, which only this thread touches. It is a byte
      // longer than any datagram the transport accepts, so one that fills it was too long.
      let capacity = maximumDatagramByteCount + 1
      let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: capacity)
      defer { buffer.deallocate() }
      while !self.isStopped {
        self.queue.wait(until: nil) { event in
          guard case .readable = event else { return }
          while !self.isStopped,
            let count = UnixSystem.receiveDatagram(
              into: UnsafeMutableRawBufferPointer(buffer),
              from: self.descriptor
            )
          {
            guard count <= maximumDatagramByteCount else { continue }
            receive(Span(_unsafeElements: UnsafeBufferPointer(rebasing: buffer[..<count])))
          }
        }
      }
    }

    private struct Peer {
      let descriptor: Int32
      /// The databases this peer was last seen advertising, by coordination key.
      var coordinationKeys: Set<String>
    }

    private struct State {
      var isStopped = false
      var peers: [String: Peer] = [:]

      mutating func descriptor(
        for peer: OrbitIPCPeer,
        coordinationKey: String
      ) throws -> Int32 {
        if let cached = self.peers[peer.endpointName] {
          self.peers[peer.endpointName]?.coordinationKeys.insert(coordinationKey)
          return cached.descriptor
        }
        let descriptor = try UnixSystem.makeConnectedDatagramSocket(path: peer.socketPath)
        self.peers[peer.endpointName] = Peer(
          descriptor: descriptor,
          coordinationKeys: [coordinationKey]
        )
        return descriptor
      }

      mutating func forget(_ endpointName: String) {
        guard let peer = self.peers.removeValue(forKey: endpointName) else { return }
        UnixSystem.closeDescriptor(peer.descriptor)
      }
    }
  }
#endif
