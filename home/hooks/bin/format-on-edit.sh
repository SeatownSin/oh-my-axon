#!/bin/sh
# oh-my-axon format-on-edit gate (PostToolUse).
# Reads the hook payload from stdin, extracts the edited file path,
# detects the project formatter (rustfmt / prettier / black) by config
# file, and runs it on that file only. Never blocks an edit — always
# exits 0.

payload=$(cat)

# Extract the edited file path from the payload JSON.
# Tries python3, then grep/sed, then gives up.
extract_path() {
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    # The tool payload nests its arguments under tool_input; check there
    # first, then fall back to top-level keys.
    for src in (d.get("tool_input") or {}, d):
        for k in ("file_path", "path", "file"):
            v = src.get(k)
            if v:
                print(v)
                sys.exit()
except Exception:
    pass
' 2>/dev/null
        return
    fi
    printf '%s' "$payload" | grep -oE '"(file_path|path|file)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"//; s/"$//'
}

# Walk up from a directory to find the project root (the nearest ancestor
# containing a formatter config file). Prints the root dir or nothing.
find_root() {
    dir="$1"
    i=0
    while [ "$i" -lt 12 ]; do
        if [ -f "$dir/rustfmt.toml" ] || [ -f "$dir/Cargo.toml" ]; then
            printf '%s\n' "$dir"
            return
        fi
        if ls "$dir"/.prettierrc* >/dev/null 2>&1; then
            printf '%s\n' "$dir"
            return
        fi
        if [ -f "$dir/package.json" ] && grep -q '"prettier"' "$dir/package.json" 2>/dev/null; then
            printf '%s\n' "$dir"
            return
        fi
        if [ -f "$dir/pyproject.toml" ] && grep -q '\[tool.black\]' "$dir/pyproject.toml" 2>/dev/null; then
            printf '%s\n' "$dir"
            return
        fi
        parent=$(dirname "$dir")
        [ "$parent" = "$dir" ] && break
        dir="$parent"
        i=$((i + 1))
    done
}

# Detect which formatter to use. Sets global FMT_TOOL or returns 1.
detect_formatter() {
    root=$(find_root "$PROJ_DIR")
    [ -z "$root" ] && return 1
    if [ -f "$root/rustfmt.toml" ] || [ -f "$root/Cargo.toml" ]; then
        if command -v rustfmt >/dev/null 2>&1; then
            FMT_TOOL="rustfmt"
        else
            return 1
        fi
    elif ls "$root"/.prettierrc* >/dev/null 2>&1 || { [ -f "$root/package.json" ] && grep -q '"prettier"' "$root/package.json" 2>/dev/null; }; then
        if command -v npx >/dev/null 2>&1; then
            FMT_TOOL="prettier"
        else
            return 1
        fi
    elif [ -f "$root/pyproject.toml" ] && grep -q '\[tool.black\]' "$root/pyproject.toml" 2>/dev/null; then
        if command -v black >/dev/null 2>&1; then
            FMT_TOOL="black"
        else
            return 1
        fi
    else
        return 1
    fi
}

file=$(extract_path)

# No file path found — nothing to do.
[ -z "$file" ] && exit 0

# Resolve to absolute path so the formatter can find it.
case "$file" in
    /*) target="$file" ;;
    *)  target="$PWD/$file" ;;
esac

# Must be a regular file — nothing to do if it doesn't exist.
[ -f "$target" ] || exit 0

PROJ_DIR=$(dirname "$target")
detect_formatter

case "$FMT_TOOL" in
    rustfmt)
        rustfmt "$target" 2>/dev/null || true
        ;;
    prettier)
        npx --no-install prettier --write "$target" 2>/dev/null || \
        npx prettier --write "$target" 2>/dev/null || true
        ;;
    black)
        black "$target" 2>/dev/null || true
        ;;
esac

exit 0
