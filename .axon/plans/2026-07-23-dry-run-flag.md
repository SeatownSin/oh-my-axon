# Plan: Add `--dry-run` flag to `install.sh` and `-DryRun` switch to `install.ps1`

## Goal
When `--dry-run`/`-DryRun` is passed, both installers enumerate every file they would install (relative path under `$AXON_HOME`), print `would install:` / `would back up:` for each, print the version line, and exit 0 — writing nothing (no copies, no backups, no manifest, no chmod). One documentation line is appended to the README Install section.

## Non-goals
- No changes to uninstall paths.
- No changes to file lists or hook-templating logic beyond gating writes behind the flag.
- No change to real-install output or behavior.

## Needs decision
**Dry-run output format** — the task specifies printing each file and any backup, plus the version line. Recommended default:
- `would install: <rel>` for every file (including `hooks/secret-scan.json`)
- `would back up: <rel> -> <$BACKUP_DIR/<rel>>` for existing files that differ (backup dir shown as the *would-be* path even though it's not created)
- version line: `oh-my-axon <version> installed into <AXON_HOME>`
- no "Next steps" block in dry-run
- exit 0

Adopted.

## Work items

### 1. Add `--dry-run` to install.sh
- **Files:** `install.sh`
- **Steps:**
  1. After the `--uninstall` positional gate (line 24), add `DRY_RUN=0` init and `[ "${1:-}" = "--dry-run" ] && DRY_RUN=1`.
  2. Inside `install_file()` (lines 44–56): wrap write operations (`mkdir -p`, `cp -p` backup, `cp`) so skipped when `DRY_RUN=1`. Instead print:
     - `would install: $2` always
     - if `[ -f "$dest" ] && ! cmp -s "$1" "$dest"`: print `would back up: $2 -> $BACKUP_DIR/$2`
     Keep `installed=` accumulation (only consumed by gated manifest path).
  3. Gate hook-descriptor `sed` write (lines 70–72): in dry-run, print `would install: hooks/secret-scan.json` instead of writing.
  4. Gate `chmod +x` (line 75) on dry-run: skip when `DRY_RUN=1`.
  5. Gate manifest-writing block (lines 80–84) on dry-run: do not create `$MANIFEST`.
  6. After manifest block: if `DRY_RUN=1`, print only version line, `exit 0` — before "Next steps" heredoc.
- **Acceptance:**
  - `sh -n install.sh` exits 0.
  - `./install.sh --dry-run` with real `$AXON_HOME`: prints `would install:` + `would back up:` lines, version line, exit 0, creates nothing.
  - `./install.sh --dry-run` with differing existing files: correct `would back up:` lines.
  - Normal `./install.sh` (no flag) behaves identically.

### 2. Add `-DryRun` switch to install.ps1
- **Files:** `install.ps1`
- **Steps:**
  1. Add `[switch]$DryRun` to `param()` (line 7): `param([switch]$Uninstall, [switch]$DryRun)`. Update header comment.
  2. Inside `Install-OmaFile` (lines 48–57): when `$DryRun`, skip writes; print `would install: <rel>` always, and `would back up: <rel> -> <backupdir/rel>` for differing existing files.
  3. Gate hook-descriptor write (lines 64–72): in dry-run, print instead of writing.
  4. Gate manifest `Set-Content` (lines 78–79) on dry-run.
  5. After manifest block: if `$DryRun`, print version line, `exit 0` — before Next-steps heredoc.
- **Acceptance:**
  - Syntax parse succeeds.
  - `.\install.ps1 -DryRun` prints would-install/would-back-up lines + version line, exit 0, writes nothing.
  - Normal `.\install.ps1` behaves identically.

### 3. Document the flag in README.md
- **Files:** `README.md`
- **Steps:**
  1. In Install section (lines 38–43), append one line after existing install-summary sentence documenting the dry-run flag.
- **Acceptance:**
  - `grep -n "dry-run\|DryRun" README.md` shows the new line.
  - Line is within/after `## Install` and before `## Use`.

## Risks
- **`set -eu` + unbound `DRY_RUN`:** mitigate with `"${DRY_RUN:-0}"` or init `DRY_RUN=0`. Reviewer: run `sh -u install.sh --dry-run`.
- **PowerShell backup-dir path in dry-run:** `$BackupDir` computed at line 48 (timestamp) even in dry-run — fine, not a write.
- **`installed` accumulation + manifest gating:** only consumer is gated manifest block.
- **Hook descriptor in dry-run (sh):** ensure no `>` redirect to `$AXON_HOME` in dry-run.
- **Line-order:** run item 1 (sh) before item 2 (ps1); README (item 3) independent, can be last.
