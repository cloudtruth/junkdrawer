#!/bin/bash

# --- Usage Function ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <project> <environment> <parameter> <desired-value> [original-value]

Polls a CloudTruth parameter's value in a specific project/environment until it matches the desired value.

Options:
  -h, --help            Show this help message and exit
  -n, --dry-run         Show actions without making changes (no effect, read-only)
  -o, --output <dir>    Specify output directory (default: $HOME)
  --profile <profile>   Use a specific profile from config

Arguments:
  <project>         CloudTruth project name
  <environment>     CloudTruth environment name
  <parameter>       CloudTruth parameter name
  <desired-value>   The value to wait for
  [original-value]  Optional. The value to start from (for info only)

Example:
  $(basename "$0") myproject default myparam newval oldval
EOF
    exit 0
}

# --- Argument Parsing ---
DRY_RUN="false"
OUTPUT_DIR="$HOME"
PROFILE="default"

while (($# > 0)); do
    case "$1" in
        -h|--help)
            usage
            ;;
        -n|--dry-run)
            DRY_RUN="true"
            shift
            ;;
        -o|--output)
            if [ -n "$2" ]; then
                OUTPUT_DIR="$2"
                shift 2
            else
                echo "🚨 Error: Option $1 requires an argument." >&2
                exit 1
            fi
            ;;
        --profile)
            if [ -n "$2" ]; then
                PROFILE="$2"
                shift 2
            else
                echo "🚨 Error: Option $1 requires an argument." >&2
                exit 1
            fi
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "🚨 Error: Unknown option: $1" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# --- Positional Arguments ---
if [ "$#" -lt 4 ]; then
    echo "🚨 Error: Missing required arguments." >&2
    usage
fi
PROJECT="$1"
ENVIRONMENT="$2"
PARAMETER="$3"
DESIRED_VALUE="$4"
ORIGINAL_VALUE="${5:-}"

# --- Dependency Checks ---
for dep in curl jq yq; do
    if ! command -v "$dep" &>/dev/null; then
        echo "🚨 Error: Required dependency '$dep' is not installed." >&2
        exit 1
    fi
done

# --- Config File Detection ---
CONFIG_FILE=""
OS="$(uname -s)"
case "$OS" in
    Linux)
        CONFIG_LOCATIONS=("$XDG_CONFIG_HOME/cloudtruth/cli.yml" "$HOME/.config/cloudtruth/cli.yml")
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

# --- API Key Handling ---
API_KEY=""
BASE_URL=""
if [ -n "$CONFIG_FILE" ]; then
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

# --- API Request Function ---
get_parameter_value() {
    local project="$1"
    local environment="$2"
    local parameter="$3"
    local url="${BASE_URL}/projects/?name=${project}"
    local project_pk
    project_pk=$(curl -sS -H "Authorization: Api-Key $API_KEY" "$url" | jq -r '.results[0].id // empty')
    if [ -z "$project_pk" ]; then
        echo "🚨 Error: Project '$project' not found." >&2
        exit 1
    fi
    local env_url="${BASE_URL}/environments/?name=${environment}"
    local env_pk
    env_pk=$(curl -sS -H "Authorization: Api-Key $API_KEY" "$env_url" | jq -r '.results[0].id // empty')
    if [ -z "$env_pk" ]; then
        echo "🚨 Error: Environment '$environment' not found." >&2
        exit 1
    fi
    local param_url="${BASE_URL}/projects/${project_pk}/parameters/?name=${parameter}"
    local param_pk
    param_pk=$(curl -sS -H "Authorization: Api-Key $API_KEY" "$param_url" | jq -r '.results[0].id // empty')
    if [ -z "$param_pk" ]; then
        echo "🚨 Error: Parameter '$parameter' not found in project '$project'." >&2
        exit 1
    fi
    local value_url="${BASE_URL}/projects/${project_pk}/parameters/${param_pk}/values/?environment=${env_pk}"
    curl -sS -H "Authorization: Api-Key $API_KEY" "$value_url" | jq -r '.results[0].value // empty'
}

# --- Polling Logic ---
START_TIME=$(date +%s)
INTERVAL=15
MAX_INTERVAL=600   # 10 minutes
BACKOFF_1=60       # After 1 minute, start backing off
BACKOFF_2=1200     # After 20 minutes, back off to 10 min
MAX_WAIT=3600      # 60 minutes

echo "Polling CloudTruth for parameter '$PARAMETER' in project '$PROJECT', environment '$ENVIRONMENT'..."
if [ -n "$ORIGINAL_VALUE" ]; then
    echo "Original value: $ORIGINAL_VALUE"
fi
echo "Desired value: $DESIRED_VALUE"
echo "Initial polling interval: ${INTERVAL}s (requests will back off over time)"

trap 'echo "Polling cancelled by user."; exit 0' SIGINT SIGTERM

elapsed=0
last_interval=$INTERVAL
first_check=true

while true; do
    VALUE=$(get_parameter_value "$PROJECT" "$ENVIRONMENT" "$PARAMETER")
    NOW=$(date +%s)
    elapsed=$((NOW - START_TIME))

    if [ "$VALUE" = "$DESIRED_VALUE" ]; then
        if [ "$first_check" = true ]; then
            echo -e "\n✅ Value is already the expected value: '$VALUE'."
        else
            echo -e "\n✅ Desired value detected: '$VALUE' matches expected value."
        fi
        if [ "$elapsed" -ge 60 ]; then
            echo "Elapsed time: $((elapsed/60)) minutes."
        else
            echo "Elapsed time: $elapsed seconds"
        fi
        exit 0
    fi

    # Warn and exit if value changes and isn't the expected value
    if [ -n "$ORIGINAL_VALUE" ] && [ "$VALUE" != "$ORIGINAL_VALUE" ] && [ "$VALUE" != "$DESIRED_VALUE" ]; then
        echo -e "\n🚨 Warning: Value changed to '$VALUE', which does NOT match the desired value ('$DESIRED_VALUE') or the original value ('$ORIGINAL_VALUE')."
        echo "Recheck the parameter configuration. Someone else may have made a change or the inputs may not be correct."
        if [ "$elapsed" -ge 60 ]; then
            echo "Elapsed time: $((elapsed/60)) minutes."
        else
            echo "Elapsed time: $elapsed seconds"
        fi
        echo "Exiting. Please investigate unexpected value change."
        exit 3
    fi

    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        echo -e "\n🚨 Timeout: Value did not change to '$DESIRED_VALUE' after $((MAX_WAIT/60)) minutes."
        if [ "$elapsed" -ge 60 ]; then
            echo "Elapsed time: $((elapsed/60)) minutes."
        else
            echo "Elapsed time: $elapsed seconds"
        fi
        echo "Please contact CloudTruth support for assistance."
        exit 2
    fi

    # Polling interval backoff logic
    if [ "$elapsed" -ge "$BACKOFF_2" ]; then
        INTERVAL="$MAX_INTERVAL"
    elif [ "$elapsed" -ge "$BACKOFF_1" ]; then
        INTERVAL=$((last_interval * 2))
        if [ "$INTERVAL" -gt "$MAX_INTERVAL" ]; then
            INTERVAL="$MAX_INTERVAL"
        fi
    fi

    # Print interval change message if interval has changed
    if [ "$INTERVAL" -ne "$last_interval" ]; then
        echo -e "\nPolling interval changed to ${INTERVAL}s (elapsed: ${elapsed}s)."
        last_interval=$INTERVAL
    fi

    # Overwrite the previous line for "still running" status
    if [ "$INTERVAL" -ge 60 ]; then
        next_check_msg="Next check in $((INTERVAL/60)) minute(s)..."
    else
        next_check_msg="Next check in ${INTERVAL}s..."
    fi
    echo -ne "Still running... Current value: '$VALUE' (expected: '$DESIRED_VALUE') (elapsed: ${elapsed}s). $next_check_msg\r"

    first_check=false
    sleep "$INTERVAL"
done
