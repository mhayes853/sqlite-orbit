#if UUIDV7
  public import UUIDV7

  // These are written out rather than left to the raw representable defaults, since `UUIDV7` is
  // only raw representable, by a Foundation `UUID`, where Foundation can be imported.
  extension UUIDV7: OrbitDatabaseValueConvertible {
    /// The identifier as lowercase text, the way a `UUID` is stored.
    ///
    /// Wrap an identifier in ``OrbitBinaryUUIDV7`` to store it as 16 bytes instead, or in
    /// ``OrbitUppercaseUUIDV7`` to store it as uppercase text.
    ///
    /// ```swift
    /// let query: SQL = "SELECT title FROM reminders WHERE id = \(id)"
    /// ```
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      .text(uuidString.lowercased())
    }

    /// Reads text spelling a version 7 UUID, in either case.
    ///
    /// ```swift
    /// let id = try UUIDV7(orbitDatabaseValue: row[0])
    /// ```
    ///
    /// - Throws: ``OrbitDatabaseValueConversionError`` for any other storage class, or for text
    ///   that does not spell a version 7 UUID.
    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .text(let text) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: UUIDV7.self)
      }
      guard let uuid = UUIDV7(uuidString: text) else {
        throw OrbitDatabaseValueConversionError(
          value: value,
          type: UUIDV7.self,
          reason: "the text is not a version 7 UUID"
        )
      }
      self = uuid
    }
  }
#endif
