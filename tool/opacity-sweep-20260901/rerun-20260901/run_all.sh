#!/usr/bin/env bash
# Re-run the 2026-09-01 opacity probe over the full sweep corpus on current master.
# Run INSIDE the flake shell, cwd = rigor repo root.
set -u
SCRATCH=/private/tmp/claude-501/-Users-megurine-repo-ruby-rigor/9c04b607-db62-40e1-a460-af9f45f9d21a/scratchpad/opacity
SURVEY=/Users/megurine/repo/ruby/rigor-survey
PROBE=$SCRATCH/probe_attrib.rb
OUT=$SCRATCH/out
mkdir -p "$OUT"

run_one() {
  local name="$1" dir="$2"; shift 2
  if [ -s "$OUT/$name.json" ]; then echo "skip $name (exists)"; return 0; fi
  echo "start $name"
  if bundle exec ruby "$PROBE" "$dir" "$OUT/$name.json" "$@" > "$OUT/$name.log" 2>&1; then
    echo "done  $name: $(tail -1 "$OUT/$name.log")"
  else
    echo "FAIL  $name (see $OUT/$name.log)"
  fi
}

# Small/medium targets first, big three last (they dominate wall time).
run_one erubi        "$SURVEY/erubi"
run_one jbuilder     "$SURVEY/jbuilder"
run_one rgl          "$SURVEY/rgl"
run_one algorithms   "$SURVEY/algorithms"
run_one ox           "$SURVEY/ox"
run_one oj           "$SURVEY/oj"
run_one rbnacl       "$SURVEY/rbnacl"
run_one pycall       "$SURVEY/pycall"
run_one protobuf     "$SURVEY/protobuf"
run_one numo-narray  "$SURVEY/numo-narray"
run_one tdiary-core  "$SURVEY/tdiary-core"
run_one slim         "$SURVEY/slim"
run_one hamlit       "$SURVEY/hamlit"
run_one haml         "$SURVEY/haml"
run_one herb         "$SURVEY/herb"
run_one liquid       "$SURVEY/liquid"
run_one kramdown     "$SURVEY/kramdown"
run_one faraday      "$SURVEY/faraday"
run_one net-ssh      "$SURVEY/net-ssh"
run_one mail         "$SURVEY/mail"
run_one concurrent-ruby "$SURVEY/concurrent-ruby"
run_one rubocop-ast  "$SURVEY/rubocop-ast"
run_one parser       "$SURVEY/parser"
run_one textbringer  "$SURVEY/textbringer"
run_one Ruby         "$SURVEY/Ruby" .
run_one Algorithms-and-Data-Structures-in-Ruby "$SURVEY/Algorithms-and-Data-Structures-in-Ruby" .
run_one Data-Structures-and-Algorithms-in-Ruby "$SURVEY/Data-Structures-and-Algorithms-in-Ruby" .
run_one rigor-lib    "/Users/megurine/repo/ruby/rigor" lib
run_one redmine      "$SURVEY/redmine"
run_one mastodon     "$SURVEY/mastodon"
echo ALL-DONE
