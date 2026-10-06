/// The observation a fetch property started when it was given a new request.
///
/// The property owns its observation, so discarding this token leaves it running. Copies share
/// cancellation and completion. Waiting ties that observation to the lifetime of the calling task:
///
/// ```swift
/// .task {
///   try? await $reminders.load(Reminder.where { !$0.isCompleted }).waitUntilFinished()
/// }
/// ```
public struct OrbitFetchSubscription: Sendable {
  private let lifetime: OrbitFetchSubscriptionLifetime

  init(lifetime: OrbitFetchSubscriptionLifetime) {
    self.lifetime = lifetime
  }

  /// Waits until this observation is cancelled, replaced, or ends with an error.
  ///
  /// Explicit cancellation and replacement return normally. An observation error is thrown and
  /// remains available as the property's `loadError`. Copies and multiple callers wait for the
  /// same result, including callers that start waiting after the observation has finished.
  ///
  /// Cancelling a waiting task cancels this exact observation and throws `CancellationError` to
  /// that caller. A newer observation the property has started is left running. The property
  /// keeps its last observed value.
  public func waitUntilFinished() async throws {
    try await lifetime.waitUntilFinished()
  }

  /// Stops the observation, leaving the property with the value it last observed.
  ///
  /// Cancelling again has no effect. If the property has since loaded or adopted another
  /// observation, that observation is left running. Waiting callers return normally.
  public func cancel() {
    lifetime.cancel()
  }
}

/// Completion shared by a property's registration and every token returned for it.
final class OrbitFetchSubscriptionLifetime: Sendable {
  private struct State {
    var onCancel: (@Sendable () -> Void)?
    var result: Result<Void, any Error>?
    var waiters: [OrbitOneShotSignal] = []
  }

  private let state: Lock<State>

  init(onCancel: @escaping @Sendable () -> Void) {
    self.state = Lock(State(onCancel: onCancel))
  }

  func finish(_ result: Result<Void, any Error>) {
    let waiters = state.withLock { state -> [OrbitOneShotSignal] in
      guard state.result == nil else { return [] }
      state.result = result
      state.onCancel = nil
      defer { state.waiters.removeAll() }
      return state.waiters
    }
    for waiter in waiters { waiter.finish(result) }
  }

  func cancel() {
    let action = state.withLock { state -> (@Sendable () -> Void)? in
      defer { state.onCancel = nil }
      return state.onCancel
    }
    guard let action else { return }
    action()
    finish(.success(()))
  }

  func waitUntilFinished() async throws {
    let signal = OrbitOneShotSignal()
    let result = state.withLock { state -> Result<Void, any Error>? in
      if let result = state.result { return result }
      state.waiters.append(signal)
      return nil
    }
    if let result { signal.finish(result) }
    try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        try await signal.wait()
        try Task.checkCancellation()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw error
      }
    } onCancel: {
      signal.finish(.failure(CancellationError()))
      cancel()
    }
  }
}
