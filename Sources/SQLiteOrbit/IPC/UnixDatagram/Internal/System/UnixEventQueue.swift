#if canImport(Darwin) || os(Linux) || os(Android)
  /// The platform's readiness queue, which a thread blocks on until a descriptor it watches is
  /// ready.
  ///
  /// It is epoll, with an eventfd to wake it, on Linux and Android, and kqueue, with a user event
  /// to wake it, on Darwin. ``wait(until:_:)`` belongs to one thread; everything else is safe to
  /// call from any thread. The queue never owns a descriptor it watches, and each must outlive its
  /// watch.
  final class UnixEventQueue: @unchecked Sendable {
    /// Something the queue saw become ready.
    enum Event {
      /// A descriptor watched by ``watchReadable(_:)`` has something to read.
      case readable(descriptor: Int32)

      /// A descriptor watched by ``watchWritable(_:)`` has room to write.
      case writable(descriptor: Int32)
    }

    private let backend: Backend

    init() throws {
      self.backend = try Backend()
    }

    /// Starts reporting ``Event/readable(descriptor:)`` whenever `descriptor` has something to
    /// read.
    func watchReadable(_ descriptor: Int32) throws {
      try self.backend.watchReadable(descriptor)
    }

    /// Starts reporting ``Event/writable(descriptor:)`` whenever a connected datagram socket's
    /// peer has room.
    ///
    /// Linux holds back a connected datagram socket's writability while the peer's receive queue
    /// is full, so it can say when to send again. Darwin's write filter looks only at the sender's
    /// own buffer, which a Unix datagram never waits in, so there the caller has to retry on a
    /// timer instead.
    ///
    /// - Parameter descriptor: A connected socket. Stop watching it before closing it.
    /// - Returns: Whether the queue will report when the socket's peer has room.
    func watchWritable(_ descriptor: Int32) -> Bool {
      self.backend.watchWritable(descriptor)
    }

    /// Stops reporting writability for a socket ``watchWritable(_:)`` said it would.
    func unwatchWritable(_ descriptor: Int32) {
      self.backend.unwatchWritable(descriptor)
    }

    /// Ends the current or next ``wait(until:_:)`` early.
    func wake() {
      self.backend.wake()
    }

    /// Blocks until something is ready, the queue is woken, or `deadline` passes, then hands every
    /// ready event to `handle`.
    ///
    /// - Parameters:
    ///   - deadline: When to stop waiting, or `nil` to wait for as long as it takes.
    ///   - handle: Receives each event that was ready.
    func wait(until deadline: ContinuousClock.Instant?, _ handle: (Event) -> Void) {
      self.backend.wait(until: deadline, handle)
    }
  }
#endif
