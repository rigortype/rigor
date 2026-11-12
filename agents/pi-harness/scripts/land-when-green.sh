#!/usr/bin/env bash
# Mark a reviewed head ready, wait for its full CI, then hand the PR to
# bin/land-pr. No model in the loop: the coordinator reviews, this lands.
#   land-when-green.sh PR SHA     SHA is the full reviewed head
# A Draft PR's CI is the light gate, which leaves "CI required" SKIPPED, so
# the full run starts only at `gh pr ready` (contribution-flow.md § "Landing
# a pull request"). This marks the PR ready first, then polls once per 30s
# for up to LAND_WAIT_MINUTES (default 60) for the newest "CI required"
# check run on the head, the rule bin/land-pr reads. It stops without
# landing when the head moved (exit 3), that check failed (exit 4) or the
# wait ran out (exit 5). Run it in the background with its output in a log;
# bin/land-pr's own exit status follows.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: land-when-green.sh PR SHA" >&2; exit 2; }
pr="$1" sha="$2"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

# The head and its "CI required" check runs as <databaseId>:<conclusion>
# entries ("none" when there is none yet; a pending run's conclusion is null).
read_state() {
  gh api graphql -F n="$pr" \
    -f query='query($n:Int!){repository(owner:"rigortype",name:"rigor"){pullRequest(number:$n){headRefOid
      commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{... on CheckRun{name databaseId conclusion}}}}}}}}}}' \
    --jq '.data.repository.pullRequest | "\(.headRefOid) \([.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
      | select(.name == "CI required") | "\(.databaseId):\(.conclusion)"] | if length == 0 then "none" else join(",") end)"'
}

# The conclusion of the newest (highest-id) entry, as bin/land-pr reads it.
newest_conclusion() {
  local entry id best=-1 conclusion=MISSING
  local -a entries
  IFS=, read -r -a entries <<<"$1"
  for entry in "${entries[@]}"; do
    id="${entry%%:*}"
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    if ((id > best)); then
      best="$id"
      conclusion="${entry#*:}"
    fi
  done
  echo "$conclusion"
}

# Refuse a moved head before marking anything ready.
if state="$(read_state 2>/dev/null)"; then
  read -r head _ <<<"$state"
  [[ "$head" == "$sha" ]] || { echo "land-when-green: #$pr head moved to $head; not landing"; exit 3; }
fi
gh pr ready "$pr" >/dev/null 2>&1 || true

deadline=$(( $(date +%s) + ${LAND_WAIT_MINUTES:-60} * 60 ))
while :; do
  if state="$(read_state 2>/dev/null)"; then
    read -r head runs <<<"$state"
    [[ "$head" == "$sha" ]] || { echo "land-when-green: #$pr head moved to $head; not landing"; exit 3; }
    ci="$(newest_conclusion "$runs")"
    case "$ci" in
      SUCCESS) break ;;
      # SKIPPED or CANCELLED is the draft's light run until the full run's check appears; null is pending.
      FAILURE | TIMED_OUT | STARTUP_FAILURE | ACTION_REQUIRED)
        echo "land-when-green: #$pr \"CI required\" is $ci on $sha; not landing"
        exit 4
        ;;
    esac
  fi
  (( $(date +%s) < deadline )) || { echo "land-when-green: #$pr CI still pending after the wait; not landing"; exit 5; }
  sleep 30
done

exec bin/land-pr "$pr" "$sha"
