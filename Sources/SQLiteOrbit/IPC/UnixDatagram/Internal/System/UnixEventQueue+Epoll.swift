#if os(Linux) || os(Android)
  // Swift's Glibc module leaves out epoll and eventfd, so this backend imports them from the
  // header-only module that declares them. Everything else goes through `UnixPlatform`.
  import CLinuxEvents

  /// The platform's readiness queue on Linux and Android: an epoll instance, which an eventfd
  /// wakes.
  final class UnixEventQueue: @unchecked Sendable {
    /// What a registration is for, kept in the upper half of its event's data beside the
    /// descriptor, so an event says what it means without a table the waiting thread shares.
    private enum Registration: UInt64 {
      case wake = 0
      case readable = 1
      case writable = 2
    }

    private let descriptor: UnixDescriptor
    private let wakeDescriptor: UnixDescriptor
    private let events: UnsafeMutableBufferPointer<epoll_event>

    init() throws {
      self.descriptor = try UnixDescriptor(epoll_create1(orbit_epoll_cloexec), from: "epoll")
      self.wakeDescriptor = try UnixDescriptor(
        eventfd(0, orbit_efd_nonblock | orbit_efd_cloexec),
        from: "eventfd"
      )
      self.events = .allocate(capacity: 64)
      try self.watch(self.wakeDescriptor.rawValue, orbit_epoll_in, .wake)
    }

    deinit {
      self.events.deallocate()
    }

    /// Starts reporting ``Event/readable(descriptor:)`` whenever `descriptor` has something to
    /// read.
    func watchReadable(_ descriptor: Int32) throws {
      try self.watch(descriptor, orbit_epoll_in, .readable)
    }

    /// Stops reporting a descriptor ``watchReadable(_:)`` was given, which must be done before it
    /// closes.
    func unwatchReadable(_ descriptor: Int32) {
      _ = epoll_ctl(self.descriptor.rawValue, orbit_epoll_ctl_del, descriptor, nil)
    }

    /// Starts reporting ``Event/writable(descriptor:)`` whenever a connected datagram socket's
    /// peer has room.
    ///
    /// Linux holds back a connected datagram socket's writability while the peer's receive queue
    /// is full, so it can say when to send again. Darwin's cannot, so there this always returns
    /// `false` and the caller retries on a timer instead.
    ///
    /// - Parameter descriptor: A connected socket. Stop watching it before closing it.
    /// - Returns: Whether the queue will report when the socket's peer has room.
    func watchWritable(_ descriptor: Int32) -> Bool {
      (try? self.watch(descriptor, orbit_epoll_out, .writable)) != nil
    }

    /// Stops reporting writability for a socket ``watchWritable(_:)`` said it would.
    func unwatchWritable(_ descriptor: Int32) {
      _ = epoll_ctl(self.descriptor.rawValue, orbit_epoll_ctl_del, descriptor, nil)
    }

    /// Ends the current or next ``wait(until:_:)`` early.
    func wake() {
      // A full counter would fail this with `EAGAIN`, and a full counter already wakes the queue.
      let increment: UInt64 = 1
      _ = withUnsafeBytes(of: increment) {
        UnixPlatform.writeBytes($0, to: self.wakeDescriptor.rawValue)
      }
    }

    /// Blocks until something is ready, the queue is woken, or `deadline` passes, then hands every
    /// ready event to `handle`.
    ///
    /// - Parameters:
    ///   - deadline: When to stop waiting, or `nil` to wait for as long as it takes.
    ///   - handle: Receives each event that was ready.
    func wait(until deadline: ContinuousClock.Instant?, _ handle: (Event) -> Void) {
      // Rounded up, so a wait never ends just short of its deadline and spins until it passes.
      let milliseconds = deadline.map { deadline in
        let timeout = max(.zero, deadline - .now).components
        return Int32(
          clamping: timeout.seconds * 1_000
            + (timeout.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        )
      }
      let count = epoll_wait(
        self.descriptor.rawValue,
        self.events.baseAddress!,
        Int32(self.events.count),
        milliseconds ?? -1
      )
      for event in self.events.prefix(Self.readyCount(count)) {
        let descriptor = Int32(bitPattern: UInt32(truncatingIfNeeded: event.data.u64))
        switch Registration(rawValue: event.data.u64 >> 32) {
        case .wake:
          var counter: UInt64 = 0
          _ = withUnsafeMutableBytes(of: &counter) {
            UnixPlatform.readBytes(from: self.wakeDescriptor.rawValue, into: $0)
          }
        case .readable:
          handle(.readable(descriptor: descriptor))
        case .writable:
          handle(.writable(descriptor: descriptor))
        case nil:
          continue
        }
      }
    }

    private func watch(_ descriptor: Int32, _ events: UInt32, _ registration: Registration) throws {
      var event = epoll_event()
      event.events = events
      event.data.u64 = registration.rawValue << 32 | UInt64(UInt32(bitPattern: descriptor))
      guard epoll_ctl(self.descriptor.rawValue, orbit_epoll_ctl_add, descriptor, &event) == 0 else {
        throw UnixSystemError.last("epoll_ctl")
      }
    }
  }
#endif
