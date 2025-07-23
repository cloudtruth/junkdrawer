#!/bin/bash

set -e

# Usage function
usage() {
    echo "Usage: $0 [options] <zip_or_folder_path>"
    echo
    echo "Merges all markdown (.md) files in a folder or zip archive into a single file."
    echo "The top heading for each file will be its relative path within the archive/folder,"
    echo "excluding the root directory. Only plain text files (like markdown) are supported."
    echo "This script will not work on binary, immutable, or proprietary formats (e.g., PDF, Word)."
    echo
    echo "This tool is called: text_file_merger.sh"
    echo
    echo "Options:"
    echo "  -o, --output FILE   Specify output file location (default: $HOME/merged_files.md)"
    echo "  -h, --help          Show this help message and exit."
}

check_prereqs() {
    local required_cmds=(find cat sort mktemp)
    if [[ "$1" == *.zip ]]; then
        required_cmds+=(unzip)
    fi
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found. Please install it and try again." >&2
            exit 1
        fi
    done
}

main() {
    local output="$HOME/merged_files.md"
    local input=""

    # Parse command-line options and arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -o|--output)
                if [[ -n "$2" ]]; then
                    output="$2"
                    shift 2
                else
                    echo "Error: --output requires a file argument." >&2
                    usage
                    exit 1
                fi
                ;;
            --)
                shift
                break
                ;;
            -* )
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
            * )
                input="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$input" ]]; then
        usage
        exit 1
    fi

    # Check for required commands
    check_prereqs "$input"

    local tmpdir=""
    local search_dir

    # If input is a zip file, extract to a temp dir; otherwise use as folder
    if [[ "$input" == *.zip ]]; then
        tmpdir=$(mktemp -d)
        unzip -q "$input" -d "$tmpdir"
        search_dir="$tmpdir"
    else
        search_dir="$input"
    fi

    # Ensure output directory exists or prompt to create if missing
    local outdir
    outdir=$(dirname -- "$output")
    if [[ ! -d "$outdir" ]]; then
        if [ -t 1 ]; then
            read -r -p "Output directory '$outdir' does not exist. Create it? [y/N] " mkoutdir
            case "$mkoutdir" in
                [yY][eE][sS]|[yY])
                    mkdir -p -- "$outdir" || { echo "Failed to create directory '$outdir'" >&2; exit 1; }
                    ;;
                *)
                    echo "Aborted. Output directory not created." >&2
                    exit 1
                    ;;
            esac
        else
            echo "Error: Output directory '$outdir' does not exist." >&2
            exit 1
        fi
    fi

    # Prompt before overwriting output file if it already exists
    if [[ -e "$output" ]]; then
        if [ -t 1 ]; then
            read -r -p "Warning: '$output' already exists. Overwrite? [y/N] " confirm
            case "$confirm" in
                [yY][eE][sS]|[yY])
                    # Truncate the file before writing
                    : > "$output"
                    ;;
                *)
                    echo "Aborted. Output file not overwritten."
                    exit 1
                    ;;
            esac
        else
            echo "Warning: '$output' already exists and will be overwritten."
            : > "$output"
        fi
    fi

    # Function to write a single markdown file to the output file, with relative path (excluding root dir) or just filename if root
    write_md() {
        local file="$1"
        local relpath
        # Remove the root directory from the path for the heading
        relpath=$(realpath --relative-to="$search_dir" "$file" 2>/dev/null || python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$file" "$search_dir")
        # If relpath is empty or ".", fallback to basename
        if [[ -z "$relpath" || "$relpath" == "." ]]; then
            relpath="$(basename "$file")"
        fi
        heading="# $relpath"
        {
            echo "$heading"
            cat "$file"
            echo
        } >> "$output"
    }

    # Find and process all .md files robustly (handles spaces/newlines)
    find "$search_dir" -type f -name '*.md' -print0 | sort -z | while IFS= read -r -d '' file; do
        write_md "$file"
    done

    if [[ -n "$tmpdir" ]]; then
        rm -rf "$tmpdir"
    fi

    echo "Merged markdown files into $output"
}

main "$@"
