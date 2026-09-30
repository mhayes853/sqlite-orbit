#if SQLiteVec
  public import StructuredQueriesSQLiteVecCore

  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  extension EmbeddingVector: OrbitDatabaseValueConvertible {
    /// Stores the vector as little-endian 32-bit floats in a SQLite Vec blob.
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      var bytes = [UInt8]()
      bytes.reserveCapacity(Self.count * MemoryLayout<Float>.stride)
      for element in self {
        var bits = element.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
      }
      return .blob(bytes)
    }

    /// Reads a SQLite Vec blob with exactly this vector's number of elements.
    /// - Throws: ``OrbitDatabaseValueConversionError`` for another storage class or dimension.
    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .blob(let bytes) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Self.self)
      }
      let expectedSize = Self.count * MemoryLayout<Float>.stride
      guard bytes.count == expectedSize else {
        throw OrbitDatabaseValueConversionError(
          value: value,
          type: Self.self,
          reason: "Expected \(expectedSize) vector bytes, found \(bytes.count)"
        )
      }
      self = bytes.withUnsafeBytes { buffer in
        Self { index in
          let bits = buffer.loadUnaligned(
            fromByteOffset: index * MemoryLayout<Float>.stride,
            as: UInt32.self
          )
          return Float(bitPattern: UInt32(littleEndian: bits))
        }
      }
    }
  }
#endif
