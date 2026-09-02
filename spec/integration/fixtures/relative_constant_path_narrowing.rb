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

    # Must-still-succeed 2: a path with no lexically nearer owner still
    # falls through to the spelling as written.
    def unshadowed_path(other)
      if other.is_a?(Nested::Leaf)
        assert_type('Bar::Nested::Leaf', other)
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
