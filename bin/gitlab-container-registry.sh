#!/usr/bin/env bash

######################################################################
#                             GLOBALS                                #
######################################################################

CI_API_V4_URL=${CI_API_V4_URL:-"https://gitlab.com/api/v4"}
CI_PROJECT_ID=${CI_PROJECT_ID:-""}
CI_PROJECT_PATH=${CI_PROJECT_PATH:-""}
CI_JOB_TOKEN=${CI_JOB_TOKEN:-""}

GITLAB_TOKEN=${GITLAB_TOKEN:-""}

# gitlab api timeout in seconds
GITLAB_API_TIMEOUT=${GITLAB_API_TIMEOUT:-"10"}

######################################################################
#                            FUNCTIONS                               #
######################################################################

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

MYNAME=$(basename "$0")
_DEBUG=${_DEBUG:-"0"}
_VERBOSE=${_VERBOSE:-"0"}
_CLEANUP_ITEMS=()

######################################################################
# bash associative array to cache gwr => project id mapping
declare -A _PROJECT_IDS=()
# resolved project id by resolve_gitlab_project_id()
_RESOLVED_PROJECT_ID=""
######################################################################

set -o pipefail
set -e

cleanup_perform() {
  local item=""
  if [ "$DO_CLEANUP" != "1" ]; then
    [ ! -z "$_CLEANUP_ITEMS" ] && msg_warn "preserving execution evidence in:"
    for item in "${_CLEANUP_ITEMS[@]}"; do
      echo "  $item" 1>&2
    done
    return 0
  fi

  # do the real cleanup
  for item in "${_CLEANUP_ITEMS[@]}"; do
    rm -rf "$item" >/dev/null 2>&1
  done
}

cleanup_add() {
  local item=""
  for item in "$@"; do
    _CLEANUP_ITEMS+=("$item")
  done
}

my_exit() {
  local exit_code=$1
  cleanup_perform
  exit $exit_code
}

die() {
  echo "FATAL: $*" 1>&2
  my_exit 1
}

msg_info() {
  echo "[INFO]:  $*"
}

msg_warn() {
  echo "[WARN]:  $*" 1>&2
}

msg_verbose() {
  test "${_VERBOSE}" = "1" || return 0
  echo "[VERBOSE]: $*" 1>&2
}

msg_debug() {
  test "${_DEBUG}" = "1" || return 0
  echo "[DEBUG]: $*" 1>&2
}

require_utils() {
  local util=""
  for util in "$@"; do
    local bin=$(which "$util" 2>/dev/null)
    test -z "$bin" -o ! -x "$bin" && die "utility is not installed: $util"
  done

  return 0
}

require_gnu_utils() {
  local util=""
  for util in "$@"; do
    local bin=$(which "$util" 2>/dev/null)
    test -z "$bin" -o ! -x "$bin" && die "GNU version of utility is not installed: $util"
    "$bin" --version | grep -Eq "\(GNU |util-linux" || die "Not a GNU version of utility: $util"
  done

  return 0
}

gitlab_auth() {
  if [ ! -z "${CI_JOB_TOKEN}" ]; then
    echo "job-token: ${CI_JOB_TOKEN}"
  elif [ ! -z "${GITLAB_TOKEN}" ]; then
    echo "private-token: ${GITLAB_TOKEN}"
  fi
}

gitlab_call() {
  local endpoint="$1"
  shift

  local url="${CI_API_V4_URL}${endpoint}"

  local auth_header_value=$(gitlab_auth)
  test -z "$auth_header_value" && die "can't determine gitlab auth header; specify either GITLAB_TOKEN or CI_JOB_TOKEN"

  # check if args contain -mXX otherwise apply default timeout
  local timeout_arg=""
  echo "$@" | grep -Eq -- "\-m[0-9]+" || timeout_arg="-m${GITLAB_API_TIMEOUT}"

  # this would be much easier if we could use --fail-with-body option
  # but it's not available in curl versions < 7.76.0, sigh
  #
  # SEE: https://daniel.haxx.se/blog/2021/02/11/curl-fail-with-body/
  #
  #  curl -Ls ${timeout_arg} --compressed \
  #    --fail-with-body \
  #    -H "$auth_header_value" \
  #    "$@" "$url"
  local curl_out=$(mktemp)
  cleanup_add "$curl_out"
  msg_debug "running curl with opts: ${timeout_arg} $@ $url"
  local http_status=$(curl -o "$curl_out" --write-out "%{http_code}" \
    -Ls ${timeout_arg} --compressed \
    -H "$auth_header_value" \
    "$@" "$url"
    )

  # http call failed?
  if [ -z "${http_status}" -o ${http_status} -lt 200 -o ${http_status} -gt 399 ]; then
    msg_warn "curl invocation failed with http status '$http_status': $url"
    cat "$curl_out" 1>&2
    return 22
  else
    cat "$curl_out"
    return 0
  fi
}

debug_project_ids() {
  test "$_DEBUG" = "1" || return 0
  return 0

  echo "---BEGIN PROJECT IDS---"
  local key=""
  for key in "${!_PROJECT_IDS[@]}"; do
    echo "$key => "${_PROJECT_IDS["$key"]}
  done
  echo "---END PROJECT IDS---"
}

# resolves given gwr to project id and stores it in _RESOLVED_PROJECT_ID
gitlab_resolve_project_id() {
  local gwr=$(echo "$1" | tr '[A-Z]' '[a-z]')
  test -z "$gwr" && die "invalid gitlab group/repo argument (example: my-glab-group/my-repo)"

  # clear current result
  _RESOLVED_PROJECT_ID=""

  # already stored in cache?
  debug_project_ids
  if [ ! -z ${_PROJECT_IDS["$gwr"]} ]; then
    _RESOLVED_PROJECT_ID=${_PROJECT_IDS["$gwr"]}
    return 0
  fi

  local out=$(gitlab_call "/projects?membership=true&simple=true&order_by=name")
  local rv=$?
  if [ "$rv" = "0" -a ! -z "$out" ]; then
    local id=$(echo "$out" | \
      jq -r ".[] | select((.path_with_namespace | ascii_downcase) == \"${gwr}\") | .id")

    if [ ! -z "$id" ]; then
      gitlab_set_project_id "$gwr" "$id"

      # set the result
      _RESOLVED_PROJECT_ID="$id"
      return 0
    fi
  fi

  die "can't resolve gitlab project id for: $gwr"
}

gitlab_set_project_id() {
  local gwr="$1"
  local project_id="$2"
  _PROJECT_IDS["$gwr"]="$project_id"
  debug_project_ids
}

gitlab_registry_ids() {
  local gwr="$1"

  # resolve project id
  gitlab_resolve_project_id "$gwr"
  local project_id="${_RESOLVED_PROJECT_ID}"

  test -z "$max_pages" && max_pages=1
  msg_debug "gitlab_package_ids, gwr=$gwr, package=$package, version=$version, max_pages=$max_pages"

  # compute endpoint
  local per_page=100
  local endpoint="/projects/${project_id}/registry/repositories"
  #endpoint="${endpoint}&order_by=version&sort=desc&per_page=${per_page}"

  gitlab_call "${endpoint}" | jq '.[] | .id'

  return $rv
}

command_repo_url() {
  local gwr="$1"
  test -z "$gwr" && die "missing gitlab group/repo argument (example: my-glab-group/my-repo)"

  local id=$(gitlab_registry_ids "$gwr" | head -n1)
  test -z "$id" && die "can't determine registry id for: $gwr"

  echo "https://gitlab.com/$gwr/container_registry/${id}"
}

script_init() {
  # add script dir to path
  PATH="${SCRIPT_DIR}:$PATH"

  require_utils curl jq awk
  require_gnu_utils getopt date tar grep touch xargs

  # initial project id cache
  if [ ! -z "$CI_PROJECT_PATH" -a ! -z "$CI_PROJECT_ID" ]; then
    local key=$(echo "$CI_PROJECT_PATH" | tr '[A-Z]' '[a-z]')
    _PROJECT_IDS["$key"]="$CI_PROJECT_ID"
  fi

  return 0
}

do_run() {
  local command="$1"
  shift
  test -z "$command" && die "unspecified command. Run $MYNAME --help for instructions."

  local func_name="command_${command}"
  ${func_name} "$@" || die "Error running command: $command"
}

printhelp() {
  cat <<EOF
Usage: $MYNAME <COMMAND>  [opts]

This script allows simple interaction with gitlab container registry

SEE:
* https://docs.gitlab.com/ee/user/packages/generic_packages/#download-package-file

COMMANDS:

* repo_url  <gwr>                           :: prints repository url

OPTIONS:
  -A  --gitlab-api=URL        gitlab api base url   [\$CI_API_V4_URL, "$CI_API_V4_URL"]
  -T  --gitlab-token=TOKEN    gitlab API token      [\$GITLAB_TOKEN, "$GITLAB_TOKEN"]
  -J  --job-token=TOKEN       gitlab CI job token   [\$CI_JOB_TOKEN, "$CI_JOB_TOKEN"]

  -h  --help                  This help message
EOF
  exit 0
}

######################################################################
#                              MAIN                                  #
######################################################################

script_init

# parse command line...
TEMP=$(getopt -o A:T:J:h \
              --long gitlab-api:,gitlab-token:,job-token:,help \
              -n "$MYNAME" -- "$@")
test "$?" != "0" && die "Command line parsing error."
eval set -- "$TEMP"
while true; do
  case $1 in
    -A|--gitlab-api)
      CI_API_V4_URL="$2"
      shift 2
      ;;
    -T|--gitlab-token)
      GITLAB_TOKEN="$2"
      shift 2
      ;;
    -J|--job-token)
      CI_JOB_TOKEN="$2"
      shift 2
      ;;
    -h|--help)
      printhelp
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      die "Command line parsing error: '$1'."
      ;;
  esac
done

do_run "$@"
my_exit "$?"

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
