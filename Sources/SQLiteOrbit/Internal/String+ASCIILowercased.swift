extension String {
  var asciiLowercased: String {
    // The bytes are read in place rather than through the `utf8` view's iterator, which costs
    // several times as much over names as short as most are. The lowercased name is written
    // straight into the new string, so one short enough to be stored inline allocates nothing.
    var string = self
    return string.withUTF8 { bytes in
      let uppercase = UInt8(ascii: "A")...UInt8(ascii: "Z")
      guard bytes.contains(where: uppercase.contains) else { return self }
      return String(unsafeUninitializedCapacity: bytes.count) { buffer in
        for index in bytes.indices {
          let byte = bytes[index]
          buffer[index] =
            uppercase.contains(byte) ? byte + (UInt8(ascii: "a") - UInt8(ascii: "A")) : byte
        }
        return bytes.count
      }
    }
  }
}
