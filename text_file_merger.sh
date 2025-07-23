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



    # Step 2: Write files to output, splitting if needed to stay under char limit

    local CHAR_LIMIT=750000
    local part=1
    local char_count=0
    local base_output="${output%.md}"
    local current_output="${base_output}_part${part}.md"
    : > "$current_output"

    echo "Writing merged files to: ${base_output}_partN.md (limit: $CHAR_LIMIT chars per file)"



    # POSIX-compatible: gather sorted list of files into an array
    files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$search_dir" -type f -name '*.md' -print0 | sort -z)

    for file in "${files[@]}"; do
        relpath=$(realpath --relative-to="$search_dir" "$file" 2>/dev/null || python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$file" "$search_dir")
        if [[ -z "$relpath" || "$relpath" == "." ]]; then
            relpath="$(basename -- "$file")"
        fi
        heading="# $relpath"
        heading_chars=$(printf '%s' "$heading" | wc -m)
        file_chars=$(wc -m < "$file")
        total_chars=$((heading_chars + 1 + file_chars + 1))

        if (( char_count + total_chars > CHAR_LIMIT )); then
            part=$((part + 1))
            current_output="${base_output}_part${part}.md"
            : > "$current_output"
            char_count=0
        fi

        {
            printf '%s\n' "$heading"
            cat -- "$file"
            printf '\n'
        } >> "$current_output"
        char_count=$((char_count + total_chars))
    done

    echo "Done. Created $part output file(s):"
    for ((i=1; i<=part; i++)); do
        echo "  ${base_output}_part${i}.md"
    done

    if [[ -n "$tmpdir" ]]; then
        rm -rf "$tmpdir"
    fi
}

main "$@"
