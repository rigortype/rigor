require "rigor/testing"

# Issue #1697 — the module is declared only in `sig/`. A top-level `include`
# mixes it into `Object`, so both calls below are defined and silent; neither
# is typed through the mixin until #1715.

include Greeting

count = greeting_count
Rigor.assert_type("Dynamic[top]", count)
label = "text".greeting_label
Rigor.assert_type("Dynamic[top]", label)
