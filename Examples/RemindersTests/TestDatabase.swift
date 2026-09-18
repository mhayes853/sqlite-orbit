import RemindersData
import SQLiteOrbit

@testable import RemindersFeature

func makeTestDatabase() throws -> SQLiteQueue {
  try SQLiteQueue.reminders()
}
