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

# A target that renders NO static path is not a fourth "keep the as-written key" form, and
# must not be keyed by the lenient render of its constant segments. `self::SELF_DEFAULT`
# names `Admin::SELF_DEFAULT` and its rvalue is `Admin::Post`, so the bare key would file an
# `Admin::Post` under the name of the RBS-declared top-level constant and hand every reader
# of `::SELF_DEFAULT` a receiver Ruby never names there.
module Admin
  self::SELF_DEFAULT = Post
end

# …and `self` is not always the enclosing declaration. `Evalled.class_eval { … }` swaps `self`
# for the RECEIVER while leaving `Module.nesting` alone, so `self::MARK` names
# `Admin::Evalled::MARK` and the rvalue `Post` still resolves through the untouched nesting to
# `Admin::Post`. Keying it by the lexical enclosure files that `Admin::Post` under `Admin::MARK`,
# which is where the RBS-declared `Admin::MARK` reader finds it
# (https://github.com/rigortype/rigor/issues/705).
module Admin
  class Evalled
  end

  Evalled.class_eval { self::MARK = Post }
end

# Fixing the KEY is only half of it: the same swap moves the rvalue's `self`, and until it did, a wrong
# type merely sat under a key no read arrived at. `self` in the block is the receiver, and so is the
# receiver of an implicit-self call — while `Module.nesting` stays lexical, which is why the two halves
# come from different places at the same site. The bare twin needs the second half just as much: its key
# was always the lexical one, so it answered the enclosing module on master too.
module Admin
  def self.build = 1

  class Evalled
    def self.build = "s"
  end

  Evalled.class_eval { self::SELF_REF = self }
  Evalled.class_eval { self::VIA_CALL = build }
  Evalled.class_eval { BARE_SELF = self }
end

# A `class_eval` receiver that names no class leaves `self` unattributable, so the write is
# DECLINED — the same answer a dynamic base takes, and for the same reason.
module Admin
  target = Evalled
  target.class_eval { self::LOOSE = Post }
end

# A genuinely dynamic base names no attributable namespace at all, so the write is DECLINED
# rather than filed under its trailing segment.
module Dyn
  class Post
  end

  holder = Post
  holder::LATE = Post

  # The OVER-EAGER witness (https://github.com/rigortype/rigor/issues/705). A read from
  # INSIDE the writing module is the only position that can pin this direction: a key
  # qualified by the enclosing declaration (`Dyn::LATE`) sits on the INNERMOST rung of the
  # lexical ladder, so it outranks the RBS top-level `LATE` here while a top-level read
  # never reaches it. Guessing that key answers `singleton(Dyn::Post)` and fires
  # `undefined method 'top_post'` on this correct call.
  class Reader
    def read_dynamic_write_in_namespace
      assert_type("singleton(Post)", LATE)
      LATE.new.top_post
    end
  end
end

# The mutation census (#540) rides on the same key. `Table::ROWS[key] = 1` mutates
# whatever `Table::ROWS` names HERE, so the census has to reach the entry the write
# accumulator is now keyed under; left unmatched, the closed empty shape survives and
# `empty?` folds to `true` on a table the module fills, licensing the negative rules.
module Admin
  class Table
  end

  Table::ROWS = {}
  Table::FROZEN = {}

  def self.fill(key)
    Table::ROWS[key] = 1
  end

  def self.shapes
    assert_type("bool", Table::ROWS.empty?)
    # Must-still-succeed: an unmutated sibling keeps its empty-shape fold, so the arm
    # above cannot pass by the widener having gone blanket.
    assert_type("true", Table::FROZEN.empty?)
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

  # Must-still-succeed: `SELF_DEFAULT` here is the RBS-declared top-level constant, not the
  # `Admin::Post` the `self::` write put under `Admin::SELF_DEFAULT`.
  def read_self_write_from_top
    assert_type("singleton(Post)", SELF_DEFAULT)
    SELF_DEFAULT.new.top_post
  end

  # Must-still-succeed: the declined dynamic write leaves the RBS constant answering.
  def read_dynamic_write_from_top
    assert_type("singleton(Post)", LATE)
    LATE.new.top_post
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

    # The `self::` write's own namespace. Master answers the top-level `Post` off the
    # mis-keyed bare entry, which is the same defect one spelling further out.
    def read_self_write_in_namespace
      assert_type("singleton(Admin::Post)", SELF_DEFAULT)
      SELF_DEFAULT.new.admin_post
    end

    # The name the `class_eval` block actually writes — a resolution keying by the lexical
    # enclosure does not have at all.
    def read_class_eval_write
      assert_type("singleton(Admin::Post)", Evalled::MARK)
      Evalled::MARK.new.admin_post
    end

    # Must-still-succeed: the lexical enclosure is NOT what `self` named there, so `Admin::MARK`
    # is still the RBS-declared top-level `Post`.
    def read_class_eval_lexical_miss
      assert_type("singleton(Post)", MARK)
      MARK.new.top_post
    end

    # Must-still-succeed: the declined `class_eval` on an unnameable receiver leaves the RBS
    # `Admin::LOOSE` answering, exactly as the declined dynamic base leaves the top-level `LATE`.
    def read_loose_eval_write
      assert_type("singleton(Post)", LOOSE)
      LOOSE.new.top_post
    end

    # The rvalue's own `self`, which the key fix made reachable.
    def read_class_eval_self_rvalue
      assert_type("singleton(Admin::Evalled)", Evalled::SELF_REF)
      Evalled::SELF_REF.evalled_only
    end

    # An implicit-self call in the block dispatches on the receiver, not on the enclosing module — the two
    # own a `build` with different return types, so the wrong one fires rather than widening.
    def read_class_eval_implicit_self_call
      assert_type("String", Evalled::VIA_CALL)
      Evalled::VIA_CALL.upcase
    end

    # The BARE twin, whose key was never wrong and whose rvalue always was.
    def read_class_eval_bare_rvalue
      assert_type("singleton(Admin::Evalled)", BARE_SELF)
      BARE_SELF.evalled_only
    end
  end
end
