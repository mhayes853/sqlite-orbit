#if canImport(SwiftUI)
  import SwiftUI

  private struct OrbitDatabaseEnvironmentKey: EnvironmentKey {
    static var defaultValue: (any OrbitObservableDatabase)? { nil }
  }

  extension EnvironmentValues {
    /// The database ``Fetch``, ``FetchAll``, and ``FetchOne`` read from when they are declared
    /// without one.
    ///
    /// A view hierarchy is the natural scope for "which database is this screen about", and it is
    /// the one scope ``OrbitDefaultDatabase`` cannot express: a preview, a sheet, or a test host
    /// wants its own database without disturbing the rest of the process. Reading this value in a
    /// view body is how a view that is not a fetch property reaches the same database its fetch
    /// properties are using.
    ///
    /// ```swift
    /// struct RemindersView: View {
    ///   @Environment(\.orbitDatabase) private var database
    ///   @FetchAll(Reminder.all) var reminders
    ///
    ///   var body: some View {
    ///     List(reminders, id: \.id) { Text($0.title) }
    ///   }
    /// }
    /// ```
    public var orbitDatabase: (any OrbitObservableDatabase)? {
      get { self[OrbitDatabaseEnvironmentKey.self] }
      set { self[OrbitDatabaseEnvironmentKey.self] = newValue }
    }
  }

  extension View {
    /// Gives this view and its descendants a database for their fetch properties to read from.
    ///
    /// A fetch property resolves its database from three places, in this order: the `database:`
    /// argument it was declared with, this modifier, and ``OrbitDefaultDatabase/current``. SwiftUI
    /// resolves this environment value before the property's first read, which lets a preview hand
    /// a database to a view written against the app's. Reading a property that finds none of these
    /// sources terminates with setup instructions.
    ///
    /// ```swift
    /// #Preview {
    ///   RemindersView()
    ///     .orbitDatabase(try! previewDatabase())
    /// }
    /// ```
    ///
    /// - Parameter database: The database descendants read from, or `nil` to leave them with
    ///   ``OrbitDefaultDatabase/current``.
    /// - Returns: A view that offers `database` to its descendants.
    public func orbitDatabase(_ database: (any OrbitObservableDatabase)?) -> some View {
      environment(\.orbitDatabase, database)
    }
  }
#endif
