#!/usr/bin/env bash
# usage: drive.sh MAX  -- measures up to MAX not-yet-measured arms from queue.txt, sequentially
S=/private/tmp/claude-501/-Users-megurine-repo-ruby-rigor/38fdd4f0-0fca-4da7-8666-f84625e7e0ae/scratchpad/sweep-1469
REPO=/Users/megurine/repo/ruby/rigor
MAX=${1:-20}; n=0
touch $S/results.jsonl
cd $S/t039
while read -r sha; do
  grep -q "\"sha\":\"$sha\"" $S/results.jsonl && continue
  [ $n -ge $MAX ] && break
  arm=$S/arms/$sha
  rm -rf $arm; mkdir -p $arm
  git -C $REPO archive $sha lib sig plugins data exe | tar -x -C $arm
  line=$(BUNDLE_GEMFILE=$REPO/Gemfile bundle exec ruby $S/measure.rb $arm $S/outs/$sha.json 2>/dev/null | tail -1)
  [ -z "$line" ] && line="{\"crash\":true}"
  echo "{\"sha\":\"$sha\",\"r\":$line}" >> $S/results.jsonl
  echo "$sha $line" | cut -c1-160
  rm -rf $arm
  n=$((n+1))
done < $S/queue.txt
