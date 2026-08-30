# swift-sqlite-cross

`swift-sqlite-cross` is a Swift package for coordinating SQLite transaction notifications and
database observation across processes.

The core library is independent of any SQLite driver or query builder. It defines the boundary used
to publish successful commits to peer processes and to tell a local driver when an external commit
requires observations to fetch fresh values.

The initial package contains:

- stable database and process identifiers;
- commit notifications with full-database or table-level change regions;
- protocols for cross-process transports and cancellable subscriptions; and
- a generic local database driver protocol.

Optional adapter products are enabled with package traits:

- The `SQLiteCrossGRDB` trait enables the `SQLiteCrossGRDB` product. It provides a GRDB local driver
  that observes commits and invalidates GRDB observations without echoing external notifications
  back to peers.
- The `SQLiteCrossStructuredQueries` trait enables the `SQLiteCrossStructuredQueries` product. It
  creates table-level change regions from swift-structured-queries `Table` types.

No IPC transport is selected yet. A local-socket transport with endpoint discovery and stale-peer
cleanup, similar to the Rust `space-sqlite` crate, is the likely first implementation.

## Installation

Add this package as a Swift Package Manager dependency and depend on the `SQLiteCross` library
product. Enable only the adapter traits needed by the application:

```swift
.package(
  url: "https://github.com/your-org/swift-sqlite-cross",
  from: "0.1.0",
  traits: ["SQLiteCrossGRDB", "SQLiteCrossStructuredQueries"]
)
```

The adapter traits are disabled by default, so clients that only use `SQLiteCross` do not build
GRDB or swift-structured-queries.
