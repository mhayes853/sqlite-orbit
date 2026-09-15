#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 TURSO_CHECKOUT [OUTPUT.artifactbundle]" >&2
  exit 64
fi

turso_checkout=$(cd "$1" && pwd)
output=${2:-"$PWD/TursoSQLite3.artifactbundle"}
stable_toolchain=${TURSO_STABLE_TOOLCHAIN:-stable}
nightly_toolchain=${TURSO_NIGHTLY_TOOLCHAIN:-nightly}
host_triple=$(rustc "+$stable_toolchain" -vV | sed -n 's/^host: //p')

targets=(
  "aarch64-apple-darwin|macos-arm64|arm64-apple-macosx|stable"
  "x86_64-apple-darwin|macos-x86_64|x86_64-apple-macosx|stable"
  "aarch64-apple-ios|ios-arm64|arm64-apple-ios|stable"
  "aarch64-apple-ios-sim|ios-sim-arm64|arm64-apple-ios-simulator|stable"
  "x86_64-apple-ios|ios-sim-x86_64|x86_64-apple-ios-simulator|stable"
  "aarch64-apple-ios-macabi|maccatalyst-arm64|arm64-apple-ios-macabi|stable"
  "x86_64-apple-ios-macabi|maccatalyst-x86_64|x86_64-apple-ios-macabi|stable"
  "aarch64-apple-tvos|tvos-arm64|arm64-apple-tvos|nightly"
  "aarch64-apple-tvos-sim|tvos-sim-arm64|arm64-apple-tvos-simulator|nightly"
  "x86_64-apple-tvos|tvos-sim-x86_64|x86_64-apple-tvos-simulator|nightly"
  "aarch64-apple-watchos|watchos-arm64|arm64-apple-watchos|nightly"
  "arm64_32-apple-watchos|watchos-arm64_32|arm64_32-apple-watchos|nightly"
  "aarch64-apple-watchos-sim|watchos-sim-arm64|arm64-apple-watchos-simulator|nightly"
  "x86_64-apple-watchos-sim|watchos-sim-x86_64|x86_64-apple-watchos-simulator|nightly"
  "aarch64-apple-visionos|visionos-arm64|arm64-apple-xros|nightly"
  "aarch64-apple-visionos-sim|visionos-sim-arm64|arm64-apple-xros-simulator|nightly"
  "x86_64-unknown-linux-gnu|linux-x86_64|x86_64-unknown-linux-gnu|stable"
)

requested_targets=${TURSO_TARGETS:-$host_triple}
read -r -a requested <<<"$requested_targets"
filtered=()
for entry in "${targets[@]}"; do
  for rust_target in "${requested[@]}"; do
    if [[ "${entry%%|*}" == "$rust_target" ]]; then
      filtered+=("$entry")
    fi
  done
done
if [[ ${#filtered[@]} -ne ${#requested[@]} ]]; then
  echo "TURSO_TARGETS names a target this script does not know how to package." >&2
  exit 64
fi

if [[ -e "$output" ]]; then
  echo "refusing to overwrite $output" >&2
  exit 73
fi

export IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-16.0}
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-13.0}
export TVOS_DEPLOYMENT_TARGET=${TVOS_DEPLOYMENT_TARGET:-16.0}
export WATCHOS_DEPLOYMENT_TARGET=${WATCHOS_DEPLOYMENT_TARGET:-9.0}
export XROS_DEPLOYMENT_TARGET=${XROS_DEPLOYMENT_TARGET:-1.0}

mkdir -p "$output/include"
header="$turso_checkout/bindings/c/include/sqlite3.h"
if [[ ! -f "$header" ]]; then
  echo "Turso's C header is missing" >&2
  exit 66
fi

# Turso implements SQLite's destructor callback ABI, but its generated declarations spell the
# callback as an untyped pointer. Preserve the ABI while exposing SQLite's function-pointer type to
# Clang importers such as Swift's.
sed 's/void \*_destroy/sqlite3_destructor_type _destroy/g' "$header" > "$output/include/sqlite3.h"
chmod 0644 "$output/include/sqlite3.h"
install -m 0644 "$turso_checkout/LICENSE.md" "$output/LICENSE.md"

printf '%s\n' \
  'module TursoSQLite3 {' \
  '  header "sqlite3.h"' \
  '  export *' \
  '}' > "$output/include/module.modulemap"

variants=()
for entry in "${filtered[@]}"; do
  IFS='|' read -r rust_target variant swift_triple toolchain <<<"$entry"
  if [[ "$rust_target" == *-apple-* && "$(uname -s)" != "Darwin" ]]; then
    echo "Building $rust_target requires macOS." >&2
    exit 69
  fi

  build_arguments=(
    build
    --manifest-path "$turso_checkout/Cargo.toml"
    --locked
    --profile lib-release
    --package turso_sqlite3
  )
  if [[ "$rust_target" != "$host_triple" ]]; then
    build_arguments+=(--target "$rust_target")
  fi
  if [[ "$toolchain" == "nightly" ]]; then
    cargo "+$nightly_toolchain" -Zbuild-std=std,panic_abort "${build_arguments[@]}"
  else
    cargo "+$stable_toolchain" "${build_arguments[@]}"
  fi

  if [[ "$rust_target" == "$host_triple" ]]; then
    library="$turso_checkout/target/lib-release/libturso_sqlite3.a"
  else
    library="$turso_checkout/target/$rust_target/lib-release/libturso_sqlite3.a"
  fi
  if [[ ! -f "$library" ]]; then
    echo "Turso did not produce its static library for $rust_target" >&2
    exit 66
  fi

  mkdir -p "$output/$variant"
  install -m 0644 "$library" "$output/$variant/libturso_sqlite3.a"
  variants+=("$variant|$swift_triple")
done

version=${TURSO_ARTIFACT_VERSION:-$(git -C "$turso_checkout" describe --tags --always)}
VARIANTS="$(printf '%s\n' "${variants[@]}")" \
  BUNDLE="$output" \
  VERSION="$version" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

variants = []
for entry in os.environ["VARIANTS"].splitlines():
    path, triple = entry.split("|", 1)
    variants.append({
        "path": f"{path}/libturso_sqlite3.a",
        "supportedTriples": [triple],
        "staticLibraryMetadata": {
            "headerPaths": ["include"],
            "moduleMapPath": "include/module.modulemap",
        },
    })

Path(os.environ["BUNDLE"], "info.json").write_text(json.dumps({
    "schemaVersion": "1.0",
    "artifacts": {
        "TursoSQLite3": {
            "version": os.environ["VERSION"],
            "type": "staticLibrary",
            "variants": variants,
        },
    },
}, indent=2) + "\n")
PY

echo "created $output for ${requested[*]}"
