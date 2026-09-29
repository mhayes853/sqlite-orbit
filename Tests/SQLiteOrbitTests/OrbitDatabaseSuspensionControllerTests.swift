import Testing

@testable import SQLiteOrbit

#if canImport(UIKit) && !os(watchOS)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@Suite @MainActor
struct OrbitDatabaseSuspensionControllerTests {
  @Test
  func manualLifecycleControlsDatabaseAndKeepsStateAfterInvalidation() {
    let database = StubDatabase()
    let controller = OrbitDatabaseSuspensionController(database: database)

    #expect(!database.isSuspended)
    #expect(database.transitions == [])

    controller.setActive(false)
    controller.setActive(false)
    #expect(database.isSuspended)
    #expect(database.transitions == [false])

    controller.setActive(true)
    #expect(!database.isSuspended)
    #expect(database.transitions == [false, true])

    controller.invalidate()
    controller.setActive(false)
    #expect(!database.isSuspended)
    #expect(database.transitions == [false, true])
  }

  #if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)
    @Test
    func applicationLifecycleUsesInjectedNotificationCenter() {
      #if canImport(UIKit) && !os(watchOS)
        let inactiveNotification = UIApplication.willResignActiveNotification
        let activeNotification = UIApplication.didBecomeActiveNotification
      #else
        let inactiveNotification = NSApplication.willResignActiveNotification
        let activeNotification = NSApplication.didBecomeActiveNotification
      #endif
      let center = NotificationCenter()
      let database = StubDatabase()
      let controller = OrbitDatabaseSuspensionController(
        database: database,
        observing: .application,
        notificationCenter: center
      )

      center.post(name: inactiveNotification, object: nil)
      #expect(database.isSuspended)
      center.post(name: activeNotification, object: nil)
      #expect(!database.isSuspended)

      controller.invalidate()
      center.post(name: inactiveNotification, object: nil)
      #expect(!database.isSuspended)
    }
  #endif

  private final class StubDatabase: OrbitSuspendable {
    private struct State {
      var isSuspended = false
      var transitions: [Bool] = []
    }

    private let state = Lock(State())

    var isSuspended: Bool { state.withLock { $0.isSuspended } }
    var transitions: [Bool] { state.withLock { $0.transitions } }

    func suspend() {
      state.withLock {
        guard !$0.isSuspended else { return }
        $0.isSuspended = true
        $0.transitions.append(false)
      }
    }

    func resume() {
      state.withLock {
        guard $0.isSuspended else { return }
        $0.isSuspended = false
        $0.transitions.append(true)
      }
    }
  }
}
