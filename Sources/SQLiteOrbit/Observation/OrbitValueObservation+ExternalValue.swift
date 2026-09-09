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

      private typealias MemberPath<Member: Sendable> =
        SendableKeyPath<WritableKeyPath<Wrapped, Member>>
      private typealias ObservedPath = SendableKeyPath<WritableKeyPath<ObservationRoot, Box>>

      // Besides counting mutations, each token gives one field a stable Sendable identity.
      private final class VersionToken: Sendable {
        private let storage = Lock(UInt64.zero)

        var value: UInt64 { storage.withLock { $0 } }

        func increment() {
          storage.withLock { $0 &+= 1 }
        }
      }

      private struct State {
        var value: Wrapped
        var memberVersions = [ObservedPath: VersionToken]()
      }

      private let registrar = ObservationRegistrar()
      private let state: Lock<State>
      private let valueVersion = VersionToken()
      private let replacementVersion = VersionToken()

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
            ($0.value, valueVersion.value)
          }
          recordAccess(
            id: ObjectIdentifier(valueVersion),
            version: .init(member: read.1, replacement: 0),
            isCurrent: { [valueVersion] in valueVersion.value == read.1 }
          )
          return read.0
        }
        set {
          withWholeValueMutation {
            state.withLock { state in
              state.value = newValue
              valueVersion.increment()
              replacementVersion.increment()
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
          let memberPath = MemberPath(keyPath)
          let path = boxedPath(for: memberPath)
          let modelPath = modelKeyPath(for: path)
          registrar.access(self, keyPath: \.replacementEpoch)
          registrar.access(self, keyPath: modelPath)
          let read = state.withLock { state in
            let memberVersion = Self.memberVersion(for: path, in: &state)
            return (
              state.value[keyPath: memberPath.value],
              memberVersion,
              memberVersion.value,
              replacementVersion.value
            )
          }
          let version = ExternalAccess.Version(
            member: read.2,
            replacement: read.3
          )
          recordAccess(
            id: ObjectIdentifier(read.1),
            version: version,
            isCurrent: { [memberVersion = read.1, replacementVersion] in
              memberVersion.value == version.member
                && replacementVersion.value == version.replacement
            }
          )
          return read.0
        }
        set {
          let memberPath = MemberPath(keyPath)
          withMemberMutation(memberPath) {
            let path = boxedPath(for: memberPath)
            state.withLock { state in
              state.value[keyPath: memberPath.value] = newValue
              valueVersion.increment()
              Self.memberVersion(for: path, in: &state).increment()
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
              valueVersion.increment()
              replacementVersion.increment()
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
        let memberPath = MemberPath(keyPath)
        try withMemberMutation(memberPath) {
          let path = boxedPath(for: memberPath)
          try state.withLock { state in
            defer {
              valueVersion.increment()
              Self.memberVersion(for: path, in: &state).increment()
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
        ObservedPath(\ObservationRoot.[path.value])
      }

      private func modelKeyPath(
        for path: ObservedPath
      ) -> KeyPath<ExternalValue<Wrapped>, Box> {
        (\ExternalValue<Wrapped>.observationRoot).appending(path: path.value)
      }

      private static func memberVersion(
        for path: ObservedPath,
        in state: inout State
      ) -> VersionToken {
        if let version = state.memberVersions[path] { return version }
        let version = VersionToken()
        state.memberVersions[path] = version
        return version
      }

      private func recordAccess(
        id: ObjectIdentifier,
        version: ExternalAccess.Version,
        isCurrent: @escaping @Sendable () -> Bool
      ) {
        ExternalAccess(
          id: id,
          version: version,
          isCurrent: isCurrent
        )
        .record()
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
