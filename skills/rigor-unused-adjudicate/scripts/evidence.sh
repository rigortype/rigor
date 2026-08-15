#!/usr/bin/env bash
# Gather the evidence needed to adjudicate one `rigor unused` candidate.
#
#   scripts/evidence.sh Admin::Reports::Exporter
#
# Searches the spellings the report itself cannot match. Re-grepping the
# fully-qualified name is wasted work — a row would not be a candidate if the
# FQN appeared anywhere the report reads — so the value is in the other forms:
# the snake_cased autoload path, the demodulized leaf, interpolated
# construction, and mentions inside data and template files.
#
# Prints evidence; draws no conclusion. Deciding is the caller's job.
set -uo pipefail

NAME="${1:?usage: evidence.sh <ConstantName>}"
LEAF="${NAME##*::}"

# ActiveSupport-style underscore, enough for autoload paths:
#   Admin::Reports::Exporter -> admin/reports/exporter
UNDERSCORED=$(printf '%s' "$NAME" |
  sed -e 's/::/\//g' \
      -e 's/\([A-Z]\+\)\([A-Z][a-z]\)/\1_\2/g' \
      -e 's/\([a-z0-9]\)\([A-Z]\)/\1_\2/g' |
  tr '[:upper:]' '[:lower:]')

if command -v rg >/dev/null 2>&1; then
  search() { rg -n --hidden --glob '!.git' --glob '!vendor' --glob '!node_modules' -- "$1" . 2>/dev/null; }
else
  search() { grep -rn --exclude-dir=.git --exclude-dir=vendor --exclude-dir=node_modules -- "$1" . 2>/dev/null; }
fi

section() { printf '\n=== %s ===\n' "$1"; }

section "every occurrence of the full name (expected: the declaration only)"
search "$NAME" | head -20

section "the demodulized leaf '$LEAF' (catches a relative reference)"
[ "$LEAF" = "$NAME" ] && echo "  (same as the full name)" || search "\\b${LEAF}\\b" | head -20

section "the autoload path '$UNDERSCORED' (catches require / autoload / a string key)"
search "$UNDERSCORED" | head -20

section "interpolated or reflective construction that could reach it"
search 'constantize|safe_constantize|const_get|const_missing' | head -20

section "mentions in data and template files (configuration can name a class)"
if command -v rg >/dev/null 2>&1; then
  rg -n --glob '*.{yml,yaml,json,erb,haml,slim}' --glob '!vendor' -- "$LEAF" . 2>/dev/null | head -20
else
  grep -rn --include='*.yml' --include='*.yaml' --include='*.json' --include='*.erb' \
       --exclude-dir=vendor -- "$LEAF" . 2>/dev/null | head -20
fi

section "history (recently added and never wired up is unfinished work, not dead code)"
# Prefer a Ruby declaration over a generated signature: `module Foo` matches in
# `sig/**.rbs` too, and reporting the signature's history instead of the class's
# would answer a question nobody asked.
FILE=$(search "class ${LEAF}\\b|module ${LEAF}\\b" | cut -d: -f1 | grep -v '\.rbs$' | head -1)
[ -z "${FILE:-}" ] && FILE=$(search "class ${LEAF}\\b|module ${LEAF}\\b" | head -1 | cut -d: -f1)
if [ -n "${FILE:-}" ] && [ -f "$FILE" ]; then
  echo "  declaration: $FILE"
  git log -1 --format='  last change: %ad  %s' --date=short -- "$FILE" 2>/dev/null
else
  echo "  (declaration site not located by pattern; read the row's path from the report)"
fi

printf '\n--- control: this search finds a name you know is used ---\n'
echo "  Re-run with a live class name. If that also prints nothing, the search"
echo "  is broken and its silence proves nothing about the candidate."
