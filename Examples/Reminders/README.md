# Reminders demo

The Reminders demo is a small iOS app patterned after SQLiteData's example app. It focuses on
SQLiteOrbit itself and Apple frameworks, without CloudKit synchronization, Dependencies, or other
Point-Free support libraries.

Open `Reminders.xcodeproj`, choose the **Reminders** scheme, and run it on an iOS 17 or later
simulator.

The app demonstrates:

- an iOS 27-inspired interface built with adaptive SwiftUI and Liquid Glass controls;
- schema migrations, foreign keys, triggers, and FTS5;
- live dashboard aggregates and observed reminder queries;
- list and reminder creation and editing, including tags, priorities, due dates, and cover photos;
- transactional writes and cascade deletion;
- due-date notifications synchronized by cross-process value observation and App Intents;
- full-text reminder search;
- a search preference persisted with `SingleRowTable` and bound with `@SingleRow`;
- TipKit-driven sample data discovery; and
- detail sorting and completed-item preferences stored directly in the database.

The app database is stored in Application Support. Cross-process coordination uses a deliberately
short path under `/tmp` so its Unix-domain socket also works in the simulator's longer container
paths.

## Tests

`RemindersTests` uses Swift Testing. Every test creates a new, empty in-memory database, applies the
real app migrations, and inserts only the records required for that test. Tests do not share seeded
mock state or use snapshots.

Run the suite from Xcode or from the command line:

```sh
xcodebuild test \
  -project Examples/Reminders/Reminders.xcodeproj \
  -scheme Reminders \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipMacroValidation
```

## Regenerating the project

The Xcode project is checked in. If files or targets change, regenerate it with:

```sh
gem install xcodeproj
ruby Scripts/generate-examples-project.rb
```
