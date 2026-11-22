#!/bin/bash
# Try everything Forge offers, on real files: one file per format it says it
# reads, into every format it offers for that kind, and through every preset.
#
#   Scripts/conformance.sh [work folder] [folder of saved presets]
#
# Needs ImageMagick, ffmpeg and pandoc to make the files; camera raw samples are
# downloaded from raw.pixls.us (public domain). The work folder is not small:
# the files are about 400 MB and what Forge writes from them about 10 GB.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mkdir -p "${1:-build/conformance}" && cd "${1:-build/conformance}" && pwd)"
export FORGE_CONFORMANCE_FIXTURES="$WORK/fixtures"
export FORGE_CONFORMANCE_REPORT="$WORK/report.tsv"
export FORGE_CONFORMANCE_OUTPUT="$WORK/out"
[ -n "${2:-}" ] && export FORGE_CONFORMANCE_PRESETS="$2"

python3 Scripts/conformance_fixtures.py "$FORGE_CONFORMANCE_FIXTURES" --raw

# The tests fail when a conversion breaks the rule; the report is wanted either way.
swift test --filter ConformanceTests || true

python3 Scripts/conformance_check.py "$WORK/report.formats.tsv"
echo "Every attempt: $WORK/report.formats.tsv and $WORK/report.presets.tsv"
