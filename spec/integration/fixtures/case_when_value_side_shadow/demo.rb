require "rigor/testing"
include Rigor::Testing

# https://github.com/rigortype/rigor/issues/655 — the VALUE side of a
# `case`. `case`/`when`'s narrowing side resolves the pattern through the
# lexical walk; the side that types the EXPRESSION matched at the
# environment level on the as-written spelling, so the two halves of one
# `case` could disagree.
#
# The disagreement is not symmetric with the narrowing side's documented
# rationale. That argument — an unresolvable pattern name orders as
# `:unknown`, yields `:maybe`, and so can only lose certainty — holds for
# a name nothing declares. A SHADOWED name is perfectly resolvable, to
# the wrong class, so the certainty answer comes back confident and wrong
# in the direction that DROPS a live arm: the expression types as a
# branch Ruby never takes, and the next call on it is then reported
# against the wrong class.
#
# The `case` is written INLINE at each site. Assigning it to a local
# routes the value through the flow side's union of branch scopes
# instead, which never consults per-pattern certainty at all.

module Bar
  module Nested
    class Random
      def nested_only
        "nested"
      end
    end

    class ValueSide
      # `other` is a core `::Random`; the pattern names
      # `Bar::Nested::Random`, which it can never be. Ruby's answer is
      # the `else` arm, and `.upcase` on it is a String method call.
      def shadowed_pattern_keeps_the_live_arm
        other = ::Random.new
        assert_type('"else"', (case other when Random then 1 else "else" end))
        (case other when Random then 1 else "else" end).upcase
      end

      # The narrowing side of the same `case`, asserted beside the value
      # side: both halves have to name one class for either answer to be
      # trustworthy.
      def narrowing_side_agrees(other)
        case other
        when Random
          assert_type("Bar::Nested::Random", other)
          other.nested_only
        end
      end
    end
  end
end

# Must-still-succeed: with nothing shadowing it, `when Random` still
# names the core class, the arm is still certainly taken, and the
# expression still types as that arm rather than degrading to the union.
class CoreRandomValueSide
  def unshadowed_pattern_still_decides
    other = ::Random.new
    assert_type("1", (case other when Random then 1 else "else" end))
    (case other when Random then 1 else "else" end).succ
  end
end

# Must-still-succeed: an undecidable subject keeps every arm. Without
# this the suite has no case where the certainty answer is required to
# stay `:maybe`, and an implementation that always answered `:no` would
# satisfy the shadowed example above.
class UndecidableValueSide
  def open_subject(other)
    assert_type('"else" | 1', (case other when Bar::Nested::Random then 1 else "else" end))
  end
end
