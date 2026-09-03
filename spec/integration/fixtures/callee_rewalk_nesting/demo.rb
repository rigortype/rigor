require "rigor/testing"
include Rigor::Testing

# The RETURN-INFERENCE re-walk of a callee body, and the last member of the
# `Module.nesting` family (https://github.com/rigortype/rigor/issues/681).
#
# `Inference::ExpressionTyper#build_user_method_body_scope` rebuilds a callee's
# body scope from the RECEIVER'S TYPE when it needs that callee's return, and a
# scope built from a self type alone carries no recorded chain — so
# `Reflection.lexical_nesting_chain` fell back to peeling the qualified name,
# which cannot tell a compact `class Admin::CompactMaker` from the nested
# spelling of the same class. The same `Post.new` therefore resolved one way on
# the line that writes it and another way through the value's consumer.
#
# Every arm is written TWICE — once compact, once nested — because an
# implementation that simply stopped walking satisfies the compact half and
# fails every nested twin. The call after each assertion is owned by exactly one
# of the two candidate classes, so a wrong resolution FIRES
# `call.undefined-method` instead of merely widening; the markers live in `sig/`
# because that rule declines on a receiver RBS does not know.

class Post
end

module Admin
  class Post
  end
end

# COMPACT. Nesting is `[Admin::CompactMaker]`, so `Post` is `::Post` — on the
# line that writes it and in the re-walk that infers `make`'s return alike.
class Admin::CompactMaker
  def make
    Post.new
  end

  def self.build
    Post.new
  end

  def via_callee
    assert_type('Post', make)
    make.top_post
  end

  def via_singleton_callee
    assert_type('Post', Admin::CompactMaker.build)
    Admin::CompactMaker.build.top_post
  end
end

# NESTED, and the must-still-succeed twin: nesting is `[Admin::NestedMaker,
# Admin]`, so the same bare `Post` names `Admin::Post` and only
# `Admin::Post#admin_post` resolves.
module Admin
  class NestedMaker
    def make
      Post.new
    end

    def self.build
      Post.new
    end

    def via_callee
      assert_type('Admin::Post', make)
      make.admin_post
    end

    def via_singleton_callee
      assert_type('Admin::Post', Admin::NestedMaker.build)
      Admin::NestedMaker.build.admin_post
    end
  end
end

# The chain has to follow the CALLEE's declaration, not the reader's: no
# same-class pair can tell the two apart. `Reader` is written nested and the
# value it receives is still `::Post`, because that is where the compact
# `Admin::CompactMaker#make` built it.
module Admin
  class Reader
    def read
      maker = Admin::CompactMaker.new
      assert_type('Post', maker.make)
      maker.make.top_post
    end
  end
end

# The same distinction across an INHERITED def, which is where keying the chain
# on the receiver's class rather than on the declaration that owns the body
# diverges from Ruby. `make` is declared once in each spelling and called on a
# subclass written in the other, so each arm answers the constant its OWNER
# names, not the one its receiver's spelling would suggest.
class Admin::CompactBase
  def make
    Post.new
  end
end

module Admin
  class NestedBase
    def make
      Post.new
    end
  end

  class InheritingChild < CompactBase
    def call
      assert_type('Post', make)
      make.top_post
    end
  end
end

class Admin::CompactChild < Admin::NestedBase
  def call
    assert_type('Admin::Post', make)
    make.admin_post
  end
end
