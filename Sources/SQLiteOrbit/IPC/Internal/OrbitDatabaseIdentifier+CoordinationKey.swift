extension OrbitDatabaseIdentifier {
  /// The identifier's stable hash as 16 lowercase hexadecimal digits, which names its files in
  /// the coordination directory.
  var coordinationKey: String {
    // Most significant byte first, so the digits read as the number does.
    withUnsafeBytes(of: self.rawValue.stableHash.bigEndian) { LowercaseHexadecimal.string($0) }
  }
}
