#if canImport(Darwin) || os(Linux) || os(Android)
  // `UnixEventQueue` is the platform's readiness queue, which a thread blocks on until a descriptor
  // it watches is ready: epoll, with an eventfd to wake it, on Linux and Android, and kqueue, with a
  // user event to wake it, on Darwin. Each backend file defines the class for its platform.
  //
  // `wait(until:_:)` belongs to one thread; everything else is safe to call from any thread. The
  // queue never owns a descriptor it watches, and each must outlive its watch. Besides sockets, it
  // can watch a `UnixDirectoryWatcher`'s descriptor for readability, which an inotify instance and
  // a kqueue both offer, so one thread can wait for datagrams and directory changes alike.
  extension UnixEventQueue {
    /// Something the queue saw become ready.
    enum Event {
      /// A descriptor watched by `watchReadable(_:)` has something to read.
      case readable(descriptor: Int32)

      /// A descriptor watched by `watchWritable(_:)` has room to write.
      case writable(descriptor: Int32)
    }

    /// How many events a wait that returned `count` handed back.
    ///
    /// A signal that interrupts the wait only ends it early. Any other failure means a descriptor
    /// the queue owns is gone, which nothing here can recover from.
    static func readyCount(_ count: Int32) -> Int {
      let code = UnixPlatform.lastErrorCode
      precondition(
        count >= 0 || code == UnixPlatform.ErrorCode.interrupted,
        "waiting for events failed with errno \(code)"
      )
      return max(0, Int(count))
    }
  }
#endif
