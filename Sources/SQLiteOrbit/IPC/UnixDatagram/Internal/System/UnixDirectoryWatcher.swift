#if canImport(Darwin) || os(Linux) || os(Android)
  /// Watches directories for entries appearing, disappearing or being renamed, and says, without
  /// blocking, whether any of them has changed.
  ///
  /// It is inotify on Linux and Android, and on Darwin a kqueue watching each directory's vnode. A
  /// directory that is removed or moved away also counts as a change, after which its watch reports
  /// nothing more. Nothing about it is thread-safe: the caller serializes every use.
  final class UnixDirectoryWatcher: @unchecked Sendable {
    private let backend: Backend

    init() throws {
      self.backend = try Backend()
    }

    /// Starts watching the directory at `path`.
    ///
    /// - Throws: A ``UnixSystemError`` if the directory cannot be watched, which includes the
    ///   system running out of watches.
    func watch(_ path: String) throws {
      try self.backend.watch(path)
    }

    /// Takes every change the kernel has queued, without waiting for more.
    ///
    /// - Returns: Whether anything changed since the last call. A queue that cannot be read counts
    ///   as a change, because it could be hiding one.
    func drainChanges() -> Bool {
      self.backend.drainChanges()
    }
  }
#endif
