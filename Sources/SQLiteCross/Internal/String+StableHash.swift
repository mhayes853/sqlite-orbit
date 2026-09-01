extension String {
  var stableHash: UInt64 {
    self.utf8.reduce(into: 0xcbf2_9ce4_8422_2325) { hash, byte in
      hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
  }
}
