#!/bin/bash

set -euo pipefail

###############################################################################
# Usage Function
###############################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <action_id>

Check the status of a CloudTruth action by action_id.
- If the action is queued for more than 10 minutes, warn the user.
- If the action is running, poll every 2 minutes until it completes (success/failure).
- While polling, display the task list for the action.

Options:
      --profile <profile>    Use a specific profile from config (default: default)
      --strict-profile       Fail if the profile or cli.yml config file is missing (for automation)
  -h, --help                 Show this help message and exit

Requires: curl, jq, yq

Example:
  $(basename "$0") --profile myprofile 123e4567-e89b-12d3-a456-426614174000
EOF
    exit 0
}

###############################################################################
# Argument Parsing
###############################################################################
PROFILE="default"
STRICT_PROFILE="false"
OUTPUT_TYPE="table"

while (($# > 0)); do
    case "$1" in
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
        -o|--output-type)
            if [ -n "${2:-}" ]; then
                OUTPUT_TYPE="$2"
                shift 2
            else
                echo "🚨 Error: Option $1 requires an argument." >&2
                exit 1
            fi
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

if [ $# -ne 1 ]; then
    usage
fi
ACTION_ID="$1"

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
    if yq e ".profiles.\"${PROFILE}\"" "$CONFIG_FILE" | grep -vq 'null'; then
        PROFILE_EXISTS="true"
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
    local OUTPUT_FILE="$2"
    curl -s -H "Authorization: Api-Key $API_KEY" -H "Content-Type: application/json" -o "$OUTPUT_FILE" "$URL"
}

###############################################################################
# Action Status and Task Polling Logic
###############################################################################
get_action_url_and_type() {
    # Try to find the action in all known integration types and actions
    # Returns: integration_type action_type integration_id
    for integration in aws azure_key_vault github; do
        local integrations_url="${BASE_URL}/integrations/${integration}/"
        local integrations_json="$TEMP_DIR/integrations_${integration}_detect.json"
        api_request "$integrations_url" "$integrations_json"
        local ids
        ids=$(jq -r '.results[]?.id' "$integrations_json")
        for integration_id in $ids; do
            for action_type in pulls pushes; do
                local action_url="${BASE_URL}/integrations/${integration}/${integration_id}/${action_type}/${ACTION_ID}/"
                local action_json="$TEMP_DIR/action_${integration}_${integration_id}_${action_type}_${ACTION_ID}.json"
                api_request "$action_url" "$action_json"
                if jq -e '.id' "$action_json" >/dev/null 2>&1; then
                    echo "$integration $action_type $integration_id $action_url"
                    return 0
                fi
            done
        done
    done
    return 1
}

get_action_status() {
    local action_url="$1"
    local action_json="$2"
    api_request "$action_url" "$action_json"
    jq -r '.latest_task.state // empty' "$action_json"
}

get_action_queued_time() {
    local action_json="$1"
    jq -r '.queued_at // .created_at // empty' "$action_json"
}

get_tasks_url() {
    local integration_type="$1"
    local integration_id="$2"
    local action_type="$3"
    local action_id="$4"
    if [ "$action_type" = "pulls" ]; then
        echo "${BASE_URL}/integrations/${integration_type}/${integration_id}/pulls/${action_id}/tasks/"
    else
        echo "${BASE_URL}/integrations/${integration_type}/${integration_id}/pushes/${action_id}/tasks/"
    fi
}

print_tasks() {
    local tasks_url="$1"
    local tasks_json="$2"
    api_request "$tasks_url" "$tasks_json"
    case "$OUTPUT_TYPE" in
        table)
            local header_printed="false"
            jq -r '
                .results[] |
                [
                    .id,
                    .state,
                    (.name // .task_type // "-"),
                    (if .error_code and .error_code != "" then .error_code else "-" end),
                    (if .error_detail and .error_detail != "" then .error_detail else "-" end),
                    (.created_at // "-")
                ] | @tsv
            ' "$tasks_json" | while IFS=$'\t' read -r id state name error_code error_detail created_at; do
                if [ "$header_printed" = "false" ]; then
                    printf "%-36s %-10s %-30s %-20s %-30s %-20s\n" "TASK_ID" "STATE" "NAME/TYPE" "ERROR_CODE" "ERROR_DETAIL" "CREATED_AT"
                    printf "%0.s-" {1..150}; echo
                    header_printed="true"
                fi
                printf "%-36s %-10s %-30s %-20s %-30s %-20s\n" \
                    "$id" "$state" "$name" "$error_code" "$error_detail" "$created_at"
            done
            ;;
        json)
            jq '.' "$tasks_json"
            ;;
        raw)
            jq -r '.results[] | [.id, .state, (.name // .task_type // "-"), (.error_code // "-"), (.error_detail // "-"), (.created_at // "-")] | @csv' "$tasks_json"
            ;;
        *)
            echo "Unknown output type: $OUTPUT_TYPE" >&2
            exit 1
            ;;
    esac
}

###############################################################################
# Main Logic
###############################################################################
main() {
    local info
    if ! info=$(get_action_url_and_type); then
        echo "🚨 Error: Action ID '$ACTION_ID' not found in any integration." >&2
        exit 1
    fi
    local integration_type action_type integration_id action_url
    read -r integration_type action_type integration_id action_url <<<"$info"

    local action_json="$TEMP_DIR/action.json"
    local state
    state=$(get_action_status "$action_url" "$action_json")

    if [ "$state" = "queued" ]; then
        # Check how long it's been queued
        queued_time=$(get_action_queued_time "$action_json")
        if [ -n "$queued_time" ]; then
            # Convert to epoch seconds
            now_epoch=$(date +%s)
            queued_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${queued_time:0:19}" +%s 2>/dev/null || date -d "$queued_time" +%s)
            if [ -n "$queued_epoch" ] && [ $((now_epoch - queued_epoch)) -gt 600 ]; then
                echo "⚠️  Action has been queued for more than 10 minutes!"
            fi
        fi
        if [ "$OUTPUT_TYPE" = "table" ]; then
            echo "Action is currently queued."
        fi
        print_tasks "$(get_tasks_url "$integration_type" "$integration_id" "$action_type" "$ACTION_ID")" "$TEMP_DIR/tasks.json"
        exit 0
    fi

    if [ "$state" = "running" ]; then
        if [ "$OUTPUT_TYPE" = "table" ]; then
            echo "Action is running. Polling every 2 minutes until completion..."
        fi
        while [ "$state" = "running" ]; do
            print_tasks "$(get_tasks_url "$integration_type" "$integration_id" "$action_type" "$ACTION_ID")" "$TEMP_DIR/tasks.json"
            sleep 120
            state=$(get_action_status "$action_url" "$action_json")
        done
        if [ "$OUTPUT_TYPE" = "table" ]; then
            echo "Polling finished. Final state: $state"
        fi
        print_tasks "$(get_tasks_url "$integration_type" "$integration_id" "$action_type" "$ACTION_ID")" "$TEMP_DIR/tasks.json"
        if [ "$state" = "failure" ]; then
            exit 2
        fi
        exit 0
    fi

    if [ "$OUTPUT_TYPE" = "table" ]; then
        echo "Action is in state: $state"
    fi
    print_tasks "$(get_tasks_url "$integration_type" "$integration_id" "$action_type" "$ACTION_ID")" "$TEMP_DIR/tasks.json"
    if [ "$state" = "failure" ]; then
        exit 2
    fi
}

main
