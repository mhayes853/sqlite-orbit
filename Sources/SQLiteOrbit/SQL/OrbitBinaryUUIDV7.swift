#if UUIDV7
  public import UUIDV7

  /// A version 7 UUID stored as its 16 bytes, rather than as text.
  ///
  /// The bytes are stored in the order they are written, the same as swift-uuidv7's
  /// `UUIDV7.BytesRepresentation` binds them, and they are read only from a 16-byte blob.
  ///
  /// ```swift
  /// let query: SQL = """
  ///   SELECT title FROM reminders WHERE id = \(OrbitBinaryUUIDV7(id))
  ///   """
  /// let id = try row[0, as: OrbitBinaryUUIDV7.self].uuidV7
  /// ```
  public struct OrbitBinaryUUIDV7: OrbitDatabaseValueConvertible, Hashable, Sendable {
    /// The identifier.
    public var uuidV7: UUIDV7

    /// Wraps an identifier to store as bytes.
    ///
    /// ```swift
    /// let id = OrbitBinaryUUIDV7(UUIDV7())
    /// ```
    ///
    /// - Parameter uuidV7: The identifier.
    public init(_ uuidV7: UUIDV7) {
      self.uuidV7 = uuidV7
    }

    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      .blob(withUnsafeBytes(of: uuidV7.uuid, [UInt8].init))
    }

    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .blob(let bytes) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Self.self)
      }
      guard bytes.count == MemoryLayout<UUIDBytes>.size else {
        throw OrbitDatabaseValueConversionError(
          value: value,
          type: Self.self,
          reason: "the blob is \(bytes.count) bytes rather than \(MemoryLayout<UUIDBytes>.size)"
        )
      }
      let uuid = bytes.withUnsafeBytes { UUIDV7(uuid: $0.loadUnaligned(as: UUIDBytes.self)) }
      guard let uuid else {
        throw OrbitDatabaseValueConversionError(
          value: value,
          type: Self.self,
          reason: "the bytes are not a version 7 UUID"
        )
      }
      self.init(uuid)
    }
  }
#endif
