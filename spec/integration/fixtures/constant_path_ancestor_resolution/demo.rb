require "rigor/testing"
include Rigor::Testing

# https://github.com/rigortype/rigor/issues/656 — a constant PATH whose
# head and tail have DIFFERENT owners. Ruby resolves `A::B` in two
# phases: `A` through `Module.nesting` (then the enclosing class's
# ancestors, then the top level), and `B` inside whatever `A` produced,
# searching THAT constant's own ancestors. So inside `P::Guard`, with
# `P::A < P::Base`, `A::B` names `P::Base::B`.
#
# Every candidate the old whole-path walk could build — `P::Guard::A::B`,
# `P::A::B`, `A::B` — either misses or names a real but DIFFERENT class,
# and the analyzer then type-checked against that different class:
# `undefined method 'base_b'` fired on the read, the `is_a?` body and the
# `when` body of correct code at once. MRI 4.0.5 is the ground truth used
# throughout this fixture.

# The shadow the wrong answer used to reach. Nothing under `P` is named
# `A::B`, so this is the class every unwalked candidate fell back to.
class A
  class B
    def toplevel_only
      "toplevel"
    end
  end
end

module P
  class Base
    class B
      def base_b
        "base"
      end
    end
  end

  # A mixin owner: the six real sites the issue's survey found on gitlab
  # all arrive through an `include` edge, and a superclass-only walk finds
  # none of them.
  module Mixin
    class M
      def mixin_m
        "mixin"
      end
    end
  end

  class A < Base
  end

  class Includer
    include Mixin
  end

  class Guard
    # The read position. `A` resolves lexically to `P::A`; `B` is owned by
    # `P::A`'s superclass.
    def read
      assert_type("singleton(P::Base::B)", A::B)
      A::B.new.base_b
    end

    # The same lookup across an `include` edge rather than a superclass.
    def read_through_include
      assert_type("singleton(P::Mixin::M)", Includer::M)
    end

    # The guard positions. Both narrow through the same resolver as the
    # read, so all three shapes have to agree on the class they name.
    def by_is_a(other)
      return unless other.is_a?(A::B)

      assert_type("P::Base::B", other)
      other.base_b
    end

    def by_case_when(other)
      case other
      when A::B
        assert_type("P::Base::B", other)
        other.base_b
      end
    end

    # Must-still-succeed 1: a rooted path names the top level, ancestors
    # or no ancestors.
    def rooted(other)
      return unless other.is_a?(::A::B)

      assert_type("A::B", other)
      other.toplevel_only
    end
  end

  # Must-still-succeed 2: the head segment itself resolved through the
  # enclosing class's ancestors, which the whole-path walk already
  # answered because `Head::Leaf` is owned outright by one prefix. Pinned
  # so the segment-wise walk cannot regress it.
  class Base2
    class Head
      class Leaf
        def leaf
          "leaf"
        end
      end
    end
  end

  class Sub < Base2
    def head_via_ancestor
      assert_type("singleton(P::Base2::Head::Leaf)", Head::Leaf)
    end
  end
end

# Must-still-succeed 3: a path with no ancestor involvement resolves
# exactly as before. `A` here is the top-level one and owns `B` itself,
# so the walk must answer the same class the bare candidate always did.
class TopLevelReader
  def read
    assert_type("singleton(A::B)", A::B)
    A::B.new.toplevel_only
  end
end
