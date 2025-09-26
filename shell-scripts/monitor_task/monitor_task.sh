#!/usr/bin/env bash

# Monitor the status of a CloudTruth integration action task until it completes.
# Usage: monitor_task.sh PROVIDER INTEGRATION_TYPE INTEGRATION_PK ACTION_PK

set -euo pipefail

# --- Configuration ---
API_BASE_URL="https://api.cloudtruth.io/api/v1"
API_BASE_INTEGRATIONS_URL="${API_BASE_URL}/integrations"
POLL_INTERVAL=10 # seconds between polls
TIMEOUT=600      # total seconds before giving up
LOG_FILE="${MONITOR_TASK_LOG:-/tmp/monitor_task.log}"

# --- Helper Functions ---
usage() {
    cat <<EOF
Monitor the status of a CloudTruth integration action task until it completes.

Usage:
  $0 PROVIDER INTEGRATION_TYPE INTEGRATION_PK ACTION_PK

Arguments:
  PROVIDER         The integration provider (e.g., aws, github, azure)
  INTEGRATION_TYPE The type of action (push or pull)
  INTEGRATION_PK   The unique ID (PK) of the integration
  ACTION_PK        The unique ID (PK) of the push or pull action

Options:
  -h, --help       Show this help message and exit

Environment:
  CLOUDTRUTH_API_KEY   Your CloudTruth API key (required)
  MONITOR_TASK_LOG     Path to log file (optional, default: /tmp/monitor_task.log)

Example:
  CLOUDTRUTH_API_KEY=xxxx $0 aws push 12e647a5-... 960e2893-...
EOF
}

log() {
    # $1 = type (TASK or STEP), $2 = message
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1 $2" >>"$LOG_FILE"
}

log_task_details() {
    echo "$1" | jq -r '
        .results[0] |
        [
            "id: \(.id)",
            "reason: \(.reason)",
            "state: \(.state)",
            "created_at: \(.created_at)",
            "modified_at: \(.modified_at)",
            (if .error_code != null then "error_code: \(.error_code)" else empty end),
            (if .error_detail != null then "error_detail: \(.error_detail)" else empty end)
        ] | .[]
    ' | while IFS= read -r line; do log "TASK" "$line"; done
}

log_step_details() {
    echo "$1" | jq -r '
        .results[]
        | select(.success==false)
        | [
            "id: \(.id)",
            "operation: \(.operation)",
            "success: \(.success)",
            "summary: \(.summary)",
            "fqn: \(.fqn)",
            "environment_name: \(.environment_name)",
            "project_name: \(.project_name)",
            "parameter_name: \(.parameter_name)",
            "created_at: \(.created_at)",
            "modified_at: \(.modified_at)",
            (if .error_code != null then "error_code: \(.error_code)" else empty end),
            (if .error_detail != null then "error_detail: \(.error_detail)" else empty end)
        ] | .[]
    ' | while IFS= read -r line; do log "STEP" "$line"; done
}

error() {
    echo "ERROR: $*" >&2
    log "ERROR" "$*"
    exit 1
}

<<<<<<< Updated upstream
=======
get_project_pk() {
    curl -sS -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" \
        "https://api.cloudtruth.io/api/v1/projects/?name=$1" | jq -r '.results[0].id // empty'
}

get_environment_pk() {
    curl -sS -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" \
        "https://api.cloudtruth.io/api/v1/environments/?name=$1" | jq -r '.results[0].id // empty'
}

get_integration_pk() {
    curl -sS -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" \
        "https://api.cloudtruth.io/api/v1/integrations/$1/?project=$2" | jq -r '.results[0].id // empty'
}

get_action_pk() {
    if [[ -n "$ENVIRONMENT_PK" ]]; then
        local env_uri="${API_BASE_URL}/environments/${ENVIRONMENT_PK}/"
        curl -sS -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" \
            "https://api.cloudtruth.io/api/v1/integrations/$1/$2/$3/?environment=${env_uri}&name=$4" | jq -r '.results[0].id // empty'
    else
        curl -sS -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" \
            "https://api.cloudtruth.io/api/v1/integrations/$1/$2/$3/?name=$4" | jq -r '.results[0].id // empty'
    fi
}

validate_environment_tag_for_action() {
    local environment_pk="$1"
    local action_pk="$2"
    local environment_name="$3"

    tags_url="https://api.cloudtruth.io/api/v1/environments/${environment_pk}/tags/?action=${action_pk}"
    tags_response=$(curl -sS -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" "$tags_url")
    tag_exists=$(echo "$tags_response" | jq -e --arg env "$environment_name" '.results[] | select(.name == $env)' > /dev/null; echo $?)
    if [[ "$tag_exists" -ne 0 ]]; then
        error "Environment '$environment_name' is not associated with action: $ACTION_NAME."
    fi
}

>>>>>>> Stashed changes
# --- Prerequisite Checks ---
command -v curl >/dev/null 2>&1 || error "curl is required but not installed."
command -v jq >/dev/null 2>&1 || error "jq is required but not installed."
[[ -n "${CLOUDTRUTH_API_KEY:-}" ]] || error "CLOUDTRUTH_API_KEY environment variable is not set."

# --- Argument Parsing ---
# --- Argument Parsing ---
if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 4 ]]; then
    usage
    exit 2
fi

PROVIDER="$1"
INTEGRATION_TYPE="$2"
INTEGRATION_PK="$3"
ACTION_PK="$4"

# Normalize action type for API path
case "$INTEGRATION_TYPE" in
push) ACTION_TYPE_PATH="pushes" ;;
pull) ACTION_TYPE_PATH="pulls" ;;
*) ACTION_TYPE_PATH="$INTEGRATION_TYPE" ;;
esac

<<<<<<< Updated upstream
# --- API URL Construction ---
if [[ "$PROVIDER" == "azure" ]]; then
    TASKS_URL="$API_BASE_URL/${PROVIDER}/key_vault/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/"
else
    TASKS_URL="$API_BASE_URL/${PROVIDER}/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/"
=======
#TODO Need error handling when does not exist
PROJECT_PK=$(get_project_pk "$PROJECT_NAME")
INTEGRATION_PK=$(get_integration_pk "$PROVIDER" "$PROJECT_PK")

if [[ -n "${ENVIRONMENT_NAME:-}" ]]; then
    ENVIRONMENT_PK=$(get_environment_pk "$ENVIRONMENT_NAME")
else
    ENVIRONMENT_PK=""
fi

ACTION_PK=$(get_action_pk "$PROVIDER" "$INTEGRATION_PK" "$INTEGRATION_TYPE_NORMALIZED" "$ACTION_NAME")

if [[ -n "$ENVIRONMENT_NAME" ]]; then
    validate_environment_tag_for_action "$ENVIRONMENT_PK" "$ACTION_PK" "$ENVIRONMENT_NAME"
fi

# --- API URL Construction ---
if [[ "$PROVIDER" == "azure" ]]; then
    TASKS_URL="$API_BASE_INTEGRATIONS_URL/${PROVIDER}/key_vault/${INTEGRATION_PK}/${INTEGRATION_TYPE_NORMALIZED}/${ACTION_PK}/tasks/"
else
    TASKS_URL="$API_BASE_INTEGRATIONS_URL/${PROVIDER}/${INTEGRATION_PK}/${INTEGRATION_TYPE_NORMALIZED}/${ACTION_PK}/tasks/"
>>>>>>> Stashed changes
fi

# --- Get Latest Task ---
response=$(curl -sS -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" "$TASKS_URL" 2> >(tee -a "$LOG_FILE" >&2))
curl_exit=$?
if [[ $curl_exit -ne 0 ]]; then
    log "TASK" "curl failed for $TASKS_URL (exit code $curl_exit)"
    error "Failed to fetch tasks."
fi
task_id=$(echo "$response" | jq -r '.results[0].id // empty')
task_state=$(echo "$response" | jq -r '.results[0].state // empty')
log "TASK" "Initial task fetch: id=$task_id, state=$task_state"

[[ -n "$task_id" && -n "$task_state" ]] || {
    log "TASK" "No tasks found. Response: $response"
    error "No tasks found for the given action."
}

echo "Monitoring task $task_id (initial state: $task_state)..."

# --- Poll for Task Completion ---
elapsed=0
while [[ "$task_state" == "queued" || "$task_state" == "running" ]]; do
    if ((elapsed >= TIMEOUT)); then
        log "TASK" "Timeout reached. Last response details:"
        error "Timeout reached while waiting for task to complete."
    fi
    sleep "$POLL_INTERVAL"
    ((elapsed += POLL_INTERVAL))

    if [[ "$PROVIDER" == "azure" ]]; then
<<<<<<< Updated upstream
        task_url="$API_BASE_URL/${PROVIDER}/key_vault/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/${task_id}/"
    else
        task_url="$API_BASE_URL/${PROVIDER}/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/${task_id}/"
=======
        task_url="$API_BASE_INTEGRATIONS_URL/${PROVIDER}/key_vault/${INTEGRATION_PK}/${INTEGRATION_TYPE_NORMALIZED}/${ACTION_PK}/tasks/${task_id}/"
    else
        task_url="$API_BASE_INTEGRATIONS_URL/${PROVIDER}/${INTEGRATION_PK}/${INTEGRATION_TYPE_NORMALIZED}/${ACTION_PK}/tasks/${task_id}/"
>>>>>>> Stashed changes
    fi

    response=$(curl -sS -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" "$task_url" 2> >(tee -a "$LOG_FILE" >&2))
    curl_exit=$?
    if [[ $curl_exit -ne 0 ]]; then
        log "TASK" "curl failed for $task_url (exit code $curl_exit)"
        error "Failed to fetch task status."
    fi
    task_state=$(echo "$response" | jq -r '.state // empty')
    echo "Task state: $task_state (elapsed: ${elapsed}s)"
done

# --- Check Final State ---
final_exit=0
if [[ "$task_state" == "failure" ]]; then
    echo "Task $task_id failed."
    log "TASK" "Task $task_id failed. Details:"
    log_task_details "$response"
    final_exit=1
elif [[ "$task_state" != "success" ]]; then
    echo "Task $task_id ended in unexpected state: $task_state"
    log "TASK" "Task $task_id ended in unexpected state: $task_state. Details:"
    log_task_details "$response"
    final_exit=1
fi

# --- Check Task Steps ---
if [[ "$PROVIDER" == "azure" ]]; then
<<<<<<< Updated upstream
    steps_url="$API_BASE_URL/${PROVIDER}/key_vault/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/${task_id}/steps/"
else
    steps_url="$API_BASE_URL/${PROVIDER}/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/${task_id}/steps/"
=======
    steps_url="$API_BASE_INTEGRATIONS_URL/${PROVIDER}/key_vault/${INTEGRATION_PK}/${INTEGRATION_TYPE_NORMALIZED}/${ACTION_PK}/tasks/${task_id}/steps/"
else
    steps_url="$API_BASE_INTEGRATIONS_URL/${PROVIDER}/${INTEGRATION_PK}/${INTEGRATION_TYPE_NORMALIZED}/${ACTION_PK}/tasks/${task_id}/steps/"
>>>>>>> Stashed changes
fi

response=$(curl -sS -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" "$steps_url" 2> >(tee -a "$LOG_FILE" >&2))
curl_exit=$?
if [[ $curl_exit -ne 0 ]]; then
    log "STEP" "curl failed for $steps_url (exit code $curl_exit)"
    error "Failed to fetch task steps."
fi

failed_steps=$(echo "$response" | jq -c '.results[] | select(.success==false)')
if [[ -n "$failed_steps" ]]; then
    echo "Some steps failed. Step IDs:"
    echo "$failed_steps" | jq -r '.id'
    log "STEP" "Failed steps details:"
    log_step_details "$response"
    final_exit=1
fi

if [[ $final_exit -eq 0 ]]; then
    echo "Task $task_id completed successfully and all steps succeeded."
    log "TASK" "Task $task_id completed successfully and all steps succeeded."
fi

exit $final_exit
