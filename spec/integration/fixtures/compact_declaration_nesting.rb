require "rigor/testing"
include Rigor::Testing

# `Module.nesting` inside a COMPACT declaration (`class Admin::CompactController`)
# is `[Admin::CompactController]` alone — Ruby never pushes the enclosing
# `Admin` — so a bare `Post` written there names the TOP-LEVEL `::Post`. The
# nested spelling of the very same class pushes two entries and does reach
# `Admin::Post`. Both render the identical qualified name, so the distinction
# survives only if it is recorded while the walk is inside the declaration
# (https://github.com/rigortype/rigor/issues/652).
#
# Reconstructing the chain by peeling that name answered `Admin::Post` for
# both, which is a wrong type on correct code and then a
# `call.undefined-method` at the next call. The peel was shared by the
# constant typer and by `Inference::Narrowing`'s class guards, so the repair
# has to hold for all four shapes at once: a plain constant read, `is_a?`,
# `case`/`when` and `Class === x`. Each is asserted twice below — once in the
# compact spelling and once in the nested one — because an implementation
# that simply stopped walking would pass every compact example and none of
# the nested twins.

class Post
  def top_post
    "top"
  end
end

LABEL = :top

module Admin
  class Post
    def admin_post
      "admin"
    end
  end

  LABEL = :admin
end

# COMPACT. Nesting is `[Admin::CompactController]`, so `Post` is `::Post`.
class Admin::CompactController
  def by_constant_read
    assert_type(':top', LABEL)
  end

  def by_is_a(other)
    if other.is_a?(Post)
      assert_type('Post', other)
      other.top_post
    end
  end

  def by_case_when(other)
    case other
    when Post
      assert_type('Post', other)
      other.top_post
    end
  end

  def by_case_equality(other)
    if Post === other
      assert_type('Post', other)
      other.top_post
    end
  end

  # A `class << self` body rewrites the innermost frame in place rather than
  # pushing one, so the recorded chain carries through and the singleton side
  # answers the same constant the instance side does.
  class << self
    def singleton_constant_read
      assert_type(':top', LABEL)
    end
  end
end

# NESTED, same class name. Nesting is `[Admin::NestedController, Admin]`, so
# `Post` is `Admin::Post` — the must-still-succeed twin of every example above.
module Admin
  class NestedController
    def by_constant_read
      assert_type(':admin', LABEL)
    end

    def by_is_a(other)
      if other.is_a?(Post)
        assert_type('Admin::Post', other)
        other.admin_post
      end
    end

    def by_case_when(other)
      case other
      when Post
        assert_type('Admin::Post', other)
        other.admin_post
      end
    end

    def by_case_equality(other)
      if Post === other
        assert_type('Admin::Post', other)
        other.admin_post
      end
    end
  end
end

# A compact declaration nested inside another declaration contributes exactly
# one entry, qualified against the entry already on top: `[Wrap::Deep::Leaf,
# Wrap]`, never the intermediate `Wrap::Deep`. `Marker` is owned by `Wrap`, so
# the outer rung must still answer while `Wrap::Deep`'s own `Marker` must not.
module Wrap
  class Marker
    def wrap_marker
      "wrap"
    end
  end

  module Deep
    class Marker
      def deep_marker
        "deep"
      end
    end
  end

  class Deep::Leaf
    def call(other)
      if other.is_a?(Marker)
        assert_type('Wrap::Marker', other)
        other.wrap_marker
      end
    end
  end
end

# Must-still-succeed: the ANCESTOR rung of the ladder, reached from a compact
# declaration. `KEY` is owned by the superclass rather than by any nesting
# entry, so step 2 has to answer it — the rung this change leaves alone.
class Ancestral
  KEY = :inherited
end

class Admin::Descendant < Ancestral
  def key
    assert_type(':inherited', KEY)
  end
end

# Must-still-succeed: nothing named `Loner` sits under `Admin`, so the compact
# body's single nesting entry must miss and the top level must answer. Without
# this the fixture has no compact case where the walk is required to find
# nothing, and an implementation that resolved its first candidate
# unconditionally would still pass everything above.
class Loner
  def loner
    "loner"
  end
end

class Admin::FallThrough
  def call(other)
    if other.is_a?(Loner)
      assert_type('Loner', other)
      other.loner
    end
  end
end
