#!/usr/bin/env bash
#
# Lint the package: SwiftLint first (`.swiftlint.yml`), then the swift-format
# check (`.swift-format`). Both must be clean; `--strict` makes SwiftLint treat
# warnings as failures so a green run means zero findings.
#
# SwiftLint is pinned in `.mise.toml` and installed with `mise install`, so the
# version used here is the version CI runs.
#
# Usage:
#   scripts/lint.sh
#
# Environment:
#   SWIFTLINT     Override the SwiftLint executable (default: `swiftlint`, which
#                 mise resolves to the pinned version).
#   SWIFT_FORMAT  Forwarded to scripts/format.sh.
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swiftlint_bin="${SWIFTLINT:-swiftlint}"
if ! "$swiftlint_bin" version >/dev/null 2>&1; then
    echo "error: swiftlint not found or not runnable. Run 'mise install' (pins 0.65.1)." >&2
    exit 1
fi

echo "SwiftLint $("$swiftlint_bin" version) — linting"
"$swiftlint_bin" lint --strict --quiet --no-cache

echo "swift-format check"
"$repo_root/scripts/format.sh" check

echo "lint OK"
