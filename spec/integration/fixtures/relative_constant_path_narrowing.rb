require "rigor/testing"
include Rigor::Testing

# A class-membership guard written as a RELATIVE constant PATH
# (`Nested::Leaf`, not the single name `Leaf`) MUST resolve the same
# way Ruby resolves it: the path's first segment is anchored through
# `Module.nesting`, so inside `Bar` the guard names `Bar::Nested::Leaf`.
#
# Narrowing to the source spelling instead left the guarded receiver an
# unknown nominal, and every reader called on it degraded to
# `Dynamic[top]` — the ~300 opaque sites in rigor's own `lib/` that
# https://github.com/rigortype/rigor/issues/635 reports.
#
# The same resolution applies to every class-membership shape, so each
# of `is_a?`, `case`/`when` and `Class === x` is asserted below.

module Outerish
  class Thing
    def top_level_thing
      "top"
    end
  end
end

# Reachable only as the as-written spelling from inside `Bar` — nothing
# under `Bar` shadows `Far`.
module Far
  class Thing
    def far_thing
      "far"
    end
  end
end

module Bar
  module Nested
    class Leaf
      def leaf_only
        "leaf"
      end
    end
  end

  # Shadows the top-level `Outerish` for anything lexically inside `Bar`.
  module Outerish
    class Thing
      def nested_thing
        "nested"
      end
    end
  end

  class Guard
    def by_is_a(other)
      if other.is_a?(Nested::Leaf)
        assert_type('Bar::Nested::Leaf', other)
      end
    end

    def by_case_when(other)
      case other
      when Nested::Leaf
        assert_type('Bar::Nested::Leaf', other)
      end
    end

    def by_case_equality(other)
      if Nested::Leaf === other
        assert_type('Bar::Nested::Leaf', other)
      end
    end

    # The nearer `Bar::Outerish::Thing` shadows the top-level one, exactly
    # as Ruby's own lookup would.
    def shadowed_path(other)
      if other.is_a?(Outerish::Thing)
        assert_type('Bar::Outerish::Thing', other)
      end
    end

    # Must-still-succeed 1: a rooted path opts out of the nesting walk and
    # names the top-level constant even where a nearer one exists.
    def rooted_path(other)
      if other.is_a?(::Outerish::Thing)
        assert_type('Outerish::Thing', other)
      end
    end

    # Must-still-succeed 2: the walk's FALL-THROUGH, inside a non-empty
    # nesting. Nothing under `Bar` owns a `Far`, so every candidate the
    # chain builds (`Bar::Guard::Far::Thing`, `Bar::Far::Thing`) must miss
    # and the as-written spelling must survive. Without this the suite has
    # no multi-segment case where the walk is required to find nothing —
    # a walk that adopted its first candidate unconditionally would pass
    # every other example in this fixture.
    def multi_segment_fall_through(other)
      if other.is_a?(Far::Thing)
        assert_type('Far::Thing', other)
        other.far_thing
      end
    end

    # The `when` twin of the same fall-through: this shape resolved nothing
    # at all before #635, so it is the one most likely to over-resolve now.
    def multi_segment_fall_through_when(other)
      case other
      when Far::Thing
        assert_type('Far::Thing', other)
        other.far_thing
      end
    end
  end
end

# Must-still-succeed 3: at the top level there is no nesting to walk, so a
# qualified path keeps naming what it spells.
class TopLevelGuard
  def call(other)
    if other.is_a?(Outerish::Thing)
      assert_type('Outerish::Thing', other)
    end
  end
end

# `case`/`when` and `===` did not walk the nesting AT ALL before #635, so
# even a BARE name in a `when` answered the top-level namesake. That is
# not only lost precision: `case message when Monitor` inside
# `Concurrent::ErlangActor` narrowed to the stdlib `::Monitor` and
# reported `undefined method 'from'` on the very next line, on correct
# code. `Beacon` below is that shape.

class Beacon
  def top_level_beacon
    "top"
  end
end

# No namesake anywhere under `Bar`, so the walk must fall through to it.
class Sentinel
  def sentinel
    "sentinel"
  end
end

module Bar
  module Nested
    class Beacon
      def nested_beacon
        "nested"
      end
    end

    class BareNameGuard
      def by_case_when(other)
        case other
        when Beacon
          assert_type('Bar::Nested::Beacon', other)
          other.nested_beacon
        end
      end

      def by_case_equality(other)
        if Beacon === other
          assert_type('Bar::Nested::Beacon', other)
        end
      end

      # Must-still-succeed: a bare name with no lexically nearer owner
      # still answers the top level.
      def unshadowed_bare_name(other)
        case other
        when Sentinel
          assert_type('Sentinel', other)
          other.sentinel
        end
      end
    end
  end
end

# The false-positive arm, in the exact shape concurrent-ruby hit: the
# shadowed name belongs to a class RBS knows completely, so the
# dispatcher DOES resolve against it and DOES fire. `Random` stands in
# for `Monitor`.
module Bar
  module Nested
    class Random
      def nested_only
        "nested"
      end
    end

    class StdlibShadowGuard
      def call(other)
        case other
        when Random
          assert_type('Bar::Nested::Random', other)
          other.nested_only
        end
      end
    end
  end
end

# Must-still-succeed: nothing shadows `Random` here, so the core class
# still answers and its own method still resolves.
class CoreRandomGuard
  def call(other)
    case other
    when Random
      assert_type('Random', other)
      other.rand
    end
  end
end
