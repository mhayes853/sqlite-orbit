#!/usr/bin/env bash
# Runs the shared fixtures and the ported upstream tests against GRDB itself.
set -euo pipefail
reference_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tests_dir="$reference_dir/.."

# All Swift files in Sources and Upstream are generated. Remove stale ones first.
rm -rf "$reference_dir/Sources" "$reference_dir/Upstream"
mkdir -p "$reference_dir/Sources" "$reference_dir/Upstream/Support" "$reference_dir/Upstream/Resources"
for fixture in "$tests_dir"/SQLiteOrbitGRDBTests/Upstream/*.swift; do
  sed 's/import SQLiteOrbitGRDB/@testable import GRDB/' "$fixture" > "$reference_dir/Sources/$(basename -- "$fixture")"
done

# Ported upstream tests run with GRDB's original harness rather than the port's adaptation, and
# without the port's runtime skips.
swift package --package-path "$reference_dir" resolve
upstream="$reference_dir/.build/checkouts/GRDB.swift/Tests/GRDBTests"
(cd "$tests_dir/SQLiteOrbitGRDBUpstreamTests/GRDBTests" && find . -name '*.swift') | while read -r file; do
  mkdir -p "$reference_dir/Upstream/GRDBTests/$(dirname -- "$file")"
  sed -e 's/^\(\s*\)import SQLiteOrbitGRDB$/\1@testable import GRDB/' \
    -e 's/^\(\s*\)import CSQLite3$/\1import GRDBSQLite/' \
    "$tests_dir/SQLiteOrbitGRDBUpstreamTests/GRDBTests/$file" > "$reference_dir/Upstream/GRDBTests/$file"
done
for support in GRDBTestCase.swift Mutex.swift AsyncSemaphore.swift; do
  cp "$upstream/$support" "$reference_dir/Upstream/Support/$support"
done
cp "$upstream/Betty.jpeg" "$reference_dir/Upstream/Resources/Betty.jpeg"

swift test --package-path "$reference_dir" "$@"
