#if Vectors
  import StructuredQueriesCore
  public import StructuredQueriesSQLiteVecCore

  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  extension FixedEmbeddingVector: OrbitDatabaseValueConvertible where Scalar: VectorScalar {
    /// Stores the vector using SQLite-Vec-data's default representation for its scalar type.
    ///
    /// Float32 uses little-endian bytes shared with SQLite Vec and Turso. Float64 and Float16
    /// include Turso/libSQL's format tag, matching the structured query representations.
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      .blob(orbitVectorBytes)
    }

    private var orbitVectorBytes: [UInt8] {
      guard case .blob(let bytes) = VectorBytesRepresentation(queryOutput: self).queryBinding else {
        preconditionFailure("A vector representation must bind a blob")
      }
      return bytes
    }

    /// Reads a blob with this vector's scalar format and number of elements.
    /// - Throws: ``OrbitDatabaseValueConversionError`` for another storage class, format, or dimension.
    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .blob(let bytes) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Self.self)
      }
      do {
        var decoder = VectorBlobDecoder(bytes: bytes)
        self = try VectorBytesRepresentation(decoder: &decoder).queryOutput
      } catch {
        // Obtain the size from the same codec rather than assuming a scalar's native memory
        // layout. Do this only on failure so successful reads do not allocate a second vector.
        let expectedSize = Self(repeating: 0).orbitVectorBytes.count
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

  // The vector representations decode one blob. A generic witness supplies QueryDecoder's
  // primitive overloads without depending on a live statement or the StructuredQueries trait.
  private struct VectorBlobDecoder: QueryDecoder {
    let bytes: [UInt8]

    mutating func decode<Value>(_ columnType: Value.Type) throws -> Value? {
      guard let value = bytes as? Value else {
        throw QueryDecodingError.typeMismatch(columnType)
      }
      return value
    }
  }
#endif
