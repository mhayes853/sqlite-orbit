/// A read-only view onto the value a fetch property observes.
///
/// A reader is what ``FetchAll``, ``FetchOne``, and ``Fetch`` project a member as, so that a part
/// of a fetched value can be handed to something that should read it but never write it, and that
/// still updates when the database does:
///
/// ```swift
/// @FetchAll(Reminder.all) var reminders
///
/// RemindersList(count: $reminders.count)  // an `OrbitFetchReader<Int>`
/// ```
///
/// Reading ``wrappedValue`` inside a SwiftUI view body or an `@Observable` model's tracked scope
/// registers the read with the Observation framework, exactly as reading the property it came from
/// does.
@dynamicMemberLookup
public struct OrbitFetchReader<Value: Sendable>: Sendable {
  private let storage: any OrbitFetchReaderStorage
  private let tracked: @Sendable () -> Value
  private let untracked: @Sendable () -> Value

  init(
    storage: any OrbitFetchReaderStorage,
    tracked: @escaping @Sendable () -> Value,
    untracked: @escaping @Sendable () -> Value
  ) {
    self.storage = storage
    self.tracked = tracked
    self.untracked = untracked
  }

  init(_ storage: OrbitFetchStorage<Value>) {
    self.init(
      storage: storage,
      tracked: { storage.value },
      untracked: { storage.untrackedValue }
    )
  }

  /// The observed value.
  public var wrappedValue: Value {
    tracked()
  }

  /// Returns this reader.
  public var projectedValue: Self {
    self
  }

  /// Whether a read is in flight.
  public var isLoading: Bool {
    storage.isLoading
  }

  /// The error the most recent read failed with, if it failed.
  ///
  /// A failed read leaves the last value it produced in place.
  public var loadError: (any Error)? {
    storage.loadError
  }

  /// Returns a reader of one member of the observed value.
  ///
  /// You do not call this subscript. Swift calls it when a member of the value is reached through
  /// the reader.
  public subscript<Member: Sendable>(
    dynamicMember keyPath: KeyPath<Value, Member>
  ) -> OrbitFetchReader<Member> {
    let path = OrbitFetchMemberPath(keyPath)
    let tracked = self.tracked
    let untracked = self.untracked
    return OrbitFetchReader<Member>(
      storage: storage,
      tracked: { tracked()[keyPath: path.value] },
      untracked: { untracked()[keyPath: path.value] }
    )
  }

  /// Reads the observed request again.
  ///
  /// A read that failed ended the observation, so this also resumes it.
  ///
  /// - Throws: Whatever the read throws, which also becomes ``loadError``.
  public func load() async throws {
    try await storage.load()
  }

  /// The observed value and every value the observation produces after it.
  ///
  /// ```swift
  /// for await reminders in $reminders.values { render(reminders) }
  /// ```
  public var values: OrbitFetchSequence<Value> {
    OrbitFetchSequence(storage: storage, value: untracked)
  }
}

extension OrbitFetchReader: CustomReflectable {
  /// A mirror reflecting the observed value.
  public var customMirror: Mirror {
    Mirror(reflecting: wrappedValue)
  }
}

/// The part of a fetch storage a reader needs, with the value's type erased.
protocol OrbitFetchReaderStorage: AnyObject, Sendable {
  var isLoading: Bool { get }
  var loadError: (any Error)? { get }
  func load() async throws
  func addObserver(_ handler: @escaping @Sendable () -> Void) -> OrbitSubscription
}

extension OrbitFetchStorage: OrbitFetchReaderStorage {}

// Key paths carry no concurrency guarantees of their own, and a reader's projections are read
// wherever the value is.
private struct OrbitFetchMemberPath<Root, Member>: @unchecked Sendable {
  let value: KeyPath<Root, Member>

  init(_ value: KeyPath<Root, Member>) {
    self.value = value
  }
}
