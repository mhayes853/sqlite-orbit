#if canImport(Observation)
  import Observation
#endif

struct ExternalCapture<Output: Sendable>: Sendable {
  let output: Output
  let dependencies: ExternalDependencies?
}

/// Captures the observable properties read by each fetch and keeps the accepted fetch's
/// dependencies active. A dependency change invalidates the observation once.
final class ExternalTracking: Sendable {
  private let changeHandler = Lock<(@Sendable () -> Void)?>(nil)
  private let activeDependencies = Lock<ExternalDependencies?>(nil)

  func onDependencyChange(_ handler: @escaping @Sendable () -> Void) {
    changeHandler.withLock { $0 = handler }
  }

  func capture<Output: Sendable>(
    _ fetch: () throws -> Output
  ) throws -> ExternalCapture<Output> {
    #if canImport(Observation)
      if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
        return try captureUsingObservation(fetch)
      }
    #endif
    return ExternalCapture(output: try fetch(), dependencies: nil)
  }

  /// Makes a fetch's captured dependencies authoritative, replacing those from the previous fetch.
  /// Returns false when a dependency changed before the fetch could be accepted.
  func accept(_ dependencies: ExternalDependencies?) -> Bool {
    guard let dependencies else { return true }
    guard dependencies.activate() else {
      dependencies.cancel()
      return false
    }
    let previous = activeDependencies.withLock { active in
      defer { active = dependencies }
      return active
    }
    previous?.cancel()
    return true
  }

  func discard(_ dependencies: ExternalDependencies?) {
    dependencies?.cancel()
  }

  func stop() {
    let dependencies = activeDependencies.withLock { active in
      defer { active = nil }
      return active
    }
    dependencies?.cancel()
  }

  deinit { stop() }

  #if canImport(Observation)
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func captureUsingObservation<Output: Sendable>(
      _ fetch: () throws -> Output
    ) throws -> ExternalCapture<Output> {
      let cancellation = ObservationCancellation()
      let dependencies = ExternalDependencies(
        detachment: OrbitSubscription { cancellation.detach() },
        onChange: { [weak self] in
          self?.changeHandler.withLock { $0 }?()
        }
      )
      let accesses = ExternalAccessRecorder()
      let result = withObservationTracking {
        accesses.recording {
          cancellation.recordAccess()
          return Result { try fetch() }
        }
      } onChange: { [weak dependencies] in
        dependencies?.didChange()
      }

      // `ExternalValue` revisions close the race between registering a property access and reading
      // its locked storage. A raced mutation makes this fetch stale even if Observation missed it.
      if !accesses.areCurrent { dependencies.didChange() }

      switch result {
      case .success(let output):
        return ExternalCapture(
          output: output,
          dependencies: dependencies
        )
      case .failure(let error):
        dependencies.cancel()
        throw error
      }
    }
  #endif
}

/// The one-shot dependency set captured by a single fetch.
final class ExternalDependencies: Sendable {
  private enum Phase: Sendable {
    case captured
    case active
    case invalidated
    case cancelled
  }

  private let phase = Lock(Phase.captured)
  private let detachment: OrbitSubscription
  private let onChange: @Sendable () -> Void

  init(
    detachment: OrbitSubscription,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.detachment = detachment
    self.onChange = onChange
  }

  func activate() -> Bool {
    phase.withLock { phase in
      guard case .captured = phase else { return false }
      phase = .active
      return true
    }
  }

  func didChange() {
    let shouldNotify = phase.withLock { phase in
      switch phase {
      case .captured, .active:
        phase = .invalidated
        return true
      case .invalidated, .cancelled:
        return false
      }
    }
    if shouldNotify { onChange() }
  }

  func cancel() {
    let shouldDetach = phase.withLock { phase in
      guard case .cancelled = phase else {
        phase = .cancelled
        return true
      }
      return false
    }
    if shouldDetach { detachment.cancel() }
  }

  deinit { cancel() }
}

// MARK: - Detecting mutations during ExternalValue reads

struct ExternalAccess: Sendable {
  struct Version: Equatable, Sendable {
    let member: UInt64
    let replacement: UInt64
  }

  let id: ObjectIdentifier
  let version: Version
  let isCurrent: @Sendable () -> Bool

  func record() {
    ExternalAccessContext.recorder?.record(self)
  }
}

private final class ExternalAccessRecorder: Sendable {
  private struct State: Sendable {
    var accesses = [ObjectIdentifier: ExternalAccess]()
    var changedWhileRecording = false
  }

  private let state = Lock(State())

  func recording<Result>(_ operation: () throws -> Result) rethrows -> Result {
    try ExternalAccessContext.$recorder.withValue(self, operation: operation)
  }

  func record(_ access: ExternalAccess) {
    state.withLock { state in
      if let previous = state.accesses[access.id], previous.version != access.version {
        state.changedWhileRecording = true
      }
      state.accesses[access.id] = access
    }
  }

  var areCurrent: Bool {
    let snapshot = state.withLock { ($0.changedWhileRecording, Array($0.accesses.values)) }
    return !snapshot.0 && snapshot.1.allSatisfy { $0.isCurrent() }
  }
}

private enum ExternalAccessContext {
  @TaskLocal static var recorder: ExternalAccessRecorder?
}

#if canImport(Observation)
  /// `withObservationTracking` has no cancellation handle. Reading this private dependency adds it
  /// to the captured set; mutating it later consumes and detaches that set's one-shot registrations.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private final class ObservationCancellation: Observable, Sendable {
    private let registrar = ObservationRegistrar()

    func recordAccess() {
      registrar.access(self, keyPath: \.value)
    }

    func detach() {
      registrar.withMutation(of: self, keyPath: \.value) {}
    }

    private var value: Void { () }
  }
#endif
