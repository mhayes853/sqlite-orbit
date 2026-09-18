import AppIntents
import RemindersData

struct RemindersIntentDatabase: Sendable {
  let value: RemindersDatabase
}

public enum RemindersIntentDependencies {
  public static func register(
    database: RemindersDatabase,
    manager: AppDependencyManager = .shared
  ) {
    manager.add(dependency: RemindersIntentDatabase(value: database))
  }
}

extension AppDependency where Value == RemindersIntentDatabase {
  static func reminders(_ database: RemindersDatabase) -> AppDependency {
    let dependency = AppDependency(manager: AppDependencyManager())
    dependency.wrappedValue = RemindersIntentDatabase(value: database)
    return dependency
  }
}
