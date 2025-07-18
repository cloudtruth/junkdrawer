#!/bin/bash

#### Functions ####

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [OPTIONS] <environment-to-move> <parent-environment> [profile]

Moves a CloudTruth environment to a new parent. This is a destructive operation
that is accomplished by creating a new temporary environment, copying values, deleting the original environment,
and then setting the temporary environment name to the original source environment's name.

Since this isn't a true 'move', audit history will be lost due to the source environment being deleted.

A full backup snapshot is performed before any destructive changes are made.

Available options:

-h, --help                  Print this help and exit.
-k, --keep-temp-files       Keep temporary files created during the script's execution.
-r, --remove-snapshot-file  Delete the backup snapshot file upon script completion.
-n, --dry-run               Dry run. Show what would be done without making any changes.
-o, --output-dir <dir>      Specify output directory for the backup file. Defaults to $HOME.
EOF
    exit
}

# Function to perform an API request with error handling.
# Globals:
#   API_KEY
# Arguments:
#   URL: The API endpoint URL.
#   METHOD: HTTP method (default: GET).
#   PAYLOAD: JSON payload (optional).
#   OUTPUT_FILE: File to save the response to.
# Returns:
#   A string containing the HTTP status code and the request time, separated by a newline.
#   If the curl command fails, prints an error message including the curl output and returns 1.
api_request() {
    local URL="$1"
    local METHOD="${2:-GET}" # Default to GET
    local PAYLOAD="${3:-}"   # Optional payload
    local OUTPUT_FILE="$4"

    local CURL_CMD=(curl -s -w "%{http_code}\n%{time_total}"
        -X "$METHOD"
        -H "Authorization: Api-Key $API_KEY"
        -H "Content-Type: application/json")

    if [ -n "$PAYLOAD" ]; then
        CURL_CMD+=(-d "$PAYLOAD")
    fi
    CURL_CMD+=(-o "$OUTPUT_FILE" "$URL")

    # Execute the curl command and capture its return code, output, and combined output (stdout/stderr)
    local CURL_OUTPUT
    CURL_OUTPUT=$("${CURL_CMD[@]}" 2>&1) # Capture both stdout and stderr
    local CURL_STATUS=$?

    if [ $CURL_STATUS -ne 0 ]; then
        echo "🚨 Error: curl command failed with status $CURL_STATUS"
        echo "Command: ${CURL_CMD[*]}"
        echo "Output: $CURL_OUTPUT"
        return 1 # Indicate failure to the caller
    fi

    echo "$CURL_OUTPUT"
}

# Function to check an environment and capture its URI if it exists.
# Globals:
#   BASE_URL
#   API_KEY
# Arguments:
#   ENV_NAME: The name of the environment to check.
#   RESPONSE_FILE: File to save the API response.
# Returns:
#   0 if successful (environment exists or target doesn't), 1 if there's an error.
check_environment() {
    local RESULT
    local STATUS
    local TIME
    local COUNT

    local ENV_NAME="$1"
    local RESPONSE_FILE="$2"
    local IS_TARGET="${3:-false}" # Optional, true if checking the target environment

    local ENV_LOOKUP_URL="${BASE_URL}/environments/?name=${ENV_NAME}"
    RESULT=$(api_request "$ENV_LOOKUP_URL" GET "" "$RESPONSE_FILE")
    STATUS=$(echo -e "$RESULT" | head -n 1)
    TIME=$(echo -e "$RESULT" | tail -n 1)

    if [ "$STATUS" -ne 200 ]; then
        echo "🚨 Error looking up environment '$ENV_NAME'. API returned status $STATUS. (took ${TIME}s.)"
        jq . "$RESPONSE_FILE"
        return 1
    fi

    COUNT=$(jq '.count' "$RESPONSE_FILE")
    if [ "$COUNT" -ne 1 ] && [ "$IS_TARGET" = false ]; then
        echo "🚨 Environment '$ENV_NAME' not found or is ambiguous (found $COUNT). (took ${TIME}s.)"
        return 1
    elif [ "$COUNT" -gt 0 ] && [ "$IS_TARGET" = true ]; then
        # For the target environment, a count > 0 is not an error, but we handle it specially later.
        return 0
    fi

    if [ "$IS_TARGET" = false ]; then
        echo "✅ Environment '$ENV_NAME' exists. (took ${TIME}s)"
    else
        echo "🤔 Target Environment '$ENV_NAME' check completed. (took ${TIME}s)"
    fi

    return 0
}

get_project_pk_by_name() {
    local project_name="$1"
    local response_file="$TEMP_DIR/project_lookup_${project_name// /_}.json"
    local lookup_url="${BASE_URL}/projects/?name=${project_name}"

    local result
    result=$(api_request "$lookup_url" GET "" "$response_file")
    local status
    status=$(echo -e "$result" | head -n 1)

    if [ "$status" -ne 200 ]; then
        echo "🚨 Error looking up project '$project_name'. API status: $status" >&2
        jq . "$response_file" >&2
        return 1
    fi

    local count
    count=$(jq '.count' "$response_file")
    if [ "$count" -ne 1 ]; then
        echo "🚨 Project '$project_name' not found or ambiguous (found $count)." >&2
        return 1
    fi

    jq -r '.results[0].id' "$response_file"
}

get_parameter_pk_by_name() {
    local project_pk="$1"
    local parameter_name="$2"
    local response_file="$TEMP_DIR/parameter_lookup_${project_pk}_${parameter_name// /_}.json"
    local lookup_url="${BASE_URL}/projects/${project_pk}/parameters/?name=${parameter_name}"

    local result
    result=$(api_request "$lookup_url" GET "" "$response_file")
    local status
    status=$(echo -e "$result" | head -n 1)

    if [ "$status" -ne 200 ]; then
        echo "🚨 Error looking up parameter '$parameter_name' in project '$project_pk'. API status: $status" >&2
        jq . "$response_file" >&2
        return 1
    fi

    local count
    count=$(jq '.count' "$response_file")
    if [ "$count" -ne 1 ]; then
        echo "🚨 Parameter '$parameter_name' not found or ambiguous in project '$project_pk' (found $count)." >&2
        return 1
    fi

    jq -r '.results[0].id' "$response_file"
}

set_parameter_value() {
    local project_pk="$1"
    local parameter_pk="$2"
    local env_uri="$3"
    local value="$4"

    local set_value_url="${BASE_URL}/projects/${project_pk}/parameters/${parameter_pk}/values/"
    local payload
    payload=$(jq -n --arg env_uri "$env_uri" --arg internal_value "$value" '{environment: $env_uri, internal_value: $internal_value}')
    local response_file="$TEMP_DIR/set_value_response_${project_pk}_${parameter_pk}.json"

    echo "Setting value for parameter '$parameter_pk' in project '$project_pk'..."

    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: Would set value '$value' for parameter '$parameter_pk' in project '$project_pk'"
        return 0
    else
        local result
        result=$(api_request "$set_value_url" POST "$payload" "$response_file")
        local status
        status=$(echo -e "$result" | head -n 1)

        if [ "$status" -eq 201 ]; then
            echo "✅ Successfully set value."
            return 0
        else
            echo "🚨 Error setting value for parameter '$parameter_pk'. API status: $status" >&2
            jq . "$response_file" >&2
            return 1
        fi
    fi
}

populate_target_environment() {
    echo "---"
    echo "📤 Populating values from '$SOURCE_ENVIRONMENT' into '$TARGET_ENVIRONMENT'..."

    local target_env_uri
    target_env_uri=$(jq -r '.results[0].url' "$TARGET_ENV_LOOKUP_RESPONSE_FILE")
    if [ -z "$target_env_uri" ] || [ "$target_env_uri" == "null" ]; then
        echo "🚨 Could not find URI for target environment '$TARGET_ENVIRONMENT' in '$TARGET_ENV_LOOKUP_RESPONSE_FILE'. Aborting value population." >&2
        return 1
    fi
    echo "✅ Found Target Environment URI: $target_env_uri"

    # This jq query extracts parameters that have explicit values set in the source environment
    local jq_query
    # This jq query extracts all parameter values that are set in an environment other than 'default'.
    # These are considered "overridden" values. The shell loop will then filter for the specific
    # source environment being moved.
    jq_query='.projects | to_entries[] | .value.parameters | to_entries[] | . as $param_entry | .value.values | to_entries[] | select(.key != "default") | {defining_project: $param_entry.value.project, param_name: $param_entry.key, env_name: .key, value: .value.value} | @base64'
    local value_count=0
    local success_count=0
    local failure_count=0

    # Read the base64 encoded JSON objects from jq
    while IFS= read -r b64_line; do
        local json_data
        json_data=$(echo "$b64_line" | base64 --decode)

        local env_name
        env_name=$(echo "$json_data" | jq -r '.env_name')

        # Only process values from the environment we are moving.
        if [ "$env_name" != "$SOURCE_ENVIRONMENT" ]; then
            continue
        fi

        ((value_count++))
        local defining_project
        defining_project=$(echo "$json_data" | jq -r '.defining_project')
        local param_name
        param_name=$(echo "$json_data" | jq -r '.param_name')
        local param_value
        param_value=$(echo "$json_data" | jq -r '.value')

        echo -e "\nProcessing: Project '$defining_project' -> Parameter '$param_name' for environment '$env_name'"

        local project_pk
        project_pk=$(get_project_pk_by_name "$defining_project")
        if [ $? -ne 0 ]; then
            echo "🚨 Failed to get PK for project '$defining_project'. Skipping parameter."
            ((failure_count++))
            continue
        fi

        local param_pk
        param_pk=$(get_parameter_pk_by_name "$project_pk" "$param_name")
        if [ $? -ne 0 ]; then
            echo "🚨 Failed to get PK for parameter '$param_name' in project '$defining_project'. Skipping parameter."
            ((failure_count++))
            continue
        fi

        if [ "$DRY_RUN" = true ]; then
            echo "DRY RUN: Would set value '$param_value' for parameter '$param_name' in project '$defining_project'"
            ((success_count++))
            continue
        else
            set_parameter_value "$project_pk" "$param_pk" "$target_env_uri" "$param_value"
            if [ $? -eq 0 ]; then
                ((success_count++))
            else
                ((failure_count++))
            fi
        fi

    done < <(jq -r "$jq_query" "$GLOBAL_BACKUP_FILE")

    if [ "$value_count" -eq 0 ]; then
        echo "✅ No explicit override values found in '$SOURCE_ENVIRONMENT' to copy."
    fi

    echo "---"
    echo "📊 Value Population Summary:"
    echo "   Total values from source environment to process: $value_count"
    echo "   ✅ Successfully set: $success_count"
    echo "   🚨 Failed to set: $failure_count"

    if [ "$failure_count" -gt 0 ]; then
        echo "⚠️ Some values could not be populated. Please review the errors above."
        return 1
    else
        echo "🎉 All values populated successfully."
        return 0
    fi
}

#### MAIN ####

# --- Argument Parsing ---
# Initialize variables for options
KEEP_TEMP_FILES="false"
REMOVE_SNAPSHOT_FILE="false"
DRY_RUN="false"
SNAPSHOT_OUTPUT_DIR="$HOME" # default output directory

# Use getopts to parse command-line arguments
while (($# > 0)); do
    case "$1" in
    -h | --help)
        usage
        ;;
    -k | --keep-temp-files)
        KEEP_TEMP_FILES="true"
        shift
        ;;
    -r | --remove-snapshot-file)
        REMOVE_SNAPSHOT_FILE="true"
        shift
        ;;
    -n | --dry-run)
        DRY_RUN="true"
        shift
        ;;
    -o | --output-dir)
        if [ -n "$2" ]; then
            SNAPSHOT_OUTPUT_DIR="$2"
            if [ ! -d "$SNAPSHOT_OUTPUT_DIR" ]; then
                echo "🚨 Error: Invalid output directory '$SNAPSHOT_OUTPUT_DIR'." >&2
                exit 1
            fi
            shift 2
        else
            echo "🚨 Error: Option -$1 requires an argument. Use -h for help." >&2
            exit 1
        fi
        ;;
    -?*)
        echo "🚨 Error: Invalid option: -$OPTARG. Use -h for help." >&2
        exit 1
        ;;
    *)
        break
        ;;
    esac
done

# Shift off the options so we're left with the positional arguments.
shift $((OPTIND - 1))

# Check for required arguments.
if [ "$#" -lt 2 ]; then
    echo "🚨 Error: Missing required arguments. Use -h for help." >&2
    exit 1
fi

# Assign positional arguments to variables.
SOURCE_ENVIRONMENT=$1
PARENT_ENVIRONMENT=$2

# If a third argument is provided, use it as the profile; otherwise, use the default.
TARGET_ENVIRONMENT="${SOURCE_ENVIRONMENT}_TEMP"
DEFAULT_PROFILE="default"
PROFILE=${3:-$DEFAULT_PROFILE}

# Basic validation of arguments, ensuring SOURCE and PARENT are not empty.
[[ -z "$SOURCE_ENVIRONMENT" || -z "$PARENT_ENVIRONMENT" ]] && {
    echo "Error: environment and parent cannot be empty"
    exit 1
}

# --- OS-Specific Configuration & Initial Checks ---

CONFIG_FILE=""
OS="$(uname -s)"

echo "Detected OS: $OS"

# Define potential configuration file locations based on OS
case "$OS" in
Linux)
    # Follows XDG Base Directory Specification
    locations=(
        "$XDG_CONFIG_HOME/cloudtruth/cli.yml"
        "$HOME/.config/cloudtruth/cli.yml"
    )
    ;;
Darwin)
    # macOS standard location
    locations=(
        "$HOME/Library/Application Support/com.cloudtruth.CloudTruth-CLI/cli.yml"
    )
    ;;
*)
    # Basic check for Windows-like environments (Git Bash, etc.)
    if [[ "$OS" == "MINGW"* ]] || [[ "$OS" == "CYGWIN"* ]]; then
        locations=(
            "$APPDATA/cloudtruth/cli.yml"
        )
    else
        locations=()
    fi
    ;;
esac

# Find the first existing config file from the locations array
for location in "${locations[@]}"; do
    if [ -f "$location" ]; then
        CONFIG_FILE="$location"
        echo "✅ Configuration file found at: $CONFIG_FILE"
        break
    fi
done

# If a config file was found, we absolutely need yq. Check for it and exit if not found.
if [ -n "$CONFIG_FILE" ]; then
    if ! command -v yq &>/dev/null; then
        echo "🚨 Error: '$CONFIG_FILE' found, but 'yq' is not installed."
        echo "Please install yq to continue, or move the config file to enter the key manually."
        exit 1
    fi
fi

# We need jq to parse API responses.
if ! command -v jq &>/dev/null; then
    echo "🚨 Error: 'jq' is not installed, but it is required to parse API responses."
    echo "Please install jq to continue."
    exit 1
fi

# Initialize API_KEY variable
API_KEY=""

# Decide how to get the API key based on whether a config file was found.
if [ -n "$CONFIG_FILE" ]; then
    # CONFIG FILE WAS FOUND and we already confirmed yq is installed.
    echo "🔑 Using profile '$PROFILE'."

    # If the profile is 'default', check for a 'source_profile' to use instead.
    if [ "$PROFILE" == "default" ]; then
        SOURCE_PROFILE=$(yq e ".profiles.default.source_profile" "$CONFIG_FILE")
        # Check if yq found a non-null, non-empty value.
        if [ -n "$SOURCE_PROFILE" ] && [ "$SOURCE_PROFILE" != "null" ]; then
            echo "Found 'source_profile' in default profile. Switching to profile '$SOURCE_PROFILE'."
            PROFILE="$SOURCE_PROFILE"
        fi
    fi

    API_KEY=$(yq e ".profiles.${PROFILE}.api_key" "$CONFIG_FILE")
else
    # NO CONFIG FILE WAS FOUND: Prompt the user for the key.
    echo "📄 No configuration file found in standard locations."
    read -rsp "Please enter your CloudTruth API Key: " API_KEY
    echo # Add a newline for cleaner output.
fi

# --- Validation and Execution ---
# Check if the API key was successfully obtained.
if [ -z "$API_KEY" ] || [ "$API_KEY" == "null" ]; then
    echo "🚨 Error: API key is missing. It was not found for profile '$PROFILE' or was not entered."
    exit 1
fi

echo "Found API key for profile '$PROFILE'."

# Construct the base URL.
BASE_URL="https://api.cloudtruth.io/api/v1"

# --- Secure Temporary File Handling ---
# Create a secure temporary directory
TEMP_DIR=$(mktemp -d)
if [ ! -d "$TEMP_DIR" ]; then
    echo "🚨 Error: Failed to create a temporary directory."
    exit 1
fi
echo "Created temporary directory: $TEMP_DIR to store temporary files created by this script."

# Define temporary file names and their full paths
GLOBAL_BACKUP_FILE="$SNAPSHOT_OUTPUT_DIR/cloudtruth_snapshot.json"
PARENT_ENV_LOOKUP_RESPONSE_FILE="$TEMP_DIR/parent_env_lookup_api_response.json"
CREATE_ENV_RESPONSE_FILE="$TEMP_DIR/create_env_api_response.json"
SOURCE_ENV_LOOKUP_RESPONSE_FILE="$TEMP_DIR/source_env_lookup_api_response.json"
TARGET_ENV_LOOKUP_RESPONSE_FILE="$TEMP_DIR/target_env_lookup_api_response.json"

TEMP_FILES="$PARENT_ENV_LOOKUP_RESPONSE_FILE $CREATE_ENV_RESPONSE_FILE $SOURCE_ENV_LOOKUP_RESPONSE_FILE $TARGET_ENV_LOOKUP_RESPONSE_FILE"

if [ "$KEEP_TEMP_FILES" = true ]; then
    echo "🧹 Option --keep-temp-files was used, temporary files will be kept and are located in $TEMP_DIR."
fi

if [ "$REMOVE_SNAPSHOT_FILE" = true ]; then
    echo "🧹 Option --delete-snapshot-file was used, deleting the snapshot file upon script completion."
    TEMP_FILES+=" $GLOBAL_BACKUP_FILE"
fi

cleanup() {
    if [ "$KEEP_TEMP_FILES" = false ]; then
        echo "🧹 Cleaning up; removing the temporary directory $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi

    unset API_KEY
}
trap cleanup EXIT

# --- Global Backup ---
echo "💾 Creating a full organization backup snapshot before proceeding..."
BACKUP_URL="${BASE_URL}/backup/snapshot/"

BACKUP_RESULT=$(api_request "$BACKUP_URL" POST "" "$GLOBAL_BACKUP_FILE")
BACKUP_HTTP_STATUS=$(echo -e "$BACKUP_RESULT" | head -n 1)
BACKUP_TIME=$(echo -e "$BACKUP_RESULT" | tail -n 1)

if [ "$BACKUP_HTTP_STATUS" -eq 200 ]; then
    echo "✅ Full backup snapshot successful. Data saved to '$GLOBAL_BACKUP_FILE'. (took ${BACKUP_TIME}s.)"
else
    echo -e "\n🚨 Error: Failed to create a full backup snapshot. The API returned status code $BACKUP_HTTP_STATUS. (took ${BACKUP_TIME}s.)"
    echo "API Response:"
    # The response is already in the file, so just display it.
    cat "$GLOBAL_BACKUP_FILE"
    return 1
fi

# --- Environment Verification and Creation ---
echo "🔎 Verifying environments..."

# Perform environment checks in parallel
check_environment "$PARENT_ENVIRONMENT" "$PARENT_ENV_LOOKUP_RESPONSE_FILE" &
PARENT_PID=$!
check_environment "$SOURCE_ENVIRONMENT" "$SOURCE_ENV_LOOKUP_RESPONSE_FILE" &
SOURCE_PID=$!
check_environment "$TARGET_ENVIRONMENT" "$TARGET_ENV_LOOKUP_RESPONSE_FILE" true &
TARGET_PID=$!

# Wait for all checks to complete
wait $PARENT_PID
PARENT_RESULT=$?
wait $SOURCE_PID
SOURCE_RESULT=$?
wait $TARGET_PID
TARGET_RESULT=$?

# Check results of parallel operations
if [ $PARENT_RESULT -ne 0 ]; then
    exit 1
elif [ $SOURCE_RESULT -ne 0 ]; then
    exit 1
elif [ $TARGET_RESULT -ne 0 ]; then
    # If target check failed, it might still exist, but we handle that logic later
    : # Do nothing here, the check_environment function already printed the error if needed.
fi

# Now that parallel checks are complete, extract the parent URI from its response file.
PARENT_ENV_URI=$(jq -r '.results[0].url' "$PARENT_ENV_LOOKUP_RESPONSE_FILE")

SKIP_CREATION=false
CHILD_COUNT=$(jq '.count' "$TARGET_ENV_LOOKUP_RESPONSE_FILE")
if [ "$CHILD_COUNT" -gt 0 ]; then
    echo "⚠️ Target environment '$TARGET_ENVIRONMENT' already exists. Did you create this environment ahead of time?"
    while true; do
        case $yn in
        [Yy]*)
            echo "✅ OK. You created this environment ahead of time, proceeding to the next step."
            # Since the target environment already exists, we need to check if its parent is correct.
            TARGET_ENV_DETAILS=$(jq -r '.results[0]' "$TARGET_ENV_LOOKUP_RESPONSE_FILE")
            TARGET_ENV_PARENT_URI=$(echo "$TARGET_ENV_DETAILS" | jq -r '.parent')
            if [ "$TARGET_ENV_PARENT_URI" != "$PARENT_ENV_URI" ]; then
                echo "🚨 Error: The existing target environment '$TARGET_ENVIRONMENT' has the wrong parent."
                echo "Expected parent: '$PARENT_ENVIRONMENT', but found a different parent."
                echo "Please correct the parent of the existing environment or specify the correct parent when running this script."
                exit 1
            else
                echo "✅ The existing target environment '$TARGET_ENVIRONMENT' has the correct parent ('$PARENT_ENVIRONMENT')."
                SKIP_CREATION=true
                break
            fi
        ;;
        [Nn]*)
            echo "❌ Please remove the existing target environment '$TARGET_ENVIRONMENT' before proceeding."
            exit 1
        ;;
        *)
            echo "❓ Please answer yes (y) or no (n)."
            read -r yn
            ;;
        esac
    done
fi

if [ "$SKIP_CREATION" = false ]; then
    # 3. If we're here, the child environment does not exist or needs to be created with a _TEMP suffix.
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: Would create environment '$TARGET_ENVIRONMENT' under '$PARENT_ENVIRONMENT'."
    else
        # --- Asynchronous Creation and Polling ---
        echo "Target environment ${TARGET_ENVIRONMENT} does not exist. Creating it under '$PARENT_ENVIRONMENT'... "
        # Update the lookup URL in case the environment name was changed to _TEMP
        TARGET_ENV_LOOKUP_URL="${BASE_URL}/environments/?name=${TARGET_ENVIRONMENT}"
        echo "Submitting request to create environment '$TARGET_ENVIRONMENT'..."
        CREATE_ENV_URL="${BASE_URL}/environments/"
        CREATE_PAYLOAD=$(jq -n --arg name "$TARGET_ENVIRONMENT" --arg parent_uri "$PARENT_ENV_URI" '{name: $name, parent: $parent_uri}')

        # Submit the creation request and run it in the background. We don't wait for it.
        # Output is redirected to /dev/null as we will poll for the result.
        api_request "$CREATE_ENV_URL" POST "$CREATE_PAYLOAD" "$CREATE_ENV_RESPONSE_FILE" >/dev/null &

        # Poll for up to 10 minutes with adaptive backoff to see if the environment was created.
        POLL_START_TIME=$SECONDS
        POLL_TIMEOUT=600 # 10 minutes

        # --- Adaptive Polling Parameters ---
        POLL_INTERVAL=5      # Initial interval in seconds
        POLL_MAX_INTERVAL=60 # Maximum interval in seconds

        echo -n "Polling for environment creation status with adaptive backoff (up to 10 minutes) "
        while :; do
            ELAPSED_TIME=$((SECONDS - POLL_START_TIME))
            if [ "$ELAPSED_TIME" -ge "$POLL_TIMEOUT" ]; then
                echo -e "\n\n🚨 Polling timed out after 10 minutes."
                echo "The environment may still be creating in the background."
                echo "Please check the CloudTruth UI or contact CloudTruth support for assistance."
                exit 1
            fi

            # Re-use the child lookup URL and file to check for the new environment
            TARGET_LOOKUP_RESULT=$(api_request "$TARGET_ENV_LOOKUP_URL" GET "" "$TARGET_ENV_LOOKUP_RESPONSE_FILE")
            LOOKUP_STATUS=$(echo -e "$TARGET_LOOKUP_RESULT" | head -n 1)

            if [ "$LOOKUP_STATUS" -eq 200 ]; then
                CHILD_COUNT=$(jq '.count' "$TARGET_ENV_LOOKUP_RESPONSE_FILE")
                if [ "$CHILD_COUNT" -gt 0 ]; then
                    TOTAL_CREATION_TIME=$((SECONDS - POLL_START_TIME))
                    echo -e "\n✅ Environment '$TARGET_ENVIRONMENT' created successfully. (took ${TOTAL_CREATION_TIME}s)"
                    break # Success, exit the polling loop
                fi
            fi

            # Still waiting...
            echo -n "."
            sleep "$POLL_INTERVAL"

            # --- Calculate next interval for adaptive backoff by multiplying by 1.5 (approximately) ---
            NEXT_POLL_INTERVAL=$(((POLL_INTERVAL * 3) / 2))

            if [ "$NEXT_POLL_INTERVAL" -gt "$POLL_MAX_INTERVAL" ]; then
                POLL_INTERVAL="$POLL_MAX_INTERVAL"
            else
                POLL_INTERVAL="$NEXT_POLL_INTERVAL"
            fi
        done
    fi
fi

populate_target_environment
POPULATE_STATUS=$?

if [ "$POPULATE_STATUS" -ne 0 ]; then
    echo "🚨 Errors occurred during value population. The temporary environment '$TARGET_ENVIRONMENT' has been created but may be incomplete."
    echo "Please check the logs above. The script will now exit, and cleanup will run."
    exit 1
fi

exit 0
