# CloudTruth Environment Move Script

## Overview

`env_move.sh` is a Bash script that moves a CloudTruth environment to a new parent environment. Since CloudTruth does not support a true environment move, the script accomplishes this by creating a temporary environment, copying all values, deleting the original environment, and renaming the temporary environment to the original name. **Note:** Audit history is lost due to the deletion and recreation process.

## Features

- **Full Backup:** Automatically creates a full organization snapshot before any destructive changes.
- **Dry Run Mode:** Preview all actions without making changes.
- **Value Copying:** Copies all explicit override values from the source environment to the new environment.
- **Parent Validation:** Ensures the new environment is created under the correct parent.
- **Robust Error Handling:** Handles API errors, ambiguous lookups, and value conflicts.
- **Config/Profile Support:** Reads API key from standard config locations or prompts for manual entry.
- **Temporary File Management:** Optionally keeps or removes temp files and backup snapshots.
- **Adaptive Polling:** Waits for environment creation with adaptive backoff.

## Requirements

- Bash (4.0+ recommended)
- `curl`, `jq` (required)
- `yq` (required if using a config file)
- CloudTruth API key (via config file or prompt)

## Usage

```bash
./env_move.sh [OPTIONS] <environment-to-move> <parent-environment> [profile]
```

### Options

- `-h`, `--help`                  Print help and exit.
- `-k`, `--keep-temp-files`       Keep temporary files created during execution.
- `-r`, `--remove-snapshot-file`  Delete the backup snapshot file upon completion.
- `-n`, `--dry-run`               Show what would be done without making changes.
- `-o`, `--output-dir <dir>`      Specify output directory for the backup file (default: `$HOME`).

### Arguments

- `<environment-to-move>`   Name of the environment to move.
- `<parent-environment>`    Name of the new parent environment.
- `[profile]`               Optional CloudTruth CLI profile (default: `default`).

### Example

```bash
./env_move.sh -n dev prod
```

## How It Works

1. **Argument Parsing:** Validates options and required arguments.
2. **API Key Retrieval:** Reads from config file or prompts user.
3. **Backup:** Creates a full organization snapshot before changes.
4. **Environment Checks:** Verifies existence of source, parent, and target environments.
5. **Environment Creation:** Creates a temporary environment under the new parent if needed.
6. **Value Copying:** Copies all explicit override values from the source to the new environment, skipping matches and reporting conflicts.
7. **Cleanup & Rename:** (Not shown in excerpt) After copying, deletes the original environment and renames the temporary one to the original name.
8. **Logging & Error Handling:** Reports all actions, errors, and keeps temp files if requested.

## Safety & Review

- **Dry Run:** Use `-n` to preview all actions before making changes.
- **Backup:** A full backup is always performed before changes.
- **Confirmation:** Errors and conflicts are reported with details for review.
- **Temp Files:** Optionally keep temp files for debugging.

## Output

- **Backup File:** Organization snapshot saved to the specified output directory.
- **Console Messages:** Progress, errors, and summaries printed to stdout/stderr.

## Notes

- This script is **destructive**. Audit history for the environment will be lost.
- Ensure your API key and profile are correct.
- For large environments, review the backup and temp files before proceeding.

---

For more details, see the script source or run with `-h` for usage information.
