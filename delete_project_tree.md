
# CloudTruth Project Tree Deletion Script

## Overview

`delete_project_tree.sh` is a Bash script designed to find and delete a hierarchy (tree) of CloudTruth projects based on a partial project name. It ensures that child projects are deleted before their parents to respect dependency relationships, and provides robust error handling, logging, and dry-run capabilities.

## Features

- **Recursive Deletion:** Deletes all projects matching a partial name and their descendants, deepest child first.
- **Dry Run Mode:** Preview what would be deleted without making any changes.
- **Dependency Handling:** Ensures deletion order respects parent-child relationships.
- **Logging:** Records deletions to a log file for auditing.
- **API Integration:** Uses CloudTruth API with authentication.
- **Robust Error Handling:** Handles API errors, missing dependencies, and retry logic for locked resources.

## Requirements

- Bash 4.0+ (for associative arrays)
- `curl` and `jq` installed
- `CLOUDTRUTH_API_KEY` environment variable set
- Optional: `CLOUDTRUTH_SERVER_URL` (defaults to `https://api.cloudtruth.io`)

## Usage

```bash
./delete_project_tree.sh [--dry-run] [--log-file <path>] <PARTIAL_PROJECT_NAME>
```

### Arguments

- `--dry-run` : Show what would be deleted without actually deleting.
- `--log-file <path>` : Specify a custom path for the deletion log file. Defaults to `$HOME/project_deletion_<timestamp>.log`.
- `<PARTIAL_PROJECT_NAME>` : Partial name to match projects for deletion.

### Example

```bash
./delete_project_tree.sh --dry-run project-count-limits
```

## How It Works

1. **Checks Bash Version & Dependencies:** Ensures Bash 4+, `curl`, and `jq` are available.
2. **Authenticates to CloudTruth API:** Requires `CLOUDTRUTH_API_KEY`.
3. **Builds Project Dependency Maps:** Fetches all projects, builds parent-child relationships.
4. **Identifies Projects to Delete:** Finds root projects matching the partial name and all their descendants.
5. **Sorts Projects by Depth:** Ensures deepest children are deleted first.
6. **Dry Run or Confirmation:** Shows the list of projects to be deleted. If not in dry-run, asks for confirmation.
7. **Deletes Projects:** Attempts deletion, retries on dependency lock (409), logs each deletion.
8. **Waits for Deletion Confirmation:** Polls API to confirm each project is fully deleted before proceeding.
9. **Logs Results:** Saves a log of all deleted projects.

## Safety & Review

- If more than 25 projects are found, the list is saved to a temporary file for review before deletion.
- User must type `yes` to confirm actual deletion.
- Script halts on first deletion failure, reporting how many projects were deleted before the error.

## Output

- **Log File:** All successful deletions are logged with timestamp, project name, and ID.
- **Console Messages:** Progress, errors, and confirmations are printed to stderr/stdout.

## Notes

- This script is **destructive**. Use `--dry-run` to preview changes before running without it.
- Ensure your API key has appropriate permissions.
- For large deletions, review the temp file before confirming.

---

For more details, see the script source or run with no arguments to display usage information.
