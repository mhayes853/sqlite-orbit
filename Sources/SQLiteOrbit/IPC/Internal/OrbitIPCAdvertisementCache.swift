#if canImport(Darwin) || os(Linux) || os(Android)
  /// What each peer advertises for the databases a sender sends to, read from their markers and
  /// kept until a watch on the database's directory says it changed.
  ///
  /// The watch is drained on the sending thread, under the cache's lock, before the cache is
  /// used. A peer widening its region renames its new marker into place before it relies on the
  /// wider region, so by the time any commit it must hear about can start, the kernel has already
  /// queued that rename, and the send that commit makes cannot miss it. A watch drained on some
  /// other thread could still be behind.
  ///
  /// A database whose directory cannot be watched is read again on every send, which is slower
  /// and always correct.
  final class OrbitIPCAdvertisementCache: Sendable {
    private let registry: OrbitIPCEndpointRegistry
    private let state: Lock<State>

    /// Creates a cache of what the endpoints in `registry` advertise.
    ///
    /// - Parameters:
    ///   - registry: The coordination directory to read.
    ///   - watchesDirectories: Whether to keep what it reads until a directory watch says it
    ///     changed, rather than reading it again on every send.
    init(registry: OrbitIPCEndpointRegistry, watchesDirectories: Bool = true) {
      self.registry = registry
      self.state = Lock(State(watcher: watchesDirectories ? try? UnixDirectoryWatcher() : nil))
    }

    /// What every endpoint advertising a database advertises now.
    ///
    /// - Returns: The region each endpoint's subscriptions cover, by endpoint name.
    func advertisements(
      for databaseIdentifier: OrbitDatabaseIdentifier
    ) throws -> [String: OrbitDatabaseRegion] {
      let coordinationKey = databaseIdentifier.coordinationKey
      return try self.state.withLock { state in
        state.applyChanges()
        if let entry = state.entries[coordinationKey], entry.isCurrent {
          return entry.advertisements
        }
        if state.entries[coordinationKey] == nil {
          state.entries[coordinationKey] = try self.makeEntry(
            coordinationKey: coordinationKey,
            state: &state
          )
        }
        // Read after the watch starts, so a change made while reading is reported again.
        let advertisements = try self.registry.advertisements(coordinationKey: coordinationKey)
        state.entries[coordinationKey]!.advertisements = advertisements
        state.entries[coordinationKey]!.isCurrent = state.entries[coordinationKey]!.watch != nil
        return advertisements
      }
    }

    private func makeEntry(coordinationKey: String, state: inout State) throws -> Entry {
      // Created up front, so there is a directory to watch before any peer advertises.
      try self.registry.createDatabaseDirectory(coordinationKey: coordinationKey)
      let path = self.registry.databaseDirectoryPath(coordinationKey: coordinationKey)
      guard let watch = try? state.watcher?.watch(path) else { return Entry(watch: nil) }
      state.watchedKeys[watch] = coordinationKey
      return Entry(watch: watch)
    }

    private struct Entry {
      /// The watch on the database's directory, or `nil` if it has none.
      let watch: Int32?
      var advertisements: [String: OrbitDatabaseRegion] = [:]
      /// Whether ``advertisements`` still says what the directory holds.
      var isCurrent = false
    }

    private struct State {
      let watcher: UnixDirectoryWatcher?
      var entries: [String: Entry] = [:]
      var watchedKeys: [Int32: String] = [:]

      mutating func applyChanges() {
        guard let changes = self.watcher?.drainChanges() else { return }
        if changes.overflowed {
          for key in self.entries.keys {
            self.entries[key]!.isCurrent = false
          }
        }
        for watch in changes.changed {
          guard let key = self.watchedKeys[watch] else { continue }
          self.entries[key]?.isCurrent = false
        }
        // A directory that went away is set up again from scratch by the next send to it.
        for watch in changes.ended {
          guard let key = self.watchedKeys.removeValue(forKey: watch) else { continue }
          self.entries[key] = nil
        }
      }
    }
  }
#endif
