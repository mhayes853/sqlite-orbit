#if canImport(Observation)
  import Observation
#endif

struct OrbitValueObservationExternallyTracked<Output: Sendable>: Sendable {
  let output: Output
  let session: OrbitValueObservationExternalSession?
}

struct OrbitValueObservationExternalDependencyID: Hashable, @unchecked Sendable {
  let object: ObjectIdentifier
  let keyPath: AnyKeyPath
}

struct OrbitValueObservationExternalDependencyRevision: Equatable, Sendable {
  let member: UInt64
  let replacement: UInt64
}

struct OrbitValueObservationExternalDependency: Sendable {
  let id: OrbitValueObservationExternalDependencyID
  let revision: OrbitValueObservationExternalDependencyRevision
  let isCurrent: @Sendable () -> Bool
}

final class OrbitValueObservationExternalAccessRecorder: Sendable {
  private struct State: Sendable {
    var dependencies = [
      OrbitValueObservationExternalDependencyID: OrbitValueObservationExternalDependency
    ]()
    var changedDuringAccess = false
  }

  private let state = Lock(State())

  func record(_ dependency: OrbitValueObservationExternalDependency) {
    state.withLock { state in
      if let previous = state.dependencies[dependency.id],
        previous.revision != dependency.revision
      {
        state.changedDuringAccess = true
      }
      state.dependencies[dependency.id] = dependency
    }
  }

  var isCurrent: Bool {
    let snapshot = state.withLock { ($0.changedDuringAccess, Array($0.dependencies.values)) }
    return !snapshot.0 && snapshot.1.allSatisfy { $0.isCurrent() }
  }
}

enum OrbitValueObservationExternalAccessContext {
  @TaskLocal static var recorder: OrbitValueObservationExternalAccessRecorder?
}

func orbitRecordValueObservationExternalAccess(
  _ dependency: OrbitValueObservationExternalDependency
) {
  OrbitValueObservationExternalAccessContext.recorder?.record(dependency)
}

final class OrbitValueObservationExternalSession: Sendable {
  private enum Status: Sendable {
    case candidate
    case active
    case changed
    case cancelled
  }

  private struct State: Sendable {
    var status = Status.candidate
    var cancellation: OrbitSubscription?
  }

  private let state: Lock<State>
  private let onChange: @Sendable () -> Void

  init(
    cancellation: OrbitSubscription,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.state = Lock(State(cancellation: cancellation))
    self.onChange = onChange
  }

  func activate() -> Bool {
    state.withLock { state in
      guard case .candidate = state.status else { return false }
      state.status = .active
      return true
    }
  }

  func dependencyDidChange() {
    let shouldNotify = state.withLock { state in
      switch state.status {
      case .candidate, .active:
        state.status = .changed
        return true
      case .changed, .cancelled:
        return false
      }
    }
    if shouldNotify { onChange() }
  }

  func cancel() {
    let cancellation = state.withLock { state in
      guard case .cancelled = state.status else {
        state.status = .cancelled
        defer { state.cancellation = nil }
        return state.cancellation
      }
      return nil
    }
    cancellation?.cancel()
  }

  deinit { cancel() }
}

final class OrbitValueObservationExternalTracking: Sendable {
  private let onChange = Lock<(@Sendable () -> Void)?>(nil)
  private let activeSession = Lock<OrbitValueObservationExternalSession?>(nil)

  func installOnChange(_ onChange: @escaping @Sendable () -> Void) {
    self.onChange.withLock { $0 = onChange }
  }

  func track<Output: Sendable>(
    _ operation: () throws -> Output
  ) throws -> OrbitValueObservationExternallyTracked<Output> {
    #if canImport(Observation)
      if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
        return try trackUsingObservation(operation)
      }
    #endif
    return OrbitValueObservationExternallyTracked(output: try operation(), session: nil)
  }

  func promote(_ session: OrbitValueObservationExternalSession?) -> Bool {
    guard let session else { return true }
    guard session.activate() else {
      session.cancel()
      return false
    }
    let previous = activeSession.withLock { active in
      defer { active = session }
      return active
    }
    previous?.cancel()
    return true
  }

  func discard(_ session: OrbitValueObservationExternalSession?) {
    session?.cancel()
  }

  func stop() {
    let session = activeSession.withLock { active in
      defer { active = nil }
      return active
    }
    session?.cancel()
  }

  deinit { stop() }

  #if canImport(Observation)
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func trackUsingObservation<Output: Sendable>(
      _ operation: () throws -> Output
    ) throws -> OrbitValueObservationExternallyTracked<Output> {
      let cancellationDependency = CancellationDependency()
      let session = OrbitValueObservationExternalSession(
        cancellation: OrbitSubscription {
          cancellationDependency.invalidate()
        },
        onChange: { [weak self] in
          let onChange = self?.onChange.withLock { $0 }
          onChange?()
        }
      )
      let accessRecorder = OrbitValueObservationExternalAccessRecorder()
      let result = withObservationTracking {
        OrbitValueObservationExternalAccessContext.$recorder.withValue(accessRecorder) {
          cancellationDependency.recordAccess()
          return Result { try operation() }
        }
      } onChange: { [weak session] in
        session?.dependencyDidChange()
      }
      if !accessRecorder.isCurrent { session.dependencyDidChange() }
      switch result {
      case .success(let output):
        return OrbitValueObservationExternallyTracked(
          output: output,
          session: session
        )
      case .failure(let error):
        session.cancel()
        throw error
      }
    }

    // `withObservationTracking` has no cancellation handle. Every session observes this private
    // dependency so cancelling can consume and detach all of its one-shot registrations.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private final class CancellationDependency: Observable, Sendable {
      private let registrar = ObservationRegistrar()

      func recordAccess() {
        registrar.access(self, keyPath: \.value)
      }

      func invalidate() {
        registrar.withMutation(of: self, keyPath: \.value) {}
      }

      private var value: Void { () }
    }
  #endif
}
