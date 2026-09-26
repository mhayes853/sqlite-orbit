import Foundation
import RemindersData
import Testing

struct RemindersRouteTests {
  @Test(arguments: [RemindersRoute.list(UUID()), .reminder(UUID())])
  func urlRoundTrips(route: RemindersRoute) throws {
    #expect(RemindersRoute(url: route.url) == route)
  }

  @Test
  func rejectsUnrecognizedURLs() throws {
    #expect(RemindersRoute(url: URL(string: "https://example.com")!) == nil)
    #expect(RemindersRoute(url: URL(string: "orbit-reminders://tags/work")!) == nil)
    #expect(RemindersRoute(url: URL(string: "orbit-reminders://reminders/not-a-uuid")!) == nil)
  }
}
