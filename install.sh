#!/bin/sh
# oh-my-axon installer (Linux / WSL / macOS).
#
#   ./install.sh              install into $AXON_HOME (default ~/.axon)
#   ./install.sh --uninstall  remove exactly what a previous install put there
#
# The installer only ever writes files listed in its manifest and backs up
# anything it would overwrite. It never touches config.toml.
set -eu

OMA_VERSION="0.1.0"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
AXON_HOME="${AXON_HOME:-$HOME/.axon}"
MANIFEST="$AXON_HOME/.oh-my-axon-manifest"

uninstall() {
    if [ ! -f "$MANIFEST" ]; then
        echo "oh-my-axon: no manifest at $MANIFEST — nothing to uninstall."
        exit 0
    fi
    # Skip the header line (oh-my-axon <version>).
    tail -n +2 "$MANIFEST" | while IFS= read -r rel; do
        [ -n "$rel" ] && rm -f "$AXON_HOME/$rel"
    done
    rm -f "$MANIFEST"
    # Prune now-empty directories we may have created (ignore failures).
    for d in skills/ultrawork skills/plan hooks/bin hooks agents personas; do
        rmdir "$AXON_HOME/$d" 2>/dev/null || true
    done
    echo "oh-my-axon: uninstalled from $AXON_HOME."
    exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ ! -d "$SRC_DIR/home" ]; then
    echo "oh-my-axon: cannot find $SRC_DIR/home — run from a checkout." >&2
    exit 1
fi

BACKUP_DIR="$AXON_HOME/oh-my-axon-backup-$(date +%Y%m%d-%H%M%S)"
backed_up=0
installed=""

install_file() {
    # $1 = source file, $2 = path relative to AXON_HOME
    dest="$AXON_HOME/$2"
    if [ "$DRY_RUN" = 1 ]; then
        echo "would install: $2"
        if [ -f "$dest" ] && ! cmp -s "$1" "$dest"; then
            echo "would back up: $2 -> $BACKUP_DIR/$2"
            backed_up=1
        fi
    else
        mkdir -p "$(dirname "$dest")"
        if [ -f "$dest" ] && ! cmp -s "$1" "$dest"; then
            mkdir -p "$BACKUP_DIR/$(dirname "$2")"
            cp -p "$dest" "$BACKUP_DIR/$2"
            backed_up=1
        fi
        cp "$1" "$dest"
    fi
    # Accumulated for the manifest path (gated in dry-run).
    installed="$installed$2
"
}

# 1. Everything under home/, except the hook descriptor (templated below).
#    Redirect (not pipe) into the loop so install_file's variables persist.
FILELIST="$(mktemp)"
(cd "$SRC_DIR/home" && find . -type f ! -name 'secret-scan.json' | sed 's|^\./||') > "$FILELIST"
while IFS= read -r rel; do
    install_file "$SRC_DIR/home/$rel" "$rel"
done < "$FILELIST"
rm -f "$FILELIST"

# 2. Hook descriptor: point the command at the POSIX script (relative paths
#    in hook JSON resolve from the descriptor's own directory).
if [ "$DRY_RUN" = 1 ]; then
    echo "would install: hooks/secret-scan.json"
else
    mkdir -p "$AXON_HOME/hooks"
    sed 's|__OMA_SECRET_SCAN_CMD__|bin/secret-scan.sh|' \
        "$SRC_DIR/home/hooks/secret-scan.json" > "$AXON_HOME/hooks/secret-scan.json"
fi
installed="$installed
hooks/secret-scan.json"

[ "$DRY_RUN" = 1 ] || chmod +x "$AXON_HOME/hooks/bin/secret-scan.sh"

# 3. Manifest for clean uninstall.
if [ "$DRY_RUN" != 1 ]; then
{
    echo "oh-my-axon $OMA_VERSION"
    printf '%s\n' "$installed" | grep -v '^$' | sort -u
} > "$MANIFEST"
fi

if [ "$DRY_RUN" = 1 ]; then
    echo "oh-my-axon $OMA_VERSION"
    exit 0
fi

echo "oh-my-axon $OMA_VERSION installed into $AXON_HOME"
[ "$backed_up" = 1 ] && echo "  (differing existing files backed up to $BACKUP_DIR)"
cat <<'EOF'

Next steps:
  1. Models: run `axon` once — the first-run wizard detects local servers
     (LM Studio/Ollama/llama.cpp/vLLM). Hand config: see config/config.toml.snippet.
  2. Try it:   /ultrawork <task>     full explore->plan->implement->verify
               /plan <task>          plan only, saved to .axon/plans/
  3. Agents land in ~/.axon/agents (scout, architect, executor, reviewer),
     personas in ~/.axon/personas (concise, thorough) — usable from the task
     tool in any session.

Uninstall any time with:  ./install.sh --uninstall
EOF
