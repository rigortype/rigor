require "rigor/testing"
include Rigor::Testing

# `ScopeIndexer`'s census pre-passes type an rvalue WHERE IT IS WRITTEN — the
# class-ivar table from every `def` body, the class-cvar table the same way, and
# the in-source constant table from the class body itself. None of those walks
# enters the declaration through `StatementEvaluator`, so nothing recorded the
# body's `Module.nesting` and the reader fell back to peeling the qualified name
# off `self_type`. That peel is identical for a compact `class Admin::CompactCensus`
# (nesting `[Admin::CompactCensus]`, so a bare `Post` names `::Post`) and for the
# nested spelling (nesting `[Admin::NestedCensus, Admin]`, where it names
# `Admin::Post`), so `@post = Post.new` in an `initialize` and a `DEFAULT = Post`
# constant were both recorded under the wrong class
# (https://github.com/rigortype/rigor/issues/681).
#
# Every census is asserted twice — once compact, once nested — because an
# implementation that simply stopped walking satisfies every compact example and
# none of the nested twins, and the peel satisfies the reverse. Each assertion is
# followed by a call only the correctly-resolved class owns, so a wrong answer
# FIRES `call.undefined-method` rather than merely widening.

class Post
end

module Admin
  class Post
  end
end

class Loner
end

# COMPACT. Nesting is `[Admin::CompactCensus]`, so `Post` is `::Post`.
class Admin::CompactCensus
  class Own
  end

  DEFAULT = Post
  # Must-still-succeed: the compact body's single nesting entry has to be
  # CONSULTED, not skipped — stamping an empty chain passes every `::Post`
  # assertion above and fails this one.
  OWNED = Own

  def initialize
    @post = Post.new
    @own = Own.new
    # Must-still-succeed: nothing named `Loner` sits under `Admin::CompactCensus`,
    # so the single entry must miss and the top level must answer.
    @lone = Loner.new
  end

  def read_ivar
    assert_type('Post', @post)
    @post.top_post
  end

  def read_owned_ivar
    assert_type('Admin::CompactCensus::Own', @own)
    @own.own_marker
  end

  def read_fallthrough_ivar
    assert_type('Loner', @lone)
    @lone.loner
  end

  def read_constant
    assert_type('singleton(Post)', DEFAULT)
    DEFAULT.new.top_post
  end

  def read_owned_constant
    assert_type('singleton(Admin::CompactCensus::Own)', OWNED)
    OWNED.new.own_marker
  end

  def store_cvar
    @@klass = Post
  end

  def read_cvar
    assert_type('singleton(Post)', @@klass)
    @@klass.new.top_post
  end
end

# NESTED, same shape. Nesting is `[Admin::NestedCensus, Admin]`, so `Post` is
# `Admin::Post` — the must-still-succeed twin of every example above, and its own
# false-positive arm.
module Admin
  class NestedCensus
    class Own
    end

    DEFAULT = Post
    OWNED = Own

    def initialize
      @post = Post.new
      @own = Own.new
    end

    def read_ivar
      assert_type('Admin::Post', @post)
      @post.admin_post
    end

    def read_owned_ivar
      assert_type('Admin::NestedCensus::Own', @own)
      @own.own_marker
    end

    def read_constant
      assert_type('singleton(Admin::Post)', DEFAULT)
      DEFAULT.new.admin_post
    end

    def read_owned_constant
      assert_type('singleton(Admin::NestedCensus::Own)', OWNED)
      OWNED.new.own_marker
    end

    def store_cvar
      @@klass = Post
    end

    def read_cvar
      assert_type('singleton(Admin::Post)', @@klass)
      @@klass.new.admin_post
    end
  end
end
