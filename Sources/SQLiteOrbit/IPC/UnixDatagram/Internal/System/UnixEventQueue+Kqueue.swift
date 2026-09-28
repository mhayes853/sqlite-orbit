#if canImport(Darwin)
  // kqueue, the `kevent` struct and the filters it takes exist only in Darwin, so this backend
  // imports it itself. The `kevent` call is reached through `systemKevent`.
  import Darwin

  /// The platform's readiness queue on Darwin: a kqueue, which a user event wakes.
  final class UnixEventQueue: @unchecked Sendable {
    private static let wakeIdentifier: UInt = 1

    private let descriptor: UnixDescriptor
    private let events: UnsafeMutableBufferPointer<kevent>

    init() throws {
      self.descriptor = try UnixDescriptor(kqueue(), from: "kqueue")
      self.events = .allocate(capacity: 64)
      _ = fcntl(self.descriptor.rawValue, F_SETFD, FD_CLOEXEC)
      try self.change(Self.wakeIdentifier, EVFILT_USER, EV_ADD | EV_CLEAR)
    }

    deinit {
      self.events.deallocate()
    }

    /// Starts reporting ``Event/readable(descriptor:)`` whenever `descriptor` has something to
    /// read.
    func watchReadable(_ descriptor: Int32) throws {
      try self.change(UInt(descriptor), EVFILT_READ, EV_ADD)
    }

    /// Stops reporting a descriptor ``watchReadable(_:)`` was given, which must be done before it
    /// closes.
    func unwatchReadable(_ descriptor: Int32) {
      try? self.change(UInt(descriptor), EVFILT_READ, EV_DELETE)
    }

    /// Always `false`: Darwin's write filter looks only at the sender's own buffer, which a Unix
    /// datagram never waits in, so the caller has to retry on a timer instead.
    func watchWritable(_ descriptor: Int32) -> Bool {
      false
    }

    func unwatchWritable(_ descriptor: Int32) {
    }

    /// Ends the current or next ``wait(until:_:)`` early.
    func wake() {
      try? self.change(Self.wakeIdentifier, EVFILT_USER, 0, NOTE_TRIGGER)
    }

    /// Blocks until something is ready, the queue is woken, or `deadline` passes, then hands every
    /// ready event to `handle`.
    ///
    /// - Parameters:
    ///   - deadline: When to stop waiting, or `nil` to wait for as long as it takes.
    ///   - handle: Receives each event that was ready.
    func wait(until deadline: ContinuousClock.Instant?, _ handle: (Event) -> Void) {
      let timeout = deadline.map { max(.zero, $0 - .now).components }
      var interval = timespec(
        tv_sec: Int(timeout?.seconds ?? 0),
        tv_nsec: Int((timeout?.attoseconds ?? 0) / 1_000_000_000)
      )
      let count = withUnsafePointer(to: &interval) { interval in
        systemKevent(
          self.descriptor.rawValue,
          nil,
          0,
          self.events.baseAddress,
          Int32(self.events.count),
          timeout == nil ? nil : interval
        )
      }
      // A signal that interrupts the wait only ends it early. Any other failure means a
      // descriptor this queue owns is gone, which nothing here can recover from.
      let code = UnixPlatform.lastErrorCode
      precondition(
        count >= 0 || code == UnixPlatform.ErrorCode.interrupted,
        "waiting for events failed with errno \(code)"
      )
      for event in self.events.prefix(max(0, Int(count))) {
        // The wake event only ends the wait, and nothing is watched for writability.
        guard event.filter == Int16(EVFILT_READ) else { continue }
        handle(.readable(descriptor: Int32(truncatingIfNeeded: event.ident)))
      }
    }

    private func change(
      _ identifier: UInt,
      _ filter: Int32,
      _ flags: Int32,
      _ filterFlags: Int32 = 0
    ) throws {
      var change = kevent(
        ident: identifier,
        filter: Int16(filter),
        flags: UInt16(flags),
        fflags: UInt32(filterFlags),
        data: 0,
        udata: nil
      )
      guard systemKevent(self.descriptor.rawValue, &change, 1, nil, 0, nil) == 0 else {
        throw UnixSystemError.last("kevent")
      }
    }
  }
#endif
