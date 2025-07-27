#!/bin/bash

# --- Usage Function ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <required-arg1> <required-arg2> [optional-arg]

Interacts with the CloudTruth Management API. See https://docs.cloudtruth.com/ for API details.

Options:
  -h, --help            Show this help message and exit
  -n, --dry-run         Show actions without making changes
  -o, --output <dir>    Specify output directory (default: $HOME)
  --profile <profile>   Use a specific profile from config
EOF
    exit 0
}

# --- Argument Parsing ---
DRY_RUN="false"
OUTPUT_DIR="$HOME"
PROFILE="default"

while (($# > 0)); do
    case "$1" in
        -h|--help)
            usage
            ;;
        -n|--dry-run)
            DRY_RUN="true"
            shift
            ;;
        -o|--output)
            if [ -n "$2" ]; then
                OUTPUT_DIR="$2"
                shift 2
            else
                echo "🚨 Error: Option $1 requires an argument." >&2
                exit 1
            fi
            ;;
        --profile)
            if [ -n "$2" ]; then
                PROFILE="$2"
                shift 2
            else
                echo "🚨 Error: Option $1 requires an argument." >&2
                exit 1
            fi
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "🚨 Error: Unknown option: $1" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# --- Positional Arguments ---
if [ "$#" -lt 2 ]; then
    echo "🚨 Error: Missing required arguments." >&2
    usage
fi
ARG1="$1"
ARG2="$2"
ARG3="${3:-}" # Optional

# --- Dependency Checks ---
for dep in curl jq yq; do
    if ! command -v "$dep" &>/dev/null; then
        echo "🚨 Error: Required dependency '$dep' is not installed." >&2
        exit 1
    fi
done

# --- Config File Detection ---
CONFIG_FILE=""
OS="$(uname -s)"
case "$OS" in
    Linux)
        CONFIG_LOCATIONS=("$XDG_CONFIG_HOME/cloudtruth/cli.yml" "$HOME/.config/cloudtruth/cli.yml")
        ;;
    Darwin)
        CONFIG_LOCATIONS=("$HOME/Library/Application Support/com.cloudtruth.CloudTruth-CLI/cli.yml")
        ;;
    *)
        CONFIG_LOCATIONS=()
        ;;
esac
for loc in "${CONFIG_LOCATIONS[@]}"; do
    if [ -f "$loc" ]; then
        CONFIG_FILE="$loc"
        break
    fi
done

# --- API Key Handling ---
API_KEY=""

BASE_URL=""
if [ -n "$CONFIG_FILE" ]; then
    API_KEY=$(yq e ".profiles.${PROFILE}.api_key" "$CONFIG_FILE")
    BASE_URL=$(yq e ".profiles.${PROFILE}.server_url" "$CONFIG_FILE")
    # If BASE_URL is empty or null, try to inherit from source_profile
    if [ -z "$BASE_URL" ] || [ "$BASE_URL" == "null" ]; then
        SOURCE_PROFILE=$(yq e ".profiles.${PROFILE}.source_profile" "$CONFIG_FILE")
        if [ -n "$SOURCE_PROFILE" ] && [ "$SOURCE_PROFILE" != "null" ]; then
            BASE_URL=$(yq e ".profiles.${SOURCE_PROFILE}.server_url" "$CONFIG_FILE")
        fi
    fi
else
    read -rsp "Enter your CloudTruth API Key: " API_KEY
    echo
    read -rp "Enter CloudTruth API Base URL [https://api.cloudtruth.io]: " BASE_URL
fi
if [ -z "$API_KEY" ] || [ "$API_KEY" == "null" ]; then
    echo "🚨 Error: API key is missing." >&2
    exit 1
fi
# Default BASE_URL if not set
if [ -z "$BASE_URL" ] || [ "$BASE_URL" == "null" ]; then
    BASE_URL="https://api.cloudtruth.io"
fi
BASE_URL="${BASE_URL%/}/api/v1"

# --- API Request Function ---
api_request() {
    local URL="$1"
    local METHOD="${2:-GET}"
    local PAYLOAD="${3:-}"
    local OUTPUT_FILE="$4"
    local CURL_CMD=(curl -s -w "%{http_code}\n%{time_total}" -X "$METHOD" -H "Authorization: Api-Key $API_KEY" -H "Content-Type: application/json")
    if [ -n "$PAYLOAD" ]; then
        CURL_CMD+=( -d "$PAYLOAD" )
    fi
    CURL_CMD+=( -o "$OUTPUT_FILE" "$URL" )
    local CURL_OUTPUT
    CURL_OUTPUT=$("${CURL_CMD[@]}" 2>&1)
    local CURL_STATUS=$?
    if [ $CURL_STATUS -ne 0 ]; then
        echo "🚨 Error: curl failed ($CURL_STATUS): $CURL_OUTPUT" >&2
        return 1
    fi
    echo "$CURL_OUTPUT"
}

# --- Temporary File Handling ---
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- Main Execution Example ---

RESPONSE_FILE="$TEMP_DIR/api_response.json"

if [ "$DRY_RUN" = "true" ]; then
    echo "DRY RUN: Would call API endpoint..."
else
    # Example GET request to environments endpoint
    RESULT=$(api_request "$BASE_URL/environments/" GET "" "$RESPONSE_FILE")
    STATUS=$(echo -e "$RESULT" | head -n 1)
    TIME=$(echo -e "$RESULT" | tail -n 1)
    if [ "$STATUS" -eq 200 ]; then
        echo "✅ API call successful. (took ${TIME}s)"
        jq . "$RESPONSE_FILE"
    else
        echo "🚨 API call failed. Status: $STATUS (took ${TIME}s)"
        cat "$RESPONSE_FILE"
        exit 1
    fi
fi
