require "rigor/testing"
include Rigor::Testing

# Methods unlocked by extracting the Set catalog from `Init_Set`
# in `references/ruby/set.c`. Set has no `set.rb` prelude on
# Ruby 3.2+ — the C side calls `rb_provide("set.rb")` so a
# `require "set"` against the built-in is a no-op. The catalog
# captures the Init_Set block directly.

# `Set#size` / `#length` / `#count` tighten through ShapeDispatch's
# `SIZE_RETURNING_NOMINALS` projection (a `Nominal[Set]` receiver
# returns `non-negative-int` rather than the RBS-declared
# `Integer`). `Set.new([…])` yields a `Nominal[Set]`; the chained
# `#size` call observes the projection.
s = Set.new([1, 2, 3])
assert_type("non-negative-int", s.size)
assert_type("non-negative-int", s.length)

# `Set#empty?` is RBS-declared `bool`. The catalog's `:leaf`
# entry confirms the underlying C body has no dispatch; the
# wider type stays the bool union (`false | true`) until a
# refinement carrier like the empty-removal projection is added
# for Set in a follow-up slice.
assert_type("false | true", s.empty?)

# `Set#include?` and its `member?` alias both classify as `:leaf`
# and route through the catalog. The result type is the
# RBS-declared `bool`.
assert_type("false | true", s.include?(2))
assert_type("false | true", s.member?(4))

# Mutating selectors are blocklisted — even though the C-body
# classifier flagged `Set#initialize_copy`, `#compare_by_identity`,
# and `#reset` as `:leaf`, each one mutates the receiver's
# internal table through a helper (`set_copy`,
# `set_reset_table_with_type`) the regex did not follow. The
# blocklist keeps the fold inert and the RBS tier answers with
# `Nominal[Set]` instead.
assert_type("Set", s.compare_by_identity)

# Bang mutators on a Nominal[Set] return `self` per RBS — the
# catalog never folds them (universal bang block) and the RBS
# projection answers `Set`.
assert_type("Set", s.clear)
