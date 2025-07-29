#!/usr/bin/env bash

# Monitor the status of a CloudTruth integration action task until it completes.
# Usage: monitor_task.sh PROVIDER INTEGRATION_TYPE INTEGRATION_PK ACTION_PK

set -euo pipefail

# --- Configuration ---
API_BASE_URL="https://api.cloudtruth.io/api/v1/integrations"
POLL_INTERVAL=10      # seconds between polls
TIMEOUT=600           # total seconds before giving up

# --- Helper Functions ---
error() { echo "ERROR: $*" >&2; exit 1; }

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
response=$(curl -sSf -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" "$TASKS_URL") || error "Failed to fetch tasks."
task_id=$(echo "$response" | jq -r '.results[0].id // empty')
task_state=$(echo "$response" | jq -r '.results[0].state // empty')

[[ -n "$task_id" && -n "$task_state" ]] || error "No tasks found for the given action."

echo "Monitoring task $task_id (initial state: $task_state)..."

# --- Poll for Task Completion ---
elapsed=0
while [[ "$task_state" == "queued" || "$task_state" == "running" ]]; do
    if (( elapsed >= TIMEOUT )); then
        error "Timeout reached while waiting for task to complete."
    fi
    sleep "$POLL_INTERVAL"
    ((elapsed+=POLL_INTERVAL))
    task_url="$API_BASE_URL/${PROVIDER}/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/${task_id}/"
    response=$(curl -sSf -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" "$task_url") || error "Failed to fetch task status."
    task_state=$(echo "$response" | jq -r '.state // empty')
    echo "Task state: $task_state (elapsed: ${elapsed}s)"
done

# --- Check Final State ---
if [[ "$task_state" == "failure" ]]; then
    echo "Task $task_id failed."
    exit 1
elif [[ "$task_state" != "success" ]]; then
    echo "Task $task_id ended in unexpected state: $task_state"
    exit 1
fi

# --- Check Task Steps ---
steps_url="$API_BASE_URL/${PROVIDER}/${INTEGRATION_PK}/${ACTION_TYPE_PATH}/${ACTION_PK}/tasks/${task_id}/steps/"
response=$(curl -sSf -H "Authorization: Api-Key $CLOUDTRUTH_API_KEY" "$steps_url") || error "Failed to fetch task steps."

failed_steps=$(echo "$response" | jq -c '.results[] | select(.success==false)')
if [[ -n "$failed_steps" ]]; then
    echo "Some steps failed:"
    echo "$failed_steps" | jq .
    exit 1
fi

echo "Task $task_id completed successfully and all steps succeeded."
exit 0
