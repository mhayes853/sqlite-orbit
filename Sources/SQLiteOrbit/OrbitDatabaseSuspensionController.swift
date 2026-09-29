import Foundation

#if canImport(UIKit) && !os(watchOS)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Selects the lifecycle observed by an ``OrbitDatabaseSuspensionController``.
///
/// Use ``manual`` when the caller owns the lifecycle. UIKit apps can observe the whole application
/// or a scene; AppKit apps can observe application activation. Keep one controller per database; a
/// scene scope is appropriate when that scene owns its own database.
public struct OrbitDatabaseSuspensionScope {
  fileprivate enum Kind {
    case manual
    #if canImport(UIKit) && !os(watchOS)
      case application
      case scene(UIScene)
    #elseif canImport(AppKit)
      case application
    #endif
  }

  fileprivate let kind: Kind

  private init(_ kind: Kind) { self.kind = kind }

  /// The owner calls ``OrbitDatabaseSuspensionController/setActive(_:)`` as its lifecycle changes.
  public static var manual: Self { Self(.manual) }

  #if canImport(UIKit) && !os(watchOS)
    /// Observes activation of the UIKit application, including apps with multiple scenes.
    public static var application: Self { Self(.application) }

    /// Observes one UIKit scene. Use only when that scene owns the database exclusively.
    public static func scene(_ scene: UIScene) -> Self { Self(.scene(scene)) }
  #elseif canImport(AppKit)
    /// Observes AppKit application activation. Losing focus can suspend writes even while the
    /// macOS process continues running; choose this scope only when that policy suits the app.
    public static var application: Self { Self(.application) }
  #endif
}

/// Suspends a database when its owning UI stops being active, then resumes it on activation.
///
/// Retain the controller for as long as it should observe the lifecycle. UIKit apps can use
/// `.application` or `.scene(scene)`; AppKit apps can observe `.application` or use `.manual` with
/// their own lifecycle callbacks.
@MainActor
public final class OrbitDatabaseSuspensionController {
  private let database: any OrbitSuspendable
  private let notificationCenter: NotificationCenter
  #if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)
    private var observers: [any NSObjectProtocol] = []
  #endif
  private var isInvalidated = false

  /// Starts observing `scope` and applies its current state to `database`.
  ///
  /// A manual controller leaves the database's current state alone until ``setActive(_:)`` is
  /// called. An automatic controller applies the current application or scene activation state now.
  /// Pass a separate `notificationCenter` when testing lifecycle notifications in isolation;
  /// post those notifications on the main thread.
  public init(
    database: any OrbitSuspendable,
    observing scope: OrbitDatabaseSuspensionScope = .manual,
    notificationCenter: NotificationCenter = .default
  ) {
    self.database = database
    self.notificationCenter = notificationCenter

    switch scope.kind {
    case .manual:
      break
    #if canImport(UIKit) && !os(watchOS)
      case .application:
        observe(UIApplication.didBecomeActiveNotification, active: true)
        observe(UIApplication.willResignActiveNotification, active: false)
        setActive(UIApplication.shared.applicationState == .active)
      case .scene(let scene):
        observe(UIScene.didActivateNotification, object: scene, active: true)
        observe(UIScene.willDeactivateNotification, object: scene, active: false)
        setActive(scene.activationState == .foregroundActive)
    #elseif canImport(AppKit)
      case .application:
        observe(NSApplication.didBecomeActiveNotification, active: true)
        observe(NSApplication.willResignActiveNotification, active: false)
        setActive(NSApplication.shared.isActive)
    #endif
    }
  }

  /// Applies a manually observed lifecycle state. Calling it repeatedly with the same state is
  /// safe. Lifecycle notifications can subsequently update an automatically observed controller.
  public func setActive(_ isActive: Bool) {
    guard !isInvalidated else { return }
    if isActive {
      database.resume()
    } else {
      database.suspend()
    }
  }

  /// Stops observing lifecycle notifications. The database keeps its current suspension state.
  public func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    #if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)
      for observer in observers { notificationCenter.removeObserver(observer) }
      observers.removeAll()
    #endif
  }

  isolated deinit {
    invalidate()
  }

  #if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)
    private func observe(
      _ name: Notification.Name,
      object: AnyObject? = nil,
      active: Bool
    ) {
      let observer = notificationCenter.addObserver(
        forName: name,
        object: object,
        queue: nil
      ) { [weak self] _ in
        // UI lifecycle notifications are posted on the main thread. Process them synchronously
        // so the writer is gated before the app can be suspended.
        MainActor.assumeIsolated { self?.setActive(active) }
      }
      observers.append(observer)
    }
  #endif
}
