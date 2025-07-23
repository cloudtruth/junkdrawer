# text_file_merger.sh

A Bash script to merge all markdown (.md) files from a folder or zip archive into one or more plain text files, with each output file kept under a configurable character limit. This is useful for preparing large document sets for import into tools with file size or character count restrictions (e.g., Google Docs).

## Features

- Recursively finds all `.md` files in a directory or extracted zip archive.
- Merges files in sorted order, preserving the integrity of each file (no file is split across outputs).
- Adds a top-level heading to each merged file, showing its relative path within the archive/folder.
- Splits output into multiple files if the character limit is exceeded (default: 750,000 characters per file).
- Skips binary, immutable, or proprietary formats (e.g., PDF, Word).
- Compatible with macOS and Linux (no Bash 4+ features required; no Python dependency; pure Bash fallback for relative paths).

## Usage

```sh
./text_file_merger.sh [options] <zip_or_folder_path>
```

### Options

- `-o, --output FILE`   Specify output file location (default: `$HOME/merged_files.md`). Output files will be named with a `_partN.md` suffix if splitting is required.
- `-h, --help`          Show help message and exit.

### Example

```sh
./text_file_merger.sh -o ~/Desktop/my_merged.md ~/Downloads/my_archive.zip
```

This will extract all markdown files from `my_archive.zip`, merge them, and write the output to `~/Desktop/my_merged_part1.md`, `my_merged_part2.md`, etc., as needed.

## Output File Structure

- Each merged file starts with a heading (e.g., `# docs/README.md`) indicating the original file's relative path.
- The content of each markdown file follows its heading.
- No file is split between output files; each output file contains only whole markdown files.

## Character Limit

- The default character limit per output file is 750,000 (adjustable in the script via the `CHAR_LIMIT` variable).
- This is set to stay well below Google Docs' 1,020,000 character limit and 50MB file size limit.

## Requirements

- Bash (macOS or Linux)
- Standard Unix tools: `find`, `cat`, `sort`, `mktemp`, `unzip` (if processing zip files), `realpath` (if available; otherwise, a pure Bash fallback is used for relative paths)

## Limitations

- Only processes plain text `.md` files. Binary or proprietary formats are ignored.
- Output files are always written as UTF-8 plain text.
- The script does not preserve file metadata (e.g., timestamps, permissions).

## License

MIT or similar open source license.

---

For questions or improvements, please open an issue or submit a pull request.
