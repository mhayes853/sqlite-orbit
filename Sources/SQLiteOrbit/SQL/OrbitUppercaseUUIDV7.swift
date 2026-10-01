#if UUIDV7
  public import UUIDV7

  /// A version 7 UUID stored as uppercase text, rather than lowercase.
  ///
  /// This is how swift-uuidv7's `UUIDV7.UppercaseRepresentation` binds an identifier. Text in
  /// either case is read.
  ///
  /// ```swift
  /// let query: SQL = """
  ///   SELECT title FROM reminders WHERE id = \(OrbitUppercaseUUIDV7(id))
  ///   """
  /// let id = try row[0, as: OrbitUppercaseUUIDV7.self].uuidV7
  /// ```
  public struct OrbitUppercaseUUIDV7: OrbitDatabaseValueConvertible, Hashable, Sendable {
    /// The identifier.
    public var uuidV7: UUIDV7

    /// Wraps an identifier to store as uppercase text.
    ///
    /// ```swift
    /// let id = OrbitUppercaseUUIDV7(UUIDV7())
    /// ```
    ///
    /// - Parameter uuidV7: The identifier.
    public init(_ uuidV7: UUIDV7) {
      self.uuidV7 = uuidV7
    }

    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      .text(uuidV7.uuidString.uppercased())
    }

    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .text(let text) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Self.self)
      }
      guard let uuid = UUIDV7(uuidString: text) else {
        throw OrbitDatabaseValueConversionError(
          value: value,
          type: Self.self,
          reason: "the text is not a version 7 UUID"
        )
      }
      self.init(uuid)
    }
  }
#endif
