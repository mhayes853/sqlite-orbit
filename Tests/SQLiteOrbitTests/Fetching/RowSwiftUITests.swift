// The bindings vendored by mutable row properties need a real SwiftUI render to prove that a
// control can write through them and that the observed commit redraws the control afterwards.
#if canImport(ViewInspector) && BuiltInSQLite
  import Combine
  import SwiftUI
  import Testing
  import ViewInspector

  @testable import SQLiteOrbit

  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct RowSwiftUITests {
    @Test
    func wholeSingleRowBindingPersistsBeforeTheSetterReturns() async throws {
      let database = try await bindingDatabase(settings: true)
      let row = SingleRow(BindingSettings.self, database: database)

      row.binding.wrappedValue = BindingSettings(id: 0, isEnabled: false)

      let persisted = try database.readBlocking { transaction in
        try transaction.find(BindingSettings.all, key: 0)
      }
      #expect(!persisted.isEnabled)
    }

    @Test
    func singleRowMemberBindingPersistsAndRedraws() async throws {
      let database = try await bindingDatabase(settings: true)
      let sut = SettingsToggle(database: database)

      try await ViewHosting.host(sut) {
        try await sut.inspection.inspect(after: settle) { view in
          let toggle = try view.find(ViewType.Toggle.self)
          let isOn = try toggle.isOn()
          #expect(isOn)
          try toggle.tap()
          let persisted = try database.readBlocking { transaction in
            try transaction.find(BindingSettings.all, key: 0)
          }
          #expect(!persisted.isEnabled)
        }
        try await waitForSetting(false, in: database)
        try await sut.inspection.inspect(after: settle) { view in
          let isOn = try view.find(ViewType.Toggle.self).isOn()
          #expect(!isOn)
        }
      }
    }

    @Test
    func rowMemberBindingPersistsAndRedraws() async throws {
      let database = try await bindingDatabase(reminderCompleted: false)
      let sut = ReminderToggle(database: database)

      try await ViewHosting.host(sut) {
        try await sut.inspection.inspect(after: settle) { view in
          let toggle = try view.find(ViewType.Toggle.self)
          let isOn = try toggle.isOn()
          #expect(!isOn)
          try toggle.tap()
          let persisted = try database.readBlocking { transaction in
            try transaction.find(BindingReminder.all, key: 1)
          }
          #expect(persisted.isCompleted)
        }
        try await waitForReminder(true, in: database)
        try await sut.inspection.inspect(after: settle) { view in
          let isOn = try view.find(ViewType.Toggle.self).isOn()
          #expect(isOn)
        }
      }
    }

    @Test
    func rowBindingDisappearsWhenTheRowIsDeleted() async throws {
      let database = try await bindingDatabase(reminderCompleted: false)
      let sut = ReminderToggle(database: database)

      try await ViewHosting.host(sut) {
        try await sut.inspection.inspect(after: settle) { view in
          let isOn = try view.find(ViewType.Toggle.self).isOn()
          #expect(!isOn)
        }
        try await database.write { transaction in
          try transaction.execute(BindingReminder.find(1).delete())
        }
        try await sut.inspection.inspect(after: settle) { view in
          let text = try view.text().string()
          #expect(text == "Missing")
        }
      }
    }

    @Test
    func bindingWritesToTheEnvironmentDatabaseItReads() async throws {
      let previous = OrbitDefaultDatabase.current
      let processDefault = try await bindingDatabase(settings: true)
      let environment = try await bindingDatabase(settings: true)
      OrbitDefaultDatabase.set(processDefault)
      defer { OrbitDefaultDatabase.set(previous) }
      let sut = EnvironmentSettingsToggle()

      try await ViewHosting.host(sut.orbitDatabase(environment)) {
        try await sut.inspection.inspect(after: settle) { view in
          try view.find(ViewType.Toggle.self).tap()
        }
        try await waitForSetting(false, in: environment)
      }

      let processValue = try await processDefault.read { transaction in
        try transaction.find(BindingSettings.all, key: 0)
      }
      #expect(processValue.isEnabled)
    }
  }

  // MARK: - Views

  @MainActor
  private struct SettingsToggle: View {
    @SingleRow private var settings: BindingSettings
    let inspection = Inspection<Self>()

    init(database: any OrbitObservableDatabase) {
      _settings = SingleRow(BindingSettings.self, database: database)
    }

    var body: some View {
      Toggle("Enabled", isOn: $settings.binding(\.isEnabled))
        .onReceive(inspection.notice) { inspection.visit(self, $0) }
    }
  }

  @MainActor
  private struct EnvironmentSettingsToggle: View {
    @SingleRow(BindingSettings.self) private var settings: BindingSettings
    let inspection = Inspection<Self>()

    var body: some View {
      Toggle("Enabled", isOn: $settings.binding(\.isEnabled))
        .onReceive(inspection.notice) { inspection.visit(self, $0) }
    }
  }

  @MainActor
  private struct ReminderToggle: View {
    @Row private var reminder: BindingReminder?
    let inspection = Inspection<Self>()

    init(database: any OrbitObservableDatabase) {
      _reminder = Row(BindingReminder.self, id: 1, database: database)
    }

    @ViewBuilder
    var body: some View {
      if let binding = $reminder.binding(\.isCompleted) {
        Toggle("Completed", isOn: binding)
          .onReceive(inspection.notice) { inspection.visit(self, $0) }
      } else {
        Text("Missing")
          .onReceive(inspection.notice) { inspection.visit(self, $0) }
      }
    }
  }

  // MARK: - Support

  private let settle = Duration.milliseconds(100)

  @MainActor
  private final class Inspection<V>: InspectionEmissary {
    let notice = PassthroughSubject<UInt, Never>()
    var callbacks: [UInt: (V) -> Void] = [:]

    func visit(_ view: V, _ line: UInt) {
      if let callback = callbacks.removeValue(forKey: line) {
        callback(view)
      }
    }
  }

  private func bindingDatabase(
    settings isEnabled: Bool? = nil,
    reminderCompleted isCompleted: Bool? = nil
  ) async throws -> OrbitDatabase<SQLiteQueue> {
    let database = try inMemoryDatabase()
    try await database.write { transaction in
      try transaction.execute(
        """
        CREATE TABLE bindingSettings (
          id INTEGER PRIMARY KEY CHECK (id = 0),
          isEnabled INTEGER NOT NULL
        )
        """
      )
      try transaction.execute(
        """
        CREATE TABLE bindingReminders (
          id INTEGER PRIMARY KEY,
          isCompleted INTEGER NOT NULL
        )
        """
      )
      if let isEnabled {
        try transaction.execute(
          BindingSettings.insert { BindingSettings(id: 0, isEnabled: isEnabled) }
        )
      }
      if let isCompleted {
        try transaction.execute(
          BindingReminder.insert { BindingReminder(id: 1, isCompleted: isCompleted) }
        )
      }
    }
    return database
  }

  private func waitForSetting(
    _ expected: Bool,
    in database: some OrbitDatabaseReader
  ) async throws {
    while try await database.read({ transaction in
      try transaction.find(BindingSettings.all, key: 0).isEnabled
    }) != expected {
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private func waitForReminder(
    _ expected: Bool,
    in database: some OrbitDatabaseReader
  ) async throws {
    while try await database.read({ transaction in
      try transaction.find(BindingReminder.all, key: 1).isCompleted
    }) != expected {
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  @Table("bindingSettings")
  private struct BindingSettings: Equatable, Sendable, SingleRowTable {
    let id: Int
    var isEnabled: Bool

    static let defaultValue = BindingSettings(id: 0, isEnabled: true)
  }

  @Table("bindingReminders")
  private struct BindingReminder: Equatable, Sendable {
    let id: Int
    var isCompleted: Bool
  }
#endif
