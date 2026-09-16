import Foundation
import SQLiteOrbit

func makeAppDatabase() throws -> OrbitIPCDatabase {
  let directory = URL.applicationSupportDirectory
    .appending(path: "SQLiteOrbitReminders", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  // Simulator container paths can exceed Darwin's Unix-domain socket path limit. `/tmp` is
  // writable in the app sandbox and keeps SQLite Orbit's IPC endpoint names comfortably short.
  let coordination = UnixDatagramIPCTransport.Configuration(
    directory: URL(filePath: "/tmp/sqlite-orbit-reminders", directoryHint: .isDirectory),
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

func makeEphemeralDatabase() throws -> SQLiteQueue {
  let database = try SQLiteQueue(path: .memory)
  try remindersMigrator().migrateBlocking(database)
  return database
}
