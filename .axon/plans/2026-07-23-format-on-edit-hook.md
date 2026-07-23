# Plan: Add OPT-IN auto-format PostToolUse hook

**Goal:** Add an opt-in `format-on-edit` hook (PostToolUse) to oh-my-axon, following the secret-scan hook pattern for descriptor layout, cross-platform scripts, and installer templating. The hook auto-formats edited files per project config (rustfmt / prettier / black) and never blocks an edit.

## Baseline (verified)

- `home/` contains 11 files: 4 agents, 2 hooks/bin scripts, 1 secret-scan.json, 2 personas, 2 skill SKILL.md files.
- The dry-run output lists **13 lines** (10 copy-loop files + secret-scan.json + manifest). With `--with-format-hook`, **4 extra lines** appear (format-on-edit.json, .sh, .ps1, + the flag is noted in dry-run) → 17 total.
- Without the flag: installed file count and dry-run output are unchanged (identical to current behavior).
- `install.sh.tmp` is stale (lacks `--dry-run`); **do not modify**.

## Necessary decisions

1. **File-count baseline (13):** The "13 files" in acceptance refers to 13 dry-run output lines (10 copied + secret-scan.json + manifest). Adopted as-is.
2. **Payload extraction:** PostToolUse payloads are JSON; file path extracted via a prioritized list of JSON keys: `file_path`, `path`, `file`. If none found or JSON is invalid (garbage stdin), do nothing and exit 0.
3. **Formatter lookup order:** rustfmt.toml or Cargo.toml top-level → rustfmt; `.prettierrc*` or `prettier` key in package.json → `npx prettier --write`; pyproject.toml with `[tool.black]` → black. First match wins.
4. **Hook timeout:** 10s, matching secret-scan's descriptor.

## Work items (sequential)

### Item 1: Create `home/hooks/format-on-edit.json`

**Files:** `home/hooks/format-on-edit.json` (new)

**Steps:**
- Copy `secret-scan.json` structure but use `PostToolUse` instead of `PreToolUse`.
- Matcher: file-editing tools only — `^(search_replace|write_file|create_file|edit_file|apply_patch|Write|Edit|MultiEdit)$` (no bash/run_terminal_cmd).
- Command: `__OMA_FORMAT_CMD__` placeholder.
- Timeout: 10.

**Acceptance:**
- File is valid JSON.
- Contains `PostToolUse`, `__OMA_FORMAT_CMD__`, matcher of edit tools only.

### Item 2: Create `home/hooks/bin/format-on-edit.sh`

**Files:** `home/hooks/bin/format-on-edit.sh` (new)

**Steps:**
- Shebang `#!/bin/sh`.
- Read payload from stdin via `payload=$(cat)`.
- Extract file path from JSON using a priority list of keys (`file_path`, `path`, `file`). Use a POSIX-compatible approach: try `grep`/`sed` to pull the value, or use `python3`/`jq` if available. **Recommended default:** use `python3 -c` to parse JSON robustly, fall back to grep/sed, fall back to no-op.
- Normalize the path to project-relative.
- Detect formatter:
  - `rustfmt.toml` or `Cargo.toml` in project root → `rustfmt "$file"` (if `rustfmt` on PATH).
  - `.prettierrc*` or `prettier` in `package.json` → `npx prettier --write "$file"` (if `npx` on PATH).
  - `pyproject.toml` with `[tool.black]` → `black "$file"` (if `black` on PATH).
- First match wins; run formatter on that file only. If config found but tool not installed, silently do nothing.
- **Always `exit 0`** — never emit a blocking decision, never fail.
- On garbage/invalid JSON stdin: do nothing, exit 0.

**Acceptance:**
- `sh -n home/hooks/bin/format-on-edit.sh` passes.
- Exits 0 on garbage stdin (e.g., `echo "garbage" | sh home/hooks/bin/format-on-edit.sh`).
- Exits 0 on valid JSON with no file path.
- Runs `rustfmt`/`prettier`/`black` when config present and tool installed (test in a temp project if feasible).

### Item 3: Create `home/hooks/bin/format-on-edit.ps1`

**Files:** `home/hooks/bin/format-on-edit.ps1` (new)

**Steps:**
- Read payload from stdin via `$payload = [Console]::In.ReadToEnd()`.
- Parse JSON with `ConvertFrom-Json` (wrapped in try/catch for garbage input).
- Extract file path from `file_path`, `path`, or `file` property.
- Detect formatter (same logic as Item 2) and run on that file only.
- **Always `exit 0`** — never block.
- On garbage JSON: do nothing, exit 0.

**Acceptance:**
- `pwsh -NoProfile -Command "& { . 'home/hooks/bin/format-on-edit.ps1' }" < NUL` exits 0 (garbage/no input).
- Valid JSON with no file path → exit 0.
- Runs formatter when config present and tool installed.

### Item 4: Modify `install.sh` — add `--with-format-hook`

**Files:** `install.sh`

**Steps:**
- Add a `FORMAT_HOOK=0` flag variable.
- Parse args: support `--with-format-hook` alongside existing `--dry-run` and `--uninstall`. Convert positional `$1` check to a `for`/`case` loop so multiple flags work.
- **Dry-run:** when `FORMAT_HOOK=1`, also list the 3 format-hook files (format-on-edit.json as "would install: hooks/format-on-edit.json (templated for this platform)", plus the .sh and .ps1 scripts).
- **Copy loop:** when `FORMAT_HOOK=1`, also copy `format-on-edit.json`, `format-on-edit.sh`, `format-on-edit.ps1` from `home/hooks/` and `home/hooks/bin/`.
- **Placeholder replacement:** when `FORMAT_HOOK=1`, after copying `format-on-edit.json`, run `sed 's|__OMA_FORMAT_CMD__|bin/format-on-edit.sh|'` on it (relative path, same as secret-scan).
- **chmod:** `chmod +x "$AXON_HOME/hooks/bin/format-on-edit.sh"` when installed.
- **Manifest:** when `FORMAT_HOOK=1`, add `hooks/format-on-edit.json`, `hooks/bin/format-on-edit.sh`, `hooks/bin/format-on-edit.ps1` to the manifest.
- **Uninstall:** when manifest contains format-hook files, `rm -f` them. (The manifest-driven uninstall already handles this — as long as the entries are in the manifest.)
- Without `--with-format-hook`: **zero changes** to behavior (still 13 dry-run lines, 12 files + manifest).

**Acceptance:**
- `sh -n install.sh` passes.
- `./install.sh --dry-run` lists exactly 13 lines (unchanged from before).
- `./install.sh --dry-run --with-format-hook` lists exactly 17 lines (13 + 4 format-hook).
- Full install without flag: 12 home files + manifest written; no format-hook files.
- Full install with flag: 15 home files + manifest written; format-hook files present and templated.

### Item 5: Modify `install.ps1` — add `-WithFormatHook`

**Files:** `install.ps1`

**Steps:**
- Add `[switch]$WithFormatHook` to the `param()` block.
- **Dry-run:** when `-WithFormatHook`, list format-on-edit.json as "would install: hooks/format-on-edit.json (templated for this platform)" plus the .sh and .ps1 scripts.
- **Copy loop:** when `-WithFormatHook`, also copy the 3 format-hook files.
- **Placeholder replacement:** build absolute command string:
  ```powershell
  $scriptPath = (Join-Path $AxonHome 'hooks\bin\format-on-edit.ps1') -replace '\\', '/'
  $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
  ```
  Then `-replace '__OMA_FORMAT_CMD__', ($cmd -replace '"', '\"')`.
- **Manifest:** add the 3 format-hook entries when installed.
- **Uninstall:** manifest-driven `Remove-Item` already handles removal.
- Without `-WithFormatHook`: **zero changes** to behavior.

**Acceptance:**
- `pwsh -NoProfile -File install.ps1 -DryRun` lists 13 lines (unchanged).
- `pwsh -NoProfile -File install.ps1 -DryRun -WithFormatHook` lists 17 lines.
- Full install with flag creates format-hook files, templated correctly.

### Item 6: Update `README.md`

**Files:** `README.md`

**Steps:**
- Add a row to the "What you get" table for the format-on-edit hook (opt-in).
- Add a sentence in the Install section documenting `--with-format-hook` / `-WithFormatHook`.

**Acceptance:**
- Table has a new row matching existing row format (e.g., `format-on-edit | Opt-in auto-format on edit (rustfmt/prettier/black)`).
- Install section mentions the flag.

### Item 7: End-to-end verification

**Steps:**
- Run `sh -n` on all .sh files (install.sh, format-on-edit.sh).
- Run both installers in `--dry-run` mode with and without the flag; verify line counts.
- Test both hook scripts with garbage stdin (exit 0).
- Verify `sh -n` / syntax of .ps1 with `pwsh` if available.
- Full install with flag in a temp AXON_HOME; verify format-hook files present + manifest entries.
- Uninstall; verify format-hook files removed.

**Acceptance:**
- All `sh -n` checks pass.
- Dry-run without flag = 13 lines; with flag = 17 lines.
- Hook scripts exit 0 on garbage.
- Uninstall cleans up format-hook files.
