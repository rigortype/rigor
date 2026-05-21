#!/usr/bin/env bash
# rigor-regression-sweep — checkout each tag, run `rigor check`
# against the frozen baseline + config, save raw JSON / stderr.
# Run inside the rigor Nix dev shell (Phase 6 of SKILL.md).
#
# Edit the four variables + TAGS for the target, then:
#   nix … develop --command bash <this-script>
set -u

# --- configure -------------------------------------------------------
RIGOR=/Users/megurine/repo/ruby/rigor
TARGET=/Users/megurine/repo/ruby/rigor-survey/mastodon
SWEEP=/Users/megurine/repo/ruby/rigor-survey/_mastodon-sweep
BASE=$SWEEP/baseline.yml
TAGS=(v4.5.0-beta.1 v4.5.0-beta.2 v4.5.0-rc.1 v4.5.0-rc.2 v4.5.0-rc.3
      v4.5.0 v4.5.1 v4.5.2 v4.5.3 v4.5.4 v4.5.5 v4.5.6 v4.5.7 v4.5.8
      v4.5.9 v4.5.10)
# ---------------------------------------------------------------------

mkdir -p "$SWEEP/reports"
cd "$TARGET" || exit 1

for t in "${TAGS[@]}"; do
  if ! git checkout -q -f "$t" 2>/dev/null; then
    echo "MISS $t"
    continue
  fi
  files=$(find app lib -name '*.rb' 2>/dev/null | wc -l | tr -d ' ')
  BUNDLE_GEMFILE=$RIGOR/Gemfile bundle exec "$RIGOR/exe/rigor" check \
    --baseline="$BASE" --no-stats --format json \
    >"$SWEEP/reports/$t.json" 2>"$SWEEP/reports/$t.err"
  echo "done $t  (files=$files)"
done
echo "SWEEP COMPLETE"
