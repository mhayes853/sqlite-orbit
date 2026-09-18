import AppIntents
import RemindersData

public enum RemindersIntentDependencies {
  public static func register(
    database: RemindersDatabase,
    manager: AppDependencyManager = .shared
  ) {
    manager.add(dependency: database)
  }
}

extension AppDependency where Value == RemindersDatabase {
  static func reminders(_ database: RemindersDatabase) -> AppDependency {
    let dependency = AppDependency(manager: AppDependencyManager())
    dependency.wrappedValue = database
    return dependency
  }
}
