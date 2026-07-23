# Plan: Add --dry-run Flag
## Overview
Add non-destructive dry-run mode to shell and PowerShell installers.

### Item 1: Add --dry-run flag to install.sh
## Steps
1. Parse --dry-run flag in shell installer
2. Set DRY_RUN environment variable based on flag presence
3. Wrap file operations in conditional check [  -eq 0 ]
4. Print files that would be installed with relative paths
5. Show backup info if existing files would be backed up
6. Execute hook descriptor templating separately
7. Exit 0 at end regardless of dry-run mode

### Acceptance Criteria
Running ./install.sh --dry-run prints version line, lists files with relative paths
No files are copied to disk (verify by checking AXON_HOME directory after run)
No manifest file is created
No backup directory is created
Hook descriptor is still templated and ready for actual use
Exit code is 0

### Item 2: Add -DryRun flag to install.ps1
## Steps
1. Add [switch] parameter to PowerShell installer
2. Check  switch in file operation blocks
3. Print files that would be installed with relative paths
4. Show backup info if existing files would be backed up
5. Execute hook descriptor templating separately
6. Exit 0 at end regardless of dry-run mode

### Acceptance Criteria
Running .\\install.ps1 -DryRun prints version line, lists files with relative paths
No files are copied to disk (verify by checking AXON_HOME directory after run)
No manifest file is created
No backup directory is created
Hook descriptor is still templated and ready for actual use
Exit code is 0

### Item 3: Update README.md Install section with examples
## Steps
1. Locate the Install section in README.md
2. Add one-line documentation of --dry-run flag to both shell and PowerShell installers
3. Include example commands showing how to use dry-run mode

### Acceptance Criteria
README.md includes clear examples of using --dry-run for shell installer
README.md includes clear examples of using -DryRun for PowerShell installer
Documentation is concise and easy to understand

### Item 4: Verify both installers work in dry-run mode
## Steps
1. Run ./install.sh --dry-run from workspace root, capture output
2. Run .\\install.ps1 -DryRun from workspace root, capture output
3. Verify AXON_HOME directory structure after each run
4. Confirm both exit codes are 0

### Acceptance Criteria
Both installers produce expected dry-run output format
No unexpected files created on disk
Exit codes are 0 for both
