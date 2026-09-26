// Every call the IPC transport makes into the platform's C library goes through this file, which is
// the only one in the transport that imports Darwin, Glibc, Musl or Android. How a constant is
// spelled, which flags a call can take, and which readiness queue a thread blocks on are settled
// here, so the rest of the transport needs no guard beyond the one that says it exists at all.
#if canImport(Darwin) || os(Linux) || os(Android)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #elseif canImport(Android)
    import Android
  #endif
  #if !canImport(Darwin)
    import CLinuxEvents
  #endif

  /// A failed system call, named by what it was doing, and the `errno` it failed with.
  struct OrbitIPCSystemError: Error, CustomStringConvertible, Sendable {
    let operation: String
    let code: Int32

    var description: String {
      "\(self.operation) failed with errno \(self.code)"
    }

    /// The error the calling thread's last failed system call left behind.
    static func last(_ operation: String) -> Self {
      Self(operation: operation, code: errno)
    }

    static func invalidArgument(_ operation: String) -> Self {
      Self(operation: operation, code: EINVAL)
    }

    static func closed(_ operation: String) -> Self {
      Self(operation: operation, code: EBADF)
    }

    static func messageTooLong(_ operation: String) -> Self {
      Self(operation: operation, code: EMSGSIZE)
    }

    /// Whether this says the peer a datagram was for is gone.
    ///
    /// A path with nothing behind it fails a connect with `ENOENT`, and one whose socket nobody
    /// holds any more with `ECONNREFUSED`. A socket connected to a peer that then closes gets
    /// `ECONNREFUSED` on Linux and `ECONNRESET` on Darwin, and `ENOTCONN` on either once the
    /// kernel has disconnected it.
    var isStalePeer: Bool {
      [ENOENT, ECONNREFUSED, ECONNRESET, ENOTCONN].contains(self.code)
    }
  }

  enum UnixSystem {
    static func closeDescriptor(_ descriptor: Int32) {
      _ = close(descriptor)
    }

    static func removeFile(atPath path: String) {
      _ = unlink(path)
    }

    /// Renames the file at `source` over the one at `destination`, in one step, so a reader finds
    /// one file or the other and never neither.
    static func renameFile(atPath source: String, toPath destination: String) throws {
      guard rename(source, destination) == 0 else { throw OrbitIPCSystemError.last("rename") }
    }

    /// Runs `body` holding an exclusive `flock` on the file at `path`, creating the file if needed.
    ///
    /// The lock belongs to the open file, so the kernel lets go of it when this process dies.
    static func withExclusiveFileLock<Result>(
      atPath path: String,
      _ body: () throws -> Result
    ) throws -> Result {
      let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o666)
      guard descriptor >= 0 else { throw OrbitIPCSystemError.last("open") }
      defer { _ = close(descriptor) }
      while flock(descriptor, LOCK_EX) != 0 {
        let code = errno
        guard code == EINTR else { throw OrbitIPCSystemError(operation: "flock", code: code) }
      }
      return try body()
    }

    /// Creates a nonblocking datagram socket bound to `path`, the address peers send to.
    static func makeBoundDatagramSocket(
      path: String,
      receiveBufferByteCount: Int
    ) throws -> Int32 {
      var address = try UnixSocketAddress(path: path)
      let descriptor = try makeDatagramSocket()
      var byteCount = Int32(clamping: receiveBufferByteCount)
      let size = socklen_t(MemoryLayout<Int32>.size)
      guard setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &byteCount, size) == 0,
        address.withSockAddr({ bind(descriptor, $0, $1) }) == 0
      else {
        let error = OrbitIPCSystemError.last("bind")
        _ = close(descriptor)
        throw error
      }
      return descriptor
    }

    /// Creates an unbound, nonblocking datagram socket connected to the one bound at `path`.
    ///
    /// Sending on it needs no address, and on Linux it reports itself unwritable while the peer's
    /// receive queue is full, which ``UnixEventQueue/watchWritability(of:)`` rests on.
    ///
    /// - Throws: An ``OrbitIPCSystemError`` whose ``OrbitIPCSystemError/isStalePeer`` holds when
    ///   nothing is bound at `path` any more.
    static func makeConnectedDatagramSocket(path: String) throws -> Int32 {
      var address = try UnixSocketAddress(path: path)
      let descriptor = try makeDatagramSocket()
      guard address.withSockAddr({ connect(descriptor, $0, $1) }) == 0 else {
        let error = OrbitIPCSystemError.last("connect")
        _ = close(descriptor)
        throw error
      }
      return descriptor
    }

    /// Sends one datagram on a connected socket.
    ///
    /// - Returns: `false` when the peer's receive queue is full, which Linux reports as `EAGAIN`
    ///   and Darwin as `ENOBUFS`. Both mean the same thing here: nothing is wrong, and the datagram
    ///   can be sent again once the peer drains.
    static func sendDatagram(_ bytes: [UInt8], on descriptor: Int32) throws -> Bool {
      // Nothing here retries `EINTR`: the socket is nonblocking, so neither this nor `recv` below
      // ever waits in the kernel long enough for a signal to interrupt it.
      let count = bytes.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, sendFlags) }
      if count == bytes.count { return true }
      guard count < 0 else { throw OrbitIPCSystemError.messageTooLong("send") }
      let code = errno
      if code == EAGAIN || code == EWOULDBLOCK || code == ENOBUFS { return false }
      throw OrbitIPCSystemError(operation: "send", code: code)
    }

    /// Receives one datagram into `buffer`.
    ///
    /// - Returns: The datagram's length, or `nil` once the queue is empty or the socket fails. A
    ///   datagram longer than `buffer` is cut short, so a caller that makes `buffer` one byte
    ///   longer than it accepts can tell one that was too long by its length.
    static func receiveDatagram(
      into buffer: UnsafeMutableBufferPointer<UInt8>,
      from descriptor: Int32
    ) -> Int? {
      let count = recv(descriptor, buffer.baseAddress, buffer.count, 0)
      return count >= 0 ? count : nil
    }

    private static func makeDatagramSocket() throws -> Int32 {
      #if canImport(Darwin)
        // Darwin cannot set these as it creates the socket, so they follow at once. A fork on
        // another thread in between would hand the child this descriptor for as long as it runs.
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw OrbitIPCSystemError.last("socket") }
        var enabled: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
          fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, size) == 0
        else {
          let error = OrbitIPCSystemError.last("socket")
          _ = close(descriptor)
          throw error
        }
        return descriptor
      #else
        let descriptor = socket(AF_UNIX, socketType, 0)
        guard descriptor >= 0 else { throw OrbitIPCSystemError.last("socket") }
        return descriptor
      #endif
    }

    #if canImport(Darwin)
      // Darwin raises no `SIGPIPE` from these sockets, because each is made with `SO_NOSIGPIPE`.
      private static let sendFlags: Int32 = 0
    #else
      // Glibc spells a socket type as a member of an enumeration, where Musl and Bionic spell it
      // as a plain integer macro.
      #if canImport(Glibc)
        private static let socketType =
          Int32(SOCK_DGRAM.rawValue) | Int32(SOCK_NONBLOCK.rawValue)
          | Int32(SOCK_CLOEXEC.rawValue)
      #else
        private static let socketType =
          Int32(SOCK_DGRAM) | Int32(SOCK_NONBLOCK) | Int32(SOCK_CLOEXEC)
      #endif
      private static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif
  }

  /// The platform's readiness queue, which the transport's thread blocks on.
  ///
  /// It is epoll with an eventfd to wake it on Linux and Android, and kqueue with a user event on
  /// Darwin. Only ``wake()`` may be called from any thread; everything else belongs to the thread
  /// that waits.
  final class UnixEventQueue: @unchecked Sendable {
    /// Something the queue saw become ready.
    enum Event {
      /// The socket the queue was created to read from has a datagram waiting.
      case readable

      /// A socket watched by ``watchWritability(of:)`` has room to send.
      case writable(descriptor: Int32)
    }

    private let descriptor: Int32
    private let socket: Int32
    #if canImport(Darwin)
      private let events = UnsafeMutableBufferPointer<kevent>.allocate(capacity: 64)
    #else
      private let wakeDescriptor: Int32
      private let events = UnsafeMutableBufferPointer<epoll_event>.allocate(capacity: 64)
    #endif

    /// Creates a queue that reports when `socket` has a datagram to read.
    ///
    /// The queue does not own `socket`, which must outlive it.
    init(readingFrom socket: Int32) throws {
      #if canImport(Darwin)
        let descriptor = kqueue()
        guard descriptor >= 0 else { throw OrbitIPCSystemError.last("kqueue") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        guard Self.change(descriptor, UInt(socket), EVFILT_READ, EV_ADD),
          Self.change(descriptor, Self.wakeIdentifier, EVFILT_USER, EV_ADD | EV_CLEAR)
        else {
          let error = OrbitIPCSystemError.last("kevent")
          _ = close(descriptor)
          throw error
        }
      #else
        let descriptor = epoll_create1(orbit_epoll_cloexec)
        let wakeDescriptor = eventfd(0, orbit_efd_nonblock | orbit_efd_cloexec)
        guard descriptor >= 0, wakeDescriptor >= 0,
          Self.control(descriptor, orbit_epoll_ctl_add, socket, orbit_epoll_in),
          Self.control(descriptor, orbit_epoll_ctl_add, wakeDescriptor, orbit_epoll_in)
        else {
          let error = OrbitIPCSystemError.last("creating an event queue")
          _ = close(wakeDescriptor)
          _ = close(descriptor)
          throw error
        }
        self.wakeDescriptor = wakeDescriptor
      #endif
      self.descriptor = descriptor
      self.socket = socket
    }

    deinit {
      #if !canImport(Darwin)
        _ = close(self.wakeDescriptor)
      #endif
      _ = close(self.descriptor)
      self.events.deallocate()
    }

    /// Ends the current or next ``wait(until:_:)`` early. Safe to call from any thread.
    func wake() {
      #if canImport(Darwin)
        _ = Self.change(self.descriptor, Self.wakeIdentifier, EVFILT_USER, 0, NOTE_TRIGGER)
      #else
        // A full counter would fail this with `EAGAIN`, and a full counter already wakes the queue.
        var increment: UInt64 = 1
        _ = write(self.wakeDescriptor, &increment, MemoryLayout<UInt64>.size)
      #endif
    }

    /// Blocks until something is ready, the queue is woken, or `deadline` passes, then hands every
    /// ready event to `handle`.
    ///
    /// - Parameters:
    ///   - deadline: When to stop waiting, or `nil` to wait for as long as it takes.
    ///   - handle: Receives each event that was ready.
    func wait(until deadline: ContinuousClock.Instant?, _ handle: (Event) -> Void) {
      let timeout = deadline.map { max(.zero, $0 - .now).components }
      #if canImport(Darwin)
        var interval = timespec(
          tv_sec: Int(timeout?.seconds ?? 0),
          tv_nsec: Int((timeout?.attoseconds ?? 0) / 1_000_000_000)
        )
        let count = withUnsafePointer(to: &interval) { interval in
          Darwin.kevent(
            self.descriptor,
            nil,
            0,
            self.events.baseAddress,
            Int32(self.events.count),
            timeout == nil ? nil : interval
          )
        }
      #else
        // Rounded up, so a wait never ends just short of its deadline and spins until it passes.
        let milliseconds = timeout.map { timeout in
          Int32(
            clamping: timeout.seconds * 1_000
              + (timeout.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
          )
        }
        let count = epoll_wait(
          self.descriptor,
          self.events.baseAddress!,
          Int32(self.events.count),
          milliseconds ?? -1
        )
      #endif
      // A signal that interrupts the wait only ends it early. Any other failure means a descriptor
      // this queue owns is gone, which nothing here can recover from.
      precondition(count >= 0 || errno == EINTR, "waiting for events failed with errno \(errno)")
      for event in self.events.prefix(max(0, Int(count))) {
        #if canImport(Darwin)
          let descriptor = Int32(truncatingIfNeeded: event.ident)
          guard event.filter == Int16(EVFILT_READ) else { continue }
        #else
          let descriptor = event.data.fd
          if descriptor == self.wakeDescriptor {
            var counter: UInt64 = 0
            _ = read(self.wakeDescriptor, &counter, MemoryLayout<UInt64>.size)
            continue
          }
        #endif
        handle(descriptor == self.socket ? .readable : .writable(descriptor: descriptor))
      }
    }

    /// Starts reporting ``Event/writable(descriptor:)`` whenever a connected socket's peer has
    /// room.
    ///
    /// Linux holds back a connected datagram socket's writability while the peer's receive queue
    /// is full, so it can say when to send again. Darwin's write filter looks only at the sender's
    /// own buffer, which a Unix datagram never waits in, so there the caller has to retry on a
    /// timer instead.
    ///
    /// - Parameter descriptor: A connected socket. Stop watching it before closing it.
    /// - Returns: Whether the queue will report when the socket's peer has room.
    func watchWritability(of descriptor: Int32) -> Bool {
      #if canImport(Darwin)
        return false
      #else
        return Self.control(self.descriptor, orbit_epoll_ctl_add, descriptor, orbit_epoll_out)
      #endif
    }

    /// Stops reporting writability for a socket ``watchWritability(of:)`` said it would.
    func stopWatchingWritability(of descriptor: Int32) {
      #if !canImport(Darwin)
        _ = Self.control(self.descriptor, orbit_epoll_ctl_del, descriptor, 0)
      #endif
    }

    #if canImport(Darwin)
      private static let wakeIdentifier: UInt = 1

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
        return Darwin.kevent(queue, &change, 1, nil, 0, nil) == 0
      }
    #else
      private static func control(
        _ queue: Int32,
        _ operation: Int32,
        _ descriptor: Int32,
        _ events: UInt32
      ) -> Bool {
        var event = epoll_event()
        event.events = events
        event.data.fd = descriptor
        return epoll_ctl(queue, operation, descriptor, &event) == 0
      }
    #endif
  }

  /// Watches directories for entries appearing, disappearing or being renamed, and says, without
  /// blocking, whether any of them has changed.
  ///
  /// It is inotify on Linux and Android, and on Darwin a kqueue watching each directory's vnode. A
  /// directory that is removed or moved away also counts as a change, after which its watch reports
  /// nothing more. Nothing about it is thread-safe: the caller serializes every use.
  final class UnixDirectoryWatcher: @unchecked Sendable {
    private let descriptor: Int32
    #if canImport(Darwin)
      private var directories: [Int32] = []
    #endif

    init() throws {
      #if canImport(Darwin)
        self.descriptor = kqueue()
        guard self.descriptor >= 0 else { throw OrbitIPCSystemError.last("kqueue") }
        _ = fcntl(self.descriptor, F_SETFD, FD_CLOEXEC)
      #else
        self.descriptor = inotify_init1(orbit_in_nonblock | orbit_in_cloexec)
        guard self.descriptor >= 0 else { throw OrbitIPCSystemError.last("inotify_init1") }
      #endif
    }

    deinit {
      #if canImport(Darwin)
        for directory in self.directories {
          _ = close(directory)
        }
      #endif
      _ = close(self.descriptor)
    }

    /// Starts watching the directory at `path`.
    ///
    /// - Throws: An ``OrbitIPCSystemError`` if the directory cannot be watched, which includes the
    ///   system running out of watches.
    func watch(_ path: String) throws {
      #if canImport(Darwin)
        // `O_EVTONLY` opens the directory only to hear about it, so the watch does not keep the
        // volume it is on from being unmounted.
        let directory = open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw OrbitIPCSystemError.last("open") }
        var change = kevent(
          ident: UInt(directory),
          filter: Int16(EVFILT_VNODE),
          flags: UInt16(EV_ADD | EV_CLEAR),
          fflags: UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE),
          data: 0,
          udata: nil
        )
        guard Darwin.kevent(self.descriptor, &change, 1, nil, 0, nil) == 0 else {
          let error = OrbitIPCSystemError.last("kevent")
          _ = close(directory)
          throw error
        }
        self.directories.append(directory)
      #else
        guard inotify_add_watch(self.descriptor, path, orbit_in_entries_changed) >= 0 else {
          throw OrbitIPCSystemError.last("inotify_add_watch")
        }
      #endif
    }

    /// Takes every change the kernel has queued, without waiting for more.
    ///
    /// - Returns: Whether anything changed since the last call. A queue that cannot be read counts
    ///   as a change, because it could be hiding one.
    func drainChanges() -> Bool {
      var changed = false
      #if canImport(Darwin)
        var events = [kevent](repeating: kevent(), count: 16)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        while true {
          let count = Darwin.kevent(
            self.descriptor,
            nil,
            0,
            &events,
            Int32(events.count),
            &timeout
          )

          guard count > 0 else { return changed || count < 0 }
          changed = true
        }
      #else
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = buffer.withUnsafeMutableBytes {
            read(self.descriptor, $0.baseAddress, $0.count)
          }
          if count > 0 {
            changed = true
            continue
          }
          let code = errno
          if count < 0, code == EINTR { continue }
          return changed || (count < 0 && code != EAGAIN && code != EWOULDBLOCK)
        }
      #endif
    }
  }

  private struct UnixSocketAddress {
    private var storage = sockaddr_un()
    private let length: socklen_t

    init(path: String) throws {
      let bytes = Array(path.utf8) + [0]
      guard !path.utf8.contains(0) else {
        throw OrbitIPCSystemError.invalidArgument("socket path contains NUL")
      }
      guard bytes.count <= MemoryLayout.size(ofValue: self.storage.sun_path) else {
        throw OrbitIPCSystemError(operation: "socket path is too long", code: ENAMETOOLONG)
      }
      self.storage.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &self.storage.sun_path) { $0.copyBytes(from: bytes) }
      self.length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count)
      #if canImport(Darwin)
        self.storage.sun_len = UInt8(self.length)
      #endif
    }

    mutating func withSockAddr<Result>(
      _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) rethrows -> Result {
      let length = self.length
      return try withUnsafePointer(to: &self.storage) { storage in
        try storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
      }
    }
  }
#endif
