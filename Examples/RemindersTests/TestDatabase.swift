import RemindersData
import SQLiteOrbit

func makeTestDatabase() throws -> SQLiteQueue {
  try SQLiteQueue.reminders()
}
