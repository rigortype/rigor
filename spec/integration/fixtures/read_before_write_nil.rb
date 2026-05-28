require "rigor/testing"
include Rigor::Testing

# B2.3 — read-before-write nil contribution (ROADMAP § Future
# cycles / Type-language / engine; tracked in
# `docs/CURRENT_WORK.md` § "Flow-folding" — G2 case 3).
#
# Without the contribution: a method body that reads `@x`
# BEFORE writing it would seed `@x` to its eventually-written
# rvalue only — e.g. `unless @warning_issued; ...;
# @warning_issued = true` produces `@x: Constant[true]`, so
# `unless @warning_issued` predicate folds to always-truthy
# (sense-inverted) and a false `flow.always-truthy-condition`
# fires.
#
# The fix detects in-order read-before-write per method body
# and contributes `Constant[nil]` to the class-wide
# accumulator when:
# (a) some method body observed read-before-write for the
#     ivar, AND
# (b) `initialize` does NOT write the ivar, AND
# (c) no class-body level `@x = …` write exists, AND
# (d) the accumulator has an existing entry to add nil to.
#
# Worked site: Mastodon
# `lib/chewy/strategy/bypass_with_warning.rb#update`.

class BypassWithWarning
  def update
    if @warning_issued
      "skip"
    else
      "first call"
    end
    @warning_issued = true
  end
end

# Symmetric sense-inverted variant.
class FirstCallSentinel
  def call!
    return if @done

    @done = true
    "first-call work"
  end
end
