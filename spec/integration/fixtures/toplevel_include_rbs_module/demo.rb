require "rigor/testing"

# Issue #1697 — the module is declared only in `sig/`. A top-level `include`
# mixes it into `Object`, so every call below is defined and silent. Issue
# #1715 types the bare call in a top-level statement from the module's
# signature, and nothing else: not a call with a receiver, nor one in a block.

include Greeting

count = greeting_count
Rigor.assert_type("Integer", count)
label = "text".greeting_label
Rigor.assert_type("Dynamic[top]", label)
in_block = [1].map { greeting_count }
Rigor.assert_type("[Dynamic[top]]", in_block)
