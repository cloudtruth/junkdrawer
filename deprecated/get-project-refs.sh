#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

NO_EVALUATED_MSG="No evaluated parameters found in project"

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--profile <profile>] --project_ref <search string>

Uses the CloudTruth CLI to iterate through all projects to find
and list any parameters matching the given search string.

Available options:

-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--profile       The profile for the CloudTruth CLI (optional, assumes the 'default' profile if not used)
--project_ref   The project reference to match in any interpolated parameters (required)
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  echo -e "\nExiting..."
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

# make sure CloudTruth CLI is installed
if ! cloudtruth -V &> /dev/null; then
    die "CloudTruth CLI is not installed: https://docs.cloudtruth.com/configuration-management/cli-and-api/cloudtruth-cli"
fi

parse_params() {
  # default values of variables 
  project_ref=''
  profile='default'

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --project_ref)
      project_ref="${2-}"
      shift
      ;;
    --profile)
      profile="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required 
  [[ -z "${project_ref-}" ]] && die "Missing required parameter: project"

  return 0
}

parse_params "$@"
setup_colors

# script logic
IFS=$'\n' read -r -d '' -a projectsArr \
  < <(cloudtruth --profile "${profile}" projects list \
  && printf '\0')

declare -a parametersArr
declare -a matchingParamArr

msg "${GREEN}Reading parameters...${NOFORMAT}"

if ((! ${#projectsArr[@]})); then
  die "No projects found!"
fi

for project in "${projectsArr[@]}"; do
  if [[ $project == "$project_ref"  ]]; then
      continue
  fi
  
  IFS=$'\n' read -r -d '' -a parametersArr \
    < <(cloudtruth --profile "${profile}" --project "$project" parameters list --values --evaluated --secrets \
    && printf '\0')

  if ((! ${#parametersArr[@]})); then
    continue
  fi

  if [[ ! "${parametersArr[0]}" =~ $NO_EVALUATED_MSG ]]; then
    for parameter in "${parametersArr[@]}"; do
      if [[ $parameter =~ $project_ref ]]; then
        matchingParamArr+=("${parameter}""$project")
      fi
    done
  fi
done

## TODO: templates

if ((! ${#matchingParamArr[@]})); then
  msg "${YELLOW}No Matches found for '${project_ref}'... ${NOFORMAT}"
  exit 0
fi

## TODO: Need to format output somewhat
# | Name                        | Value       | Raw
# | reference-from-common-stuff | foo-default | {{cloudtruth.projects["Common Stuff"].parameters.["dynamically-inherit-to-all-envs"]}}
msg "${GREEN}Matches found for '${project_ref}': ${NOFORMAT}"
for match in "${matchingParamArr[@]}"; do
  msg "${match}"
done

exit 0