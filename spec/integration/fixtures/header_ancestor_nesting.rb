require "rigor/testing"
include Rigor::Testing

# The cref an ANCESTOR NAME is resolved in
# (https://github.com/rigortype/rigor/issues/682).
#
# Ruby evaluates a superclass expression BEFORE entering the body, so the
# `Module.nesting` that governs it is the one the declaration's HEADER sits in.
# The engine reconstructed that by peeling the SUBCLASS's qualified name one
# `::` segment at a time, which is the NESTED spelling's chain handed to both
# spellings: `class Admin::Widget < Base` written at the top level searched an
# `Admin::Base` Ruby never looks at.
#
# Every arm is written twice — once compact, once nested — because an
# implementation that simply stopped peeling satisfies each compact assertion
# and no nested twin, and the peel satisfies the reverse. `by_two_hops` is the
# arm no first-hop-only repair reaches: the class whose header nesting decides
# the answer is not the one the walk started from.
#
# The last two lines are the must-fire arms, and they use the same technique the
# rooted-header fixture does: `call.undefined-method` declines on a receiver
# whose class RBS does not know, and declaring these classes in a `sig/` would
# hand RBS an ancestry that CONTRADICTS the source and decide the question
# itself. So the diagnostic is taken one call further along, on the Symbol the
# resolved ancestor's method returns — a receiver RBS does know.

class Base
  KEY = :top_key
  def top_val = :top_val
end

module Admin
  class Base
    KEY = :admin_key
    def admin_val = :admin_val
  end
end

# COMPACT at the top level. The header's cref is EMPTY, so `Base` is `::Base`.
class Admin::Widget < Base
  def by_inherited_method
    assert_type(':top_val', top_val)
  end

  def by_ancestor_constant
    assert_type(':top_key', KEY)
  end
end

# NESTED twin, and the must-stay-unchanged arm: the header sits in `[Admin]`,
# so the same bare `Base` names `Admin::Base`.
module Admin
  class Nested < Base
    def by_inherited_method
      assert_type(':admin_val', admin_val)
    end

    def by_ancestor_constant
      assert_type(':admin_key', KEY)
    end
  end
end

# TWO HOPS. `Admin::Leaf`'s own superclass name resolves the same way under the
# peel and under the recorded chain; it is the SECOND hop, from `Admin::Middle`
# — declared compactly — that the peel gets wrong.
class Admin::Middle < Base
end

module Admin
  class Leaf < Middle
    def by_two_hops
      assert_type(':top_val', top_val)
    end

    def by_two_hop_constant
      assert_type(':top_key', KEY)
    end
  end
end

# The include half of the same question. `include` is written inside the body,
# but the candidate order it walks is the same one.
module Helper
  def top_helper = :top_helper
end

module Admin
  module Helper
    def admin_helper = :admin_helper
  end
end

class Admin::Mixed
  include Helper

  def by_included_method
    assert_type(':top_helper', top_helper)
  end
end

module Admin
  class NestedMixed
    include Helper

    def by_included_method
      assert_type(':admin_helper', admin_helper)
    end
  end
end

# The same question through an EXPLICIT receiver, which is the shape the
# cross-class ancestor walk answers rather than the implicit-self one.
class Reader
  def read_compact
    assert_type(':top_val', Admin::Widget.new.top_val)
  end

  def read_mixed
    assert_type(':top_helper', Admin::Mixed.new.top_helper)
  end

  # The must-still-succeed twin: the nested spellings resolve to `Admin::Base` /
  # `Admin::Helper` on both sides, so these calls must keep resolving.
  def read_nested
    assert_type(':admin_val', Admin::Nested.new.admin_val)
  end

  def read_nested_mixed
    assert_type(':admin_helper', Admin::NestedMixed.new.admin_helper)
  end
end

# The must-fire pair. The compact half reported NOTHING on master, because the
# receiver reached `Admin::Base`, resolved no `top_val`, and typed opaque; the
# nested half fired there and must keep firing.
Admin::Widget.new.top_val.nope
Admin::Nested.new.admin_val.nope
