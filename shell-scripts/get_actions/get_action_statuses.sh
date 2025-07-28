#!/bin/bash

set -euo pipefail

###############################################################################
# Usage Function
###############################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Query CloudTruth integrations for actions and report their task states if in failure, queued, or running.

Options:
  -o, --output-type <type>   Output format: table (default), json, or raw
  -a, --all-states           Show all action states (not just failure, queued, running)
      --profile <profile>    Use a specific profile from config (default: default)
      --strict-profile       Fail if the profile or cli.yml config file is missing (for automation)
  -h, --help                 Show this help message and exit

Functionality:
  - Only integrations that exist in your CloudTruth account (aws, azure_key_vault, github) will be queried.
  - If --strict-profile is set, the script will exit if the profile or config file is missing.
  - If --all-states is not set, only actions in failure, queued, or running state are shown.

Examples:
  $(basename "$0") --output-type json
  $(basename "$0") -o raw --profile myprofile
  $(basename "$0") --all-states
  $(basename "$0") --strict-profile --profile prod

Requires: curl, jq, yq
EOF
    exit 0
}

###############################################################################
# Argument Parsing
###############################################################################
OUTPUT_TYPE="table"
PROFILE="default"
SHOW_ALL_STATES="false"
STRICT_PROFILE="false"

while (($# > 0)); do
    case "$1" in
        -o|--output-type)
            if [ -n "${2:-}" ]; then
                OUTPUT_TYPE="$2"
                shift 2
            else
                echo "🚨 Error: Option $1 requires an argument." >&2
                exit 1
            fi
            ;;
        -a|--all-states)
            SHOW_ALL_STATES="true"
            shift
            ;;
        --profile)
            if [ -n "${2:-}" ]; then
                PROFILE="$2"
                shift 2
            else
                echo "🚨 Error: Option $1 requires an argument." >&2
                exit 1
            fi
            ;;
        --strict-profile)
            STRICT_PROFILE="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

###############################################################################
# Dependency Checks
###############################################################################
for dep in curl jq yq; do
    if ! command -v "$dep" &>/dev/null; then
        echo "🚨 Error: Required dependency '$dep' is not installed." >&2
        exit 1
    fi
done

###############################################################################
# Config File Detection
###############################################################################
CONFIG_FILE=""
OS="$(uname -s)"
case "$OS" in
    Linux)
        CONFIG_LOCATIONS=("${XDG_CONFIG_HOME:-$HOME/.config}/cloudtruth/cli.yml" "$HOME/.config/cloudtruth/cli.yml")
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

if [ "$STRICT_PROFILE" = "true" ]; then
    if [ -z "$CONFIG_FILE" ]; then
        echo "🚨 Error: cli.yml config file not found and --strict-profile was specified." >&2
        exit 1
    fi
fi

###############################################################################
# API Key Handling
###############################################################################
API_KEY=""
BASE_URL=""
PROFILE_EXISTS="false"
if [ -n "$CONFIG_FILE" ]; then
    # Check if the profile exists in the config file
    if yq e ".profiles.\"${PROFILE}\"" "$CONFIG_FILE" | grep -vq 'null'; then
        PROFILE_EXISTS="true"
        API_KEY=$(yq e ".profiles.\"${PROFILE}\".api_key" "$CONFIG_FILE")
        BASE_URL=$(yq e ".profiles.\"${PROFILE}\".server_url" "$CONFIG_FILE")
        if [ -z "$BASE_URL" ] || [ "$BASE_URL" = "null" ] || [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
            SOURCE_PROFILE=$(yq e ".profiles.\"${PROFILE}\".source_profile" "$CONFIG_FILE")
            if [ -n "$SOURCE_PROFILE" ] && [ "$SOURCE_PROFILE" != "null" ]; then
                # Only override if missing/null
                if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
                    API_KEY=$(yq e ".profiles.\"${SOURCE_PROFILE}\".api_key" "$CONFIG_FILE")
                fi
                if [ -z "$BASE_URL" ] || [ "$BASE_URL" = "null" ]; then
                    BASE_URL=$(yq e ".profiles.\"${SOURCE_PROFILE}\".server_url" "$CONFIG_FILE")
                fi
            fi
        fi
    else
        echo "Warning: Profile '$PROFILE' not found in $CONFIG_FILE." >&2
    fi
fi

if [ "$STRICT_PROFILE" = "true" ]; then
    if [ "$PROFILE_EXISTS" = "false" ]; then
        echo "🚨 Error: Profile '$PROFILE' not found in $CONFIG_FILE and --strict-profile was specified." >&2
        exit 1
    fi
fi

if [ "$PROFILE_EXISTS" = "false" ] && [ "$STRICT_PROFILE" = "false" ]; then
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

###############################################################################
# Temporary File Handling
###############################################################################
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

###############################################################################
# API Request Function
###############################################################################
api_request() {
    local URL="$1"
    local METHOD="${2:-GET}"
    local PAYLOAD="${3:-}"
    local OUTPUT_FILE="$4"
    local CURL_CMD
    CURL_CMD=(curl -s -X "$METHOD" -H "Authorization: Api-Key $API_KEY" -H "Content-Type: application/json")
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
}

###############################################################################
# Output Helpers
###############################################################################
print_table() {
    printf "%-36s %-20s %-20s %-10s\n" "ACTION_ID" "INTEGRATION" "ACTION_TYPE" "STATE"
    printf "%0.s-" {1..90}; echo
    jq -r '.[] | [.id, .integration, .type, .state] | @tsv' | while IFS=$'\t' read -r id integration type state; do
        printf "%-36s %-20s %-20s %-10s\n" "$id" "$integration" "$type" "$state"
    done
}

print_raw() {
    jq -r '.[] | [.id, .integration, .type, .state] | @csv'
}

print_json() {
    jq .
}

print_output() {
    case "$OUTPUT_TYPE" in
        table) print_table ;;
        json) print_json ;;
        raw) print_raw ;;
        *) echo "Unknown output type: $OUTPUT_TYPE" >&2; exit 1 ;;
    esac
}

###############################################################################
# Main Logic
###############################################################################
if [ "$SHOW_ALL_STATES" = "true" ]; then
    FILTER_STATES=""
else
    FILTER_STATES="failure,queued,running"
fi

# Helper to build URLs using bash string interpolation
build_url() {
    local integration_type="$1"
    local integration_id="$2"
    local action_type="$3"
    local action_id="$4"
    local endpoint="$5"
    case "$endpoint" in
        pulls)
            echo "${BASE_URL}/integrations/${integration_type}/${integration_id}/pulls/"
            ;;
        pushes)
            echo "${BASE_URL}/integrations/${integration_type}/${integration_id}/pushes/"
            ;;
        pull_tasks)
            echo "${BASE_URL}/integrations/${integration_type}/${integration_id}/pulls/${action_id}/tasks/"
            ;;
        push_tasks)
            echo "${BASE_URL}/integrations/${integration_type}/${integration_id}/pushes/${action_id}/tasks/"
            ;;
        *)
            echo "Unknown endpoint: $endpoint" >&2
            return 1
            ;;
    esac
}

collect_actions() {
    local integration_type="$1"
    local action_type="$2"

    # Get all integrations of this type
    local integrations_json="$TEMP_DIR/integrations_${integration_type}.json"
    api_request "${BASE_URL}/integrations/${integration_type}/" GET "" "$integrations_json" >/dev/null

    if ! jq empty "$integrations_json" 2>/dev/null; then
        echo "Warning: Invalid or empty JSON from ${BASE_URL}/integrations/${integration_type}/" >&2
        return
    fi

    jq -r '.results[]?.id' "$integrations_json" | while read -r integration_id; do
        # Get all actions (pulls or pushes) for this integration
        local actions_json="$TEMP_DIR/${integration_type}_${action_type}_${integration_id}.json"
        local actions_url
        if [ "$action_type" = "pull" ]; then
            actions_url=$(build_url "$integration_type" "$integration_id" "$action_type" "" "pulls")
        else
            actions_url=$(build_url "$integration_type" "$integration_id" "$action_type" "" "pushes")
        fi
        api_request "$actions_url" GET "" "$actions_json" >/dev/null

        if ! jq empty "$actions_json" 2>/dev/null; then
            echo "Warning: Invalid or empty JSON for actions $integration_id" >&2
            continue
        fi

        jq -r '.results[]?.id' "$actions_json" | while read -r action_id; do
            # Get all tasks for this action
            local tasks_json="$TEMP_DIR/${integration_type}_${action_type}_tasks_${action_id}.json"
            local tasks_url
            if [ "$action_type" = "pull" ]; then
                tasks_url=$(build_url "$integration_type" "$integration_id" "$action_type" "$action_id" "pull_tasks")
            else
                tasks_url=$(build_url "$integration_type" "$integration_id" "$action_type" "$action_id" "push_tasks")
            fi
            api_request "$tasks_url" GET "" "$tasks_json" >/dev/null

            if ! jq empty "$tasks_json" 2>/dev/null; then
                echo "Warning: Invalid or empty JSON for tasks $action_id" >&2
                continue
            fi

            if [ -z "$FILTER_STATES" ]; then
                jq -c --arg action_id "$action_id" \
                    '.results[] | {id: $action_id, integration: "'"$integration_type"'", type: "'"$action_type"'", state: .state}' \
                    "$tasks_json"
            else
                jq -c --arg action_id "$action_id" --argjson states "$(printf '["%s"]' "${FILTER_STATES//,/\",\"}")" \
                    '.results[] | select(.state as $s | $states | index($s)) |
                    {id: $action_id, integration: "'"$integration_type"'", type: "'"$action_type"'", state: .state}' \
                    "$tasks_json"
            fi
        done
    done
}

detect_integrations() {
    ACTIVE_INTEGRATIONS=()
    for integration in aws azure_key_vault github; do
        local url="${BASE_URL}/integrations/${integration}/"
        local tmp_json="$TEMP_DIR/integrations_${integration}_detect.json"
        api_request "$url" GET "" "$tmp_json" >/dev/null
        if jq -e '.results | length > 0' "$tmp_json" >/dev/null 2>&1; then
            ACTIVE_INTEGRATIONS+=("$integration")
        fi
    done
}

main() {
    detect_integrations

    {
        for integration in "${ACTIVE_INTEGRATIONS[@]}"; do
            case "$integration" in
                aws)
                    collect_actions "aws" "pull"
                    collect_actions "aws" "push"
                    ;;
                azure_key_vault)
                    collect_actions "azure_key_vault" "pull"
                    collect_actions "azure_key_vault" "push"
                    ;;
                github)
                    collect_actions "github" "pull"
                    ;;
            esac
        done
    } | jq -s '.' | print_output
}

main
