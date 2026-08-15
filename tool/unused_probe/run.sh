#!/usr/bin/env bash
# THROWAWAY — issue #345 spike. Measures unreferenced project constants on one project.
#
#   tool/unused_probe/run.sh <PROJECT_DIR> <OUT.json> [extra rigor args...]
#
# Must be invoked from the Rigor worktree that carries the instrumentation, INSIDE the Nix flake:
#
#   nix --extra-experimental-features 'nix-command flakes' develop \
#     --command tool/unused_probe/run.sh /path/to/project /tmp/proj.json
#
# `--no-cache` and `--workers=0` are forced here, not left to the target's `.rigor.yml`: a cache HIT
# file is never re-analyzed (zero references) and a pooled run accumulates references in a child
# process that never writes the dump. The report script re-checks both from the dump and refuses to
# print a number if either is wrong.
set -euo pipefail

PROJECT="${1:?usage: run.sh <PROJECT_DIR> <OUT.json> [extra rigor args]}"
OUT="${2:?usage: run.sh <PROJECT_DIR> <OUT.json> [extra rigor args]}"
shift 2

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

cd "$PROJECT"
RIGOR_UNUSED_PROBE="$OUT" \
BUNDLE_GEMFILE="$WT/Gemfile" \
BUNDLE_PATH="$WT/vendor/bundle" \
  bundle exec ruby "$WT/exe/rigor" check --no-cache --no-ci-detect --workers=0 "$@" || true

ruby "$WT/tool/unused_probe/report.rb" "$OUT" --limit 40
