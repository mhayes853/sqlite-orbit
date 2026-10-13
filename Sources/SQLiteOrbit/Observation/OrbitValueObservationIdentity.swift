/// An opaque identity for an observation definition within this process.
///
/// Obtain one from ``OrbitValueObservation/identity``. Keeping an identity does not retain the
/// observation, its captured values, or its subscriptions. It remains distinct from identities
/// created later, even after the observation is released. Identities are not persistent query keys.
public struct OrbitValueObservationIdentity: Hashable, Sendable {
  private final class Token: Sendable {}
  private let token = Token()

  init() {}

  /// Whether both identities refer to the same observation definition.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.token === rhs.token
  }

  /// Hashes the observation's identity.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(token))
  }
}
