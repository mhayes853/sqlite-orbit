import OSLog
import RemindersData
import SQLiteOrbit

public final class ReminderNotificationObservation: Sendable {
  private let database: RemindersDatabase
  private let scheduler: ReminderNotificationScheduler
  private let task: Task<Void, Never>

  public init(
    database: RemindersDatabase,
    scheduler: ReminderNotificationScheduler = ReminderNotificationScheduler()
  ) {
    self.database = database
    self.scheduler = scheduler
    task = Task { @concurrent in
      let observation = OrbitValueObservation
        .trackingAll(ReminderNotificationScheduler.scheduledReminders)
        .removeDuplicates()
      do {
        for try await reminders in observation.values(
          in: database,
          bufferingPolicy: .bufferingNewest(1)
        ) {
          if
            !reminders.isEmpty,
            await scheduler.authorizationStatus() == .notDetermined
          {
            _ = try await scheduler.requestAuthorization()
          }
          try await scheduler.reconcile(reminders)
        }
      } catch is CancellationError {
      } catch {
        Logger.remindersNotifications.error(
          "Reminder notification observation failed: \(error.localizedDescription)"
        )
      }
    }
  }

  deinit {
    task.cancel()
  }

  public func reconcile() async {
    do {
      try await scheduler.reconcileAll(in: database)
    } catch {
      Logger.remindersNotifications.error(
        "Reminder notification reconciliation failed: \(error.localizedDescription)"
      )
    }
  }
}

private extension Logger {
  static let remindersNotifications = Logger(
    subsystem: "co.sqlite-orbit.Reminders",
    category: "Notifications"
  )
}
