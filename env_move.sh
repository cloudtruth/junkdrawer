#!/bin/bash

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
    if ! command -v yq &> /dev/null; then
        echo "🚨 Error: '$CONFIG_FILE' found, but 'yq' is not installed."
        echo "Please install yq to continue, or move the config file to enter the key manually."
        exit 1
    fi
fi

# We need jq to parse API responses.
if ! command -v jq &> /dev/null; then
    echo "🚨 Error: 'jq' is not installed, but it is required to parse API responses."
    echo "Please install jq to continue."
    exit 1
fi

# --- Argument Parsing ---
KEEP_FILES=false
DRY_RUN=false

# Parse command-line options like --keep-files
while [[ "$1" =~ ^- ]]; do
    case "$1" in
        --keep-files)
            KEEP_FILES=true
            shift # past argument
            ;;
        --dry-run)
            DRY_RUN=true
            shift # past argument
            ;;
        *)
            echo "🚨 Error: Unknown option '$1'"
            echo "Usage: $0 [--keep-files] [--dry-run] <environment-to-move> <parent-environment> [profile]"
            exit 1
            ;;
    esac
done

# Check for required arguments.
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "🚨 Error: Missing required arguments."
    echo "Usage: $0 [--keep-files] [--dry-run] <environment-to-move> <parent-environment> [profile]"
    exit 1
fi

SOURCE_ENVIRONMENT=$1
PARENT_ENVIRONMENT=$2
TARGET_ENVIRONMENT="${SOURCE_ENVIRONMENT}_TEMP"
DEFAULT_PROFILE="default"
PROFILE=${3:-$DEFAULT_PROFILE}

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

# --- Temporary File Management ---
# Define human-readable names for temporary files in the current directory.
GLOBAL_BACKUP_FILE="cloudtruth_snapshot.json"
PARENT_ENV_LOOKUP_RESPONSE_FILE="parent_env_lookup_api_response.json"
CREATE_ENV_RESPONSE_FILE="create_env_api_response.json"
TARGET_ENV_LOOKUP_RESPONSE_FILE="target_env_lookup_api_response.json"
SOURCE_ENV_LOOKUP_RESPONSE_FILE="source_env_lookup_api_response.json"

if [ "$KEEP_FILES" = false ]; then
    # Ensure all temporary files are removed when the script exits by default.
    echo "🧹 Temporary files will be deleted on exit. Use --keep-files to prevent this."
    trap 'rm -f "$GLOBAL_BACKUP_FILE" "$PARENT_ENV_LOOKUP_RESPONSE_FILE" "$CREATE_ENV_RESPONSE_FILE" "$TARGET_ENV_LOOKUP_RESPONSE_FILE" "$SOURCE_ENV_LOOKUP_RESPONSE_FILE"; unset API_KEY' EXIT
else
    echo "🐛 Keeping temporary files for debugging: $GLOBAL_BACKUP_FILE, $PARENT_ENV_LOOKUP_RESPONSE_FILE, $CREATE_ENV_RESPONSE_FILE, $TARGET_ENV_LOOKUP_RESPONSE_FILE, $SOURCE_ENV_LOOKUP_RESPONSE_FILE"
fi

# --- Global Backup ---
echo "💾 Creating a full organization backup snapshot before proceeding..."
BACKUP_URL="${BASE_URL}/backup/snapshot/"

CURL_OUTPUT=$(curl -s -w "%{http_code}\n%{time_total}" -o "$GLOBAL_BACKUP_FILE" \
    -X POST \
    -H "Authorization: Api-Key $API_KEY" \
    "$BACKUP_URL")

BACKUP_HTTP_STATUS=$(echo -e "$CURL_OUTPUT" | head -n 1)
BACKUP_TIME=$(echo -e "$CURL_OUTPUT" | tail -n 1)

if [ "$BACKUP_HTTP_STATUS" -eq 200 ]; then
    echo "✅ Full backup snapshot successful. Data saved to '$GLOBAL_BACKUP_FILE'. (took ${BACKUP_TIME}s)"
else
    echo -e "\n🚨 Error: Failed to create a full backup snapshot. The API returned status code $BACKUP_HTTP_STATUS. (took ${BACKUP_TIME}s)"
    echo "API Response:"
    # The response is already in the file, so just display it.
    cat "$GLOBAL_BACKUP_FILE"
    echo "Aborting move operation due to backup failure."
    exit 1
fi

# --- Environment Verification and Creation ---
echo "🔎 Verifying environments..."

# 1. Check for the parent environment and capture its URI.
PARENT_ENV_LOOKUP_URL="${BASE_URL}/environments/?name=${PARENT_ENVIRONMENT}"
CURL_OUTPUT=$(curl -s -w "%{http_code}\n%{time_total}" -o "$PARENT_ENV_LOOKUP_RESPONSE_FILE" \
    -H "Authorization: Api-Key $API_KEY" \
    "$PARENT_ENV_LOOKUP_URL")

PARENT_LOOKUP_STATUS=$(echo -e "$CURL_OUTPUT" | head -n 1)
PARENT_LOOKUP_TIME=$(echo -e "$CURL_OUTPUT" | tail -n 1)

if [ "$PARENT_LOOKUP_STATUS" -ne 200 ]; then
    echo "🚨 Error looking up the parent environment '$PARENT_ENVIRONMENT'. API returned status $PARENT_LOOKUP_STATUS. (took ${PARENT_LOOKUP_TIME}s)"
    jq . "$PARENT_ENV_LOOKUP_RESPONSE_FILE"
    exit 1
fi

PARENT_COUNT=$(jq '.count' "$PARENT_ENV_LOOKUP_RESPONSE_FILE")
if [ "$PARENT_COUNT" -ne 1 ]; then
    echo "🚨 Parent environment '$PARENT_ENVIRONMENT' not found or is ambiguous (found $PARENT_COUNT). (took ${PARENT_LOOKUP_TIME}s)"
    die "Parent environment '$PARENT_ENVIRONMENT' not found or is ambiguous.  Exiting."
fi

echo "✅ Parent Environment '$PARENT_ENVIRONMENT' exists. (took ${PARENT_LOOKUP_TIME}s)"
PARENT_ENV_URI=$(jq -r '.results[0].url' "$PARENT_ENV_LOOKUP_RESPONSE_FILE")

# 2. Check that the source environment to move exists.
SOURCE_ENV_LOOKUP_URL="${BASE_URL}/environments/?name=${SOURCE_ENVIRONMENT}"
CURL_OUTPUT=$(curl -s -w "%{http_code}\n%{time_total}" -o "$SOURCE_ENV_LOOKUP_RESPONSE_FILE" \
    -H "Authorization: Api-Key $API_KEY" \
    "$SOURCE_ENV_LOOKUP_URL")

SOURCE_LOOKUP_STATUS=$(echo -e "$CURL_OUTPUT" | head -n 1)
SOURCE_LOOKUP_TIME=$(echo -e "$CURL_OUTPUT" | tail -n 1)

if [ "$SOURCE_LOOKUP_STATUS" -ne 200 ]; then
    echo "🚨 Error looking up the source environment '$SOURCE_ENVIRONMENT'. API returned status $SOURCE_LOOKUP_STATUS. (took ${SOURCE_LOOKUP_TIME}s)"
    jq . "$SOURCE_ENV_LOOKUP_RESPONSE_FILE"
    exit 1
fi

SOURCE_COUNT=$(jq '.count' "$SOURCE_ENV_LOOKUP_RESPONSE_FILE")
if [ "$SOURCE_COUNT" -ne 1 ]; then
    echo "🚨 Error: Source environment to move '$SOURCE_ENVIRONMENT' not found or is ambiguous (found $SOURCE_COUNT). (took ${SOURCE_LOOKUP_TIME}s)"
    die "Source environment '$SOURCE_ENVIRONMENT' not found or is ambiguous. Exiting."
fi
echo "✅ Source environment to move '$SOURCE_ENVIRONMENT' found. (took ${SOURCE_LOOKUP_TIME}s)"

# 3. Check if the target environment already exists. It should NOT.
TARGET_ENV_LOOKUP_URL="${BASE_URL}/environments/?name=${TARGET_ENVIRONMENT}"
CURL_OUTPUT=$(curl -s -w "%{http_code}\n%{time_total}" -o "$TARGET_ENV_LOOKUP_RESPONSE_FILE" \
    -H "Authorization: Api-Key $API_KEY" \
    "$TARGET_ENV_LOOKUP_URL")

TARGET_ENV_LOOKUP_STATUS=$(echo -e "$CURL_OUTPUT" | head -n 1)
TARGET_ENV_LOOKUP_TIME=$(echo -e "$CURL_OUTPUT" | tail -n 1)

if [ "$TARGET_ENV_LOOKUP_STATUS" -ne 200 ]; then
    echo "🚨 Error looking up the target environment '$TARGET_ENVIRONMENT'. API returned status $TARGET_ENV_LOOKUP_STATUS. (took ${TARGET_ENV_LOOKUP_TIME}s)"
    jq . "$TARGET_ENV_LOOKUP_RESPONSE_FILE"
    exit 1
fi

CHILD_COUNT=$(jq '.count' "$TARGET_ENV_LOOKUP_RESPONSE_FILE")
if [ "$CHILD_COUNT" -gt 0 ]; then
    echo "⚠️ Target environment '$TARGET_ENVIRONMENT' already exists. Did you create this environment ahead of time?"
    while true; do
        case $yn in
            [Yy]*)
                echo "✅ OK. You created this environment ahead of time, proceeding to the next step."
                SKIP_CREATION=true
                break
                ;;
            [Nn]*)
                echo "❌ Please remove the existing target environment '$TARGET_ENVIRONMENT' before proceeding."
                exit 1
                break
                ;;
            *)
                echo "❓ Please answer yes (y) or no (n)."
                read -r yn
                ;;
        esac
    done
else
    echo "🤔 Environment '$TARGET_ENVIRONMENT' not found. (took ${TARGET_ENV_LOOKUP_TIME}s)"
fi

if [ "$SKIP_CREATION" = false ]; then
    # 3. If we're here, the child environment does not exist or needs to be created with a _TEMP suffix.
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: Would create environment '$TARGET_ENVIRONMENT' under '$PARENT_ENVIRONMENT'."
    else
        # --- Asynchronous Creation and Polling ---
        # Update the lookup URL in case the environment name was changed to _TEMP
        TARGET_ENV_LOOKUP_URL="${BASE_URL}/environments/?name=${TARGET_ENVIRONMENT}"
        echo "Submitting request to create environment '$TARGET_ENVIRONMENT'..."
        CREATE_ENV_URL="${BASE_URL}/environments/"
        CREATE_PAYLOAD=$(jq -n --arg name "$TARGET_ENVIRONMENT" --arg parent_uri "$PARENT_ENV_URI" '{name: $name, parent: $parent_uri}')

        # Submit the creation request and run it in the background. We don't wait for it.
        # Output is redirected to /dev/null as we will poll for the result.
        curl -s -o /dev/null \
            -X POST \
            -H "Authorization: Api-Key $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$CREATE_PAYLOAD" \
            "$CREATE_ENV_URL" &

        # Poll for up to 10 minutes to see if the environment was created.
        POLL_START_TIME=$SECONDS
        POLL_TIMEOUT=600  # 10 minutes
        POLL_INTERVAL=15 # Check every 15 seconds

        echo -n "Polling for creation status (up to 10 minutes) "
        while true; do
            ELAPSED_TIME=$((SECONDS - POLL_START_TIME))
            if [ "$ELAPSED_TIME" -ge "$POLL_TIMEOUT" ]; then
                echo -e "\n\n🚨 Polling timed out after 10 minutes."
                echo "The environment may still be creating in the background."
                echo "Please check the CloudTruth UI or contact CloudTruth support for assistance."
                exit 1
            fi

            # Re-use the child lookup URL and file to check for the new environment
            CURL_OUTPUT=$(curl -s -w "%{http_code}\n%{time_total}" -o "$TARGET_ENV_LOOKUP_RESPONSE_FILE" \
                -H "Authorization: Api-Key $API_KEY" \
                "$TARGET_ENV_LOOKUP_URL")

            LOOKUP_STATUS=$(echo -e "$CURL_OUTPUT" | head -n 1)

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
        done
    fi
fi

echo
echo "---"
echo "Next step: Populate values for the environment '$TARGET_ENVIRONMENT' (logic to be added)."
