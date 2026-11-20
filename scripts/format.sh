#!/usr/bin/env bash
#
# Format — or check the formatting of — the Swift sources with swift-format.
#
# swift-format is the single source of truth for formatting in this repository;
# `.swift-format` holds the configuration. Use `fix` before committing and let
# `check` (which is what CI runs through `make verify`) catch drift.
#
# Usage:
#   scripts/format.sh            # check only (default)
#   scripts/format.sh check      # check only
#   scripts/format.sh fix        # rewrite files in place
#
# Environment:
#   SWIFT_FORMAT  Override the swift-format command (default: `xcrun swift-format`).
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

targets=(Sources Tests Package.swift)
configuration=".swift-format"

if [[ ! -f "$configuration" ]]; then
    echo "error: $configuration not found (run this script from a checkout)" >&2
    exit 1
fi

if [[ -n "${SWIFT_FORMAT:-}" ]]; then
    read -r -a swift_format <<<"$SWIFT_FORMAT"
else
    swift_format=(xcrun swift-format)
fi

if ! command -v "${swift_format[0]}" >/dev/null 2>&1; then
    echo "error: '${swift_format[0]}' not found. Install Xcode or the Swift toolchain," >&2
    echo "       or set SWIFT_FORMAT to a swift-format executable." >&2
    exit 1
fi

mode="${1:-check}"

case "$mode" in
    fix)
        echo "swift-format $( "${swift_format[@]}" --version | head -1 ) — formatting ${targets[*]}"
        "${swift_format[@]}" format \
            --in-place \
            --recursive \
            --configuration "$configuration" \
            "${targets[@]}"
        echo "formatting applied; review the diff with 'git diff' before committing."
        ;;
    check)
        echo "swift-format $( "${swift_format[@]}" --version | head -1 ) — checking ${targets[*]}"
        if ! "${swift_format[@]}" lint \
            --strict \
            --recursive \
            --configuration "$configuration" \
            "${targets[@]}"; then
            echo "" >&2
            echo "Formatting check failed. Run 'make format' and commit the result." >&2
            exit 1
        fi
        echo "formatting OK"
        ;;
    *)
        echo "usage: $(basename "$0") [check|fix]" >&2
        exit 64
        ;;
esac
