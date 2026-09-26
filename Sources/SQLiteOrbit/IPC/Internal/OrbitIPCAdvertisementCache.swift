#if canImport(Darwin) || os(Linux) || os(Android)
  /// What each peer advertises for the databases a sender sends to, read from their markers and
  /// kept until a watch on the coordination directory reports a change.
  ///
  /// The watch is drained on the sending thread, under the cache's lock, before the cache is
  /// used. A peer widening its region renames its new marker into place before it relies on the
  /// wider region, so by the time any commit it must hear about can start, the kernel has already
  /// queued that rename, and the send that commit makes cannot miss it. A watch drained on some
  /// other thread could still be behind.
  ///
  /// Any change forgets everything, watches included, so a database is read and watched again from
  /// scratch by the next send to it. A database whose directory cannot be watched is read on every
  /// send, which is slower and always correct.
  final class OrbitIPCAdvertisementCache: Sendable {
    private struct State {
      var watcher: UnixDirectoryWatcher?
      var advertisements: [String: [String: OrbitDatabaseRegion]] = [:]
    }

    private let registry: OrbitIPCEndpointRegistry
    private let watchesDirectories: Bool
    private let state = Lock(State())

    /// Creates a cache of what the endpoints in `registry` advertise.
    ///
    /// - Parameters:
    ///   - registry: The coordination directory to read.
    ///   - watchesDirectories: Whether to keep what it reads until a directory watch says it
    ///     changed, rather than reading it again on every send.
    init(registry: OrbitIPCEndpointRegistry, watchesDirectories: Bool = true) {
      self.registry = registry
      self.watchesDirectories = watchesDirectories
    }

    /// What every endpoint advertising a database advertises now.
    ///
    /// - Returns: The region each endpoint's subscriptions cover, by endpoint name.
    func advertisements(
      for databaseIdentifier: OrbitDatabaseIdentifier
    ) throws -> [String: OrbitDatabaseRegion] {
      let coordinationKey = databaseIdentifier.coordinationKey
      return try self.state.withLock { state in
        if state.watcher?.drainChanges() == true {
          state = State()
        }
        if let advertisements = state.advertisements[coordinationKey] {
          return advertisements
        }
        if state.watcher == nil, self.watchesDirectories {
          state.watcher = try? UnixDirectoryWatcher()
        }
        // Created up front so there is a directory to watch, and watched before it is read, so a
        // change made while reading it is reported.
        let directory = try self.registry.createDatabaseDirectory(coordinationKey: coordinationKey)
        let isWatched = (try? state.watcher?.watch(directory.path)) != nil
        let advertisements = try self.registry.advertisements(coordinationKey: coordinationKey)
        if isWatched {
          state.advertisements[coordinationKey] = advertisements
        }
        return advertisements
      }
    }
  }
#endif
