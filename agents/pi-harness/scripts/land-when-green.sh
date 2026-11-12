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
# Once it passes, the advisory jobs of that same run are read before landing.
# Both stay green when they warn, run only in the full run, and are not among
# "CI required"'s needs, so it can pass before they finish: a job still going
# keeps this waiting. It stops with exit 6 and the run's link when "Engine
# allocations (advisory)" warns that the PR passes `pr_allocations_pct`, when
# "Acceptance gates (cold analysis)" warns that the type_of shadow failed, and
# whenever either has no verdict: missing from the run, ending other than
# success or skipped, unreadable, or still pending when the wait runs out. The
# cumulative "Release gate allocations" warning is not a hold. Read the job
# summary, and land by hand with bin/land-pr if the warning is answered or
# accepted (contribution-flow.md step 3).
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

# The advisory job names (ci.yml) and the warning titles that hold (an exact
# title, then a title prefix); spec/tool/land_when_green_spec.rb pins each to
# its source.
ALLOC_JOB="Engine allocations (advisory)"
SHADOW_JOB="Acceptance gates (cold analysis)"
ALLOC_TITLE="Engine allocations"
SHADOW_TITLE_PREFIX="type_of shadow"

head_of() {
  gh pr view "$pr" --json headRefOid -q .headRefOid
}

# Whether annotation title $1 holds the landing.
holding_title() {
  [[ "$1" == "$ALLOC_TITLE" || "$1" == "$SHADOW_TITLE_PREFIX"* ]]
}

# Read the advisory jobs of check suite $1. Print one line per reason to hold;
# return 0 clear, 1 unreadable, 2 a job still pending, 3 hold.
advisory_state() {
  local rows job row_suite id status conclusion url name found pending=0 hold=0 titles title
  rows="$(gh api --paginate "repos/rigortype/rigor/commits/$sha/check-runs?filter=all&per_page=100" \
    --jq '.check_runs[] | "\(.check_suite.id)\t\(.id)\t\(.status)\t\(.conclusion)\t\(.html_url)\t\(.name)"')" ||
    return 1
  for job in "$ALLOC_JOB" "$SHADOW_JOB"; do
    found=0
    while IFS=$'\t' read -r row_suite id status conclusion url name; do
      [[ "$row_suite" == "$1" && "$name" == "$job" ]] || continue
      found=1
      if [[ "$status" != completed ]]; then
        pending=1
      elif [[ "$conclusion" == success ]]; then
        titles="$(gh api --paginate "repos/rigortype/rigor/check-runs/$id/annotations" --jq '.[] | .title // ""')" ||
          return 1
        while IFS= read -r title; do
          holding_title "$title" && { echo "$job warns \"$title\": $url"; hold=1; }
        done <<<"$titles"
      elif [[ "$conclusion" != skipped ]]; then
        echo "$job concluded $conclusion, so it has no verdict: $url"
        hold=1
      fi
    done <<<"$rows"
    ((found)) || { echo "$job has no check run in the run that passed"; hold=1; }
  done
  ((hold)) && return 3
  ((pending)) && return 2
  return 0
}

head="$(head_of 2>/dev/null)" || { echo "land-when-green: cannot read #$pr; not marking it ready"; exit 1; }
[[ "$head" == "$sha" ]] || { echo "land-when-green: #$pr head moved to $head; not landing"; exit 3; }
gh pr ready "$pr" >/dev/null 2>&1 || true

deadline=$(( $(date +%s) + ${LAND_WAIT_MINUTES:-60} * 60 ))
waiting_on="CI"
while :; do
  if head="$(head_of 2>/dev/null)" && verdict="$(bin/ci-required "$sha" 2>/dev/null)"; then
    [[ "$head" == "$sha" ]] || { echo "land-when-green: #$pr head moved to $head; not landing"; exit 3; }
    read -r ci suite <<<"$verdict"
    case "$ci" in
      SUCCESS)
        holds="$(advisory_state "$suite")"
        case $? in
          0) break ;;
          1)
            echo "land-when-green: #$pr cannot read the advisory results of the run that passed on $sha; not landing"
            exit 6
            ;;
          2) waiting_on="the advisory jobs" ;;
          *)
            echo "land-when-green: #$pr passed CI on $sha, but an advisory job holds it; read its summary, and land by hand if accepted:"
            printf '  %s\n' "$holds"
            exit 6
            ;;
        esac
        ;;
      FAILURE | TIMED_OUT | STARTUP_FAILURE | ACTION_REQUIRED)
        echo "land-when-green: #$pr \"CI required\" is $ci on $sha; not landing"
        exit 4
        ;;
    esac
  fi
  if (( $(date +%s) >= deadline )); then
    if [[ "$waiting_on" == CI ]]; then
      echo "land-when-green: #$pr CI still pending after the wait; not landing"
      exit 5
    fi
    echo "land-when-green: #$pr passed CI on $sha, but the advisory jobs are still pending after the wait; not landing"
    exit 6
  fi
  sleep "${LAND_WAIT_INTERVAL:-30}"
done

exec bin/land-pr "$pr" "$sha"
