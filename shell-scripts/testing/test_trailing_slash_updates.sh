#!/bin/bash

# CloudTruth Template Trailing Slash Update Test Script
# Tests PATCH/PUT with and without trailing slashes on templates.

# --- Dependency Checks ---
for dep in curl jq yq; do
    if ! command -v "$dep" &>/dev/null; then
        echo "🚨 Error: Required dependency '$dep' is not installed." >&2
        exit 1
    fi
done

# --- Usage Function ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <project>

Tests CloudTruth API template update behavior with and without trailing slashes using PATCH and PUT.

Options:
  -h, --help                Show this help message and exit
  -n, --dry-run             Show actions without making changes
  --profile <profile>       Use a specific CloudTruth CLI profile (default: "default")
  --env <environment>       Specify environment (optional)
  --template <template>     Specify template name (optional, default: "test-template")
  --follow-redirects        Act like curl and follow redirects for PUT/PATCH
EOF
    exit 0
}

# --- Argument Parsing ---
DRY_RUN="false"
PROFILE="default"
ENVIRONMENT=""
TEMPLATE_NAME="test-template"
FOLLOW_REDIRECTS="false"

while (($# > 0)); do
    case "$1" in
        -h|--help)
            usage
            ;;
        -n|--dry-run)
            DRY_RUN="true"
            shift
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --env)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --template)
            TEMPLATE_NAME="$2"
            shift 2
            ;;
        --follow-redirects)
            FOLLOW_REDIRECTS="true"
            shift
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

if [ "$#" -lt 1 ]; then
    echo "🚨 Error: Missing required <project> argument." >&2
    usage
fi
PROJECT="$1"

# --- Config File Detection (from template) ---
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

API_KEY=""
BASE_URL=""
if [ -n "$CONFIG_FILE" ]; then
    API_KEY=$(yq e ".profiles.\"${PROFILE}\".api_key" "$CONFIG_FILE")
    BASE_URL=$(yq e ".profiles.\"${PROFILE}\".server_url" "$CONFIG_FILE")
    if [ -z "$BASE_URL" ] || [ "$BASE_URL" = "null" ] || [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
        SOURCE_PROFILE=$(yq e ".profiles.\"${PROFILE}\".source_profile" "$CONFIG_FILE")
        if [ -n "$SOURCE_PROFILE" ] && [ "$SOURCE_PROFILE" != "null" ]; then
            if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
                API_KEY=$(yq e ".profiles.\"${SOURCE_PROFILE}\".api_key" "$CONFIG_FILE")
            fi
            if [ -z "$BASE_URL" ] || [ "$BASE_URL" = "null" ]; then
                BASE_URL=$(yq e ".profiles.\"${SOURCE_PROFILE}\".server_url" "$CONFIG_FILE")
            fi
        fi
    fi
else
    read -rsp "Enter your CloudTruth API Key: " API_KEY
    echo
    read -rp "Enter CloudTruth API Base URL [https://api.cloudtruth.io]: " BASE_URL
fi
if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
    echo "🚨 Error: API key is missing." >&2
    exit 1
fi
if [ -z "$BASE_URL" ] || [ "$BASE_URL" = "null" ]; then
    BASE_URL="https://api.cloudtruth.io"
fi
BASE_URL="${BASE_URL%/}/api/v1"

# --- Helper Functions ---
api_request() {
    local URL="$1"
    local METHOD="${2:-GET}"
    local PAYLOAD="${3:-}"
    local OUTPUT_FILE="$4"
    local FOLLOW_REDIRECTS_ARG=""
    if [ "$FOLLOW_REDIRECTS" = "true" ]; then
        FOLLOW_REDIRECTS_ARG="-L"
    fi
    local CURL_CMD=(curl -s -w "%{http_code}\n%{time_total}" -X "$METHOD" -H "Authorization: Api-Key $API_KEY" -H "Content-Type: application/json" $FOLLOW_REDIRECTS_ARG)
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

get_id_by_name() {
    local url="$1"
    local name="$2"
    local jq_filter="$3"
    local id
    id=$(curl -s -H "Authorization: Api-Key $API_KEY" "$url" | jq -r ".results[] | select(.name==\"$name\") | .id")
    echo "$id"
}

# --- Source HTTP Status Code Names ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utilities/http_status_name.sh"

# --- Test Update Function ---
test_update() {
    local method="$1"
    local slash="$2"
    local new_body="$3"
    local url="$BASE_URL/projects/$PROJECT_ID/templates/$TEMPLATE_ID$slash"
    local resp_file="$TEMP_DIR/resp_${method}_${slash//\//_}.json"
    local payload

    # For PUT, both name and body are required
    if [ "$method" = "PUT" ]; then
        payload="{\"name\": \"$TEMPLATE_NAME\", \"body\": \"$new_body\"}"
    else
        payload="{\"body\": \"$new_body\"}"
    fi

    # Get body before update
    GET_URL="$BASE_URL/projects/$PROJECT_ID/templates/$TEMPLATE_ID/"
    BODY_BEFORE=$(curl -s -H "Authorization: Api-Key $API_KEY" "$GET_URL" | jq -r '.body')

    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY RUN: $method $url with payload: $payload"
        echo "Body before: $BODY_BEFORE"
        echo "Body after: (dry run, not updated)"
        return 0
    fi

    echo "Testing $method $url"
    RESULT=$(api_request "$url" "$method" "$payload" "$resp_file")
    STATUS=$(echo -e "$RESULT" | head -n 1)
    if [[ "$STATUS" =~ ^2 ]]; then
        echo "✅ $method $url succeeded."
    else
        STATUS_NAME=$(http_status_name "$STATUS")
        echo "❌ $method $url failed. Status: $STATUS ($STATUS_NAME)"
        cat "$resp_file"
    fi

    # Get body after update
    BODY_AFTER=$(curl -s -H "Authorization: Api-Key $API_KEY" "$GET_URL" | jq -r '.body')

    echo "Body before: $BODY_BEFORE"
    echo "Body after:  $BODY_AFTER"

    if [ "$BODY_AFTER" = "$new_body" ]; then
        echo "✅ Template body updated as expected."
    else
        echo "❌ Template body NOT updated as expected."
    fi
}

# --- Setup Temp Dir ---
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- Get Project ID ---
PROJECTS_URL="$BASE_URL/projects/"
PROJECT_ID=$(get_id_by_name "$PROJECTS_URL" "$PROJECT" ".results[] | select(.name==\"$PROJECT\") | .id")
if [ -z "$PROJECT_ID" ]; then
    echo "🚨 Error: Project '$PROJECT' not found." >&2
    exit 1
fi

# --- Get/Create Template ---
TEMPLATES_URL="$BASE_URL/projects/$PROJECT_ID/templates/"
TEMPLATE_ID=$(get_id_by_name "$TEMPLATES_URL" "$TEMPLATE_NAME" ".results[] | select(.name==\"$TEMPLATE_NAME\") | .id")
if [ -z "$TEMPLATE_ID" ]; then
    echo "ℹ️  Template '$TEMPLATE_NAME' not found in project '$PROJECT'. Creating a new blank template..."
    PAYLOAD="{\"name\": \"$TEMPLATE_NAME\", \"body\": \"initial body\"}"
    CREATE_RESP=$(curl -s -w "%{http_code}" -H "Authorization: Api-Key $API_KEY" -H "Content-Type: application/json" -d "$PAYLOAD" "$TEMPLATES_URL")
    CREATE_STATUS="${CREATE_RESP: -3}"
    if [[ "$CREATE_STATUS" =~ ^2 ]]; then
        echo "✅ Template '$TEMPLATE_NAME' created."
    else
        echo "🚨 Error: Failed to create template. Status: $CREATE_STATUS"
        echo "$CREATE_RESP" | head -c -3
        exit 1
    fi
    # Confirm existence
    TEMPLATE_ID=$(get_id_by_name "$TEMPLATES_URL" "$TEMPLATE_NAME" ".results[] | select(.name==\"$TEMPLATE_NAME\") | .id")
    if [ -z "$TEMPLATE_ID" ]; then
        echo "🚨 Error: Could not confirm template creation."
        exit 1
    fi
else
    echo "✅ Template '$TEMPLATE_NAME' exists in project '$PROJECT'."
fi

# --- Generate Random Body ---
RANDOM_BODY="body-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8)"

# --- Run Tests ---
echo "== PATCH without trailing slash =="
test_update "PATCH" "" "$RANDOM_BODY-patch-no-slash"

echo "== PATCH with trailing slash =="
test_update "PATCH" "/" "$RANDOM_BODY-patch-slash"

echo "== PUT without trailing slash =="
test_update "PUT" "" "$RANDOM_BODY-put-no-slash"

echo "== PUT with trailing slash =="
test_update "PUT" "/" "$RANDOM_BODY-put-slash"

echo "Done."
