#if canImport(Darwin)
  // kqueue, the `kevent` struct and the filters it takes exist only in Darwin, so this backend
  // imports it itself. The `kevent` call is reached through `systemKevent`.
  import Darwin

  extension UnixEventQueue {
    typealias Backend = Kqueue

    /// The kqueue behind a ``UnixEventQueue`` on Darwin, which a user event wakes.
    final class Kqueue {
      private static let wakeIdentifier: UInt = 1

      private let descriptor: UnixDescriptor
      private let events: UnsafeMutableBufferPointer<kevent>

      init() throws {
        let descriptor = try UnixDescriptor(kqueue(), from: "kqueue")
        try? descriptor.setCloseOnExec()
        guard
          Self.change(descriptor.rawValue, Self.wakeIdentifier, EVFILT_USER, EV_ADD | EV_CLEAR)
        else { throw UnixSystemError.last("kevent") }
        self.descriptor = descriptor
        self.events = .allocate(capacity: 64)
      }

      deinit {
        self.events.deallocate()
      }

      func watchReadable(_ descriptor: Int32) throws {
        guard Self.change(self.descriptor.rawValue, UInt(descriptor), EVFILT_READ, EV_ADD) else {
          throw UnixSystemError.last("kevent")
        }
      }

      func watchWritable(_ descriptor: Int32) -> Bool {
        false
      }

      func unwatchWritable(_ descriptor: Int32) {
      }

      func wake() {
        _ = Self.change(self.descriptor.rawValue, Self.wakeIdentifier, EVFILT_USER, 0, NOTE_TRIGGER)
      }

      func wait(
        until deadline: ContinuousClock.Instant?,
        _ handle: (UnixEventQueue.Event) -> Void
      ) {
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

      private static func change(
        _ queue: Int32,
        _ identifier: UInt,
        _ filter: Int32,
        _ flags: Int32,
        _ filterFlags: Int32 = 0
      ) -> Bool {
        var change = kevent(
          ident: identifier,
          filter: Int16(filter),
          flags: UInt16(flags),
          fflags: UInt32(filterFlags),
          data: 0,
          udata: nil
        )
        return systemKevent(queue, &change, 1, nil, 0, nil) == 0
      }
    }
  }
#endif
