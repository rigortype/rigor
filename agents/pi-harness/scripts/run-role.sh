#!/usr/bin/env bash
# Role-bound pi launcher for ADR-115 (architect → lane first).
# Binds --model / --models so free /model cycling cannot quietly demote.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
cd "$REPO_ROOT"

usage() {
  cat <<'USAGE'
Usage:
  run-role.sh <role> [pi args... / prompt...]
  ROLE=<role> ISSUE=<n|URL> MODEL=<id> PRINT=1 DRY_RUN=1 run-role.sh

Roles: architect | lane | reviewer | docs | orchestrator

Environment:
  ROLE          Role name (or pass as first arg)
  ISSUE         Optional issue number/URL appended to the prompt
  MODEL         Override model id/pattern (skips default resolution)
  PRINT=1       Use pi -p (print and exit); default is interactive
  DRY_RUN=1     Print the pi command and exit without running
  PI_BIN        Path to pi (default: pi on PATH)

Model defaults (patterns; first match from `pi --list-models` wins):
  reviewer (rigor-reviewer-grok agent): xai/grok-4.6 — use xai/grok-4.7 only for deep RCA
  architect / orchestrator
    patterns: claude-bridge/*opus*  anthropic/*opus*  xai/grok*  *opus*  grok*
    preferred ids: claude-bridge/claude-opus-5 , anthropic/claude-opus-5 , xai/grok-4.7 (deep RCA; review default is 4.6)
  lane
    patterns: opencode-go/deepseek-v4.1-flash  opencode-go/*deepseek*flash*  opencode/*deepseek*flash*  *deepseek*flash*
    preferred ids: opencode-go/deepseek-v4.1-flash
  reviewer
    patterns: claude-bridge/*fable*  anthropic/*fable*  *fable*  *opus*  grok*
    preferred: claude-bridge/claude-fable-5 (Fable); else Opus/Grok-class
  docs
    patterns: antigravity/gemini*flash*  opencode/gemini*flash*  google/gemini*flash*  *gemini*flash*
    preferred ids: antigravity/gemini-3.8-flash

If no provider is authenticated / no pattern matches, the script exits with
`pi auth` / `pi --list-models` guidance instead of falling back to a random
default (e.g. google).
USAGE
}

ROLE="${ROLE:-${1:-}}"
if [[ -n "${1:-}" && "$1" == "$ROLE" ]]; then
  shift
fi

case "${ROLE:-}" in
  -h|--help|help) usage; exit 0 ;;
  "")
    echo "error: ROLE required" >&2
    usage >&2
    exit 2
    ;;
  architect|lane|reviewer|docs|orchestrator) ;;
  *)
    echo "error: unknown role '$ROLE' (expected architect|lane|reviewer|docs|orchestrator)" >&2
    exit 2
    ;;
esac

PI_BIN="${PI_BIN:-pi}"
if ! command -v "$PI_BIN" >/dev/null 2>&1; then
  echo "error: '$PI_BIN' not found on PATH. Install: npm install -g --ignore-scripts @earendil-works/pi-coding-agent" >&2
  exit 127
fi

SKILL_DIR="$ROOT/skills/rigor-${ROLE}"
if [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
  echo "error: missing skill at $SKILL_DIR/SKILL.md" >&2
  exit 1
fi

# Preferred id + fallback fuzzy patterns per role (ADR-115 bands).
# Patterns are tried against `pi --list-models` output (provider/id lines).
declare -a PATTERNS=()
PREFERRED=""
case "$ROLE" in
  architect|orchestrator)
    # Prefer Claude Max via pi-claude-bridge (subscription), then API Anthropic, then Grok.
    PREFERRED="claude-bridge/claude-opus-5"
    PATTERNS=(
      "claude-bridge/claude-opus-5"
      "claude-bridge/claude-opus"
      "anthropic/claude-opus-5"
      "anthropic/claude-opus"
      "xai/grok-4.7"
      "xai/grok-4.6"
      "xai/grok-4.5"
      "xai/grok"
      "opus"
      "grok"
    )
    CYCLE="claude-bridge/*opus*,*opus*,grok*,anthropic/claude-opus*,xai/grok*"
    ;;
  lane)
    # OpenCode Go Flash-class (subscription). Prefer latest v4.1; deepseek/deepseek-flash is not listed.
    PREFERRED="opencode-go/deepseek-v4.1-flash"
    PATTERNS=(
      "opencode-go/deepseek-v4.1-flash"
      "opencode-go/deepseek-v4-flash"
      "opencode/deepseek-v4.1-flash"
      "opencode/deepseek-v4-flash"
      "opencode-go/*deepseek*flash*"
      "opencode/*deepseek*flash*"
      "deepseek-v4.1-flash"
      "deepseek-v4-flash"
      "deepseek/*flash*"
      "deepseek-flash"
    )
    CYCLE="opencode-go/*deepseek*flash*,opencode/*deepseek*flash*,*deepseek*flash*"
    ;;
  reviewer)
    PREFERRED="claude-bridge/claude-fable-5"
    PATTERNS=(
      "claude-bridge/claude-fable-5"
      "claude-bridge/claude-fable"
      "anthropic/claude-fable-5"
      "anthropic/claude-fable"
      "fable"
      "claude-bridge/claude-opus-5"
      "anthropic/claude-opus-5"
      "anthropic/claude-opus"
      "xai/grok"
      "opus"
    )
    CYCLE="claude-bridge/*fable*,*fable*,claude-bridge/*opus*,*opus*,grok*,anthropic/claude-fable*,anthropic/claude-opus*,xai/grok*"
    ;;
  docs)
    # Prefer Google AI Pro via pi-antigravity (subscription), then OpenCode Gemini, then google API.
    PREFERRED="antigravity/gemini-3.8-flash"
    PATTERNS=(
      "antigravity/gemini-3.8-flash"
      "antigravity/gemini-3.7-flash"
      "antigravity/gemini*flash"
      "opencode/gemini-3.8-flash"
      "opencode/gemini*flash"
      "google/gemini-3.8-flash"
      "google/gemini-flash-latest"
      "google/gemini-3.5-flash"
      "gemini-flash-latest"
      "gemini*flash"
      "gemini"
    )
    CYCLE="antigravity/gemini*flash*,opencode/gemini*flash*,google/gemini*flash*,gemini*flash*"
    ;;
esac

auth_help() {
  cat >&2 <<'HELP'
No usable model matched this role's band.

Authenticate a provider, then re-run:

  pi          # interactive: /login
  # or set an API key, e.g.:
  #   export ANTHROPIC_API_KEY=...    # architect / reviewer / orchestrator
  #   export XAI_API_KEY=...          # grok-class architect alternative
  #   export DEEPSEEK_API_KEY=...     # lane
  #   export GEMINI_API_KEY=...       # docs

Inspect what pi can see:

  pi --list-models
  pi --list-models opus
  pi --list-models deepseek
  pi --list-models fable
  pi --list-models gemini

Override explicitly when you know an id:

  MODEL=claude-bridge/claude-opus-5 ./agents/pi-harness/scripts/run-role.sh architect

This harness refuses to silently fall back to an unbound default (e.g. google).
HELP
}

# Convert a simple glob (* and ?) to an extended regex for grep -iE.
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

# pi --list-models prints two columns: provider  model  …
# Emit provider/model ids (and pass through already-slashed tokens).
list_model_ids() {
  awk '
    BEGIN { IGNORECASE = 1 }
    /^[[:space:]]*$/ { next }
    $1 == "provider" && $2 == "model" { next }
    /No models available|No models matching|Use \/login|Models:|available models/ { next }
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.:*-]+$/) {
          print $i
          next
        }
      }
      if (NF >= 2 && $1 ~ /^[a-zA-Z0-9_.-]+$/ && $2 ~ /^[a-zA-Z0-9_.:*-]+$/) {
        print $1 "/" $2
      }
    }
  '
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

  if echo "$list" | grep -qiE 'No models available|No models matching|Use /login'; then
    echo "error: no models available (providers not configured)" >&2
    auth_help
    return 1
  fi

  local ids pat ere candidate searched
  ids="$(echo "$list" | list_model_ids)"

  # Exact preferred id first when present.
  if [[ -n "$PREFERRED" ]] && echo "$ids" | grep -Fxq "$PREFERRED"; then
    echo "$PREFERRED"
    return 0
  fi

  for pat in "${PATTERNS[@]}"; do
    ere="$(glob_to_ere "$pat")"
    candidate="$(echo "$ids" | grep -iE "^${ere}$" | head -1 || true)"
    if [[ -n "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
    searched="$("$PI_BIN" --list-models "$pat" 2>/dev/null || true)"
    if echo "$searched" | grep -qiE 'No models available|No models matching|Use /login'; then
      continue
    fi
    candidate="$(echo "$searched" | list_model_ids | grep -iE "^${ere}$" | head -1 || true)"
    if [[ -z "$candidate" ]]; then
      candidate="$(echo "$searched" | list_model_ids | head -1 || true)"
    fi
    if [[ -n "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  echo "error: none of the role patterns matched available models" >&2
  echo "role=$ROLE preferred=$PREFERRED patterns=${PATTERNS[*]}" >&2
  echo "--- pi --list-models (head) ---" >&2
  echo "$list" | head -40 >&2
  auth_help
  return 1
}

RESOLVED="$(resolve_model)" || exit 1

APPEND=$(cat <<APPEND
[rigor-pi-harness] Role binding: ${ROLE}
- You MUST stay on model band for this role; do not demote via /model to a cheaper band.
- Load skill rigor-${ROLE} (path: ${SKILL_DIR}/SKILL.md) and obey its finish phrases.
- Hard constraints: no parallel host make verify; lanes do not CI-watch; Issues = backlog (ADR-98).
- See agents/pi-harness/roles/${ROLE}.md and agents/pi-harness/contracts/README.md.
APPEND
)

PI_ARGS=(
  --model "$RESOLVED"
  --models "$CYCLE"
  --no-skills
  --skill "$SKILL_DIR"
  --append-system-prompt "$APPEND"
)

# Optional issue context
PROMPT_PARTS=()
if [[ -n "${ISSUE:-}" ]]; then
  PROMPT_PARTS+=("Issue: ${ISSUE}")
fi

# Remaining CLI args go to pi (prompts / @files / flags)
EXTRA=("$@")

if [[ "${PRINT:-0}" == "1" ]]; then
  PI_ARGS+=(--no-session -p)
fi

CMD=("$PI_BIN" "${PI_ARGS[@]}")
if ((${#PROMPT_PARTS[@]})); then
  CMD+=("${PROMPT_PARTS[@]}")
fi
if ((${#EXTRA[@]})); then
  CMD+=("${EXTRA[@]}")
fi

echo "rigor-pi-harness: role=${ROLE} model=${RESOLVED} skill=${SKILL_DIR}" >&2

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf 'DRY_RUN:'
  printf ' %q' "${CMD[@]}"
  printf '\n'
  exit 0
fi

exec "${CMD[@]}"
