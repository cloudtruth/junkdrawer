#!/usr/bin/env bash

# A script to find and delete a tree of CloudTruth projects.
#
# Deletes projects matching a partial name, and all of their children.
# Deletion happens from the deepest child up to the parent to respect
# dependencies.
#
# Usage:
#   ./delete_project_tree.sh [--dry-run] <PARTIAL_PROJECT_NAME>
#
# Requirements:
#   - bash 4+ (for associative arrays)
#   - curl
#   - jq
#   - CLOUDTRUTH_API_KEY environment variable must be set.
#   - CLOUDTRUTH_SERVER_URL is optional, defaults to https://api.cloudtruth.io

# --- Bash Version Check ---
# This script uses associative arrays (declare -A) which require bash 4.0+.
if [[ -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "Error: This script requires Bash version 4.0 or higher." >&2
    echo "You are using Bash version: $BASH_VERSION" >&2
    exit 1
fi

set -euo pipefail

# This variable will hold the path to the temp file if it's created.
TMP_FILE=""
# Ensure the temp file is cleaned up on script exit (success, error, or interrupt).
trap '[[ -n "$TMP_FILE" ]] && rm -f "$TMP_FILE"' EXIT

# Declare LOG_FILE globally, will be defined after arg parsing.
LOG_FILE=""

# --- Configuration ---
SERVER_URL="${CLOUDTRUTH_SERVER_URL:-https://api.cloudtruth.io}"
API_LAST_HTTP_CODE=0

# Declare global associative arrays for project data.
declare -A project_ids project_names project_parents project_children

# --- Functions ---

# Print usage information and exit.
usage() {
    echo "Usage: $0 [--dry-run] [--log-file <path>] <PARTIAL_PROJECT_NAME>" >&2
    echo "  --dry-run: Show what would be deleted without actually deleting." >&2
    echo "  --log-file: Specify a path for the deletion log file." >&2
    echo "              Defaults to \$HOME/project_deletion_<timestamp>.log" >&2
    echo "  Example: $0 --dry-run project-count-limits" >&2
    exit 1
}

# Helper for making authenticated API GET requests.
# Exits on non-200 status codes.
api_get() {
    local url="$1"
    local response
    local http_code
    local body

    API_LAST_HTTP_CODE=0

    response=$(curl -s -w "\n%{http_code}" -X GET \
        -H "Authorization: Api-Key ${CLOUDTRUTH_API_KEY}" \
        -H "Content-Type: application/json" \
        "$url")

    http_code=$(tail -n1 <<<"$response")
    body=$(sed '$d' <<<"$response")
    API_LAST_HTTP_CODE="$http_code"

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$body"
        return 0
    else
        # On failure, print the error to stderr and return the failure code.
        echo -e "\nAPI GET Error (HTTP ${http_code}) for URL ${url}:" >&2
        if command -v jq &>/dev/null && jq -e . >/dev/null 2>&1 <<<"$body"; then
            echo "$body" | jq . >&2
        else
            echo "$body" >&2
        fi
        return 1
    fi
}

# Helper for making authenticated API DELETE requests.
api_delete() {
    local url="$1"
    local response
    local http_code

    API_LAST_HTTP_CODE=0

    # Make the curl request, capturing the response body and appending the HTTP status code.
    response=$(curl -s -w "\n%{http_code}" -X DELETE \
        -H "Authorization: Api-Key ${CLOUDTRUTH_API_KEY}" \
        -H "Content-Type: application/json" \
        "$url")

    # Extract the HTTP status code from the response.
    http_code=$(tail -n1 <<<"$response")
    API_LAST_HTTP_CODE="$http_code"

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        return 0
    else
        # On failure, extract the response body (everything except the HTTP status code)).
        local body
        body=$(sed '$d' <<<"$response")
        echo -e "\nAPI DELETE Error (HTTP ${http_code}) for URL ${url}" >&2
        # Try to pretty-print if it's JSON, otherwise print as is.
        if command -v jq &>/dev/null && jq -e . >/dev/null 2>&1 <<<"$body"; then
            echo "$body" | jq . >&2
        else
            echo "$body" >&2
        fi
        return 1
    fi
}

# Fetches all projects from the API, handling pagination.
# Returns a single JSON array of all project objects.
get_all_projects_json() {
    local next_url="${SERVER_URL}/api/v1/projects/?page_size=100"
    local all_projects="[]"

    echo "Fetching all projects from CloudTruth..." >&2
    while [[ -n "$next_url" && "$next_url" != "null" ]]; do
        echo -n "." >&2
        local response
        # The api_get function now handles errors and prints details.
        # `set -e` will cause the script to exit if the call fails.
        response=$(api_get "$next_url")
        all_projects=$(jq -s '.[0] + .[1].results' <(echo "$all_projects") <(echo "$response"))
        next_url=$(echo "$response" | jq -r '.next')
    done
    echo " done." >&2
    echo "$all_projects"
}

# Recursively finds all descendant project names for a given project.
# Reads from the global `project_children` associative array.
# Echos each descendant name on a new line.
get_all_descendants() {
    local project_name="$1"
    local children_string="${project_children[$project_name]:-}"

    if [[ -z "$children_string" ]]; then
        return
    fi

    # Use a `for` loop with a modified IFS to iterate over the newline-separated
    # list of children. This is a robust way to handle the list and avoids
    # potential issues with nested `while read` loops.
    local old_ifs="$IFS"
    IFS=$'\n'
    # The expansion must be unquoted to allow word splitting by IFS.
    for child in $children_string; do
        [[ -n "$child" ]] && echo "$child" && get_all_descendants "$child"
    done
    IFS="$old_ifs"
}

# Calculates the depth of a project in the hierarchy (0 for root projects).
# Reads from the global `project_parents` associative array.
get_depth() {
    local project_name="$1"
    local depth=0
    local current_proj="$project_name"
    while [[ -n "${project_parents[$current_proj]:-}" ]]; do
        depth=$((depth + 1))
        current_proj="${project_parents[$current_proj]}"
    done
    echo "$depth"
}

# Polls the API to confirm a project has been fully deleted.
# If the project has a parent, it polls the parent until the child is no longer
# listed as a dependency. If it has no parent, it polls the project's own
# endpoint until it returns a 404.
#
# Usage: wait_for_deletion_confirmation <child_id> <child_name> [parent_id]
wait_for_deletion_confirmation() {
    local child_id="$1"
    local child_name="$2"
    local parent_id="${3:-}"
    local max_wait_seconds=60
    local poll_interval_seconds=2
    local elapsed_seconds=0

    if [[ -n "$parent_id" ]]; then
        # --- Poll parent's 'dependents' list ---
        local child_url="${SERVER_URL}/api/v1/projects/${child_id}/"
        echo -n "  Waiting for '$child_name' to be removed from parent's dependencies..." >&2

        while [[ $elapsed_seconds -lt $max_wait_seconds ]]; do
            local parent_response
            # Use api_get and check its exit code.
            if ! parent_response=$(api_get "${SERVER_URL}/api/v1/projects/${parent_id}/"); then
                # If the parent is gone (404), the dependency is implicitly gone too.
                echo " confirmed (parent disappeared)." >&2
                return 0
            fi

            # Check if the child URL is still in the dependents list.
            if ! echo "$parent_response" | jq -e --arg child_url "$child_url" '.dependents | any(. == $child_url)' >/dev/null; then
                echo " confirmed." >&2
                return 0
            fi

            echo -n "." >&2
            sleep "$poll_interval_seconds"
            elapsed_seconds=$((elapsed_seconds + poll_interval_seconds))
        done
    else
        # --- Poll for project to 404 (for root projects) ---
        echo -n "  Waiting for project '$child_name' to be fully deleted..." >&2
        while [[ $elapsed_seconds -lt $max_wait_seconds ]]; do
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Api-Key ${CLOUDTRUTH_API_KEY}" "${SERVER_URL}/api/v1/projects/${child_id}/")
            if [[ "$http_code" -eq 404 ]]; then
                echo " confirmed." >&2
                return 0 # Success, project is gone.
            fi
            echo -n "." >&2
            sleep "$poll_interval_seconds"
            elapsed_seconds=$((elapsed_seconds + poll_interval_seconds))
        done
    fi

    echo " timeout!" >&2
    echo "Warning: Timed out after ${max_wait_seconds}s waiting for deletion of '$child_name' to be confirmed. Subsequent deletions may fail." >&2
}

# Attempts to delete a project, with a specific retry mechanism for 409 Conflict errors.
# This handles eventual consistency issues on the backend.
#
# Usage: attempt_delete_with_retry <project_name> <project_id>
attempt_delete_with_retry() {
    local project_name="$1"
    local project_id="$2"
    local max_retries=5
    local retry_delay=3
    local project_url="${SERVER_URL}/api/v1/projects/${project_id}/"

    echo -n "Deleting project: '$project_name' (ID: $project_id)... "

    # Initial attempt
    if api_delete "$project_url"; then
        echo "Success."
        return 0
    fi

    # Initial attempt failed. Check if it's a retryable 409 error.
    if [[ "$API_LAST_HTTP_CODE" -ne 409 ]]; then
        # Not a 409, so it's a hard failure. Error was already printed by api_delete.
        return 1
    fi

    # It was a 409, so we begin retrying.
    for ((i = 1; i <= max_retries; i++)); do
        echo # Newline for readability
        echo -n "  Project is still locked by dependencies. Retrying in ${retry_delay}s (${i}/${max_retries})... "
        sleep "$retry_delay"
        if api_delete "$project_url"; then
            echo "Success."
            return 0
        fi
    done

    # If the loop finishes, all retries have failed.
    return 1
}

# Fetches all project data and populates the global dependency maps.
# This function modifies the following global associative arrays:
# - project_ids



# Fetches all project data and populates the global dependency maps.
# This function modifies the following global associative arrays:
# - project_ids
# - project_names
# - project_parents
# - project_children
build_dependency_maps() {
    local all_projects_json
    all_projects_json=$(get_all_projects_json)

    local total_projects_found
    total_projects_found=$(echo "$all_projects_json" | jq 'length')
    if [[ "$total_projects_found" -eq 0 ]]; then
        # The get_all_projects_json function handles API errors, so this means
        # the API key is valid but has access to an org with no projects.
        echo "API query successful, but found 0 projects for this API key." >&2
        echo "Please verify that the CLOUDTRUTH_API_KEY has access to the correct organization." >&2
        # Exit here because there's nothing more to do.
        exit 0
    fi
    echo "Found a total of $total_projects_found projects. Building dependency map..." >&2

    # Pass 1: Build basic ID <-> Name maps for all projects.
    while IFS=$'\t' read -r id name; do
        project_ids["$name"]="$id"
        project_names["$id"]="$name"
    done < <(echo "$all_projects_json" | jq -r '.[] | "\(.id)\t\(.name)"' | tr -d '\r')

    # Pass 2: Build parent -> child relationship maps now that all names are known.
    while IFS=$'\t' read -r name parent_id; do
        # Only proceed if we have a valid parent_id that exists in our name map.
        if [[ -n "$parent_id" && "$parent_id" != "null" && ${project_names[$parent_id]+_} ]]; then
            local parent_name="${project_names[$parent_id]}"
            project_parents["$name"]="$parent_name"
            project_children["$parent_name"]+="${name}"$'\n'
        fi
    done < <(echo "$all_projects_json" | jq -r '.[] | "\(.name)\t\(if .depends_on then (.depends_on | split("/")[-2]) else "null" end)"' | tr -d '\r')
}

# --- Main Script ---

# Check for dependencies
if ! command -v jq &>/dev/null; then
    echo "Error: jq is not installed. Please install it to continue." >&2
    exit 1
fi
if ! command -v curl &>/dev/null; then
    echo "Error: curl is not installed. Please install it to continue." >&2
    exit 1
fi
if [[ -z "${CLOUDTRUTH_API_KEY:-}" ]]; then
    echo "Error: CLOUDTRUTH_API_KEY environment variable is not set." >&2
    exit 1
fi

# Parse arguments
DRY_RUN=false
PARTIAL_PROJECT_NAME=""
LOG_FILE_PATH=""

# Robust argument parsing loop allows options in any order.
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    --dry-run)
        DRY_RUN=true
        shift # past argument
        ;;
    --log-file)
        if [[ -z "${2:-}" ]]; then
            echo "Error: --log-file option requires an argument." >&2
            usage
        fi
        LOG_FILE_PATH="$2"
        shift 2 # past argument and value
        ;;
    *) # Anything else is treated as the project name.
        if [[ -n "$PARTIAL_PROJECT_NAME" ]]; then
            echo "Error: Only one project name argument can be specified." >&2
            usage
        fi
        PARTIAL_PROJECT_NAME="$1"
        shift # past argument
        ;;
    esac
done

if [[ -z "$PARTIAL_PROJECT_NAME" ]]; then
    echo "Error: A partial project name must be provided." >&2
    usage
fi

# Set up the log file path.
if [[ -n "$LOG_FILE_PATH" ]]; then
    LOG_FILE="$LOG_FILE_PATH"
else
    # Default to the user's home directory with a timestamped name.
    LOG_FILE="${HOME}/project_deletion_$(date +%Y%m%d_%H%M%S).log"
fi

# Call the main logic function and capture its output into an array.
declare -a sorted_projects_for_deletion

# Build the dependency maps. This function populates the global project_* arrays.
build_dependency_maps

# --- Find and Sort Projects for Deletion ---

echo "Finding projects to delete..." >&2
declare -A projects_to_delete

# 1. Identify the "highest-level" projects that match the search term.
declare -a root_projects_for_deletion
for proj_name in "${!project_ids[@]}"; do
    if [[ "$proj_name" == *"$PARTIAL_PROJECT_NAME"* ]]; then
        parent_name="${project_parents[$proj_name]:-}"
        if [[ -z "$parent_name" || "$parent_name" != *"$PARTIAL_PROJECT_NAME"* ]]; then
            root_projects_for_deletion+=("$proj_name")
        fi
    fi
done

# 2. For each root, add it and all its descendants to the final deletion list.
for root_proj in "${root_projects_for_deletion[@]}"; do
    projects_to_delete["$root_proj"]=1
    while read -r descendant; do
        projects_to_delete["$descendant"]=1
    done < <(get_all_descendants "$root_proj")
done

# 3. Prepare and sort the final list
declare -a unsorted_list
for proj in "${!projects_to_delete[@]}"; do
    unsorted_list+=("$(get_depth "$proj")|${proj}")
done

# 4. Sort the list and populate the final `sorted_projects_for_deletion` array.
mapfile -t sorted_projects_for_deletion < <(printf "%s\n" "${unsorted_list[@]}" | sort -t'|' -k1,1nr -k2,2)


count=${#sorted_projects_for_deletion[@]}

if [[ $count -eq 0 ]]; then
    echo "No projects found matching '${PARTIAL_PROJECT_NAME}'."
    exit 0
fi

# If the list is large, save it to a temp file for review.
if [[ $count -gt 25 ]]; then
    TMP_FILE=$(mktemp /tmp/projects_to_delete.XXXXXX)
    echo "# List of projects to be deleted, sorted by depth (deepest first)." > "$TMP_FILE"
    for item in "${sorted_projects_for_deletion[@]}"; do
        # Format as: (Depth: D) project_name
        printf "(Depth: %s) %s\n" "${item%%|*}" "${item#*|}" >> "$TMP_FILE"
    done
fi

# --- Execution ---
echo
if [ "$DRY_RUN" = true ]; then
    echo "--- DRY RUN ---"
    echo "The following $count project(s) would be deleted (in order):"
    if [[ -n "$TMP_FILE" ]]; then
        echo "Total count is over 25. The full list of $count projects has been saved for review to:"
        echo "  $TMP_FILE"
    else
        for item in "${sorted_projects_for_deletion[@]}"; do
            printf "  (Depth: %s) %s\n" "${item%%|*}" "${item#*|}"
        done
    fi
    echo "-----------------"
else
    echo "!!! WARNING: This is a destructive action! !!!"
    echo "The following $count project(s) will be PERMANENTLY DELETED (in order):"
    if [[ -n "$TMP_FILE" ]]; then
        echo "Total count is over 25. Please review the full list of $count projects in the file below before proceeding:"
        echo "  $TMP_FILE"
    else
        for item in "${sorted_projects_for_deletion[@]}"; do
            printf "  (Depth: %s) %s\n" "${item%%|*}" "${item#*|}"
        done
    fi
    echo
    read -p "Are you sure you want to continue? Type 'yes' to proceed: " -r
    echo
    if [[ "$REPLY" != "yes" ]]; then
        echo "Aborted by user."
        exit 1
    fi

    echo "Proceeding with deletion..."
    deleted_count=0
    for item in "${sorted_projects_for_deletion[@]}"; do
        project_name="${item#*|}"
        project_id="${project_ids[$project_name]}"
        if attempt_delete_with_retry "$project_name" "$project_id"; then
            # Log the successful deletion with a timestamp for auditing.
            echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') DELETED: Name='$project_name', ID='$project_id'" >> "$LOG_FILE"
            deleted_count=$((deleted_count + 1))
        else
            echo "ERROR: Failed to delete project '$project_name' after multiple attempts. Halting script." >&2
            echo "  $deleted_count projects were deleted before this failure." >&2
            exit 1
        fi

        # Don't poll after the very last deletion.
        if [[ $deleted_count -lt $count ]]; then
            # Find the parent's ID to pass to the wait function.
            parent_name="${project_parents[$project_name]:-}"
            parent_id=""
            if [[ -n "$parent_name" ]]; then
                parent_id="${project_ids[$parent_name]}"
            fi
            wait_for_deletion_confirmation "$project_id" "$project_name" "$parent_id"
        fi
    done
    echo
    echo "All $count projects have been successfully deleted."
    echo "A log of all deleted projects has been saved to: $LOG_FILE"
fi

exit 0
