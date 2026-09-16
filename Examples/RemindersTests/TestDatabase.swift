import SQLiteOrbit

@testable import RemindersFeature

func makeTestDatabase() throws -> SQLiteQueue {
  try makeEphemeralDatabase()
}
