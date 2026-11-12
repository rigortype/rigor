#!/usr/bin/env bash
# Lay out a takt control room in the CURRENT herdr tab (run it from a herdr pane):
#
#   +----------------------+----------------------+
#   |  this pane (shell)   |  status (live table) |
#   |                      +----------------------+
#   |                      |  log tail (newest)   |
#   +----------------------+----------------------+
#
# Usage: herdr-takt-up.sh [lane...]   # lanes, e.g. 2576 2777+2807; omit for status only
# Never closes or moves existing panes; new panes are created without stealing focus.
set -euo pipefail

test "${HERDR_ENV:-}" = 1 || { echo "herdr-takt-up: not inside a herdr pane" >&2; exit 1; }
command -v jq >/dev/null || { echo "herdr-takt-up: jq is required" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
S="$REPO/agents/pi-harness/scripts"
WT_ROOT="${WT_ROOT:-$(dirname "$REPO")/rigor-wt}"

status_pane="$(herdr pane split --current --direction right --cwd "$REPO" --no-focus | jq -r '.result.pane.pane_id')"
herdr pane run "$status_pane" "$S/takt-status.sh -l 5"

tail_pane="$(herdr pane split "$status_pane" --direction down --cwd "$REPO" --no-focus | jq -r '.result.pane.pane_id')"
# Follow whichever lane log was touched last; re-evaluated when the file set changes.
herdr pane run "$tail_pane" "mkdir -p '$WT_ROOT/.takt-logs' && touch '$WT_ROOT/.takt-logs/.keep' && tail -F -n 20 \$(ls -t '$WT_ROOT'/.takt-logs/*.log 2>/dev/null | head -3)"

herdr pane rename "$status_pane" "takt: status" >/dev/null
herdr pane rename "$tail_pane" "takt: logs" >/dev/null
echo "status pane: $status_pane   log pane: $tail_pane"
if [[ $# -gt 0 ]]; then
  echo "launching lanes in this pane: $*"
  exec "$S/run-takt-lanes.sh" "$@"
fi
