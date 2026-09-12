#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 TURSO_CHECKOUT [OUTPUT.artifactbundle]" >&2
  exit 64
fi

turso_checkout=$(cd "$1" && pwd)
output=${2:-"$PWD/TursoSQLite3.artifactbundle"}
host_triple=$(rustc -vV | sed -n 's/^host: //p')
target_triple=${TURSO_TARGET_TRIPLE:-$host_triple}

if [[ -e "$output" ]]; then
  echo "refusing to overwrite $output" >&2
  exit 73
fi

build_arguments=(
  build
  --manifest-path "$turso_checkout/Cargo.toml"
  --locked
  --profile lib-release
  --package turso_sqlite3
)
if [[ "$target_triple" != "$host_triple" ]]; then
  build_arguments+=(--target "$target_triple")
fi
cargo "${build_arguments[@]}"

if [[ "$target_triple" == "$host_triple" ]]; then
  library="$turso_checkout/target/lib-release/libturso_sqlite3.a"
else
  library="$turso_checkout/target/$target_triple/lib-release/libturso_sqlite3.a"
fi
header="$turso_checkout/bindings/c/include/sqlite3.h"
if [[ ! -f "$library" || ! -f "$header" ]]; then
  echo "Turso did not produce its static library and C header" >&2
  exit 66
fi

variant="$output/$target_triple"
mkdir -p "$variant/include"
install -m 0644 "$library" "$variant/libturso_sqlite3.a"
# Turso implements SQLite's destructor callback ABI, but its generated declarations spell the
# callback as an untyped pointer. Preserve the ABI while exposing SQLite's function-pointer type to
# Clang importers such as Swift's.
sed 's/void \*_destroy/sqlite3_destructor_type _destroy/g' "$header" > "$variant/include/sqlite3.h"
chmod 0644 "$variant/include/sqlite3.h"
install -m 0644 "$turso_checkout/LICENSE.md" "$output/LICENSE.md"

printf '%s\n' \
  'module TursoSQLite3 {' \
  '  header "sqlite3.h"' \
  '  export *' \
  '}' > "$variant/include/module.modulemap"

version=${TURSO_ARTIFACT_VERSION:-$(git -C "$turso_checkout" describe --tags --always)}
printf '%s\n' \
  '{' \
  '  "schemaVersion": "1.0",' \
  '  "artifacts": {' \
  '    "TursoSQLite3": {' \
  "      \"version\": \"$version\"," \
  '      "type": "staticLibrary",' \
  '      "variants": [' \
  '        {' \
  "          \"path\": \"$target_triple/libturso_sqlite3.a\"," \
  "          \"supportedTriples\": [\"$target_triple\"]," \
  '          "staticLibraryMetadata": {' \
  "            \"headerPaths\": [\"$target_triple/include\"]," \
  "            \"moduleMapPath\": \"$target_triple/include/module.modulemap\"" \
  '          }' \
  '        }' \
  '      ]' \
  '    }' \
  '  }' \
  '}' > "$output/info.json"

echo "created $output for $target_triple"
