#!/usr/bin/env bash
# Optional helper: launch pi with queue skill + session-id bound.
# Preferred DX: `pi` in the Rigor repo → /queue-release or /queue-survey
# (package already in .pi/settings.json). Use this only when you want a
# dedicated --session-id / model band without starting from a bare `pi`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
cd "$REPO_ROOT"

usage() {
  cat <<'USAGE'
Usage:
  run-queue.sh release|survey [extra pi args…]

Preferred (no wrapper):
  pi
  /queue-release [vX.Y.Z]
  /queue-survey [survey-root]
  pi -c          # continue same project session

This script is optional. It binds --session-id and orchestrator model band.

Environment:
  TARGET=v1.2.3   Release context only (not release auth)
  SURVEY_ROOT=…   Survey tree (default ~/repo/ruby/rigor-survey)
  SESSION_ID=…    Override default rigor-queue-release|rigor-queue-survey
  CONTINUE=1      Add pi --continue (-c) for same session-id
  MODEL=…         Override model id
  PRINT=1         pi -p (print and exit)
  DRY_RUN=1       Print argv only
  PI_BIN          Path to pi (default: pi)
USAGE
}

MODE="${1:-}"
case "${MODE}" in
  -h|--help|help) usage; exit 0 ;;
  release|survey) shift ;;
  "")
    echo "error: mode required (release|survey). Prefer: pi → /queue-release|/queue-survey" >&2
    usage >&2
    exit 2
    ;;
  *)
    echo "error: unknown mode '$MODE' (expected release|survey)" >&2
    exit 2
    ;;
esac

PI_BIN="${PI_BIN:-pi}"
if ! command -v "$PI_BIN" >/dev/null 2>&1; then
  echo "error: '$PI_BIN' not found on PATH" >&2
  exit 127
fi

if [[ "$MODE" == "release" ]]; then
  SKILL_DIR="$ROOT/skills/rigor-queue-release"
  SESSION_ID="${SESSION_ID:-rigor-queue-release}"
  SLASH_HINT="/queue-release"
else
  SKILL_DIR="$ROOT/skills/rigor-queue-survey"
  SESSION_ID="${SESSION_ID:-rigor-queue-survey}"
  SLASH_HINT="/queue-survey"
fi

if [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
  echo "error: missing skill at $SKILL_DIR/SKILL.md" >&2
  exit 1
fi

# Orchestrator band: claude-bridge opus first, then anthropic opus, then grok.
PREFERRED="claude-bridge/claude-opus-5"
PATTERNS=(
  "claude-bridge/*opus*"
  "claude-bridge/opus"
  "*claude-bridge*opus*"
  "anthropic/claude-opus-5"
  "anthropic/claude-opus"
  "xai/grok-4.7"
  "xai/grok-4.6"
  "xai/grok-4.5"
  "xai/grok"
  "opus"
  "grok"
)
CYCLE="*opus*,claude-bridge/*,grok*,anthropic/claude-opus*,xai/grok*"

glob_to_ere() {
  local g="$1" out="" i c
  for ((i = 0; i < ${#g}; i++)); do
    c="${g:i:1}"
    case "$c" in
      '*') out+='.*' ;;
      '?') out+='.' ;;
      '.'|'['|']'|'^'|'$'|'+'|'('|')'|'{'|'}'|'|'|'\\') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

first_model_token() {
  awk '
    /^[[:space:]]*$/ { next }
    /No models available|Use \/login|Models:|available models/ { next }
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.:*-]+/ || $i ~ /^(claude|grok|gemini|deepseek)-/) {
          print $i
          exit
        }
      }
    }
  '
}

auth_help() {
  cat >&2 <<'HELP'
No usable orchestrator-band model matched.

  pi          # /login
  pi --list-models opus
  MODEL=anthropic/claude-opus-5 ./agents/pi-harness/scripts/run-queue.sh release

Prefer starting bare `pi` and using /queue-release or /queue-survey instead.
HELP
}

resolve_model() {
  if [[ -n "${MODEL:-}" ]]; then
    echo "$MODEL"
    return 0
  fi
  local list
  if ! list="$("$PI_BIN" --list-models 2>&1)"; then
    echo "error: pi --list-models failed" >&2
    echo "$list" >&2
    auth_help
    return 1
  fi
  if echo "$list" | grep -qiE 'No models available|Use /login'; then
    echo "error: no models available" >&2
    auth_help
    return 1
  fi
  local pat ere candidate
  for pat in "${PATTERNS[@]}"; do
    ere="$(glob_to_ere "$pat")"
    candidate="$(echo "$list" | grep -iE "$ere" | first_model_token || true)"
    if [[ -n "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
    candidate="$("$PI_BIN" --list-models "$pat" 2>/dev/null | first_model_token || true)"
    if [[ -n "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  echo "error: none of the orchestrator patterns matched" >&2
  echo "preferred=$PREFERRED patterns=${PATTERNS[*]}" >&2
  auth_help
  return 1
}

RESOLVED="$(resolve_model)" || exit 1

APPEND=$(cat <<APPEND
[rigor-pi-harness] Queue mode: ${MODE}
- Primary DX is in-session: stay here; obey skill turn protocol (next/skip/stop).
- Load skill at ${SKILL_DIR}/SKILL.md; slash ${SLASH_HINT} is the usual entry.
- Hard: no silent /rigor-release-prep; survey targets must be disjoint checkouts.
- No parallel host make verify; lanes push SHA and stop; Issues = backlog (ADR-98).
- Sparse gh CI polls only (statusCheckRollup, ≤1/min/PR).
APPEND
)

PI_ARGS=(
  --model "$RESOLVED"
  --models "$CYCLE"
  --session-id "$SESSION_ID"
  --no-skills
  --skill "$SKILL_DIR"
  --append-system-prompt "$APPEND"
)

PROMPT_PARTS=()
if [[ "$MODE" == "release" && -n "${TARGET:-}" ]]; then
  PROMPT_PARTS+=("Release target context (NOT release auth): ${TARGET}")
fi
if [[ "$MODE" == "survey" ]]; then
  SURVEY_ROOT="${SURVEY_ROOT:-$HOME/repo/ruby/rigor-survey}"
  PROMPT_PARTS+=("Survey root: ${SURVEY_ROOT}")
fi

if [[ "${CONTINUE:-0}" == "1" ]]; then
  PI_ARGS+=(--continue)
fi
if [[ "${PRINT:-0}" == "1" ]]; then
  PI_ARGS+=(--no-session -p)
fi

CMD=("$PI_BIN" "${PI_ARGS[@]}")
if ((${#PROMPT_PARTS[@]})); then
  CMD+=("${PROMPT_PARTS[@]}")
fi
if (($#)); then
  CMD+=("$@")
fi

echo "rigor-pi-harness: queue=${MODE} model=${RESOLVED} session-id=${SESSION_ID} (optional wrapper; prefer pi → ${SLASH_HINT})" >&2

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf 'DRY_RUN:'
  printf ' %q' "${CMD[@]}"
  printf '\n'
  exit 0
fi

exec "${CMD[@]}"
