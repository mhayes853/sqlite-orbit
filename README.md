# swift-sqlite-cross

`swift-sqlite-cross` is a Swift package for coordinating SQLite transaction notifications and
database observation across processes.

GRDB remains responsible for local database access, transactions, and value observation. This
package defines the boundary used to publish successful commits to peer processes and to tell GRDB
when an external commit requires local observations to fetch fresh values.

The initial package contains:

- stable database and process identifiers;
- a commit notification value;
- protocols for cross-process transports and cancellable subscriptions; and
- a GRDB-backed database protocol with explicit external-change notification.

No IPC transport is selected yet. A local-socket transport with endpoint discovery and stale-peer
cleanup, similar to the Rust `space-sqlite` crate, is the likely first implementation.

## Installation

Add this package as a Swift Package Manager dependency and depend on the `SQLiteCross` library
product.
