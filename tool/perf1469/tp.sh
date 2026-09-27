#!/usr/bin/env bash
S=/private/tmp/claude-501/-Users-megurine-repo-ruby-rigor/38fdd4f0-0fca-4da7-8666-f84625e7e0ae/scratchpad/sweep-1469
REPO=/Users/megurine/repo/ruby/rigor
sha=$(git -C $REPO rev-parse "$1")
mkdir -p $S/probes; arm=$S/arms/$sha
[ -d $arm/lib ] || { mkdir -p $arm; git -C $REPO archive $sha lib sig plugins data exe | tar -x -C $arm; }
cd $S/t039 && BUNDLE_GEMFILE=$REPO/Gemfile bundle exec ruby $S/tp.rb $arm $S/probes/$1-tp.json 2>&1 | grep -v "warning:" | tail -3
