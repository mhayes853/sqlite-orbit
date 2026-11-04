#if Vectors
  import SQLiteOrbit
  import Testing

  @Suite
  struct TursoVectorValueTests {
    @Test
    func encodedValuesPreserveComponentsInRawSQLConversions() throws {
      let quantized = try Quantized8Vector(codes: [10, 20, 30], scale: 2, shift: 1)
      let sparse = try SparseFloat32Vector(
        dimensions: 6,
        indices: [0, 2, 5],
        values: [-0.0, 1.5, 2.5]
      )
      #expect(quantized.orbitDatabaseValue() == .blob(quantized.vectorBytes))
      #expect(sparse.orbitDatabaseValue() == .blob(sparse.vectorBytes))
      #expect(try Quantized8Vector(orbitDatabaseValue: quantized.orbitDatabaseValue()) == quantized)
      #expect(try SparseFloat32Vector(orbitDatabaseValue: sparse.orbitDatabaseValue()) == sparse)
      #expect(try Quantized8Vector(quantizing: quantized.decodedValues()) != quantized)
      #expect(try SparseFloat32Vector(compressing: sparse.denseValues()) != sparse)
      #expect(try Quantized8Vector?(orbitDatabaseValue: .null) == nil)
      #expect(try SparseFloat32Vector?(orbitDatabaseValue: .null) == nil)

      if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
        let inline = try InlineQuantized8Vector<3>(codes: [10, 20, 30], scale: 2, shift: 1)
        let sized = try SizedSparseFloat32Vector<6>(indices: sparse.indices, values: sparse.values)
        #expect(inline.orbitDatabaseValue() == quantized.orbitDatabaseValue())
        #expect(sized.orbitDatabaseValue() == sparse.orbitDatabaseValue())
        #expect(
          try InlineQuantized8Vector<3>(orbitDatabaseValue: quantized.orbitDatabaseValue())
            == inline
        )
        #expect(
          try SizedSparseFloat32Vector<6>(orbitDatabaseValue: sparse.orbitDatabaseValue()) == sized
        )
      }
    }

    @Test(arguments: [
      OrbitDatabaseValue.null, .integer(1), .text("[1,2,3]"), .blob([]), .blob([1, 2, 3])
    ])
    func invalidEncodedValuesReportConversionErrors(_ value: OrbitDatabaseValue) {
      let quantized = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try Quantized8Vector(orbitDatabaseValue: value)
      }
      let sparse = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try SparseFloat32Vector(orbitDatabaseValue: value)
      }
      #expect(quantized?.value == value)
      #expect(sparse?.value == value)
    }

    @Test
    func fixedEncodedValuesRejectOtherDimensions() throws {
      guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else {
        return
      }
      let quantized = try Quantized8Vector(codes: [10, 20, 30], scale: 2, shift: 1)
      let sparse = try SparseFloat32Vector(dimensions: 6, indices: [2, 5], values: [1.5, 2.5])
      let inline = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try InlineQuantized8Vector<2>(orbitDatabaseValue: quantized.orbitDatabaseValue())
      }
      let sized = #expect(throws: OrbitDatabaseValueConversionError.self) {
        try SizedSparseFloat32Vector<5>(orbitDatabaseValue: sparse.orbitDatabaseValue())
      }
      #expect(inline?.reason?.contains("dimensionMismatch") == true)
      #expect(sized?.reason?.contains("dimensionMismatch") == true)
    }
  }
#endif
