import Foundation

extension OrbitDatabaseIdentifier {
  // A fixed-width, filesystem-safe key naming this database in the coordination directory.
  //
  // The key is derived only from `OrbitDatabaseIdentifier.rawValue`, so every process that opens
  // the same database computes the same key without sharing any state.
  var coordinationKey: String {
    String(format: "%016llx", self.rawValue.stableHash)
  }
}
