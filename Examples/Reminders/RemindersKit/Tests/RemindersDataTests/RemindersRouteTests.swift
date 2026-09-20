import Foundation
import RemindersData
import Testing

struct RemindersRouteTests {
  @Test
  func listURLRoundTrips() throws {
    let route = RemindersRoute.list(UUID())

    #expect(RemindersRoute(url: route.url) == route)
  }

  @Test
  func reminderURLRoundTrips() throws {
    let route = RemindersRoute.reminder(UUID())

    #expect(RemindersRoute(url: route.url) == route)
  }

  @Test
  func rejectsUnrecognizedURLs() throws {
    #expect(RemindersRoute(url: URL(string: "https://example.com")!) == nil)
    #expect(RemindersRoute(url: URL(string: "orbit-reminders://tags/work")!) == nil)
    #expect(RemindersRoute(url: URL(string: "orbit-reminders://reminders/not-a-uuid")!) == nil)
  }
}
