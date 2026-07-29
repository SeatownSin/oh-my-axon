#!/bin/sh
# oh-my-axon installer smoke test (Linux / WSL / macOS).
#
#   ./tests/smoke-install.sh
#
# Drives install.sh through its full lifecycle against a throwaway AXON_HOME:
# dry run writes nothing, install lands the manifest and templates the hook,
# re-install backs up what it replaces, uninstall leaves no residue.
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
INSTALLER="$REPO_ROOT/install.sh"

# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"

SCRATCH=$(mktemp -d)
AXON_HOME="$SCRATCH/axon-home"
export AXON_HOME

# Belt and braces: this test installs and then deletes files, so make certain
# it can never be pointed at a real Axon home.
case "$AXON_HOME" in
    "$HOME"/.axon | "$HOME"/.axon/*)
        echo "refusing to run against the real AXON_HOME: $AXON_HOME" >&2
        exit 1
        ;;
esac

# Deliberately no `trap cleanup EXIT`. Under dash -- which is /bin/sh on
# Debian and Ubuntu, including the CI runners -- the exit status set by an
# EXIT trap is discarded, so a trap that ends in a successful `rm` turns a
# failing suite green. Verified: the trap observed $?=1, called `exit 1`, and
# the script still returned 0. Cleanup happens explicitly at the end instead;
# if the suite aborts early the scratch dir is left in TMPDIR, which is a far
# cheaper problem than a false green.

MANIFEST="$AXON_HOME/.oh-my-axon-manifest"

run_installer() {
    set +e
    OUT=$(sh "$INSTALLER" "$@" 2>&1)
    CODE=$?
    set -e
}

echo "oh-my-axon installer smoke test"
echo "  AXON_HOME=$AXON_HOME"

# ------------------------------------------------------------- argument gate
# An unknown flag used to fall through the arg loop into a REAL install, so a
# typo in --dry-run wrote every file the user was trying not to write. The
# Windows half never had the bug: PowerShell's parameter binder rejects an
# unrecognised flag before install.ps1 runs.
echo
echo "argument handling"
run_installer --dry-runn
assert_eq 'unknown flag is refused (exit 2)' "$CODE" 2
assert_match 'unknown flag names itself' "$OUT" 'unknown argument: --dry-runn'
assert_match 'unknown flag points at --help' "$OUT" '--help'
assert_absent 'a typo installs nothing' "$AXON_HOME"

run_installer --version
assert_eq '--version exits 0' "$CODE" 0
assert_match '--version prints a semver' "$OUT" 'oh-my-axon [0-9]+\.[0-9]+\.[0-9]+$'
assert_absent '--version installs nothing' "$AXON_HOME"

run_installer --help
assert_eq '--help exits 0' "$CODE" 0
assert_match '--help lists the uninstall flag' "$OUT" '\-\-uninstall'
assert_absent '--help installs nothing' "$AXON_HOME"

# ------------------------------------------------------------------ dry run
echo
echo "dry run writes nothing"
run_installer --dry-run
assert_eq 'dry run exits 0' "$CODE" 0
assert_match 'dry run lists an agent' "$OUT" 'would install: agents/scout\.md'
assert_match 'dry run lists the manifest' "$OUT" 'would write:.*oh-my-axon-manifest'
assert_no_match 'dry run omits the opt-in format hook' "$OUT" 'format-on-edit'
assert_absent 'dry run created no AXON_HOME' "$AXON_HOME"

# ------------------------------------------------------------------ install
echo
echo "default install"
run_installer
assert_eq 'install exits 0' "$CODE" 0
assert_file 'agent installed'   "$AXON_HOME/agents/scout.md"
assert_file 'looker installed'  "$AXON_HOME/agents/looker.md"
assert_file 'persona installed' "$AXON_HOME/personas/concise.toml"
assert_file 'skill installed'   "$AXON_HOME/skills/ultrawork/SKILL.md"
assert_file 'audit skill installed' "$AXON_HOME/skills/audit/SKILL.md"
assert_file 'hook script installed' "$AXON_HOME/hooks/bin/secret-scan.sh"
assert_file 'hook descriptor installed' "$AXON_HOME/hooks/secret-scan.json"
assert_file 'manifest written' "$MANIFEST"

# The format hook is opt-in; a default install must not land any part of it.
assert_absent 'format hook descriptor not installed' "$AXON_HOME/hooks/format-on-edit.json"
assert_absent 'format hook script not installed' "$AXON_HOME/hooks/bin/format-on-edit.sh"

# config.toml is the user's own file and must never be touched.
assert_absent 'config.toml untouched' "$AXON_HOME/config.toml"

HOOK_JSON=$(cat "$AXON_HOME/hooks/secret-scan.json")
assert_no_match 'hook template placeholder substituted' "$HOOK_JSON" '__OMA_'
assert_match 'hook points at the POSIX script' "$HOOK_JSON" 'bin/secret-scan\.sh'

if [ -x "$AXON_HOME/hooks/bin/secret-scan.sh" ]; then
    pass 'hook script is executable'
else
    fail 'hook script is executable' "not executable: $AXON_HOME/hooks/bin/secret-scan.sh"
fi

assert_match 'manifest header carries a version' "$(head -n 1 "$MANIFEST")" '^oh-my-axon [0-9]+\.[0-9]+\.[0-9]+$'

# Every path the manifest claims to have installed must actually be there,
# or uninstall silently leaves files behind.
missing=''
for rel in $(tail -n +2 "$MANIFEST"); do
    if [ ! -f "$AXON_HOME/$rel" ]; then
        missing="$missing $rel"
    fi
done
assert_eq 'every manifest entry exists on disk' "$missing" ''

# Keep a copy of the manifest so the uninstall check can verify against it.
cp "$MANIFEST" "$SCRATCH/manifest.copy"

# ----------------------------------------------------------- backup on retry
echo
echo "re-install backs up what it replaces"
echo '# locally modified' >> "$AXON_HOME/agents/scout.md"
run_installer
assert_eq 're-install exits 0' "$CODE" 0
assert_match 're-install reports a backup' "$OUT" 'backed up the files that differ'
BACKUP_COPY=$(find "$AXON_HOME" -path '*oh-my-axon-backup-*/agents/scout.md' | head -n 1)
if [ -n "$BACKUP_COPY" ]; then
    pass 'modified file was backed up'
    assert_match 'backup holds the modified content' "$(cat "$BACKUP_COPY")" 'locally modified'
else
    fail 'modified file was backed up' 'no backup copy of agents/scout.md found'
fi
assert_no_match 'installed file was restored from source' "$(cat "$AXON_HOME/agents/scout.md")" 'locally modified'

# ---------------------------------------------------------------- uninstall
echo
echo "uninstall leaves no residue"
run_installer --uninstall
assert_eq 'uninstall exits 0' "$CODE" 0
assert_absent 'manifest removed' "$MANIFEST"
assert_absent 'agents dir removed' "$AXON_HOME/agents"
assert_absent 'personas dir removed' "$AXON_HOME/personas"
assert_absent 'hooks dir removed' "$AXON_HOME/hooks"
assert_absent 'skills dir removed' "$AXON_HOME/skills"

# Anything at all left under AXON_HOME (other than backup dirs, which are
# deliberately preserved) means uninstall is not clean.
residue=$(find "$AXON_HOME" -mindepth 1 -not -path '*oh-my-axon-backup-*' 2>/dev/null || true)
assert_eq 'nothing but backups left under AXON_HOME' "$residue" ''

leftover=''
for rel in $(tail -n +2 "$SCRATCH/manifest.copy"); do
    if [ -e "$AXON_HOME/$rel" ]; then
        leftover="$leftover $rel"
    fi
done
assert_eq 'no manifest entry survives uninstall' "$leftover" ''

run_installer --uninstall
assert_eq 'uninstall is idempotent' "$CODE" 0
assert_match 'second uninstall says so' "$OUT" 'nothing to uninstall'

# ------------------------------------------------------- opt-in format hook
echo
echo "install --with-format-hook"
rm -rf "$AXON_HOME"
run_installer --with-format-hook
assert_eq 'install exits 0' "$CODE" 0
assert_file 'format hook descriptor installed' "$AXON_HOME/hooks/format-on-edit.json"
assert_file 'format hook sh installed' "$AXON_HOME/hooks/bin/format-on-edit.sh"
assert_file 'format hook ps1 installed' "$AXON_HOME/hooks/bin/format-on-edit.ps1"

FMT_JSON=$(cat "$AXON_HOME/hooks/format-on-edit.json")
assert_no_match 'format hook placeholder substituted' "$FMT_JSON" '__OMA_'
assert_match 'format hook points at the POSIX script' "$FMT_JSON" 'bin/format-on-edit\.sh'

if [ -x "$AXON_HOME/hooks/bin/format-on-edit.sh" ]; then
    pass 'format hook script is executable'
else
    fail 'format hook script is executable' 'not executable'
fi

missing=''
for rel in $(tail -n +2 "$MANIFEST"); do
    if [ ! -f "$AXON_HOME/$rel" ]; then
        missing="$missing $rel"
    fi
done
assert_eq 'format-hook manifest is accurate' "$missing" ''

run_installer --uninstall
assert_eq 'uninstall after format-hook install exits 0' "$CODE" 0
assert_absent 'format hook descriptor removed' "$AXON_HOME/hooks/format-on-edit.json"

# ---------------------------------------------------- opt-in telemetry hook
echo
echo "install --with-telemetry"
rm -rf "$AXON_HOME"
run_installer
assert_absent 'telemetry hook is not installed by default' \
    "$AXON_HOME/hooks/subagent-telemetry.json"
assert_absent 'the shared parser is not installed by default' \
    "$AXON_HOME/hooks/lib/probe.sh"

rm -rf "$AXON_HOME"
run_installer --with-telemetry
assert_eq 'install exits 0' "$CODE" 0
assert_file 'telemetry descriptor installed' "$AXON_HOME/hooks/subagent-telemetry.json"
assert_file 'telemetry sh installed' "$AXON_HOME/hooks/bin/subagent-telemetry.sh"
assert_file 'telemetry ps1 installed' "$AXON_HOME/hooks/bin/subagent-telemetry.ps1"
# The hook resolves each role's model through the shared parser, so the parser
# has to travel with it. Without this the model field silently becomes null.
assert_file 'the shared parser travels with the hook' "$AXON_HOME/hooks/lib/probe.sh"
assert_file 'the Windows parser travels with the hook' "$AXON_HOME/hooks/lib/Probe.ps1"

TEL_JSON=$(cat "$AXON_HOME/hooks/subagent-telemetry.json")
assert_no_match 'telemetry placeholder substituted' "$TEL_JSON" '__OMA_'
assert_match 'telemetry hook points at the POSIX script' "$TEL_JSON" 'bin/subagent-telemetry\.sh'
# Registered under the canonical event name. Before Axon 0.3.5 the documented
# alias SubagentEnd landed in a bucket nothing fired, and ran zero times.
assert_match 'telemetry hook registers SubagentStop' "$TEL_JSON" '"SubagentStop"'

if [ -x "$AXON_HOME/hooks/bin/subagent-telemetry.sh" ]; then
    pass 'telemetry hook script is executable'
else
    fail 'telemetry hook script is executable' 'not executable'
fi

missing=''
for rel in $(tail -n +2 "$MANIFEST"); do
    if [ ! -f "$AXON_HOME/$rel" ]; then
        missing="$missing $rel"
    fi
done
assert_eq 'telemetry manifest is accurate' "$missing" ''

# Measurements already recorded are the user's, so uninstall must not take them.
mkdir -p "$AXON_HOME/telemetry"
echo '{"ts":"t","subagentType":"scout"}' > "$AXON_HOME/telemetry/subagents.jsonl"
run_installer --uninstall
assert_eq 'uninstall after telemetry install exits 0' "$CODE" 0
assert_absent 'telemetry descriptor removed' "$AXON_HOME/hooks/subagent-telemetry.json"
assert_absent 'the shared parser is removed' "$AXON_HOME/hooks/lib/probe.sh"
assert_file 'uninstall leaves the recorded log alone' \
    "$AXON_HOME/telemetry/subagents.jsonl"
assert_match 'uninstall says where the log is' "$OUT" 'telemetry log is still at'

# ------------------------------------------------------------------ summary
if summary 'installer smoke test passed'; then
    status=0
else
    status=1
fi
rm -rf "$SCRATCH"
exit "$status"
