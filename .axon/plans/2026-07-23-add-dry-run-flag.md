# Plan: Add dry-run flag to install.sh and install.ps1

## Overview
Add a --dry-run flag to install.sh (already implemented) and a -DryRun switch to install.ps1. When set, the installer prints each file it would install (relative destination path under AXON_HOME) and any existing file it would back up, but writes NOTHING: no copies, no manifest, no backup dir, no chmod. It still prints the version line and exits 0. Also add one line documenting the flag to the Install section of README.md.

## Work Items

### Item 1: Modify install.ps1 to add -DryRun switch with dry-run functionality
**Files:** install.ps1
**Steps:**
1. Add [switch]$DryRun parameter to the param block
2. Add logic to handle -DryRun similar to how install.sh handles --dry-run:
   - When -DryRun is set, print what would be installed/backed up without actually doing it
   - Still print version line and exit 0
   - Do NOT copy files, create manifest, create backup directory, or run any chmod commands
3. Ensure the dry-run mode prints:
   - "Would install: <relative path>" for each file that would be installed
   - "Would back up: <relative path>" for each existing file that would be backed up
   - Version line: "oh-my-axon 0.1.0"
**Acceptance Criteria:**
- .\install.ps1 -DryRun prints version line and file operations without making changes
- .\install.ps1 -DryRun exits with code 0
- Normal installation (.install.ps1) still works as before
- No files are copied, no manifest created, no backup directory created, no chmod run when -DryRun is used

### Item 2: Update README.md to document the new flag in the Install section
**Files:** README.md
**Steps:**
1. In the Install section, after documenting ./install.sh --uninstall and .\install.ps1 -Uninstall
2. Add documentation for the dry-run flags:
   - For Linux/WSL/macOS: mention ./install.sh --dry-run
   - For Windows: mention .\install.ps1 -DryRun
3. Add a brief description: "Prints what would be installed/backed up without making changes"
**Acceptance Criteria:**
- README.md Install section includes documentation for both --dry-run and -DryRun flags
- Documentation is clear and concise
- No existing content is broken or removed