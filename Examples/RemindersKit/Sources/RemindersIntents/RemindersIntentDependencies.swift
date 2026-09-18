import AppIntents
import RemindersData

enum RemindersIntentDependencyKey {
  static let database = "RemindersIntentDatabase"
}

public enum RemindersIntentDependencies {
  public static func register(
    database: RemindersDatabase,
    manager: AppDependencyManager = .shared
  ) {
    manager.add(
      key: RemindersIntentDependencyKey.database,
      dependency: database
    )
  }
}
