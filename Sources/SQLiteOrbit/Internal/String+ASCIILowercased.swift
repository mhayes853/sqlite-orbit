extension String {
  var asciiLowercased: String {
    String(
      decoding: utf8.map { byte in
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
          byte + (UInt8(ascii: "a") - UInt8(ascii: "A"))
        default:
          byte
        }
      },
      as: UTF8.self
    )
  }
}
