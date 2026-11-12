#!/usr/bin/env bash
# Wait for CI on a reviewed head, then hand the PR to bin/land-pr. No model
# in the loop: the coordinator reviews, this lands.
#   land-when-green.sh PR SHA     SHA is the full reviewed head
# Marks a Draft PR ready, polls once per 30s for up to LAND_WAIT_MINUTES
# (default 60), and stops without landing when the head moved (exit 3), a
# check failed (exit 4) or the wait ran out (exit 5). Run it in the
# background with its output in a log; bin/land-pr's own exit status follows.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: land-when-green.sh PR SHA" >&2; exit 2; }
pr="$1" sha="$2"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

query='"\(.headRefOid) \([.statusCheckRollup[]|select(.conclusion=="FAILURE" or .conclusion=="CANCELLED" or .conclusion=="TIMED_OUT")]|length) \([.statusCheckRollup[]|select(.status!="COMPLETED")]|length) \(.statusCheckRollup|length)"'
deadline=$(( $(date +%s) + ${LAND_WAIT_MINUTES:-60} * 60 ))
while :; do
  if state="$(gh pr view "$pr" --json headRefOid,statusCheckRollup -q "$query" 2>/dev/null)"; then
    read -r head failed pending total <<<"$state"
    [[ "$head" == "$sha" ]] || { echo "land-when-green: #$pr head moved to $head; not landing"; exit 3; }
    [[ "$failed" == 0 ]] || { echo "land-when-green: #$pr has $failed failed check(s) on $sha; not landing"; exit 4; }
    [[ "$pending" == 0 && "$total" != 0 ]] && break
  fi
  (( $(date +%s) < deadline )) || { echo "land-when-green: #$pr CI still pending after the wait; not landing"; exit 5; }
  sleep 30
done

gh pr ready "$pr" >/dev/null 2>&1 || true
exec bin/land-pr "$pr" "$sha"
