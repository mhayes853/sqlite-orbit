extension OrbitDatabaseIdentifier {
  /// The identifier's stable hash as 16 lowercase hexadecimal digits, which names its files in
  /// the coordination directory.
  var coordinationKey: String {
    let digits = String(self.rawValue.stableHash, radix: 16)
    return String(repeating: "0", count: 16 - digits.count) + digits
  }
}
