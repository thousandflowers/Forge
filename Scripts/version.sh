#!/bin/bash
#
# The single place the version comes from: the newest v* tag, or a development
# placeholder when the tree has no tags.
set -uo pipefail
cd "$(dirname "$0")/.."

if TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null)" && [ -n "$TAG" ]; then
  echo "${TAG#v}"
else
  echo "0.0.0-dev"
fi
