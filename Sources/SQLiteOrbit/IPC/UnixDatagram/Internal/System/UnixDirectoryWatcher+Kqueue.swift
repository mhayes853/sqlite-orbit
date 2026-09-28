#if canImport(Darwin)
  // kqueue, the `kevent` struct and the vnode filter exist only in Darwin, as does `O_EVTONLY`, so
  // this backend imports it itself. The `kevent` call is reached through `systemKevent`.
  import Darwin

  /// Watches directories for entries appearing, disappearing or being renamed, and says, without
  /// blocking, whether any of them has changed.
  ///
  /// It is a kqueue watching each directory's vnode on Darwin, and inotify on Linux and Android. A
  /// directory that is removed or moved away also counts as a change, after which its watch reports
  /// nothing more. Nothing about it is thread-safe: the caller serializes every use.
  final class UnixDirectoryWatcher: @unchecked Sendable {
    private let descriptor: UnixDescriptor
    private var directories: [UnixDescriptor] = []

    init() throws {
      self.descriptor = try UnixDescriptor(kqueue(), from: "kqueue")
      _ = fcntl(self.descriptor.rawValue, F_SETFD, FD_CLOEXEC)
    }

    /// Starts watching the directory at `path`.
    ///
    /// - Throws: A ``UnixSystemError`` if the directory cannot be watched, which includes the
    ///   system running out of watches.
    func watch(_ path: String) throws {
      // `O_EVTONLY` opens the directory only to hear about it, so the watch does not keep the
      // volume it is on from being unmounted.
      let directory = try UnixDescriptor(
        open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC),
        from: "open"
      )
      var change = kevent(
        ident: UInt(directory.rawValue),
        filter: Int16(EVFILT_VNODE),
        flags: UInt16(EV_ADD | EV_CLEAR),
        fflags: UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE),
        data: 0,
        udata: nil
      )
      guard systemKevent(self.descriptor.rawValue, &change, 1, nil, 0, nil) == 0 else {
        throw UnixSystemError.last("kevent")
      }
      self.directories.append(directory)
    }

    /// Takes every change the kernel has queued, without waiting for more.
    ///
    /// - Returns: Whether anything changed since the last call. A queue that cannot be read counts
    ///   as a change, because it could be hiding one.
    func drainChanges() -> Bool {
      var changed = false
      var events: [kevent] = Array(
        repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil),
        count: 16
      )
      var timeout = timespec(tv_sec: 0, tv_nsec: 0)
      while true {
        let count = systemKevent(
          self.descriptor.rawValue,
          nil,
          0,
          &events,
          Int32(events.count),
          &timeout
        )

        guard count > 0 else { return changed || count < 0 }
        changed = true
      }
    }
  }
#endif
