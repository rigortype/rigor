#!/usr/bin/env bash
# Launch the takt `rigor-ready-for-agent` workflow on issue lanes, one detached
# git worktree per lane, ending in a Draft PR (takt does the push / PR itself).
# Opus steps use the Anthropic API: TAKT_ANTHROPIC_API_KEY must be set in the
# environment of this process (see .takt/runtime.yaml). Never merges.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WT_ROOT="${WT_ROOT:-$(dirname "$REPO")/rigor-wt}"
LOG_DIR="${LOG_DIR:-$WT_ROOT/.takt-logs}"
WORKFLOW="${WORKFLOW:-rigor-ready-for-agent}"
JOBS="${JOBS:-2}"

usage() {
  cat <<'USAGE'
Usage:
  run-takt-lanes.sh [-j N] LANE...

LANE is an issue number (2576) or issues sharing one PR joined by "+" (2777+2807).

Examples:
  DRY_RUN=1 run-takt-lanes.sh 2576 2777+2807 2404 2769 2742
  run-takt-lanes.sh -j 2 2576 2777+2807 2404 2769 2742

Environment:
  TAKT_ANTHROPIC_API_KEY  required (Opus via API); set on this process only
  JOBS=2                  parallel lanes (also -j); keep low: each lane runs specs
  WORKFLOW=...            default rigor-ready-for-agent
  WT_ROOT=...             default <repo>/../rigor-wt (logs in .takt-logs/)
  DRY_RUN=1               print the per-lane plan only
USAGE
}

run_one() {
  local lane="$1" name wt log task
  name="takt-${lane//+/-}"
  wt="$WT_ROOT/$name"
  log="$LOG_DIR/$name.log"

  local target
  if [[ "$lane" == *+* ]]; then
    task="Implement GitHub issues #${lane//+/ and #} as ONE change and ONE PR. Read each with gh issue view <n> --comments and satisfy every issue's acceptance."
    target=(--task "$task")
  else
    target=(--issue "$lane")
  fi

  if [[ -n "${DRY_RUN:-}" ]]; then
    echo "[$name] worktree $wt (detached origin/master); takt --pipeline -w $WORKFLOW ${target[*]} --auto-pr --draft; log $log"
    return 0
  fi

  mkdir -p "$LOG_DIR"
  # One live run per lane: a second launch must not rebuild the worktree under it.
  local lock="$LOG_DIR/$name.lock"
  if [[ -e "$lock" ]] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
    echo "[$name] ALREADY RUNNING (pid $(cat "$lock")); not starting a second run"
    return 1
  fi
  echo $$ >"$lock"
  trap 'rm -f "$lock"' EXIT
  : >"$log"
  if [[ -e "$wt" ]]; then
    if [[ -n "$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
      echo "[$name] SKIPPED: $wt has tracked changes from an earlier run; inspect or remove it" | tee -a "$log"
      return 1
    fi
    # Stale lane from a run that stopped before producing anything: rebuild it.
    git -C "$REPO" worktree remove --force "$wt" >>"$log" 2>&1
  fi
  git -C "$REPO" fetch -q origin master
  git -C "$REPO" worktree add --detach "$wt" origin/master >>"$log" 2>&1
  (
    cd "$wt"
    MAIN_REPO="$REPO" bash agents/pi-harness/scripts/worktree-bundle-config.sh
    # Overlay the main checkout's .takt/ (uncommitted workflow/runtime edits that
    # origin/master lacks) and keep the overlay out of the lane's commits:
    # skip-worktree hides edits to tracked files; the origin/master .gitignore
    # (`*` + allow-list) is restored so untracked runtime.yaml stays ignored.
    # A *new* file under workflows/ or facets/ would NOT be hidden: commit those
    # to master before launching.
    cp -R "$REPO/.takt/." .takt/
    rm -rf .takt/runs .takt/tasks .takt/events .takt/exec .takt/tasks.yaml
    git checkout -- .takt/.gitignore
    git ls-files -m -- .takt | xargs -I{} git update-index --skip-worktree {}
    takt --pipeline -w "$WORKFLOW" "${target[@]}" --auto-pr --draft -q </dev/null
  ) >>"$log" 2>&1 && echo "[$name] done  (log $log)" || echo "[$name] FAILED (log $log; worktree kept: $wt)"
}

if [[ "${1:-}" == "--one" ]]; then
  run_one "$2"
  exit 0
fi

while getopts "j:h" opt; do
  case "$opt" in
    j) JOBS="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -gt 0 ]] || { usage; exit 2; }

# Fall back to the macOS keychain (service "takt-anthropic") so the key need not
# live in the calling shell. Store it once with:
#   security add-generic-password -s takt-anthropic -a "$USER" -w
if [[ -z "${DRY_RUN:-}" && -z "${TAKT_ANTHROPIC_API_KEY:-}" ]]; then
  TAKT_ANTHROPIC_API_KEY="$(security find-generic-password -s takt-anthropic -w 2>/dev/null || true)"
  export TAKT_ANTHROPIC_API_KEY
fi
if [[ -z "${DRY_RUN:-}" && -z "${TAKT_ANTHROPIC_API_KEY:-}" ]]; then
  echo "run-takt-lanes: TAKT_ANTHROPIC_API_KEY is not set and keychain item 'takt-anthropic' not found" >&2
  exit 1
fi

export REPO WT_ROOT LOG_DIR WORKFLOW DRY_RUN
printf '%s\n' "$@" | xargs -P "$JOBS" -I{} bash "${BASH_SOURCE[0]}" --one {}
