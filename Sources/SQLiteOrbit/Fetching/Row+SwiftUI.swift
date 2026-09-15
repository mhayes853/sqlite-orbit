#if canImport(SwiftUI)
  import SwiftUI

  extension SingleRow {
    /// A binding to the complete singleton value.
    ///
    /// Assigning the binding blocks the calling thread until the save commits. A failure is
    /// reported through ``saveError`` and leaves the database observation as the authoritative
    /// value.
    @MainActor
    public var binding: Binding<Value> {
      Binding(
        get: { wrappedValue },
        set: { value in
          try? saveBlocking(value)
        }
      )
    }

    /// A binding to one member of the singleton.
    ///
    /// Assigning the binding blocks the calling thread until the save commits.
    ///
    /// Each assignment reads the latest row and changes only this member in one write transaction,
    /// so a stale view cannot overwrite unrelated fields another writer changed first.
    @MainActor
    public func binding<Member: Sendable>(
      _ keyPath: WritableKeyPath<Value, Member>
    ) -> Binding<Member> {
      let path = SendableKeyPath(keyPath)
      return Binding(
        get: { wrappedValue[keyPath: path.value] },
        set: { member in
          try? updateBlocking { $0[keyPath: path.value] = member }
        }
      )
    }
  }

  extension Row {
    /// A binding to one member of the row, or `nil` while the row is absent.
    ///
    /// Assigning the binding blocks the calling thread until the save commits.
    ///
    /// SwiftUI invalidates the view when the row disappears, but a control may read a binding once
    /// more before the replacement render. During that interval the binding returns the last
    /// member it observed. Assigning after deletion reports ``OrbitDatabaseRecordNotFoundError``
    /// through ``saveError`` and does not recreate the row.
    @MainActor
    public func binding<Member: Sendable>(
      _ keyPath: WritableKeyPath<Value, Member>
    ) -> Binding<Member>? {
      let path = SendableKeyPath(keyPath)
      guard let initialValue = wrappedValue?[keyPath: path.value] else { return nil }
      return Binding(
        get: { wrappedValue?[keyPath: path.value] ?? initialValue },
        set: { member in
          try? updateBlocking { $0[keyPath: path.value] = member }
        }
      )
    }
  }
#endif
