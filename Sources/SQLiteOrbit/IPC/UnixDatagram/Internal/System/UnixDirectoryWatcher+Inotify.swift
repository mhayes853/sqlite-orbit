#if os(Linux) || os(Android)
  // inotify is imported from the same header-only module as epoll, for the same reason: Swift's
  // Glibc module leaves it out. Everything else goes through `UnixPlatform`.
  import CLinuxEvents

  extension UnixDirectoryWatcher {
    typealias Backend = Inotify

    /// The inotify instance behind a ``UnixDirectoryWatcher`` on Linux and Android.
    final class Inotify {
      private let descriptor: UnixDescriptor

      init() throws {
        self.descriptor = try UnixDescriptor(
          inotify_init1(orbit_in_nonblock | orbit_in_cloexec),
          from: "inotify_init1"
        )
      }

      func watch(_ path: String) throws {
        guard inotify_add_watch(self.descriptor.rawValue, path, orbit_in_entries_changed) >= 0
        else { throw UnixSystemError.last("inotify_add_watch") }
      }

      func drainChanges() -> Bool {
        var changed = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = buffer.withUnsafeMutableBytes {
            UnixPlatform.readBytes(from: self.descriptor.rawValue, into: $0)
          }
          if count > 0 {
            changed = true
            continue
          }
          let code = UnixPlatform.lastErrorCode
          if count < 0, code == UnixPlatform.ErrorCode.interrupted { continue }
          return changed
            || (count < 0 && code != UnixPlatform.ErrorCode.tryAgain
              && code != UnixPlatform.ErrorCode.wouldBlock)
        }
      }
    }
  }
#endif
