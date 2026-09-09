/// A key path that can cross a concurrency boundary.
///
/// Key paths are not `Sendable`: a subscript key path captures its arguments, which can be
/// anything at all, and the standard library has no way to describe the paths that capture
/// nothing. Every key path this package sends is a literal path to a member of a `Sendable`
/// value, so it captures nothing and is immutable, which is the guarantee the type system cannot
/// yet be told about.
struct SendableKeyPath<Path: AnyKeyPath>: Hashable, @unchecked Sendable {
  let value: Path

  init(_ value: Path) {
    self.value = value
  }
}
