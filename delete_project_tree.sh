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

# --- Configuration ---
SERVER_URL="${CLOUDTRUTH_SERVER_URL:-https://api.cloudtruth.io}"
WAIT_SECONDS=5

# Declare global associative arrays for project data.
declare -A project_ids project_names project_parents project_children

# --- Functions ---

# Print usage information and exit.
usage() {
    echo "Usage: $0 [--dry-run] <PARTIAL_PROJECT_NAME>" >&2
    echo "  --dry-run: Show what would be deleted without actually deleting." >&2
    echo "  Example: $0 --dry-run project-count-limits" >&2
    exit 1
}

# Helper for making authenticated API GET requests.
# Exits on non-200 status codes.
api_get() {
    local url="$1"
    curl -s -f -X GET \
        -H "Authorization: Api-Key ${CLOUDTRUTH_API_KEY}" \
        -H "Content-Type: application/json" \
        "$url"
}

# Helper for making authenticated API DELETE requests.
api_delete() {
    local url="$1"
    # We don't want to see the progress meter, but we do want errors.
    # -f makes curl fail silently on HTTP errors, which we check via the exit code.
    curl -s -f -X DELETE \
        -H "Authorization: Api-Key ${CLOUDTRUTH_API_KEY}" \
        -H "Content-Type: application/json" \
        "$url"
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
        # Capture response and handle potential empty result from curl -f on error.
        # The `|| true` prevents `set -e` from exiting the script on a curl failure,
        # allowing our custom error handling to take over.
        response=$(api_get "$next_url" || true)
        if [[ -z "$response" ]]; then
            echo " error!" >&2
            echo "Error: API call to ${next_url} failed or returned an empty response. Please check your CLOUDTRUTH_API_KEY, CLOUDTRUTH_SERVER_URL, and network connection." >&2
            exit 1
        fi
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

    # Use a while-read loop to safely handle names with spaces or other special characters.
    while IFS= read -r child; do
        # The check for -n ensures we don't process empty lines.
        [[ -n "$child" ]] && echo "$child" && get_all_descendants "$child"
    done <<<"$children_string"
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

# Encapsulates the logic to fetch, map, find, and sort all projects for deletion.
# It populates the global `project_ids` map (as a side-effect) for use in the
# deletion loop and populates the `sorted_projects_for_deletion` global array
# with the final, sorted list of projects.
prepare_deletion_list() {
    local partial_name="$1"

    # Fetch all projects and build dependency maps
    local all_projects_json
    all_projects_json=$(get_all_projects_json)

    local total_projects_found
    total_projects_found=$(echo "$all_projects_json" | jq 'length')
    if [[ "$total_projects_found" -eq 0 ]]; then
        echo "API query successful, but found 0 projects for this API key." >&2
        echo "Please verify that the CLOUDTRUTH_API_KEY has access to the correct organization." >&2
        return # Return with no output
    fi
    echo "Found a total of $total_projects_found projects. Building dependency map..." >&2

    # Pass 1: Build basic ID <-> Name maps for all projects.
    while IFS=$'\t' read -r id name; do
        project_ids["$name"]="$id"
        project_names["$id"]="$name"
    done < <(echo "$all_projects_json" | jq -r '.[] | "\(.id)\t\(.name)"' | tr -d '\r')

    # Pass 2: Build parent -> child relationship maps now that all names are known.
    while IFS=$'\t' read -r name parent_id; do
        if [[ -n "$parent_id" && "$parent_id" != "null" && ${project_names[$parent_id]+_} ]]; then
            local parent_name="${project_names[$parent_id]}"
            project_parents["$name"]="$parent_name"
            # Use a newline delimiter for robustness; handles names with spaces.
            project_children["$parent_name"]+="${name}"$'\n'
        fi
    done < <(echo "$all_projects_json" | jq -r '.[] | "\(.name)\t\(if .depends_on then (.depends_on | split("/")[-2]) else "null" end)"' | tr -d '\r')

    # Find all projects to delete
    echo "Finding projects to delete..." >&2
    local -A projects_to_delete

    # 1. Identify the "highest-level" projects that match the search term.
    local -a root_projects_for_deletion
    for proj_name in "${!project_ids[@]}"; do
        if [[ "$proj_name" == *"$partial_name"* ]]; then
            local parent_name="${project_parents[$proj_name]:-}"
            if [[ -z "$parent_name" || "$parent_name" != *"$partial_name"* ]]; then
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

    # Prepare and sort the final list
    local -a unsorted_list
    for proj in "${!projects_to_delete[@]}"; do
        unsorted_list+=("$(get_depth "$proj")|${proj}")
    done

    # Sort the list and populate the global `sorted_projects_for_deletion` array.
    # Using mapfile is safer than word-splitting the output of sort.
    mapfile -t sorted_projects_for_deletion < <(printf "%s\n" "${unsorted_list[@]}" | sort -t'|' -k1,1nr -k2,2)
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

# Robust argument parsing loop allows options in any order.
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    --dry-run)
        DRY_RUN=true
        shift # past argument
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

# Call the main logic function and capture its output into an array.
declare -a sorted_projects_for_deletion
# This function is called directly to populate the global arrays, including `sorted_projects_for_deletion`.
prepare_deletion_list "$PARTIAL_PROJECT_NAME"

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
        echo -n "Deleting project: '$project_name' (ID: $project_id)... "
        if api_delete "${SERVER_URL}/api/v1/projects/${project_id}/"; then
            echo "Success."
            deleted_count=$((deleted_count + 1))
        else
            echo "ERROR: Failed to delete project '$project_name'. Halting script." >&2
            echo "  $deleted_count projects were deleted before this failure." >&2
            exit 1
        fi

        if [[ $deleted_count -lt $count ]]; then
            echo "Waiting for $WAIT_SECONDS seconds..."
            sleep "$WAIT_SECONDS"
        fi
    done
    echo "All $count projects have been deleted."
fi

exit 0
