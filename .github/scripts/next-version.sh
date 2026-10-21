#!/usr/bin/env bash
# Prints the version that follows a version tag, for a release label's bump.
#
# usage: next-version.sh <major|minor|patch> [latest tag]
#   next-version.sh minor v0.1.0   -> v0.2.0
#   next-version.sh patch          -> v0.0.1 (no tag yet: from v0.0.0)
#
# The project stays on 0.x until the final defense: there, as semantic
# versioning allows, a major bump only moves the minor number. The move to
# v1.0.0 is a tag pushed by hand.
set -euo pipefail

bump=${1:?usage: next-version.sh <major|minor|patch> [latest tag]}
latest=${2:-v0.0.0}

if [[ ! $latest =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "next-version.sh: not a version tag: $latest" >&2
  exit 1
fi
major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
patch=${BASH_REMATCH[3]}

case $bump in
  major)
    if ((major == 0)); then
      minor=$((minor + 1))
    else
      major=$((major + 1))
      minor=0
    fi
    patch=0
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  patch)
    patch=$((patch + 1))
    ;;
  *)
    echo "next-version.sh: not a bump: $bump (major, minor or patch)" >&2
    exit 1
    ;;
esac

echo "v$major.$minor.$patch"
