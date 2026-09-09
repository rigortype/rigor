#!/usr/bin/env bash
# Runs census_gap_sites.rb over the survey corpus. Must run inside the Flake
# shell (see tool/probe-693/README.md). $1 = output directory for the JSON rows.
set -uo pipefail
OUT="${1:-tool/probe-693/out}"
SURVEY="${SURVEY_ROOT:-/Users/megurine/repo/ruby/rigor-survey}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$OUT"

run() { # name root subdir...
  local name="$1" root="$2"; shift 2
  echo "== $name"
  PROBE693_FORMAT=json ruby "$HERE/tool/probe-693/census_gap_sites.rb" "$root" "$@" > "$OUT/$name.json" || return
  ruby "$HERE/tool/probe-693/census_gap_sites.rb" "$root" "$@"
}

run rigor            "$HERE"                        lib plugins
run mastodon         "$SURVEY/mastodon"             app lib
run gitlab           "$SURVEY/gitlab"               app lib
run redmine          "$SURVEY/redmine"              app lib
run rails            "$SURVEY/rails"                activerecord activesupport actionpack actionview activejob activemodel activestorage actionmailer actioncable
run dependabot-core  "$SURVEY/dependabot-core"      common bundler npm_and_yarn python go_modules
run concurrent-ruby  "$SURVEY/concurrent-ruby"      lib
run mail             "$SURVEY/mail"                 lib
run haml             "$SURVEY/haml"                 lib
run faraday          "$SURVEY/faraday"              lib
run liquid           "$SURVEY/liquid"               lib
run parser           "$SURVEY/parser"               lib
run rubocop-ast      "$SURVEY/rubocop-ast"          lib
run kramdown         "$SURVEY/kramdown"             lib
