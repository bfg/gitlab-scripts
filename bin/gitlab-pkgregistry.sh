#!/usr/bin/env bash

######################################################################
#                             GLOBALS                                #
######################################################################

CI_API_V4_URL=${CI_API_V4_URL:-"https://gitlab.com/api/v4"}
CI_PROJECT_ID=${CI_PROJECT_ID:-""}
CI_PROJECT_PATH=${CI_PROJECT_PATH:-""}
CI_JOB_TOKEN=${CI_JOB_TOKEN:-""}

GITLAB_TOKEN=${GITLAB_TOKEN:-""}
DOWNLOAD_DIR=${DOWNLOAD_DIR:-"/tmp"}
GIT_COMMIT_TIMESTAMP=${GIT_COMMIT_TIMESTAMP:-""}

# gitlab api timeout in seconds
GITLAB_API_TIMEOUT=${GITLAB_API_TIMEOUT:-"10"}

# gitlab upload/download timeout in seconds
GITLAB_TX_TIMEOUT=${GITLAB_TX_TIMEOUT:-"120"}

# perform cleanup?
DO_CLEANUP=${DO_CLEANUP:-"1"}

PRINT_HEADERS=${PRINT_HEADERS:-"1"}

# really perform destructive actions?
DO_IT=${DO_IT:-"0"}

# prune: remove packages older than given days
PRUNE_OLDER_THAN_DAYS=${PRUNE_OLDER_THAN_DAYS:-"7"}

# prune: retain package versions regardless of their age if their version matches any of given
#        regexes
declare -a PRUNE_PROTECT_VERSIONS=('^(v|rel-|release-).+')

# prune: retain latest version of any package even if it's older than PRUNE_OLDER_THAN_DAYS
PRUNE_RETAIN_LATEST_VERSION=${PRUNE_RETAIN_LATEST_VERSION:-"1"}

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

gitlab_package_ids() {
  local gwr="$1"
  local package="$2"
  local version="$3"
  local max_pages="$4"

  # resolve project id
  gitlab_resolve_project_id "$gwr"
  local project_id="${_RESOLVED_PROJECT_ID}"

  test -z "$max_pages" && max_pages=1
  msg_debug "gitlab_package_ids, gwr=$gwr, package=$package, version=$version, max_pages=$max_pages"

  # compute endpoint
  local per_page=100
  local endpoint="/projects/${project_id}/packages?foo=bar"
  test ! -z "$package" && endpoint="${endpoint}&package_name=$package"
  test ! -z "$version" && endpoint="${endpoint}&package_version=$version"
  endpoint="${endpoint}&order_by=version&sort=desc&per_page=${per_page}"

  # execute call using pagination
  local page=0
  local rv=1
  while [ ${page} -lt ${max_pages} ]; do
    page=$((page+1))

    local out=$(gitlab_call "${endpoint}&page=${page}")
    local curl_ex=$?
    test "$curl_ex" != 0 && break

    if [ ! -z "$out" ]; then
      # empty array, might be end of pagination or no results at all
      test "$out" = "[]" && break

      # extract what we need
      rv=0
      echo "$out" | jq -r '.[] | (.id|tostring) +" "+ .created_at +" "+ .name +" "+ .version'

      # we're done if we received less than max results per page
      local num_results=$(echo "$out" | jq -r '. | length')
      [ "$num_results" -lt "$per_page" ] && break
    fi
  done

  return $rv
}

gitlab_package_latest_id() {
  local gwr="$1"
  local package="$2"
  gitlab_package_ids "$gwr" "$package" | head -n1
}

gitlab_package_info() {
  local gwr="$1"
  local package="$2"
  local version="$3"

  local tmp=$(gitlab_package_ids "$gwr" "$package" "$version" | head -n1 | awk '{print $1, $4}')
  test -z "$tmp" && die "no such package: $gwr, package=$package, version=$version"
  local package_id=$(echo "$tmp" | awk '{print $1}')
  local package_version=$(echo "$tmp" | awk '{print $2}')

  # resolve project id
  gitlab_resolve_project_id "$gwr"
  local project_id="${_RESOLVED_PROJECT_ID}"
  #local project_id=$(gitlab_project_id "$gwr")
  local endpoint="/projects/${project_id}/packages/${package_id}/package_files"

  local out=$(gitlab_call "${endpoint}")
  local rv=$?
  if [ "$rv" = "0" -a ! -z "$out" ]; then
    local res=$(echo "$out" | \
     jq -r ".[] | (.id|tostring) +\" \"+ .created_at +\" \"+ (.size|tostring) +\" $package_version \"+ .file_name +\" \"+ .file_sha256")
     test -z "$res" && rv=1
     echo "$res"
  fi

  return $rv
}

archives_unpack() {
  local src_dir="$1"
  local dst_dir="$2"
  test -d "$src_dir" || die "not a directory: $src_dir"
  test -d "$dst_dir" || die "not a directory: $dst_dir"

  local archive=""
  for archive in "${src_dir}"/*.{zip,tar,tgz,tar.gz,tbz,tar.bz2,txz,tar.xz}; do
    test -f "$archive" || continue

    archive_unpack "$archive" "$dst_dir" || die "unpack failed: $archive"
    rm -f "$archive" || true
  done
}


archive_unpack() {
  local archive="$1"
  local dst_dir="$2"

  test -f "$archive" || die "bad archive file: $archive"
  test -d "$dst_dir" || die "not a directory: $dst_dir"

  if [ "${archive: -4}" = ".tar" ]; then
    tar xpf "$archive" -C "$dst_dir"
  elif [ "${archive: -4}" = ".zip" ]; then
    unzip -q "$archive" -d "$dst_dir"
  elif [ "${archive: -4}" = ".tgz" -o "${archive: -7}" = ".tar.gz" ]; then
    tar zxpf "$archive" -C "$dst_dir"
  elif [ "${archive: -4}" = ".tbz" -o "${archive: -8}" = ".tar.bz2" ]; then
    tar jxpf "$archive" -C "$dst_dir"
  elif [ "${archive: -4}" = ".txz" -o "${archive: -7}" = ".tar.xz" ]; then
    tar Jxpf "$archive" -C "$dst_dir"
  else
    die "don't know how to unpack: $archive"
  fi
}

# detects archive timestamp
archive_timestamp() {
  if [ ! -z "${CI_COMMIT_TIMESTAMP}" ]; then
    date --date="${CI_COMMIT_TIMESTAMP}" +%s
  elif [ ! -z "${GIT_COMMIT_TIMESTAMP}" ]; then
    echo "${GIT_COMMIT_TIMESTAMP}"
  else
    date +%s
  fi
}

# runs tar with options to create reproducible archives
tar_run() {
  local timestamp=$(archive_timestamp)

  tar --sort=name \
    --mtime="@${timestamp}" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    "$@"
}

archive_create() {
  local dir="$1"
  local archive="$2"
  shift 2

  test -d "$dir" -a -r "$dir" || die "not a readable directory: $dir"
  test -z "$archive" && die "archive name not specified"
  test -z "$@" && die "no files to archive"

  # archives should be reproducible, set fixed mtime on all dirs/files
  archive_dir_set_mtime "$dir" $(archive_timestamp)

  ( cd "$dir" && _archive_create "$archive" "$@" ) || die "archive creation failed: $archive"
  local size=$(du -h "${archive}" | awk '{print $1}')
  msg_info "created archive [size=$size]: $archive"
}

archive_dir_set_mtime() {
  local dir="$1"
  local timestamp=$2

  local time_str=$(date --date="@${timestamp}" +"%Y%m%d%H%M.%S")
  find "$dir" | xargs -n50 -- touch --no-dereference -t "${time_str}" || die "can't set mtime for: $dir"
}

_archive_create() {
  local archive="$1"
  shift

  msg_debug "creating $archive in dir => $(pwd) with args: $*"
  local args=$(eval echo "$@")
  msg_debug "  computed args: $args"

  if [ "${archive: -4}" = ".zip" ]; then
    zip -rqX "$archive" $args
  elif [ "${archive: -4}" = ".tar" ]; then
    tar_run -cpf "$archive" $args
  elif [ "${archive: -4}" = ".tgz" -o "${archive: -7}" = ".tar.gz" ]; then
    tar_run -cpf - $args | gzip -n > "$archive"
  elif [ "${archive: -4}" = ".tbz" -o "${archive: -8}" = ".tar.bz2" ]; then
    tar_run -jcpf "$archive" $args
  elif [ "${archive: -4}" = ".txz" -o "${archive: -7}" = ".tar.xz" ]; then
    tar_run -Jcpf "$archive" $args
  else
    die "don't know how to create archive: $archive"
  fi
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

command_project_id() {
  gitlab_resolve_project_id "$1"
  echo "${_RESOLVED_PROJECT_ID}"
}

command_latest() {
  local gwr="$1"
  local packages="$2"

  gitlab_resolve_project_id "$gwr"

  local packages="$2"
  if [ -z "$packages" ]; then
    packages=$(command_packages "$gwr" | xargs echo)
  fi

  local fmt="%-10.10s %-24.24s %-45s %s\n"
  [ "$PRINT_HEADERS" = "1" ] && printf "$fmt" "ID" "CREATED" "PACKAGE" "VERSION"

  local pkg=""
  for pkg in ${packages}; do
    local out=$(gitlab_package_ids "$gwr" "$pkg" "" | head -n1)
    test -z "$out" && continue

    printf "$fmt" \
      $(echo "$out" | awk '{print $1}') \
      $(echo "$out" | awk '{print $2}') \
      $(echo "$out" | awk '{print $3}') \
      $(echo "$out" | awk '{print $4}')
  done
}

command_versions() {
  local gwr="$1"
  gitlab_resolve_project_id "$1"

  local packages="$2"
  if [ -z "$packages" ]; then
    packages=$(command_packages "$gwr" | xargs echo)
  fi
  test -z "$packages" && die "no packages found for: $gwr"

  local max_versions="$3"
  test -z "$max_versions" && max_versions=5

  local fmt="%-10.10s %-24.24s %-45s %s\n"

  local pkg=""
  local header_printed=0
  for pkg in ${packages}; do
    local out=$(gitlab_package_ids "$gwr" "$pkg" "" 100 | head -n"${max_versions}")
    test -z "$out" && die "no packages found for gwr=$gwr, package=$pkg"

    if [ "$header_printed" != "1" ]; then
      header_printed=1
      [ "$PRINT_HEADERS" = "1" ] && printf "$fmt" "ID" "CREATED" "PACKAGE" "VERSION"
    fi

    local line=""
    while read -s line; do
      test -z "$line" && continue
      printf "$fmt" \
        $(echo "$line" | awk '{print $1}') \
        $(echo "$line" | awk '{print $2}') \
        $(echo "$line" | awk '{print $3}') \
        $(echo "$line" | awk '{print $4}')
    done <<< "$out"
  done
}

command_info() {
  local gwr="$1"
  local package="$2"
  local version="$3"

  gitlab_resolve_project_id "$gwr"

  local out=$(gitlab_package_info "$gwr" "$package" "$version" 2>/dev/null)
  test -z "$out" && die "no such package: $gwr, package=$package, version=$version"

  local fmt="%-10.10s %-24.24s %-10.10s %-50s %-50s %s\n"
  [ "$PRINT_HEADERS" = "1" ] && printf "$fmt" "ID" "CREATED" "SIZE" "VERSION" "FILENAME" "CHECKSUM"

  printf "$fmt" \
    $(echo "$out" | awk '{print $1}') \
    $(echo "$out" | awk '{print $2}') \
    $(echo "$out" | awk '{print $3}') \
    $(echo "$out" | awk '{print $4}') \
    $(echo "$out" | awk '{print $5}') \
    $(echo "$out" | awk '{print $6}')
}

command_packages() {
  local gwr="$1"

  gitlab_resolve_project_id "$gwr"
  gitlab_package_ids "$gwr" "" "" 200 | awk '{print $3}' | sort -u
}

command_fetch() {
  local gwr="$1"
  local package="$2"
  local version="$3"

  test -z "$package" && package=$(basename "$gwr")

  # compute download directory
  local dst_dir="$DOWNLOAD_DIR"
  test -z "$dst_dir" && die "unspecified destination directory, run $MYNAME --help for instructions."
  mkdir -p "$dst_dir" || die "can't create destination directory: $dst_dir"
  msg_debug "using download dir: $dst_dir"

  # resolve project id
  gitlab_resolve_project_id "$gwr"
  local project_id="${_RESOLVED_PROJECT_ID}"
  #local project_id=$(gitlab_project_id "$gwr")
  test -z "$project_id" && die "can't determine gitlab project id for: $gwr"

  # local project_id=$(gitlab_project_id "$gwr")
  test -z "$package" && package=$(basename "$gwr")

  # version?
  local info_file=$(mktemp)
  cleanup_add "$info_file"
  gitlab_package_info "$gwr" "$package" "$version" > "$info_file"
  test ! -s "$info_file" && die "can't get info for package: $gwr, version=$version, package=$package"

  local line=
  while IFS= read -r line; do
    local id=$(echo "$line" | awk '{print $1}')
    local version=$(echo "$line" | awk '{print $4}')
    local filename=$(echo "$line" | awk '{print $5}')
    local checksum=$(echo "$line" | awk '{print $6}')
    test -z "$id" -o -z "$version" -o -z "$filename" -o -z "$checksum" && continue

    local full_filename="${dst_dir}/${filename}"

    local endpoint="/projects/${project_id}/packages/generic/${package}/${version}/${filename}"
    msg_info "fetching [version=$version]: $filename"
    gitlab_call "$endpoint" "-m${GITLAB_TX_TIMEOUT}" > "$full_filename" || die "gitlab fetch failed: $endpoint"
    test -f "$full_filename" || die "file was not downloaded: $endpoint"

    # verify checksum
    local downloaded_checksum=$(sha256sum "$full_filename" | awk '{print $1}')
    test "$downloaded_checksum" = "$checksum" || die "checksum mismatch for $filename: downloaded=$downloaded_checksum, expecting=$checksum"

    local file_size=$(du -h "$full_filename" | awk '{print $1}')
    msg_info "  downloaded [$version, size=$file_size]: $full_filename"
  done < "$info_file"
}

command_install() {
  local gwr="$1"
  local package="$2"
  local version="$3"

  local install_dir="$DOWNLOAD_DIR"
  test -z "$install_dir" && die "unspecified destination directory; run $0 --help for instructions"
  mkdir -p "$install_dir" 2>/dev/null || true
  test -d "$install_dir" -a -w "$install_dir" || die "bad installation directory: $install_dir"

  local download_dir=$(mktemp -d)
  test -d "$download_dir" || die "can't create tmp download dir."
  cleanup_add "$download_dir"

  local tmp_dst_dir=$(mktemp -d)
  test -d "$tmp_dst_dir" || die "can't create tmp destination dir."
  cleanup_add "$tmp_dst_dir"

  # download stuff
  DOWNLOAD_DIR="$download_dir"
  command_fetch "$gwr" "$package" "$version" || die "can't download package: $gwr, package=$package, version=$version"

  # unpack archives
  archives_unpack "$download_dir" "$tmp_dst_dir"

  # move files left in download dir
  mv -f "$download_dir"/* "${tmp_dst_dir}" 2>/dev/null || true

  # time to install files from tmp dir into real destination directory
  cp -raf "$tmp_dst_dir"/. "$install_dir" || die "copy to final destination failed"
  msg_info "successfully installed files to: $install_dir"
}


command_archive() {
  local archive_name="$1"
  local src_dir="$2"
  shift 2

  test -z "$archive_name" && die "archive name not specified"
  test -z "$src_dir" -o ! -d "$src_dir" && die "no source dir given or a bad directory: $src_dir"
  test -z "$*" && die "no files given to archive"

  msg_info "creating archive $archive_name using directory $src_dir with pattern: $*"
  archive_create "$src_dir" "$archive_name" "$@"
}

command_upload() {
  local gwr="$1"
  local package="$2"
  local version="$3"
  shift 3

  test -z "$package" && die "undefined package name"
  test -z "$version" && die "version not specified"
  test -z "$*" && die "no files to upload"

  # resolve project id
  gitlab_resolve_project_id "$gwr"
  local project_id="${_RESOLVED_PROJECT_ID}"
  #local project_id=$(gitlab_project_id "$gwr")
  test -z "$project_id" && die "can't determine gitlab project id for: $gwr"

  # target url, see: https://docs.gitlab.com/ee/user/packages/generic_packages/index.html#publish-a-package-file
  local base_url="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}"

  local base_endpoint="/projects/${project_id}/packages/generic/${package}/${version}"

  local file=""
  for file in "$@"; do
    test -f "$file" || die "not a file: $file"
    local pkg_file_basename=$(basename "$file")

    local endpoint="${base_endpoint}/${pkg_file_basename}?select=package_file"

    msg_info "uploading version '${version}': ${file} => $endpoint"
    gitlab_call "$endpoint" "-m${GITLAB_TX_TIMEOUT}" --upload-file "$file" | jq . || die "upload failed: $file"
  done
}

duration_str() {
  local h=$((h=${1}/3600))
  local m=$((m=(${1}%3600)/60))
  local s=$((s=${1}%60))
  printf '%02dh %02dm %02ds\n' $h $m $s
}

command_prune() {
  local gwr="$1"
  local package="$2"

  test -z "$PRUNE_OLDER_THAN_DAYS" && die "undefined PRUNE_OLDER_THAN_DAYS interval"

  # prune older-than must be a number, add 0 to force "type conversion"
  PRUNE_OLDER_THAN_DAYS=$((PRUNE_OLDER_THAN_DAYS + 0))
  test ${PRUNE_OLDER_THAN_DAYS} -lt 1 && die "invalid PRUNE_OLDER_THAN_DAYS interval: ${PRUNE_OLDER_THAN_DAYS}; must be >= 1"

  # resolve project id
  gitlab_resolve_project_id "$gwr"
  local project_id="${_RESOLVED_PROJECT_ID}"

  # compute timestamp
  local now_datetime=$(TZ=UTC date --iso-8601=seconds)
  local now_timestamp=$(date --date="${now_datetime}" +%s)
  local older_than_datetime=$(TZ=UTC date --date="${now_datetime} - ${PRUNE_OLDER_THAN_DAYS} days" --iso-8601=seconds)
  local older_than_timestamp=$(date --date="${older_than_datetime}" +%s)

  # find packages to prune
  local pkg_info_file=$(mktemp)
  cleanup_add "$pkg_info_file"
  gitlab_package_ids "$gwr" "$package" "" 1000 > "$pkg_info_file"
  test -s "$pkg_info_file" || die "no packages found for gwr=$gwr, package=$package"

  # ask for all packages if no package was given
  local packages="${package}"
  [ -z "$packages" ] && packages=$(cat "$pkg_info_file" | awk '{print $3}' | sort -u | xargs echo)
  test -z "$packages" && die "no packages found for gwr=$gwr, package=$package"

  msg_info "current time: $now_datetime; will prune packages older than ${PRUNE_OLDER_THAN_DAYS} days, max creation date: $older_than_datetime [timestamp: ${older_than_timestamp}]"

  for package in ${packages}; do
    _prune_package "$pkg_info_file" "$package" "$older_than_timestamp" "$now_timestamp"
  done
}

_prune_package() {
  local info_file="$1"
  local package="$2"
  local older_than_timestamp="$3"
  local now_timestamp="$4"

  # should we retain latest version of this package regardless of its age
  local skip_lines=1
  [ "$PRUNE_RETAIN_LATEST_VERSION" = "1" ] && skip_lines=$((skip_lines + 1))

  # find packages to prune
  local pkg_info_file=$(mktemp)
  cleanup_add "$pkg_info_file"

  grep " $package " "$info_file" > "$pkg_info_file"
  test -s "$pkg_info_file" || die "no packages found package=$package"

  # how many versions of this package do we have?
  local num_versions=$(cat "$pkg_info_file" | wc -l)
  [ ${num_versions} -lt 1 ] && return 0

  # only one version?!

  msg_debug "_prune_package: package=${package}, num_versions=${num_versions} older_than_timestamp=${older_than_timestamp}, now_timestamp=${now_timestamp}"
  local num_deleted=0
  local num_read=0
  local line=""
  while read -s line; do
    local pkg_id=$(echo "$line" | awk '{print $1}')
    local created_at=$(echo "$line" | awk '{print $2}')
    local pkg_name=$(echo "$line" | awk '{print $3}')
    local pkg_version=$(echo "$line" | awk '{print $4}')
    test -z "$pkg_id" -o -z "$created_at" -o -z "$pkg_name" -o -z "$pkg_version" && continue

    num_read=$((num_read + 1))
    msg_debug "  [#$num_read]: $line"

    # created_at must be positive
    local created_at_ts=$(date --date="${created_at}" +%s 2>/dev/null)
    created_at_ts=$((created_at_ts + 0))
    test ${created_at_ts} -gt 0 || {
      msg_verbose "skipping [created_at_ts is undefined]: $pkg_name, version=$pkg_version, created_at=$created_at, created_at_ts=$created_at_ts"
      continue
    }

    # created at must be bigger than older_than_timestamp
    local age_seconds=$((now_timestamp - ${created_at_ts}))
    local age_duration=$(duration_str ${age_seconds})
    [ ${created_at_ts} -lt ${older_than_timestamp} ] || {
      msg_verbose "skipping [only $age_duration old]: $pkg_name, version=$pkg_version, created_at=$created_at, created_at_ts=$created_at_ts"
      continue
    }

    # check if version is protected
    local ver_pattern=""
    for ver_pattern in "${PRUNE_PROTECT_VERSIONS[@]}"; do
      test -z "$ver_pattern" && continue
      echo "$pkg_version" | grep -Pq "$ver_pattern" && {
        msg_verbose "skipping [protected version: ${ver_pattern}]: $pkg_name, version=$pkg_version, created_at=$created_at, created_at_ts=$created_at_ts, age: ${age_duration}"
        # continue: 2 => next iteration of while loop
        continue 2
      }
    done

    # don't remove the latest version of the package even it's older than allowed and version is not protected
    if [ "${PRUNE_RETAIN_LATEST_VERSION}" = "1" -a $num_read -eq 1 -a $num_deleted -eq 0 ]; then
      msg_verbose "skipping [latest version]: $pkg_name, version=$pkg_version, created_at=$created_at, created_at_ts=$created_at_ts, age: ${age_duration}"
      continue
    fi

    # time to remove this package version
    local log_str=""
    [ "${DO_IT}" != "1" ] && log_str=" [not really, \`--do-it\` arg unspecified]"
    num_deleted=$((num_deleted + 1))
    if [ "${DO_IT}" = "1" ]; then
      local endpoint="/projects/${project_id}/packages/${pkg_id}"
      gitlab_call "$endpoint" -X DELETE || die "can't delete package $pkg_name, version=$pkg_version, created_at=$created_at [age=$age_duration]: $endpoint"
    fi
    msg_info "deleted version${log_str}: $pkg_version, package=$pkg_name, created_at=$created_at [age=$age_duration]"
  done < "$pkg_info_file"

  msg_info "[$package]: deleted ${num_deleted}/${num_read} packages"
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

This script allows simple interaction with gitlab package registry

SEE:
* https://docs.gitlab.com/ee/user/packages/generic_packages/#download-package-file

COMMANDS:

* project_id <gwr>                          :: prints project id
* packages <gwr>                            :: prints package names
* versions <gwr> [package]                  :: prints last 10 package versions
* latest <gwr> [package]                    :: prints latest package version
* info <gwr> [package] [version]            :: prints info about all files in a given package

* fetch <gwr> [package] [version]           :: downloads the package
* install <gwr> [package] [version]         :: downloads and unpacks the package to a filesystem

* archive <archive_name> <src_dir> <patt> [<patt2>] :: creates archive with given name from given directory
                                            * src_dir => base archive directory
                                            * patt => files to include in the archive relative to <src_dir>,
                                                      names should be quoted to avoid shell expansion

* upload <gwr> <package> <version> file1 [...fileN] :: uploads given files to gitlab package registry

* prune <gwr> [package]                     :: removes obsolete non-release builds from package registry

OPTIONS:
  -A  --gitlab-api=URL        gitlab api base url   [\$CI_API_V4_URL, "$CI_API_V4_URL"]
  -T  --gitlab-token=TOKEN    gitlab API token      [\$GITLAB_TOKEN, "$GITLAB_TOKEN"]
  -J  --job-token=TOKEN       gitlab CI job token   [\$CI_JOB_TOKEN, "$CI_JOB_TOKEN"]

  -d  --dst-dir=DIR           package download/install directory

  -O  --older-than=DAYS       prune packages older than specified [\$PRUNE_OLDER_THAN_DAYS, "$PRUNE_OLDER_THAN_DAYS"]
  -P  --protect-version=PATT  prune don't remove package versions that match given regex pattern
                              [\$PRUNE_PROTECT_VERSIONS, ${PRUNE_PROTECT_VERSIONS[@]}]
  -X  --no-retain-latest      also remove latest version package version, even if that means removing all versions

  -y  --do-it                 really perform destructive actions?

      --no-cleanup            don't remove temporary files on exit

  -v  --verbose               verbose execution
  -D  --debug                 enable debug output
  -q  --quiet                 quiet mode
  -h  --help                  This help message

EXAMPLES:
# get latest package in the repository
  $MYNAME latest my-glab-group/my-repo

# get last 20 package versions
  $MYNAME versions my-glab-group/my-repo

# get info about package with latest version in package repository
  $MYNAME info my-glab-group/my-repo

# get specific package version
  $MYNAME info my-glab-group/my-repo some_version

# download latest package to /tmp/foo
  $MYNAME -d /tmp/foo fetch my-glab-group/my-repo

# download version 1.0.0 of package "my-repo" to /tmp/foo
  $MYNAME -d /tmp/foo fetch my-glab-group/my-repo 1.0.0

# download version 1.0.0 of package "foo-package" to /tmp/foo
  $MYNAME -d /tmp/foo fetch my-glab-group/my-repo 1.0.0 foo-package

# install latest package to /tmp/bar
  $MYNAME -d /tmp/foo install my-glab-group/my-repo

# install version 1.0.0 of package "my-repo" to /tmp/bar
  $MYNAME -d /tmp/foo install my-glab-group/my-repo 1.0.0

# install version 1.0.0 of package "foo-package" to /tmp/bar
  $MYNAME -d /tmp/foo install my-glab-group/my-repo 1.0.0 foo-package

# create package
  $MYNAME archive /path/to/shared-libs.zip   ./src/dir "*.so" "*.dll"
  $MYNAME archive /path/to/binaries.tgz      ./src/dir "bin/*"
  $MYNAME archive /path/to/binaries-dbg.tgz  ./src/dir "bin-debug/*"

# upload to package registry
  $MYNAME upload my-glab-group/my-repo 1.0.0 my-package /path/to/shared-libs.zip
  $MYNAME upload my-glab-group/my-repo 1.0.0 my-package /path/to/binaries.tgz
  $MYNAME upload my-glab-group/my-repo 1.0.0 my-package /path/to/binaries-dbg.tgz

# prune non-release packages older than 17 days
  $MYNAME prune my-glab-group/my-repo -O 17

# prune non-release packages of "sub_package" older than 13 days whose versions don't start with foo or bar
  $MYNAME prune my-glab-group/my-repo sub_package -O 13 -P '^(foo|bar)'
EOF
  exit 0
}

######################################################################
#                              MAIN                                  #
######################################################################

script_init

# parse command line...
TEMP=$(getopt -o A:T:J:d:O:P:Xyvdqh \
              --long gitlab-api:,gitlab-token:,job-token:,dst-dir:,older-than:,protect-version:,no-retain-latest,do-it,no-cleanup,verbose,debug,quiet,help \
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
    -d|--dst-dir)
      DOWNLOAD_DIR="$2"
      shift 2
      ;;
    -O|--older-than)
      PRUNE_OLDER_THAN_DAYS="$2"
      shift 2
      ;;
    -P|--protect-version)
      PRUNE_PROTECT_VERSIONS+=("$2")
      shift 2
      ;;
    -X|--no-retain-latest)
      PRUNE_RETAIN_LATEST_VERSION=0
      shift
      ;;
    -y|--do-it)
      DO_IT=1
      shift
      ;;
    --no-cleanup)
      DO_CLEANUP=0
      shift
      ;;
    -v|--verbose)
      _VERBOSE=1
      shift
      ;;
    -D|--debug)
      _DEBUG=1
      shift
      ;;
    -q|--quiet)
      _DEBUG=0
      _VERBOSE=0
      PRINT_HEADERS=0
      shift
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