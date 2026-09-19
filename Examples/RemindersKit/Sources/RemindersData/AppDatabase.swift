import Foundation
import SQLiteOrbit

public typealias RemindersDatabase = any OrbitDatabaseWriter & OrbitObservableDatabase

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
    let coordination = UnixDatagramIPCTransport.Configuration(
      directory: coordinationDirectory,
      backPressure: .suspend(upTo: .milliseconds(250))
    )
    let database = try OrbitIPCDatabase(
      path: .file(directory.appending(path: "reminders.sqlite")),
      coordination: coordination
    )
    #if DEBUG
      let erasesDatabaseOnSchemaChange = true
    #else
      let erasesDatabaseOnSchemaChange = false
    #endif
    try remindersMigrator(
      erasesDatabaseOnSchemaChange: erasesDatabaseOnSchemaChange
    ).migrateBlocking(database)
    return database
  }
}

extension SQLiteQueue {
  public static func reminders() throws -> SQLiteQueue {
    let database = try SQLiteQueue(path: .memory)
    try remindersMigrator().migrateBlocking(database)
    return database
  }
}
