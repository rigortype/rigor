#!/usr/bin/env bash
# Mark a reviewed head ready, wait for its full CI, then hand the PR to
# bin/land-pr. No model in the loop: the coordinator reviews, this lands.
#   land-when-green.sh PR SHA     SHA is the full reviewed head
#
# A Draft PR's CI is the light gate, which leaves "CI required" SKIPPED, so
# the full run starts only at `gh pr ready` (contribution-flow.md § "Landing
# a pull request"). This reads the head first and stops before touching the
# PR when it cannot (exit 1) or the head moved (exit 3); then it marks the PR
# ready and polls once per 30s, for up to LAND_WAIT_MINUTES (default 60), the
# newest "CI required" check run on SHA through bin/ci-required, the rule
# bin/land-pr reads. It stops without landing when the head moved (exit 3),
# that check failed (exit 4) or the wait ran out (exit 5). SKIPPED and
# CANCELLED keep it waiting: they are the draft's run until the full run's
# check appears.
#
# Once it passes, the advisory jobs of that same run are read before landing:
# "Engine allocations (advisory)" warning that the PR passes
# `pr_allocations_pct`, or "Acceptance gates" warning that the type_of shadow
# failed, stops it with exit 6 and the run's link. Both jobs stay green when
# they warn, and both run only in the full run. Read the job summary, and land
# by hand with bin/land-pr if the warning is answered or accepted
# (contribution-flow.md step 3). An advisory result it cannot read also stops
# it with exit 6.
#
# After exit 4, 5 or 6 the PR stays ready: every fix push then starts a full
# run, and `gh pr ready --undo` does not cancel a full run already going.
# Run it in the background with its output in a log; bin/land-pr's own exit
# status follows.
set -uo pipefail

[[ $# -eq 2 ]] || { echo "usage: land-when-green.sh PR SHA" >&2; exit 2; }
pr="$1" sha="$2"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO" || exit 1

head_of() {
  gh pr view "$pr" --json headRefOid -q .headRefOid
}

# Print the advisory warnings in check suite $1 that hold the landing, one
# "<title> <run url>" per line; fail when GitHub cannot be read.
advisory_holds() {
  local runs id url titles title
  runs="$(gh api --paginate "repos/rigortype/rigor/commits/$sha/check-runs?filter=all&per_page=100" \
    --jq ".check_runs[] | select(.check_suite.id == $1)
      | select(.name == \"Engine allocations (advisory)\" or (.name | startswith(\"Acceptance gates\")))
      | \"\(.id) \(.html_url)\"")" || return 1
  while read -r id url; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    titles="$(gh api --paginate "repos/rigortype/rigor/check-runs/$id/annotations" \
      --jq '.[] | select(.title == "Engine allocations" or ((.title // "") | startswith("type_of shadow"))) | .title')" ||
      return 1
    while IFS= read -r title; do
      [[ -n "$title" ]] && echo "$title: $url"
    done <<<"$titles"
  done <<<"$runs"
  return 0
}

head="$(head_of 2>/dev/null)" || { echo "land-when-green: cannot read #$pr; not marking it ready"; exit 1; }
[[ "$head" == "$sha" ]] || { echo "land-when-green: #$pr head moved to $head; not landing"; exit 3; }
gh pr ready "$pr" >/dev/null 2>&1 || true

deadline=$(( $(date +%s) + ${LAND_WAIT_MINUTES:-60} * 60 ))
while :; do
  if head="$(head_of 2>/dev/null)" && verdict="$(bin/ci-required "$sha" 2>/dev/null)"; then
    [[ "$head" == "$sha" ]] || { echo "land-when-green: #$pr head moved to $head; not landing"; exit 3; }
    read -r ci suite <<<"$verdict"
    case "$ci" in
      SUCCESS) break ;;
      FAILURE | TIMED_OUT | STARTUP_FAILURE | ACTION_REQUIRED)
        echo "land-when-green: #$pr \"CI required\" is $ci on $sha; not landing"
        exit 4
        ;;
    esac
  fi
  (( $(date +%s) < deadline )) || { echo "land-when-green: #$pr CI still pending after the wait; not landing"; exit 5; }
  sleep "${LAND_WAIT_INTERVAL:-30}"
done

if ! holds="$(advisory_holds "$suite")"; then
  echo "land-when-green: #$pr cannot read the advisory results of the run that passed on $sha; not landing"
  exit 6
fi
if [[ -n "$holds" ]]; then
  echo "land-when-green: #$pr passed CI on $sha, but an advisory job warns; read its summary, and land by hand if accepted:"
  printf '  %s\n' "$holds"
  exit 6
fi

exec bin/land-pr "$pr" "$sha"
