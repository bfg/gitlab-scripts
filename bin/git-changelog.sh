#!/bin/sh
######################################################################
#                             GLOBALS                                #
######################################################################

######################################################################
#                            FUNCTIONS                               #
######################################################################

die() {
  echo "FATAL: $@" 1>&2
  exit 1
}

printhelp() {
  cat <<EOF
Usage: $0 -y

This script generates changelong since nearest tag.

EOF
}

######################################################################
#                               MAIN                                 #
######################################################################

test "$1" = "-y" ||  {
  printhelp
  exit 1
}

# find previous commit
#prev_commit=$(git rev-parse HEAD^1)
#test -z "$prev_commit" && die "no previous commit found"

# find nearest tag
prev_tag=$(git describe --tags --abbrev=0 HEAD^)
test ! -z "$2" && prev_tag="$2"

# display changelog
echo "## changes since since \`$prev_tag\`"
echo ""
git log --oneline --pretty=format:"* %h %s" "${prev_tag}"..HEAD

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
