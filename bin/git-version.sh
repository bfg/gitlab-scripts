#!/usr/bin/env bash

#
# NOTE: variables and functions are prefixed with `_` so that file can be safely sourced into a current
#       shell in a attempt to prevent name clashes

_GIT_ENV=""
_GIT_JSON=""
_GIT_PROPS=""
_PROJECT_VERSION=""
_DISPLAY_VERSION=""
_DISPLAY_VERSION_PREFIX=""

die() {
  echo "FATAL: $*" 1>&2
  exit 1
}

_format_var_str_single_word() {
  _format_var_str "$1" | \
    awk '{print $1}' | \
    tr '[:upper:]' '[:lower:]' | \
    tr '_' '-' | \
    tr ':' '-' | \
    tr '/' '-' | \
    tr '\\' '-' | \
    sed -e 's/--/-/g' | \
    tr -cd '[:print:]' | \
    sed -e 's/--/-/g' | \
    sed -e 's/-$//g'
}

_format_var_str() {
  local format="$1"
  test -z "$format" && return 0

  local git_commit_date=""
  local git_commit_time=""
  local git_commit_datetime=""
  if [ ! -z "$GIT_COMMIT_TIMESTAMP" -a "$GIT_COMMIT_TIMESTAMP" != "0" ]; then
    git_commit_date=$(date --date "@${GIT_COMMIT_TIMESTAMP}" +'%Y%m%d')
    git_commit_time=$(date --date "@${GIT_COMMIT_TIMESTAMP}" +'%H%M')
    git_commit_datetime=$(date --date "@${GIT_COMMIT_TIMESTAMP}" +'%Y%m%d-%H%M')
  fi

  echo "$format" | \
    sed -e "s/%GIT_SHA%/$GIT_SHA/g" | \
    sed -e "s/%GIT_BRANCH%/$GIT_BRANCH/g" | \
    sed -e "s/%GIT_BUILD_VERSION%/$GIT_BUILD_VERSION/g" | \
    sed -e "s/%GIT_BUILD_IS_RELEASE%/$GIT_BUILD_IS_RELEASE/g" | \
    sed -e "s/%GIT_COMMIT_ID%/$GIT_COMMIT_ID/g" | \
    sed -e "s/%GIT_COMMIT_ID_ABBREV%/$GIT_COMMIT_ID_ABBREV/g" | \
    sed -e "s/%GIT_COMMIT_TIME%/$GIT_COMMIT_TIME/g" | \
    sed -e "s/%GIT_COMMIT_TIMESTAMP%/$GIT_COMMIT_TIMESTAMP/g" | \
    sed -e "s!%GIT_COMMIT_CHANGELOG_URL%!$GIT_COMMIT_CHANGELOG_URL!g" | \
    sed -e "s!%GIT_REMOTE_ORIGIN_URL%!$GIT_REMOTE_ORIGIN_URL!g" | \
    sed -e "s/%GIT_TAGS%/$GIT_TAGS/g"
}

_compute_project_version() {
  # check if there's a git tag
  local version=$(_do_compute_project_version_from_git_tags "$GIT_TAGS")
  if [ ! -z "$version" ]; then
    echo "$version"
    return 0
  fi

  # try to compute something from VERSION file
  version=$(_format_var_str_single_word "$_PROJECT_VERSION")
  if [ ! -z "$version" ]; then
    echo "$version"
    return 0
  fi

  # fallback
  version=$(_format_var_str_single_word "%GIT_BRANCH%-%GIT_COMMIT_ID_ABBREV%")
  if [ ! -z "$version" ]; then
    echo "$version"
    return 0
  fi

  # ... we need to output something as a last resort:-/
  echo "0.0-dev"
}

_do_compute_project_version_from_git_tags() {
  local tags="$1"
  test -z "$tags" && return 0

  # select first from available git tags...
  local tag="$(echo "$tags" | awk '{print $1}' | tr -d ' ')"
  if [ ! -z "$tag" ]; then
    # remove release-/v prefixes
    tag=$(echo "$tag" | sed -e 's/^release-//g' | sed -e 's/^v//g')
    if [ ! -z "$tag" ]; then
      echo "$tag"
      return 0
    fi
  fi

  return 0
}

_do_compute_project_version_fallback() {
  if [ ! -z "$GIT_BRANCH" -a ! -z "$GIT_COMMIT_ID_ABBREV" ]; then
    echo "${GIT_BRANCH}-${GIT_COMMIT_ID_ABBREV}"
  else
    echo "0.0-dev"
  fi
}

_compute_changelog_url() {
  echo "${GIT_REMOTE_ORIGIN_URL}" | \
    sed -e 's/^git@/https:\/\//g' | \
    sed -e 's/\.com:/\.com\//' | \
    sed -e "s/\\.git\$/\/commits\/${GIT_COMMIT_ID_ABBREV}/g"
}

# SEE: https://docs.gitlab.com/ee/ci/variables/predefined_variables.html
_set_vars_via_env_gitlab() {
  # check that we're running as a gitlab-ci job first
  #test "$CI" = "true" -a ! -z "$CI_COMMIT_BRANCH" -a ! -z "$CI_COMMIT_SHA" || return 0
  test "$CI" = "true" -a ! -z "$CI_COMMIT_SHA" || return 0

  export GIT_BRANCH="$CI_COMMIT_BRANCH"
  export GIT_COMMIT_ID="$CI_COMMIT_SHA"
  export GIT_COMMIT_ID_ABBREV="$CI_COMMIT_SHORT_SHA"
  export GIT_COMMIT_TIME="$CI_COMMIT_TIMESTAMP"

  export GIT_COMMIT_TIMESTAMP=$(date -d "${GIT_COMMIT_TIME}" +%s 2>/dev/null)
  test -z GIT_COMMIT_TIMESTAMP && GIT_COMMIT_TIMESTAMP=0

  export GIT_REMOTE_ORIGIN_URL=$(echo "$CI_REPOSITORY_URL" | sanitize_git_url)
  export GIT_TAGS="$CI_COMMIT_TAG"
}

# SEE: https://docs.github.com/en/actions/learn-github-actions/variables#default-environment-variables
_set_vars_via_env_github() {
  # check that we're running as a github action first
  test "$CI" = "true" -a "$GITHUB_ACTIONS" = "true" -a ! -z "$GITHUB_ACTION" || return 0

  export GIT_BRANCH="$GITHUB_REF_NAME"
  export GIT_COMMIT_ID="$GITHUB_SHA"
  export GIT_COMMIT_ID_ABBREV=${GITHUB_SHA:0,8}

  # there's no git commit time among github env vars
  GIT_COMMIT_TIMESTAMP=$(git show -s --format=%ct "${GIT_COMMIT_ID}" 2>/dev/null)
  test -z "$GIT_COMMIT_TIMESTAMP" && GIT_COMMIT_TIMESTAMP=0
  export GIT_COMMIT_TIME=$(date --iso-8601=seconds -u --date=@"${GIT_COMMIT_TIMESTAMP}" 2>/dev/null)

  # there's no remote url among github env args
  export GIT_REMOTE_ORIGIN_URL=$(git remote get-url origin 2>/dev/null)

  export GIT_TAGS=
  if [ "$GITHUB_REF_TYPE" = "tag" ]; then
    export GIT_TAGS="$GITHUB_REF_NAME"
  fi
  return 0
}

# SEE: https://docs.travis-ci.com/user/environment-variables#default-environment-variables
_set_vars_via_env_travis() {
  # check that we're running as a travis build first
  test "$CI" = "true" -a "$TRAVIS" = "true" || return 0

  # TODO: implement travis env => GIT_XXX env var translation
  return 0
}

_set_vars_via_env() {
  _set_vars_via_env_gitlab
  _set_vars_via_env_github
  _set_vars_via_env_travis
}

_set_vars_via_git() {
  export GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  export GIT_COMMIT_ID=$(git rev-parse HEAD 2>/dev/null)
  export GIT_COMMIT_ID_ABBREV=$(git rev-parse --short HEAD 2>/dev/null)
  export GIT_COMMIT_TIME=$(TZ=UTC git show -s --date=iso-strict-local --format=%cd 2>/dev/null)

  export GIT_COMMIT_TIMESTAMP=$(git show --no-patch --format=%ct 2>/dev/null)
  test -z GIT_COMMIT_TIMESTAMP && GIT_COMMIT_TIMESTAMP=0

  export GIT_REMOTE_ORIGIN_URL=$(git ls-remote --get-url origin  2>/dev/null | grep -v origin | head -n1 | sanitize_git_url)
  export GIT_TAGS=$(git tag --points-at HEAD 2>/dev/null | sort -u|tr  '\n' ' ' | sed -e 's/ $//g')
}

_set_vars() {
  if [ -z "$CI" ]; then
    _set_vars_via_git
  else
    _set_vars_via_env
  fi

  export GIT_BUILD_IS_RELEASE="false"
  test ! -z "$GIT_TAGS" && GIT_BUILD_IS_RELEASE="true"

  # try to read project version from a file
  _PROJECT_VERSION=$(_project_version_file_read)

  export GIT_SHA="${GIT_COMMIT_ID_ABBREV}"
  export GIT_BUILD_VERSION=$(_compute_project_version)
  export GIT_COMMIT_CHANGELOG_URL=$(_compute_changelog_url)
}

sanitize_git_url() {
  # remove gitlab-ci-token:[MASKED]@ stuff from git remote url
  sed -e 's/https:\/\/.*:.*@/https:\/\//g'
}

_project_version_file_read() {
  local version_file="VERSION"

  if [ -f "$version_file" ]; then
    local tmp=$(cat "${version_file}" | grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*$'  | head -n1 | awk '{print $1}')
    if [ ! -z "${tmp}" ]; then
      echo "$tmp"
      return 0
    fi
  fi

  return 0
}

_write_git_props() {
  cat <<EOF
git.branch="$GIT_BRANCH"
git.build.version="$GIT_BUILD_VERSION"
git.build.is_release=$GIT_BUILD_IS_RELEASE
git.commit.id="$GIT_COMMIT_ID"
git.commit.id.abbrev="$GIT_COMMIT_ID_ABBREV"
git.commit.time="$GIT_COMMIT_TIME"
git.commit.time=$GIT_COMMIT_TIMESTAMP"
git.commit.changelog=$GIT_COMMIT_CHANGELOG_URL"
git.remote.origin.url="$GIT_REMOTE_ORIGIN_URL"
git.tags="$GIT_TAGS"
EOF
}

_write_git_json() {
cat <<EOF
{
  "git": {
    "build": {
      "version": "$GIT_BUILD_VERSION",
      "is_release": $GIT_BUILD_IS_RELEASE
    },
    "commit": {
      "changelog": "${GIT_COMMIT_CHANGELOG_URL}",
      "id": "$GIT_COMMIT_ID",
      "abbrev": "$GIT_COMMIT_ID_ABBREV",
      "time": "$GIT_COMMIT_TIME",
      "timestamp": $GIT_COMMIT_TIMESTAMP
    },
    "remote": {
      "origin": {
        "url": "$GIT_REMOTE_ORIGIN_URL"
      }
    },
    "branch": "$GIT_BRANCH",
    "tags": "$GIT_TAGS"
  }
}
EOF
}


_write_git_envfile() {
cat <<EOF
export GIT_SHA="$GIT_SHA"
export GIT_BRANCH="$GIT_BRANCH"
export GIT_BUILD_VERSION="$GIT_BUILD_VERSION"
export GIT_BUILD_IS_RELEASE="$GIT_BUILD_IS_RELEASE"
export GIT_COMMIT_ID="$GIT_COMMIT_ID"
export GIT_COMMIT_ID_ABBREV="$GIT_COMMIT_ID_ABBREV"
export GIT_COMMIT_TIME="$GIT_COMMIT_TIME"
export GIT_COMMIT_TIMESTAMP="$GIT_COMMIT_TIMESTAMP"
export GIT_COMMIT_CHANGELOG_URL="$GIT_COMMIT_CHANGELOG_URL"
export GIT_REMOTE_ORIGIN_URL="$GIT_REMOTE_ORIGIN_URL"
export GIT_TAGS="$GIT_TAGS"
EOF
}

_ensure_parent_dir() {
  local file="$1"
  local dir=$(dirname "$file")
  test ! -d "$dir" && mkdir -p "$dir"
}

_do_run() {
  # set variables
  _set_vars

  # write git info
  if [ ! -z "$_GIT_ENV" ]; then
    _ensure_parent_dir "$_GIT_ENV"
    _write_git_envfile > "$_GIT_ENV"
  fi
  if [ ! -z "$_GIT_JSON" ]; then
    _ensure_parent_dir "$_GIT_JSON"
    _write_git_json > "$_GIT_JSON"
  fi
  if [ ! -z "$_GIT_PROPS" ]; then
    _ensure_parent_dir "$_GIT_PROPS"
    _write_git_props > "$_GIT_PROPS"
  fi

  # maybe output version
  if [ ! -z "$_DISPLAY_VERSION" ]; then
    local prefix=""
    test "${GIT_BUILD_IS_RELEASE}" = "true" && prefix="${_DISPLAY_VERSION_PREFIX}"
    echo "${prefix}${GIT_BUILD_VERSION}"
  fi

  # required because failed `test` above can make this function to return 1
  return 0
}

_printhelp() {
  cat <<EOF
Usage: $0 [OPTIONS]

This script tries to read GIT information via \$CI_XXX variables or via git(1) binary
and outputs various formats that can be consumed by application stored in the repository.

OPTIONS
  -p <file>            Outputs git.properties-style file
  -j <file>            Outputs json file
  -e <file>            Outputs file that can be sourced into any shell
  -E                   Same as -e <file>, but output will be written to stdout
  -v                   Shows computed project version
  -T                   Prepend \`v\` to computed project version if current version is a release

  -f <fmt pattern>     Formats given format string using magic %GIT_XXX% placeholders
                       and exits

  -F <fmt pattern>     Formats given format string using magic %GIT_XXX% placeholders
                       as a single word

  -h                   This help message

PROJECT VERSION COMPUTATION

Project version (-v flag or %GIT_BUILD_VERSION% magic var) gets computed from:

* first non-empty git tag
* \`VERSION\`                 file content with magic vars
* \`%GIT_BRANCH%-%GIT_SHA%\`  as a fallback

MAGIC VARIABLES:

NOTE: magic variables can be used in \`VERSION\` file, as -f/-F cli argument string

* %GIT_SHA%                      git commit short sha
* %GIT_BRANCH%                   git branch name
* %GIT_BUILD_VERSION%            computed build version
* %GIT_BUILD_IS_RELEASE%         'true' if this commit is a tag, otherwise 'false'
* %GIT_COMMIT_ID%                git commit full sha
* %GIT_COMMIT_ID_ABBREV%         git commit short sha
* %GIT_COMMIT_TIME%              git commit ISO8601 datetime
* %GIT_COMMIT_TIMESTAMP%         git commit timestamp in epoch seconds
* %GIT_COMMIT_CHANGELOG_URL%     git commit changelog url
* %GIT_REMOTE_ORIGIN_URL%        git remote url
* %GIT_TAGS%                     comma separated list of git tags

\`VERSION\` FILE

This script reads file \`VERSION\` if exists in current directory and uses it's
content to compute version from it (see -v flag). File should contain magic
%GIT_XXX% placeholders to compute project versions

EXAMPLES:
  # just output project version
  $0 -vT

  # write output to stdout that can be sourced into sh-style scripts
  $0 -E

  # source git env vars into a current shell
  \$($0 -E)

  # write output to file that can be sourced into sh-style scripts
  $0 -e git.env

  # write json and env output to a file and computed project version to stdout
  $0 -e /path/to/git.env -j /path/to/git.json -vT

  # format a given pattern
  $0 -f '%GIT_BUILD_VERSION%-%GIT_BRANCH%-%GIT_SHA%-%GIT_REMOTE_ORIGIN_URL%-%GIT_COMMIT_CHANGELOG_URL%'
  $0 -F '%GIT_BUILD_VERSION%-%GIT_BRANCH%-%GIT_SHA%-%GIT_REMOTE_ORIGIN_URL%-%GIT_COMMIT_CHANGELOG_URL%'
EOF
}

# parse command line...
TEMP=$(getopt -o p:j:e:EvTf:F:h -- "$@")
test "$?" != "0" && die "Command line parsing error."
eval set -- "$TEMP"
while true; do
  case $1 in
    -p)
      _GIT_PROPS="$2"
      shift 2
      ;;
    -j)
      _GIT_JSON="$2"
      shift 2
      ;;
    -e)
      _GIT_ENV="$2"
      shift 2
      ;;
    -E)
      _GIT_ENV="/dev/stdout"
      shift
      ;;
    -v)
      _DISPLAY_VERSION=1
      shift
      ;;
    -T)
      _DISPLAY_VERSION_PREFIX="v"
      shift
      ;;
    -f)
      _set_vars
      _format_var_str "$2"
      exit 0
      ;;
    -F)
      _set_vars
      _format_var_str_single_word "$2"
      echo
      exit 0
      ;;
    -h|--help)
      _printhelp
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Command line parsing error: '$1'." 1>&2
      exit 1
      ;;
  esac
done

_do_run

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
