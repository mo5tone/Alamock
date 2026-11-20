#!/usr/bin/env bash
#
# Lint the package: SwiftLint first (`.swiftlint.yml`), then the swift-format
# check (`.swift-format`). Both must be clean; `--strict` makes SwiftLint treat
# warnings as failures so a green run means zero findings.
#
# Usage:
#   scripts/lint.sh
#
# Environment:
#   SWIFTLINT     Override the SwiftLint executable (default: `swiftlint`).
#   SWIFT_FORMAT  Forwarded to scripts/format.sh.
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Resolve SwiftLint. A version-manager shim (mise/asdf/rtx) can shadow Homebrew's
# install while no version is selected, in which case `swiftlint` exists but
# cannot run — fall back to the Homebrew formula in that case.
resolve_swiftlint() {
    local candidate="${SWIFTLINT:-swiftlint}"
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" version >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return 0
    fi
    if command -v brew >/dev/null 2>&1; then
        local brew_prefix
        brew_prefix="$(brew --prefix swiftlint 2>/dev/null || true)"
        if [[ -n "$brew_prefix" && -x "$brew_prefix/bin/swiftlint" ]]; then
            printf '%s\n' "$brew_prefix/bin/swiftlint"
            return 0
        fi
    fi
    return 1
}

if ! swiftlint_bin="$(resolve_swiftlint)"; then
    echo "error: swiftlint not found. Install it with 'brew install swiftlint'." >&2
    exit 1
fi

echo "SwiftLint $("$swiftlint_bin" version) — linting"
"$swiftlint_bin" lint --strict --quiet --no-cache

echo "swift-format check"
"$repo_root/scripts/format.sh" check

echo "lint OK"
