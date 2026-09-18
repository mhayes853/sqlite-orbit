import AppIntents
import RemindersFeature
import SwiftUI

@main
struct RemindersApp: App {
  var body: some Scene {
    WindowGroup {
      RemindersRoot()
    }
  }
}

struct RemindersAppIntentsPackage: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] {
    [RemindersFeatureIntentsPackage.self]
  }
}
