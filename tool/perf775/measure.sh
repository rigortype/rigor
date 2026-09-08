#!/bin/bash
# usage: measure.sh <label>   (run from the tree under test)
S=/private/tmp/claude-501/-Users-megurine-repo-ruby-rigor/d5c4b586-ae43-410a-bb0b-b68b8a11a46d/scratchpad
label=$1
RIGOR_DISABLE_YJIT=1 /nix/var/nix/profiles/default/bin/nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec ruby $S/measure.rb $S/out_$label.json lib 2>&1 | tail -1
if cmp -s $S/out_$label.json $S/ref_lib_master.json; then echo "output: BYTE-IDENTICAL to master"; else echo "output: DIFFERS from master"; diff <(python3 -m json.tool $S/ref_lib_master.json) <(python3 -m json.tool $S/out_$label.json) | head -20; fi
