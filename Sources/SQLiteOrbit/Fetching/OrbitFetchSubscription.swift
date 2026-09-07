/// The observation a fetch property started when it was given a new request.
///
/// Tying one to a SwiftUI view's `task` is what makes a query live exactly as long as the view
/// that reads it, so drilling into a child screen stops the observation and popping back restarts
/// it:
///
/// ```swift
/// .task {
///   try? await $reminders.load(Reminder.where { !$0.isCompleted }).task
/// }
/// ```
public struct OrbitFetchSubscription: Sendable {
  private let onCancel: @Sendable () -> Void

  init(onCancel: @escaping @Sendable () -> Void) {
    self.onCancel = onCancel
  }

  /// Suspends until the surrounding task is cancelled, and then stops the observation.
  ///
  /// The property keeps the value it last observed.
  public var task: Void {
    get async throws {
      let signal = OrbitFetchSignal()
      try await withTaskCancellationHandler {
        try await signal.wait()
      } onCancel: {
        onCancel()
      }
    }
  }

  /// Stops the observation, leaving the property with the value it last observed.
  public func cancel() {
    onCancel()
  }
}
