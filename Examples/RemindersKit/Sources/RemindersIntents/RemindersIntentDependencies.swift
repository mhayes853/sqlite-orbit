import AppIntents
import RemindersData

public struct RemindersIntentDatabase: Sendable {
  public let value: RemindersDatabase
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
  public static func reminders(_ database: RemindersDatabase) -> AppDependency {
    let dependency = AppDependency(manager: AppDependencyManager())
    dependency.wrappedValue = RemindersIntentDatabase(value: database)
    return dependency
  }
}
