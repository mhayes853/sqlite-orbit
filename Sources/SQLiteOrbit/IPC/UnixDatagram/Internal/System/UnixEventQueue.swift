#if canImport(Darwin) || os(Linux) || os(Android)
  // `UnixEventQueue` is the platform's readiness queue, which a thread blocks on until a descriptor
  // it watches is ready: epoll, with an eventfd to wake it, on Linux and Android, and kqueue, with a
  // user event to wake it, on Darwin. Each backend file defines the class for its platform.
  //
  // `wait(until:_:)` belongs to one thread; everything else is safe to call from any thread. The
  // queue never owns a descriptor it watches, and each must outlive its watch.
  extension UnixEventQueue {
    /// Something the queue saw become ready.
    enum Event {
      /// A descriptor watched by `watchReadable(_:)` has something to read.
      case readable(descriptor: Int32)

      /// A descriptor watched by `watchWritable(_:)` has room to write.
      case writable(descriptor: Int32)
    }
  }
#endif
