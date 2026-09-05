import Foundation

extension OrbitDatabaseIdentifier {
  var coordinationKey: String {
    String(format: "%016llx", self.rawValue.stableHash)
  }
}
