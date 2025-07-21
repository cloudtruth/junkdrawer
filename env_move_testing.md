# Test Suite

## Positive Scenario / "Happy Path" Testing

This suite ensures the script works as expected under normal, ideal conditions.

### Test Case: Basic Move

- Setup: Use an existing and populated CloudTruth test organization (alternatively, create a new one and populate it via the loadtestdata.sh script from this repo). Be sure the source environment to copy has several overridden parameters and of different types (secrets, strings, etc).
- Action: Run the script to move the source environment to be a child of a new parent environment.
- Verification:
  - A \<source_env\>_TEMP environment is created under the target parent environment.
  - Only the parameters that were explicitly overridden in the source environment are populated in \<source_env\>_TEMP
  - Parameters inherited from default in the original source environment are not explicitly set in \<source_env\>_TEMP.
  - The values of the copied parameters are correct.
  - The script exits with a status code of 0.
  - A cloudtruth_snapshot.json file is created.

### Test Case: No Overrides

- Setup: Create a source environment that has no parameter overrides of its own.
- Action: Run the script to move this environment.
- Verification:
  - The temporary environment is created successfully.
  - The script reports "No explicit override values found... to copy."
  - The script exits with a status code of 0.

## Idempotency and State-Awareness Testing

This suite ensures the script can be run multiple times without causing errors or unintended side effects.

### Test Case: Re-run After Success

- Setup: Successfully complete [Test Case: Basic Move](#test-case-basic-move).
- Action: Run the exact same command a second time.
- Verification:
  - The script should detect that the temporary environment and all its values already exist and match.
  - The log output should show "Value already exists and matches. Skipping." for each parameter.
  - The script should not attempt any POST or PATCH API calls to set values.
  - The script should exit with a status code of 0.

### Test Case: Re-run After Value Conflict

- Setup: Successfully complete [Test Case: Basic Move](#test-case-basic-move). Manually change the value of one parameter in the \<source_env\>_TEMP environment.
- Action: Run the exact same command a second time.
- Verification:
  - The script should detect the mismatched value.
  - It should log a "WARNING: Parameter ... already has a different value..." message, showing both the existing and incoming values.
  - It should not change the value in the target environment.
  - The script should exit with a non-zero status code, as this is considered a failure.

## Argument and Flag Testing

This suite validates all the command-line options.

### Test Case: --dry-run

- Setup: Use the "Happy Path" setup [Test Case: Basic Move](#test-case-basic-move).
- Action: Run the script with the -n or --dry-run flag.
- Verification:
  - Verify that no new environment is created in CloudTruth.
  - Verify that no parameter values are set.
  - The log output should clearly indicate "DRY RUN" for all actions that would have been performed.
  - The script should exit with status 0.

### Test Case: --keep-temp-files

- Action: Run any test case with the -k flag.
- Verification:
  - After the script exits, verify that the temporary directory (e.g., /tmp/tmp.XXXXXX) and its contents (API response files) are not deleted.

### Test Case: --output-dir

- Action: Run the script with -o /tmp.
- Verification:
- Verify that cloudtruth_snapshot.json is created in /tmp instead of $HOME.

### Test Case: Invalid Arguments

- Action: Run the script with missing arguments (e.g., only the source environment).
- Verification: The script should immediately exit with an error and display the usage message.

## Negative and Failure Mode Testing

This is the most critical suite for a destructive script. It tests how the script behaves when things go wrong.

### Test Case: Invalid Source/Parent Environment

- Action: Provide a source or parent environment name that does not exist.
- Verification: The script should fail early with a clear message "Environment '...' not found" and exit with a non-zero status.

### Test Case: Invalid API Key

- Action: Run the script with an incorrect API key.
- Verification: The script should fail on the first API call (the backup) with a clear authentication error (e.g., Status 401) and exit.

### Test Case: Insufficient Permissions

- Action: Use an API key that has read-only permissions.
- Verification: The script should successfully perform the backup and environment lookups but fail when it attempts to create the temporary environment or set a parameter value. The error message should be clear.

### Test Case: Script Interruption

- Action: Run a long test (e.g., with many parameters) and interrupt it with Ctrl+C during the value population loop.
- Verification: The cleanup trap should execute, and the temporary directory should be removed (unless -k was specified).

### Test Case: Pre-existing Conflicting Temp Environment

- Setup: Manually create an environment named \<source_env\>_TEMP under a different parent than the one specified in the script.
- Action: Run the script to move staging.
- Verification: The script should prompt the user about the existing environment. When the user confirms, the script should detect the parent mismatch and exit with a clear error message.
