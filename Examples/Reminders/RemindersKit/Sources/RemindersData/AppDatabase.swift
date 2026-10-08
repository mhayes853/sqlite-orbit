import Foundation
import SQLiteOrbit

public typealias RemindersDatabase = any OrbitDatabaseWriter & OrbitObservableDatabase

/// The configured default database, which the Reminders app requires to support writes.
public var defaultRemindersDatabase: RemindersDatabase {
  guard let database = OrbitDefaultDatabase.current as? RemindersDatabase else {
    preconditionFailure("Reminders requires a writable default database.")
  }
  return database
}

public enum RemindersDatabaseConfiguration {
  public static let appGroupIdentifier = "group.co.sqlite-orbit.Reminders"
}

public enum RemindersDatabaseError: Error {
  case appGroupContainerUnavailable
}

extension OrbitIPCDatabase {
  public static func reminders() throws -> OrbitIPCDatabase {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: RemindersDatabaseConfiguration.appGroupIdentifier
      )
    else {
      throw RemindersDatabaseError.appGroupContainerUnavailable
    }
    let directory = container.appending(path: "Database", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #if targetEnvironment(simulator)
      let coordinationDirectory = URL(
        filePath: "/tmp/sqlite-orbit-reminders",
        directoryHint: .isDirectory
      )
    #else
      let coordinationDirectory = container.appending(
        path: "Coordination",
        directoryHint: .isDirectory
      )
    #endif
    let coordination = UnixDatagramIPCTransport.Configuration(directory: coordinationDirectory)
    var configuration = SQLiteConfiguration.default
    configuration.register(function: RemindersClock().$currentDate)
    let database = try OrbitIPCDatabase(
      path: .file(directory.appending(path: "reminders.sqlite")),
      configuration: configuration,
      coordination: coordination
    )
    #if DEBUG
      let erasesDatabaseOnSchemaChange = true
    #else
      let erasesDatabaseOnSchemaChange = false
    #endif
    try remindersMigrator(
      erasesDatabaseOnSchemaChange: erasesDatabaseOnSchemaChange
    )
    .migrateBlocking(database)
    return database
  }
}

extension SQLiteQueue {
  public static func reminders(
    now: @escaping @Sendable () -> Date = { .now }
  ) throws -> SQLiteQueue {
    var configuration = SQLiteConfiguration.default
    configuration.register(function: RemindersClock(now: now).$currentDate)
    let database = try SQLiteQueue(path: .memory, configuration: configuration)
    try remindersMigrator().migrateBlocking(database)
    return database
  }
}
