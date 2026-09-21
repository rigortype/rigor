#!/usr/bin/env bash
# Write an untracked .bundle/config in CWD pointing BUNDLE_PATH at the main
# Rigor checkout's vendor/bundle. Usage:
#   MAIN_REPO=/path/to/rigor ./agents/pi-harness/scripts/worktree-bundle-config.sh
# Or from a managed worktree with MAIN_REPO auto-detected via git common dir.
set -euo pipefail
if [[ -n "${MAIN_REPO:-}" ]]; then
  main="$MAIN_REPO"
else
  common="$(git rev-parse --git-common-dir)"
  main="$(cd "$(dirname "$common")" && pwd)"
fi
bundle_path="$main/vendor/bundle"
if [[ ! -d "$bundle_path" ]]; then
  echo "rigor-pi-harness: missing $bundle_path — run bundle install in the main checkout first" >&2
  exit 1
fi
mkdir -p .bundle
cat > .bundle/config <<CFG
---
BUNDLE_PATH: "$bundle_path"
CFG
echo "rigor-pi-harness: wrote .bundle/config BUNDLE_PATH=$bundle_path (keep untracked)"
