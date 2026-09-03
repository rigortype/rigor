require "rigor/testing"
include Rigor::Testing

# `Foo::BAR = …` is a constant write whose NAMESPACE is itself resolved through the
# nesting at the write site, so the entry `ScopeIndexer`'s constant census records has
# two halves that both depend on the enclosing declaration: the qualified name it is
# keyed under, and the class its rvalue names. One parameter carried both roles, so the
# path form passed it EMPTY and lost the two together — the entry went under the
# as-written `Holder::DEFAULT`, and the rvalue was typed as though written at the top
# level (https://github.com/rigortype/rigor/issues/690).
#
# The two halves compound rather than adding up. A read spelled `Admin::Holder::DEFAULT`
# reached no entry at all and answered `Dynamic[top]`, while the in-namespace spelling
# `Holder::DEFAULT` fell past the qualified rung of the lexical ladder to the bare one,
# hit the mis-keyed entry, and got a top-level class of the same name — `undefined
# method` on correct code. Fixing only the rvalue leaves the first; fixing only the key
# leaves the second.
#
# Every write below is asserted through BOTH read spellings where they differ, and each
# assertion is followed by a call only the correctly-resolved class owns (declared in
# `sig/` so `call.undefined-method` can fire at all), so a wrong answer FIRES rather than
# merely widening.

# The classes a write's RVALUE can name.
class Post
end

module Admin
  class Post
  end
end

# The namespaces a write's PATH can name. Both spellings exist, which is what makes the
# namespace resolution observable at all.
class Registry
end

module Admin
  class Registry
  end
end

class Loner
end

# TOP LEVEL — must be unchanged. Nothing encloses the write, so the key is the spelling
# and the rvalue names `::Post`.
Registry::PLAIN = Post

# NESTED enclosing declaration. Nesting is `[Admin::PathNested, Admin]`, so the OUTER
# rung answers both halves: the namespace is `Admin::Registry`, and the rvalue `Post` is
# `Admin::Post`.
module Admin
  class PathNested
    Registry::NESTED = Post
  end
end

# COMPACT enclosing declaration, the same statement. Nesting is `[Admin::PathCompact]`
# alone, so neither half reaches `Admin`: `Admin::PathCompact::Registry` does not exist,
# so the namespace stays `::Registry` and the rvalue stays `::Post`. Stamping the nested
# chain on the compact spelling satisfies every nested assertion and fails these.
class Admin::PathCompact
  Registry::COMPACT = Post
end

# Must-still-succeed: nothing named `Loner` sits under `Admin::PathFallthrough` or under
# `Admin`, so the namespace is not attributable to the nesting and the key stays the
# as-written `Loner::FALLBACK`. The RVALUE still resolves through the nesting, which is
# what stops this arm from passing under a change that did nothing.
module Admin
  class PathFallthrough
    Loner::FALLBACK = Post
  end
end

# Must-still-succeed: `::Registry` names the top level unconditionally, so the key is
# `Registry::ROOTED` even though `Admin::Registry` exists and would win for the unrooted
# spelling one line up.
module Admin
  class PathRooted
    ::Registry::ROOTED = Post
  end
end

# The pair that must answer IDENTICALLY, and the reason the two above may not. When the
# INNERMOST declaration owns the namespace, the extra `Admin` rung the nested spelling
# contributes is never reached, so both spellings key the entry under their own owner and
# name their own `Value`.
class Admin::OwnCompact
  class Own
  end

  class Value
  end

  Own::MARK = Value
end

module Admin
  class OwnNested
    class Own
    end

    class Value
    end

    Own::MARK = Value
  end
end

class TopReader
  def read_plain
    assert_type("singleton(Post)", Registry::PLAIN)
    Registry::PLAIN.new.top_post
  end

  # The fully-qualified spelling of the nested write, which the mis-keyed entry could not
  # answer at all.
  def read_nested_qualified
    assert_type("singleton(Admin::Post)", Admin::Registry::NESTED)
    Admin::Registry::NESTED.new.admin_post
  end

  def read_compact
    assert_type("singleton(Post)", Registry::COMPACT)
    Registry::COMPACT.new.top_post
  end

  def read_fallthrough
    assert_type("singleton(Admin::Post)", Loner::FALLBACK)
    Loner::FALLBACK.new.admin_post
  end

  def read_rooted
    assert_type("singleton(Admin::Post)", Registry::ROOTED)
    Registry::ROOTED.new.admin_post
  end

  def read_own_compact
    assert_type("singleton(Admin::OwnCompact::Value)", Admin::OwnCompact::Own::MARK)
    Admin::OwnCompact::Own::MARK.new.own_marker
  end

  def read_own_nested
    assert_type("singleton(Admin::OwnNested::Value)", Admin::OwnNested::Own::MARK)
    Admin::OwnNested::Own::MARK.new.own_marker
  end
end

module Admin
  class NestedReader
    # The in-namespace spelling: the read that fell past the qualified rung to the bare
    # one, reached the mis-keyed entry, and got the top-level `Post`.
    def read_nested_relative
      assert_type("singleton(Admin::Post)", Registry::NESTED)
      Registry::NESTED.new.admin_post
    end
  end
end
