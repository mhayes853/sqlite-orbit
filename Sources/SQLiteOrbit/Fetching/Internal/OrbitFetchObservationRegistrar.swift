#if canImport(Observation)
  import Observation
#endif

/// Publishes one field of a fetch storage to the Observation framework, so that reading the field
/// inside a SwiftUI view body or an `@Observable` model's tracked scope invalidates it when the
/// field changes.
///
/// Observation arrived after the platforms this package supports, so a registrar is a token that
/// only exists where the framework does. Without it, reads and mutations are ordinary ones, and a
/// property keeps working with no automatic invalidation.
struct OrbitFetchObservationRegistrar: Sendable {
  #if canImport(Observation)
    private let token: (any Sendable)?
  #endif

  init() {
    #if canImport(Observation)
      if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
        self.token = Token()
      } else {
        self.token = nil
      }
    #endif
  }

  /// Records that the current tracked scope, if any, read this field.
  func access() {
    #if canImport(Observation)
      guard
        #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *),
        let token = self.token as? Token
      else { return }
      token.registrar.access(token, keyPath: \.field)
    #endif
  }

  /// Runs `mutation`, telling every tracked scope that read this field that it changed.
  ///
  /// - Parameter mutation: The change to perform.
  /// - Returns: Whatever `mutation` returns.
  func withMutation<Result>(_ mutation: () throws -> Result) rethrows -> Result {
    #if canImport(Observation)
      guard
        #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *),
        let token = self.token as? Token
      else { return try mutation() }
      return try token.registrar.withMutation(of: token, keyPath: \.field, mutation)
    #else
      return try mutation()
    #endif
  }
}

#if canImport(Observation)
  /// The observed subject standing in for one field.
  ///
  /// Its `field` is never read for its value: the registrar only needs a key path to identify what
  /// was accessed, and a field of a storage that Observation can name.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private final class Token: Observable, Sendable {
    let registrar = ObservationRegistrar()

    var field: Int { 0 }
  }
#endif
