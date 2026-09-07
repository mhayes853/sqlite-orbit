#if canImport(Observation)
  import Observation

  extension OrbitValueObservation where Value == Never {
    /// A thread-safe external value whose reads can invalidate a value observation.
    ///
    /// Accessing a member through dynamic member lookup observes only that member. Accessing
    /// ``value`` observes the value as a whole.
    ///
    /// ```swift
    /// struct Filters: Sendable {
    ///   var showsCompleted = false
    ///   var search = ""
    /// }
    ///
    /// let filters = OrbitValueObservation.ExternalValue(Filters())
    /// let observation = OrbitValueObservation.tracking { transaction in
    ///   if filters.showsCompleted {
    ///     // Fetch completed values.
    ///   } else {
    ///     // Fetch incomplete values.
    ///   }
    /// }
    /// ```
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @dynamicMemberLookup
    public final class ExternalValue<Wrapped: Sendable>: Observable, Sendable {
      private struct Box: Sendable {
        let value: any Sendable
      }

      private struct ObservationRoot {
        var value: Wrapped

        subscript<Member: Sendable>(_ keyPath: WritableKeyPath<Wrapped, Member>) -> Box {
          get { Box(value: value[keyPath: keyPath]) }
          set { value[keyPath: keyPath] = newValue.value as! Member }
        }
      }

      private struct MemberPath<Member: Sendable>: @unchecked Sendable {
        let value: WritableKeyPath<Wrapped, Member>
      }

      private struct ObservedPath: Hashable, @unchecked Sendable {
        let value: WritableKeyPath<ObservationRoot, Box>
      }

      private struct State {
        var value: Wrapped
        var valueRevision: UInt64 = 0
        var replacementRevision: UInt64 = 0
        var memberRevisions = [ObservedPath: UInt64]()
      }

      private let registrar = ObservationRegistrar()
      private let state: Lock<State>

      /// Creates an external value.
      public init(_ value: Wrapped) {
        self.state = Lock(State(value: value))
      }

      /// The complete underlying value.
      ///
      /// Reading this property observes every mutation. Prefer dynamic member lookup when only a
      /// subset of a structured value affects the observation.
      public var value: Wrapped {
        get {
          registrar.access(self, keyPath: \.value)
          let read = state.withLock {
            ($0.value, $0.valueRevision)
          }
          recordAccess(
            keyPath: \ExternalValue<Wrapped>.value,
            revision: .init(member: read.1, replacement: 0),
            isCurrent: { [weak self] in
              self?.state.withLock { $0.valueRevision == read.1 } ?? false
            }
          )
          return read.0
        }
        set {
          withWholeValueMutation {
            state.withLock { state in
              state.value = newValue
              state.valueRevision &+= 1
              state.replacementRevision &+= 1
            }
          }
        }
        _modify {
          var value = self.value
          defer { self.value = value }
          yield &value
        }
      }

      /// Reads or replaces one observed member of the underlying value.
      public subscript<Member: Sendable>(
        dynamicMember keyPath: WritableKeyPath<Wrapped, Member>
      ) -> Member {
        get {
          let memberPath = MemberPath(value: keyPath)
          let path = boxedPath(for: memberPath)
          let modelPath = modelKeyPath(for: path)
          registrar.access(self, keyPath: \.replacementEpoch)
          registrar.access(self, keyPath: modelPath)
          let read = state.withLock { state in
            (
              state.value[keyPath: memberPath.value],
              state.memberRevisions[path, default: 0],
              state.replacementRevision
            )
          }
          let revision = OrbitValueObservationExternalDependencyRevision(
            member: read.1,
            replacement: read.2
          )
          recordAccess(
            keyPath: modelPath,
            revision: revision,
            isCurrent: { [weak self] in
              self?.state
                .withLock {
                  $0.memberRevisions[path, default: 0] == revision.member
                    && $0.replacementRevision == revision.replacement
                } ?? false
            }
          )
          return read.0
        }
        set {
          let memberPath = MemberPath(value: keyPath)
          withMemberMutation(memberPath) {
            let path = boxedPath(for: memberPath)
            state.withLock { state in
              state.value[keyPath: memberPath.value] = newValue
              state.valueRevision &+= 1
              state.memberRevisions[path, default: 0] &+= 1
            }
          }
        }
        _modify {
          var value = self[dynamicMember: keyPath]
          defer { self[dynamicMember: keyPath] = value }
          yield &value
        }
      }

      /// Atomically mutates the complete underlying value.
      ///
      /// Since the changed members cannot be inferred from an arbitrary operation, this notifies
      /// whole-value observers and all current member observers.
      public func update(
        _ operation: (inout Wrapped) throws -> Void
      ) rethrows {
        try withWholeValueMutation {
          try state.withLock { state in
            defer {
              state.valueRevision &+= 1
              state.replacementRevision &+= 1
            }
            try operation(&state.value)
          }
        }
      }

      /// Atomically mutates one member of the underlying value.
      public func update<Member: Sendable>(
        _ keyPath: WritableKeyPath<Wrapped, Member>,
        _ operation: (inout Member) throws -> Void
      ) rethrows {
        let memberPath = MemberPath(value: keyPath)
        try withMemberMutation(memberPath) {
          let path = boxedPath(for: memberPath)
          try state.withLock { state in
            defer {
              state.valueRevision &+= 1
              state.memberRevisions[path, default: 0] &+= 1
            }
            try operation(&state.value[keyPath: memberPath.value])
          }
        }
      }

      // This property exists only to give each wrapped member a stable, type-erased key path for
      // ObservationRegistrar. The registrar never evaluates it.
      private var observationRoot: ObservationRoot {
        get { state.withLock { ObservationRoot(value: $0.value) } }
        set { state.withLock { $0.value = newValue.value } }
      }

      // Member reads also observe this key. Only whole-value mutations announce it, which lets a
      // replacement invalidate every member without retaining every key path ever accessed.
      private var replacementEpoch: UInt8 { 0 }

      private func boxedPath<Member: Sendable>(for path: MemberPath<Member>) -> ObservedPath {
        ObservedPath(value: \ObservationRoot.[path.value])
      }

      private func modelKeyPath(
        for path: ObservedPath
      ) -> KeyPath<ExternalValue<Wrapped>, Box> {
        (\ExternalValue<Wrapped>.observationRoot).appending(path: path.value)
      }

      private func recordAccess(
        keyPath: AnyKeyPath,
        revision: OrbitValueObservationExternalDependencyRevision,
        isCurrent: @escaping @Sendable () -> Bool
      ) {
        orbitRecordValueObservationExternalAccess(
          OrbitValueObservationExternalDependency(
            id: OrbitValueObservationExternalDependencyID(
              object: ObjectIdentifier(self),
              keyPath: keyPath
            ),
            revision: revision,
            isCurrent: isCurrent
          )
        )
      }

      private func withMemberMutation<Member: Sendable, Result: ~Copyable>(
        _ memberPath: MemberPath<Member>,
        _ operation: () throws -> Result
      ) rethrows -> Result {
        let path = boxedPath(for: memberPath)
        let modelPath = modelKeyPath(for: path)
        registrar.willSet(self, keyPath: modelPath)
        registrar.willSet(self, keyPath: \.value)
        defer {
          registrar.didSet(self, keyPath: \.value)
          registrar.didSet(self, keyPath: modelPath)
        }
        return try operation()
      }

      private func withWholeValueMutation<Result: ~Copyable>(
        _ operation: () throws -> Result
      ) rethrows -> Result {
        registrar.willSet(self, keyPath: \.value)
        registrar.willSet(self, keyPath: \.replacementEpoch)
        defer {
          registrar.didSet(self, keyPath: \.replacementEpoch)
          registrar.didSet(self, keyPath: \.value)
        }
        return try operation()
      }
    }
  }
#endif
