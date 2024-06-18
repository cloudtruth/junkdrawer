#!/bin/bash

ROOT_NAME="project-count-limits"
MAX_DEPTH=5
CHILDREN_PER_TIER=4

# Main script
main() {
    local config_profile="$1"
    local ct_type="$2"
    local root="$ROOT_NAME"
    local max_depth="$MAX_DEPTH"
    local num_children="$CHILDREN_PER_TIER"

    echo "Creating root: $root"
    cloudtruth --profile "$config_profile" "$ct_type" set "$root"

    declare -a current_depth_array
    declare -a next_depth_array
    current_depth_array=("$root")

    for (( depth = 1; depth <= max_depth; depth++ )); do
        next_depth_array=()

        for current_item in "${current_depth_array[@]}"; do
            for (( i = 1; i <= num_children; i++ )); do
                local item="${current_item}_child${i}"
                cloudtruth --profile "$config_profile" "$ct_type" set -p "$current_item" "$item"
                next_depth_array+=("$item")
            done
            echo "Created/Updated $(( num_children )) items"
        done

        current_depth_array=("${next_depth_array[@]}")
        echo "Created/Updated $(( ${#current_depth_array[@]} )) items at depth $depth"
    done

    echo "Created/Updated $(( num_children^max_depth )) items total"
}

# Run the main script
## $1 = config_profile
## $2 = ct_type (projects or environments)
main "$@"
