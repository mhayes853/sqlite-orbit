#!/usr/bin/env bash
set -euo pipefail
reference_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for fixture in "$reference_dir"/../SQLiteOrbitGRDBTests/Upstream/*.swift; do
  sed 's/import SQLiteOrbitGRDB/@testable import GRDB/' "$fixture" > "$reference_dir/Sources/$(basename -- "$fixture")"
done
swift test --package-path "$reference_dir" "$@"
