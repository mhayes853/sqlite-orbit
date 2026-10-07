#if Vectors
  public import StructuredQueriesSQLiteVecCore

  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  extension FixedEmbeddingVector: OrbitDatabaseValueConvertible where Scalar: VectorScalar {
    /// Stores the vector using SQLite-Vec-data's default representation for its scalar type.
    ///
    /// Float32 uses little-endian bytes shared with SQLite Vec and Turso. Float64 includes
    /// Turso's format tag, matching the structured query representations.
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      .blob(vectorBytes)
    }

    /// Reads a blob with this vector's scalar format and number of elements.
    /// - Throws: ``OrbitDatabaseValueConversionError`` for another storage class, format, or dimension.
    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .blob(let bytes) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Self.self)
      }
      do {
        try self.init(vectorBytes: bytes)
      } catch {
        // Obtain the size from the same codec rather than assuming a scalar's native memory
        // layout. Do this only on failure so successful reads do not allocate a second vector.
        let expectedSize = Self(repeating: 0).vectorBytes.count
        throw OrbitDatabaseValueConversionError(
          value: value,
          type: Self.self,
          reason: bytes.count != expectedSize
            ? "Expected \(expectedSize) vector bytes, found \(bytes.count)"
            : "Invalid vector bytes for \(Scalar.self)"
        )
      }
    }
  }

#endif
