#!/bin/sh
# oh-my-axon installer (Linux / WSL / macOS).
#
#   ./install.sh              install into $AXON_HOME (default ~/.axon)
#   ./install.sh --dry-run    print what an install writes, and write nothing
#   ./install.sh --uninstall  remove exactly what a previous install put there
#   ./install.sh --help       list every flag
#
# The installer only ever writes files listed in its manifest and backs up
# anything it would overwrite. It never touches config.toml.
set -eu

OMA_VERSION="0.1.4"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
AXON_HOME="${AXON_HOME:-$HOME/.axon}"
MANIFEST="$AXON_HOME/.oh-my-axon-manifest"

uninstall() {
    if [ ! -f "$MANIFEST" ]; then
        echo "oh-my-axon: no manifest at $MANIFEST. There is nothing to uninstall."
        exit 0
    fi
    # Skip the header line (oh-my-axon <version>).
    tail -n +2 "$MANIFEST" | while IFS= read -r rel; do
        [ -n "$rel" ] && rm -f "$AXON_HOME/$rel"
    done
    rm -f "$MANIFEST"
    # Prune now-empty directories we may have created (ignore failures).
    # Children before parents: rmdir only removes empty directories, so
    # skills/* has to go before skills itself gets a chance.
    for d in skills/ultrawork skills/plan skills/handoff skills/audit skills hooks/bin hooks agents personas; do
        rmdir "$AXON_HOME/$d" 2>/dev/null || true
    done
    echo "oh-my-axon: removed from $AXON_HOME."
    exit 0
}

usage() {
    cat <<'EOF'
oh-my-axon installer.

  ./install.sh                     install into ~/.axon
  ./install.sh --with-format-hook  also install the opt-in format-on-edit hook
  ./install.sh --dry-run           show what an install does, write nothing
  ./install.sh --uninstall         remove the files listed in the manifest
  ./install.sh --version           print the version
  ./install.sh --help              print this text

Set AXON_HOME to install somewhere other than ~/.axon.
EOF
    exit 0
}

FORMAT_HOOK=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --uninstall) uninstall ;;
        --dry-run) DRY_RUN=1 ;;
        --with-format-hook) FORMAT_HOOK=1 ;;
        --version) echo "oh-my-axon $OMA_VERSION"; exit 0 ;;
        -h|--help) usage ;;
        # An unrecognised flag used to fall through to a full install, so a
        # typo in --dry-run wrote every file the user was trying not to write.
        # Refuse instead, and use the same exit code as gen-roles.
        *)
            echo "oh-my-axon: unknown argument: $arg" >&2
            echo "  Run ./install.sh --help to see the flags this accepts." >&2
            exit 2
            ;;
    esac
done

if [ ! -d "$SRC_DIR/home" ]; then
    echo "oh-my-axon: cannot find $SRC_DIR/home." >&2
    echo "  Run this script from a checkout of the repository." >&2
    exit 1
fi

# --dry-run: report what an install would do, then exit without writing
# anything — no copies, no manifest, no backup dir, no chmod.
if [ "$DRY_RUN" = "1" ]; then
    echo "oh-my-axon $OMA_VERSION dry run. This writes nothing to $AXON_HOME."
    (cd "$SRC_DIR/home" && find . -type f ! -name 'secret-scan.json' ! -name 'format-on-edit.json' ! -name 'format-on-edit.sh' ! -name 'format-on-edit.ps1' | sed 's|^\./||') |
    while IFS= read -r rel; do
        echo "  would install: $rel"
        dest="$AXON_HOME/$rel"
        if [ -f "$dest" ] && ! cmp -s "$SRC_DIR/home/$rel" "$dest"; then
            echo "  would back up: $rel"
        fi
    done
    echo "  would install: hooks/secret-scan.json (templated for this platform)"
    if [ "$FORMAT_HOOK" = "1" ]; then
        echo "  would install: hooks/format-on-edit.json (templated for this platform)"
        echo "  would install: hooks/bin/format-on-edit.sh"
        echo "  would install: hooks/bin/format-on-edit.ps1"
    fi
    echo "  would write:   .oh-my-axon-manifest"
    exit 0
fi

BACKUP_DIR="$AXON_HOME/oh-my-axon-backup-$(date +%Y%m%d-%H%M%S)"
backed_up=0
installed=""

install_file() {
    # $1 = source file, $2 = path relative to AXON_HOME
    dest="$AXON_HOME/$2"
    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ] && ! cmp -s "$1" "$dest"; then
        mkdir -p "$BACKUP_DIR/$(dirname "$2")"
        cp -p "$dest" "$BACKUP_DIR/$2"
        backed_up=1
    fi
    cp "$1" "$dest"
    installed="$installed$2
"
}

# 1. Everything under home/, except the hook descriptor (templated below).
#    Redirect (not pipe) into the loop so install_file's variables persist.
FILELIST="$(mktemp)"
(cd "$SRC_DIR/home" && find . -type f ! -name 'secret-scan.json' ! -name 'format-on-edit.json' ! -name 'format-on-edit.sh' ! -name 'format-on-edit.ps1' | sed 's|^\./||') > "$FILELIST"
while IFS= read -r rel; do
    install_file "$SRC_DIR/home/$rel" "$rel"
done < "$FILELIST"
rm -f "$FILELIST"

# 2. Hook descriptor: point the command at the POSIX script (relative paths
#    in hook JSON resolve from the descriptor's own directory).
mkdir -p "$AXON_HOME/hooks"
sed 's|__OMA_SECRET_SCAN_CMD__|bin/secret-scan.sh|' \
    "$SRC_DIR/home/hooks/secret-scan.json" > "$AXON_HOME/hooks/secret-scan.json"
installed="$installed
hooks/secret-scan.json"

chmod +x "$AXON_HOME/hooks/bin/secret-scan.sh"

if [ "$FORMAT_HOOK" = "1" ]; then
    # 2b. Format-on-edit hook descriptor: same pattern as secret-scan,
    #     command resolves to the POSIX script relative to the descriptor.
    mkdir -p "$AXON_HOME/hooks"
    sed 's|__OMA_FORMAT_CMD__|bin/format-on-edit.sh|' \
        "$SRC_DIR/home/hooks/format-on-edit.json" > "$AXON_HOME/hooks/format-on-edit.json"
    installed="$installed
hooks/format-on-edit.json
"
    install_file "$SRC_DIR/home/hooks/bin/format-on-edit.sh" "hooks/bin/format-on-edit.sh"
    install_file "$SRC_DIR/home/hooks/bin/format-on-edit.ps1" "hooks/bin/format-on-edit.ps1"
    chmod +x "$AXON_HOME/hooks/bin/format-on-edit.sh"
fi

# 3. Manifest for clean uninstall.
{
    echo "oh-my-axon $OMA_VERSION"
    printf '%s\n' "$installed" | grep -v '^$' | sort -u
} > "$MANIFEST"

echo "oh-my-axon $OMA_VERSION installed into $AXON_HOME"
[ "$backed_up" = 1 ] && echo "  oh-my-axon backed up the files that differ to $BACKUP_DIR."
cat <<'EOF'

Next steps:
  1. Run `axon` once. The first-run wizard finds your local servers
     (LM Studio, Ollama, llama.cpp, vLLM). To configure them by hand, see
     config/config.toml.snippet.
  2. Run /ultrawork <task> to explore, plan, implement, and verify in one pass.
     Run /plan <task> to plan only. Axon writes the plan to .axon/plans/.
  3. The agents are in ~/.axon/agents: scout, architect, executor, reviewer,
     and looker. The personas are in ~/.axon/personas: concise and thorough.
     Use both from the task tool in any session.

To remove oh-my-axon, run:  ./install.sh --uninstall
EOF
