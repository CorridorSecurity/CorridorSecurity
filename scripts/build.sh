#!/bin/bash
#
# Builds the customer-facing MDM scripts in mdm/ from the templates in src/.
#
#   scripts/build.sh          write mdm/*-macos.sh
#   scripts/build.sh --check  fail if any generated file in mdm/ is stale
#
# A line of the form "# @include <relative path>" is replaced by the contents of
# that file (relative to the including file). Includes may nest.

set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
MAX_INCLUDE_DEPTH=10

# source (relative to src/macos) -> output (relative to mdm/)
BUILDS="
kandji.sh:kandji-macos.sh
jamf.sh:jamf-macos.sh
fleet.sh:fleet-macos.sh
intune.sh:intune-macos.sh
"

die() {
    echo "build.sh: $*" >&2
    exit 1
}

# expand_file <file> <depth> <stack>: write <file> to stdout with includes expanded.
expand_file() {
    local file="$1" depth="$2" stack="$3"
    local dir line target first=1

    [ -f "$file" ] || die "include not found: $file"
    [ "$depth" -le "$MAX_INCLUDE_DEPTH" ] || die "include depth exceeds $MAX_INCLUDE_DEPTH at $file"
    case "$stack" in
        *"|$file|"*) die "include cycle detected at $file" ;;
    esac
    stack="$stack|$file|"
    dir=$(dirname "$file")

    while IFS= read -r line || [ -n "$line" ]; do
        # Included files drop their shebang; the top-level file keeps its own.
        if [ "$first" -eq 1 ] && [ "$depth" -gt 0 ]; then
            first=0
            case "$line" in "#!"*) continue ;; esac
        fi
        first=0
        case "$line" in
            "# @include "*)
                target="${line#"# @include "}"
                case "$target" in
                    ""|*[[:space:]]*) die "malformed include in $file: $line" ;;
                esac
                target=$(cd "$dir" && cd "$(dirname "$target")" 2>/dev/null && echo "$PWD/$(basename "$target")") \
                    || die "include not found: $dir/${line#"# @include "} (from $file)"
                expand_file "$target" $((depth + 1)) "$stack"
                ;;
            *)
                printf '%s\n' "$line"
                ;;
        esac
    done < "$file"
}

# build_one <name.sh> <out-file>
build_one() {
    local src="$REPO_ROOT/src/macos/$1" out="$2"
    local banner="# GENERATED from src/macos/$1 by scripts/build.sh - edit the source, not this file."
    # Not a pipeline, so a die inside expand_file aborts the whole build.
    expand_file "$src" 0 "" > "$out.raw"
    awk -v banner="$banner" 'NR == 1 { print; print banner; next } { print }' "$out.raw" > "$out"
    rm -f "$out.raw"
}

build_all() {
    local outdir="$1" pair
    for pair in $BUILDS; do
        build_one "${pair%%:*}" "$outdir/${pair##*:}"
    done
}

STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/corridor-build.XXXXXX")
trap 'rm -rf "$STAGE_DIR"' EXIT
build_all "$STAGE_DIR"

if [ "${1:-}" = "--check" ]; then
    stale=0
    for pair in $BUILDS; do
        name="${pair##*:}"
        if ! diff -u "$REPO_ROOT/mdm/$name" "$STAGE_DIR/$name"; then
            echo "mdm/$name is out of date; run scripts/build.sh" >&2
            stale=1
        fi
    done
    exit "$stale"
elif [ $# -eq 0 ]; then
    for pair in $BUILDS; do
        name="${pair##*:}"
        # Overwrite in place so an existing file keeps its mode.
        if [ ! -e "$REPO_ROOT/mdm/$name" ]; then
            : > "$REPO_ROOT/mdm/$name"
            chmod 755 "$REPO_ROOT/mdm/$name"
        fi
        cat "$STAGE_DIR/$name" > "$REPO_ROOT/mdm/$name"
    done
else
    die "usage: scripts/build.sh [--check]"
fi
