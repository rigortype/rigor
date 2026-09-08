#!/bin/bash
set -u
S=/private/tmp/claude-501/-Users-megurine-repo-ruby-rigor/d5c4b586-ae43-410a-bb0b-b68b8a11a46d/scratchpad
WT=/Users/megurine/repo/ruby/rigor-wt/perf-bisect-775
NIX=/nix/var/nix/profiles/default/bin/nix
OUT=$S/sweep.csv
cd "$WT" || exit 1
echo "sha,files,lines,allocations,wall_s,diagnostics" > "$OUT"
for sha in $(cat "$S/${1:-shas.txt}"); do
  if ! git checkout -q --detach "$sha"; then echo "$sha,checkout-failed" >> "$OUT"; continue; fi
  files=$(find lib -name '*.rb' | wc -l | tr -d ' ')
  lines=$(find lib -name '*.rb' -print0 | xargs -0 cat | wc -l | tr -d ' ')
  RIGOR_DISABLE_YJIT=1 "$NIX" --extra-experimental-features 'nix-command flakes' develop --command \
    bundle exec ruby tool/bench.rb --target lib --baseline /dev/null --write-baseline "$S/runs/$sha.json" > "$S/runs/$sha.log" 2>&1
  alloc=$(grep -o '"allocations": [0-9]*' "$S/runs/$sha.json" | grep -o '[0-9]*$')
  wall=$(grep -o '"wall_s": [0-9.]*' "$S/runs/$sha.json" | grep -o '[0-9.]*$')
  diag=$(grep -o '"diagnostics": [0-9a-z]*' "$S/runs/$sha.json" | awk '{print $2}')
  echo "$sha,$files,$lines,${alloc:-NA},${wall:-NA},${diag:-NA}" >> "$OUT"
done
echo DONE >> "$OUT"
