#!/bin/sh

set -e

die() {
  echo "FATAL: $@" 1>&2
  exit 1
}

test -z "$1" -o "$1" = "-h" -o "$1" = "--help" && {
  cat <<EOF
Usage: $0 -y <dir>

This script fixes git project permissions which get mangled by
gitlab saas runner that clones git repositories with umask value
of \`0000\` 🤦‍🤦‍‍🤦‍

Users have repeatedly asked that this "feature" should be turned off
by default, but it seems that it's still under consideration, see:

* https://gitlab.com/gitlab-org/gitlab-runner/-/issues/1736
* https://gitlab.com/gitlab-org/gitlab-runner/-/issues/28867
* https://docs.gitlab.com/runner/configuration/feature-flags.html#available-feature-flags (search umask)

What does this script do?
* finds all existing files with executable bit set
* chmods all files with mode 0644
* chmods all files with mode 0755
* restores executable bit on files that originally had it

EXAMPLE USAGE in .gitlab-ci.yml:

build-job:
  stage:  build
  script:
    # fix repository permissions mangled by gitlab saas-runner
    - ./scripts/gitlab-fix-project-permissions.sh -y $(pwd)
EOF
  exit 0
}

test "$1" = "-y" || die "Run $0 --help for instructions"

# check that second cli argument is a git repository
dir="$2"
test ! -z "$dir" -a -d "${dir}/.git" || die "directory is not a git repository: $dir"
cd "$dir" || die "can't enter git repository: $dir"

# find all files with exec bit set
XBIT_SET_FILE=$(mktemp)
echo "saving executable names into: ${XBIT_SET_FILE}"
find . -type f -executable | grep -v './.git/' > "${XBIT_SET_FILE}"

# reset dir/file permissions
echo "resetting permissions on files/dirs"
find . -type d -print0 | xargs -0 chmod 0755
find . -type f -print0 | xargs -0 chmod 0644

# restore permissions on files that had exec perms on at the beginning
echo "restoring executable permissions from: ${XBIT_SET_FILE}"
while IFS= read -r binary; do
  echo "  $binary"
  chmod 0755 "$binary"
done < "$XBIT_SET_FILE"

echo "successfully reset permissions on: $dir"

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF