#if os(Linux) || os(Android)
  // inotify is imported from the same header-only module as epoll, for the same reason: Swift's
  // Glibc module leaves it out. Everything else goes through `UnixPlatform`.
  import CLinuxEvents

  /// Watches directories for entries appearing, disappearing or being renamed, and says, without
  /// blocking, whether any of them has changed.
  ///
  /// It is inotify on Linux and Android, and on Darwin a kqueue watching each directory's vnode. A
  /// directory that is removed or moved away also counts as a change, after which its watch reports
  /// nothing more. Nothing about it is thread-safe: the caller serializes every use.
  final class UnixDirectoryWatcher: @unchecked Sendable {
    private let inotify: UnixDescriptor

    init() throws {
      self.inotify = try UnixDescriptor(
        inotify_init1(orbit_in_nonblock | orbit_in_cloexec),
        from: "inotify_init1"
      )
    }

    /// A descriptor that is readable while a change is waiting to be drained, so a thread can
    /// wait for changes along with everything else by handing it to
    /// ``UnixEventQueue/watchReadable(_:)``. It stays readable until ``drainChanges()`` takes
    /// what is queued, and is valid for as long as the watcher is.
    var descriptor: Int32 {
      self.inotify.rawValue
    }

    /// Starts watching the directory at `path`.
    ///
    /// - Throws: A ``UnixSystemError`` if the directory cannot be watched, which includes the
    ///   system running out of watches.
    func watch(_ path: String) throws {
      guard inotify_add_watch(self.inotify.rawValue, path, orbit_in_entries_changed) >= 0
      else { throw UnixSystemError.last("inotify_add_watch") }
    }

    /// Takes every change the kernel has queued, without waiting for more.
    ///
    /// - Returns: Whether anything changed since the last call. A queue that cannot be read counts
    ///   as a change, because it could be hiding one.
    func drainChanges() -> Bool {
      var changed = false
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = buffer.withUnsafeMutableBytes {
          UnixPlatform.readBytes(from: self.inotify.rawValue, into: $0)
        }
        guard count > 0 else {
          return changed
            || (count < 0 && UnixPlatform.lastErrorCode != UnixPlatform.ErrorCode.wouldBlock)
        }
        changed = true
      }
    }
  }
#endif
