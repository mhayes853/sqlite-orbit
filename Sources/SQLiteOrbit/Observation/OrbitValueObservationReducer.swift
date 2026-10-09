/// Transforms observed values while remembering state within one observation runtime.
///
/// Pass a reducer expression to ``OrbitValueObservation/applying(_:)``. It is evaluated lazily for
/// each runtime, giving it fresh state. The observation serializes calls to the reducer, allowing
/// ordinary mutable properties:
///
/// ```swift
/// struct RunningTotal: OrbitValueObservationReducer {
///   var total = 0
///
///   mutating func reduce(_ value: Int) -> Int? {
///     total += value
///     return total
///   }
/// }
///
/// let totals = counts.applying(RunningTotal())
/// ```
public protocol OrbitValueObservationReducer<Input, Output>: Sendable {
  /// The value emitted by the preceding observation.
  associatedtype Input: Sendable

  /// The value emitted by this reducer.
  associatedtype Output: Sendable

  /// Processes an upstream value, returning `nil` to suppress it.
  ///
  /// When `Output` is optional, return `.some(nil)` to emit `nil` rather than suppress the value.
  /// A thrown error ends the observation runtime and is reported to all its subscribers.
  mutating func reduce(_ value: Input) throws -> Output?
}
