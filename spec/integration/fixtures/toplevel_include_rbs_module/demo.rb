require "rigor/testing"

# Issue #1697 — the module is declared only in `sig/`. A top-level `include`
# mixes it into `Object`, so every call below is defined and silent. Issue
# #1715 types a bare call in a top-level statement from the module's
# signature only under a whole-project pre-pass, whose census says no file
# defines the name; this harness indexes one file without it, so even that
# call stays `Dynamic[top]` here, as it does in an editor's per-buffer run.

include Greeting

count = greeting_count
Rigor.assert_type("Dynamic[top]", count)
label = "text".greeting_label
Rigor.assert_type("Dynamic[top]", label)
in_block = [1].map { greeting_count }
Rigor.assert_type("[Dynamic[top]]", in_block)
