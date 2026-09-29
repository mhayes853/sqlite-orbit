#if canImport(SwiftUI)
  import SwiftUI

  private struct OrbitDatabaseSuspensionModifier: ViewModifier {
    let database: any OrbitSuspendable & AnyObject
    // An explicit value drives manual suspension; nil observes the application lifecycle.
    let isActive: Bool?
    @State private var controller: OrbitDatabaseSuspensionController?

    func body(content: Content) -> some View {
      content
        .onAppear { start() }
        .onChange(of: ObjectIdentifier(database)) { _ in start() }
        .onChange(of: isActive) { value in
          if let value { controller?.setActive(value) }
        }
        .onDisappear {
          controller?.invalidate()
          controller = nil
        }
    }

    private func start() {
      controller?.invalidate()
      if let isActive {
        let controller = OrbitDatabaseSuspensionController(database: database)
        controller.setActive(isActive)
        self.controller = controller
      } else {
        #if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)
          controller = OrbitDatabaseSuspensionController(
            database: database,
            observing: .application
          )
        #else
          controller = OrbitDatabaseSuspensionController(database: database)
        #endif
      }
    }
  }

  extension View {
    /// Suspends `database` whenever `isActive` is false, and resumes it when true.
    ///
    /// The controller follows the identity of the database instance when the view redraws. This
    /// modifier accepts reference types so that identity remains stable across redraws.
    public func orbitDatabaseSuspension(
      _ database: any OrbitSuspendable & AnyObject,
      isActive: Bool
    ) -> some View {
      modifier(OrbitDatabaseSuspensionModifier(database: database, isActive: isActive))
    }
  }

  #if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)
    extension View {
      /// Observes UIKit or AppKit application activation and manages suspension of `database`.
      ///
      /// Apply this at the root of a view that stays mounted for the application lifecycle. On
      /// macOS, losing focus can suspend writes even while the process keeps running; use the
      /// `isActive:` overload for another policy.
      public func orbitDatabaseSuspension(
        _ database: any OrbitSuspendable & AnyObject
      ) -> some View {
        modifier(OrbitDatabaseSuspensionModifier(database: database, isActive: nil))
      }
    }
  #elseif os(watchOS)
    private struct OrbitSceneDatabaseSuspensionModifier: ViewModifier {
      let database: any OrbitSuspendable & AnyObject
      @Environment(\.scenePhase) private var scenePhase

      func body(content: Content) -> some View {
        content.orbitDatabaseSuspension(database, isActive: scenePhase == .active)
      }
    }

    extension View {
      /// Uses the watchOS scene phase to manage suspension of `database`.
      public func orbitDatabaseSuspension(
        _ database: any OrbitSuspendable & AnyObject
      ) -> some View {
        modifier(OrbitSceneDatabaseSuspensionModifier(database: database))
      }
    }
  #endif
#endif
