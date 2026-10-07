#if Vectors
  public import StructuredQueriesTursoVecCore

  extension ConvertibleToOrbitDatabaseValue where Self: VectorBytesRepresentable {
    /// Stores the vector's encoded bytes without quantizing or expanding its values.
    public func orbitDatabaseValue() -> OrbitDatabaseValue {
      .blob(vectorBytes)
    }
  }

  extension ConvertibleFromOrbitDatabaseValue where Self: VectorBytesRepresentable {
    /// Reads a vector blob, validating its encoding and any fixed dimensions.
    public init(orbitDatabaseValue value: OrbitDatabaseValue) throws {
      guard case .blob(let bytes) = value else {
        throw OrbitDatabaseValueConversionError(value: value, type: Self.self)
      }
      do {
        try self.init(vectorBytes: bytes)
      } catch {
        throw OrbitDatabaseValueConversionError(
          value: value,
          type: Self.self,
          reason: String(describing: error)
        )
      }
    }
  }

  extension Quantized8Vector: OrbitDatabaseValueConvertible {}
  extension SparseFloat32Vector: OrbitDatabaseValueConvertible {}

  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  extension InlineQuantized8Vector: OrbitDatabaseValueConvertible {}

  @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  extension SizedSparseFloat32Vector: OrbitDatabaseValueConvertible {}
#endif
