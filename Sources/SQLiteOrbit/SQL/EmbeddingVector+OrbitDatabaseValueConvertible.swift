#if Vectors
  public import StructuredQueriesSQLiteVecCore

  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  extension FixedEmbeddingVector: OrbitDatabaseValueConvertible where Scalar: VectorScalar {
    /// Stores the vector using SQLite-Vec-data's default representation for its scalar type.
    ///
    /// Every scalar type uses raw little-endian bytes, matching the structured query
    /// representations. Float32 bytes are shared with SQLite Vec and Turso. Turso's tagged
    /// Float64 format and optional Float32 tag need `.TursoFloat64BytesRepresentation` and
    /// `.TursoFloat32BytesRepresentation`.
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

  // SQLiteVec's signed Int8 vectors are raw bytes without scale or shift metadata, unlike Turso's
  // `Quantized8Vector`. SQL still needs `vec_int8` to tag a bound blob before SQLiteVec uses it.
  extension [Int8].Int8BytesRepresentation: OrbitDatabaseValueConvertible {}

  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  extension FixedEmbeddingVector.Int8BytesRepresentation: OrbitDatabaseValueConvertible {}
#endif
