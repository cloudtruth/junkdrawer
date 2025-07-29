#!/usr/bin/env bash

# Monitor the status of a CloudTruth integration action task until it completes.
# Usage: monitor_task.sh PROVIDER INTEGRATION_TYPE INTEGRATION_PK ACTION_PK

set -euo pipefail

# --- Configuration ---
API_BASE_URL="https://api.cloudtruth.io/api/v1/integrations"
POLL_INTERVAL=10      # seconds between polls
TIMEOUT=600           # total seconds before giving up
LOG_FILE="${MONITOR_TASK_LOG:-/tmp/monitor_task.log}"

# --- Helper Functions ---
log() {
    # $1 = type (TASK or STEP), $2 = message
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1 $2" >> "$LOG_FILE"
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

# --- Prerequisite Checks ---
command -v curl >/dev/null 2>&1 || error "curl is required but not installed."
command -v jq >/dev/null 2>&1 || error "jq is required but not installed."
[[ -n "${CLOUDTRUTH_API_KEY:-}" ]] || error "CLOUDTRUTH_API_KEY environment variable is not set."

# --- Argument Parsing ---
if [[ $# -ne 4 ]]; then
    echo "Usage: $0 PROVIDER INTEGRATION_TYPE INTEGRATION_PK ACTION_PK"
    exit 2
fi

PROVIDER="$1"
INTEGRATION_TYPE="$2"
INTEGRATION_PK="$3"
ACTION_PK="$4"

# Normalize action type for API path
case "$INTEGRATION_TYPE" in
    push)   ACTION_TYPE_PATH="pushes" ;;
    pull)   ACTION_TYPE_PATH="pulls" ;;
    *)      ACTION_TYPE_PATH="$INTEGRATION_TYPE" ;;
esac

# --- API URL Construction ---
TASKS_URL="$API_BASE_URL/${PROVIDER}/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/"

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

[[ -n "$task_id" && -n "$task_state" ]] || { log "TASK" "No tasks found. Response: $response"; error "No tasks found for the given action."; }

echo "Monitoring task $task_id (initial state: $task_state)..."

# --- Poll for Task Completion ---
elapsed=0
while [[ "$task_state" == "queued" || "$task_state" == "running" ]]; do
    if (( elapsed >= TIMEOUT )); then
        log "TASK" "Timeout reached. Last response details:"
        error "Timeout reached while waiting for task to complete."
    fi
    sleep "$POLL_INTERVAL"
    ((elapsed+=POLL_INTERVAL))
    task_url="$API_BASE_URL/${PROVIDER}/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/${task_id}/"
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
steps_url="$API_BASE_URL/${PROVIDER}/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/${task_id}/steps/"
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
