#!/usr/bin/env bash
set -euo pipefail
reference_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$reference_dir/Sources"
# All Swift files here are generated fixtures. Remove files whose source fixture was moved or deleted.
shopt -s nullglob
for generated in "$reference_dir"/Sources/*.swift; do
  rm -- "$generated"
done
for fixture in "$reference_dir"/../SQLiteOrbitGRDBTests/Upstream/*.swift; do
  sed 's/import SQLiteOrbitGRDB/@testable import GRDB/' "$fixture" > "$reference_dir/Sources/$(basename -- "$fixture")"
done
swift test --package-path "$reference_dir" "$@"
