#if os(Linux) || os(Android)
  // Swift's Glibc module leaves out epoll and eventfd, so this backend imports them from the
  // header-only module that declares them. Everything else goes through `UnixPlatform`.
  import CLinuxEvents

  extension UnixEventQueue {
    typealias Backend = Epoll

    /// The epoll instance behind a ``UnixEventQueue`` on Linux and Android, which an eventfd
    /// wakes.
    final class Epoll {
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
        let descriptor = try UnixDescriptor(epoll_create1(orbit_epoll_cloexec), from: "epoll")
        let wakeDescriptor = try UnixDescriptor(
          eventfd(0, orbit_efd_nonblock | orbit_efd_cloexec),
          from: "eventfd"
        )
        guard
          Self.control(
            descriptor.rawValue,
            orbit_epoll_ctl_add,
            wakeDescriptor.rawValue,
            orbit_epoll_in,
            .wake
          )
        else { throw UnixSystemError.last("epoll_ctl") }
        self.descriptor = descriptor
        self.wakeDescriptor = wakeDescriptor
        self.events = .allocate(capacity: 64)
      }

      deinit {
        self.events.deallocate()
      }

      func watchReadable(_ descriptor: Int32) throws {
        guard
          Self.control(
            self.descriptor.rawValue,
            orbit_epoll_ctl_add,
            descriptor,
            orbit_epoll_in,
            .readable
          )
        else { throw UnixSystemError.last("epoll_ctl") }
      }

      func watchWritable(_ descriptor: Int32) -> Bool {
        Self.control(
          self.descriptor.rawValue,
          orbit_epoll_ctl_add,
          descriptor,
          orbit_epoll_out,
          .writable
        )
      }

      func unwatchWritable(_ descriptor: Int32) {
        _ = Self.control(self.descriptor.rawValue, orbit_epoll_ctl_del, descriptor, 0, .writable)
      }

      func wake() {
        // A full counter would fail this with `EAGAIN`, and a full counter already wakes the
        // queue.
        let increment: UInt64 = 1
        _ = withUnsafeBytes(of: increment) {
          UnixPlatform.writeBytes($0, to: self.wakeDescriptor.rawValue)
        }
      }

      func wait(
        until deadline: ContinuousClock.Instant?,
        _ handle: (UnixEventQueue.Event) -> Void
      ) {
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
        // A signal that interrupts the wait only ends it early. Any other failure means a
        // descriptor this queue owns is gone, which nothing here can recover from.
        let code = UnixPlatform.lastErrorCode
        precondition(
          count >= 0 || code == UnixPlatform.ErrorCode.interrupted,
          "waiting for events failed with errno \(code)"
        )
        for event in self.events.prefix(max(0, Int(count))) {
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

      private static func control(
        _ queue: Int32,
        _ operation: Int32,
        _ descriptor: Int32,
        _ events: UInt32,
        _ registration: Registration
      ) -> Bool {
        var event = epoll_event()
        event.events = events
        event.data.u64 = registration.rawValue << 32 | UInt64(UInt32(bitPattern: descriptor))
        return epoll_ctl(queue, operation, descriptor, &event) == 0
      }
    }
  }
#endif
