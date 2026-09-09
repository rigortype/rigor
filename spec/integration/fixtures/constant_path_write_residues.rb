require "rigor/testing"
include Rigor::Testing

# The two residues the adversarial review of https://github.com/rigortype/rigor/issues/690 found, both
# about the same word: a constant written through a PATH
# (https://github.com/rigortype/rigor/issues/703).

# ---- 1. A meta-new factory assigned through a path ----
#
# `Holder::Thing = Struct.new(:a) do … end` inside a module is ordinary Ruby, and every walk that gives
# such a write a class name took only the bare `ConstantWriteNode`. The four things that name buys are
# lost together — the discovered class, the member layout, the `.new` shape and the block body's own defs
# — so the constant answered `singleton(Struct)`, its instance answered `Struct`, and correct member and
# override calls reported `undefined method … for Struct`. A false positive on correct code, not a
# precision loss, which is why the arms below are read back through calls as well as `assert_type`.

class Holder
end

module Admin
  class Holder
  end

  Holder::Thing = Struct.new(:a) do
    def other = "y"
  end

  # The bare twin, identical but for the spelling. It answers what it always did, and every path
  # assertion is written against ITS answer — which is what says the path arm was brought to the
  # existing behaviour rather than given a second one of its own.
  Bare = Struct.new(:a) do
    def other = "y"
  end

  # A ROOTED path write names the top level unconditionally, so its class is `Holder::Rooted` — the
  # top-level `Holder` above — and not the `Admin::Holder::Rooted` the unrooted spelling one write up
  # takes from the very same body. Both spellings resolving to `Admin::Holder` would satisfy every
  # unrooted assertion and none of these.
  ::Holder::Rooted = Struct.new(:r) do
    def rooted_only = "r"
  end
end

class FactoryReader
  # The two member reads (`thing.a`, `bare.a`) are the false-positive arm: master answers `Struct` for
  # the receiver, and `Struct` is a class RBS knows, so `call.undefined-method` fires on both of them
  # and on `thing.other`. Once the receiver is the discovered class the calls go lenient instead.
  def read_path_form
    assert_type("singleton(Admin::Holder::Thing)", Admin::Holder::Thing)
    thing = Admin::Holder::Thing.new(1)
    assert_type("Admin::Holder::Thing(a: 1)", thing)
    assert_type("\"y\"", thing.other)
    thing.a
  end

  def read_bare_twin
    assert_type("singleton(Admin::Bare)", Admin::Bare)
    bare = Admin::Bare.new(1)
    assert_type("Admin::Bare(a: 1)", bare)
    assert_type("\"y\"", bare.other)
    bare.a
  end

  def read_rooted_form
    assert_type("singleton(Holder::Rooted)", Holder::Rooted)
    rooted = Holder::Rooted.new(2)
    assert_type("Holder::Rooted(r: 2)", rooted)
    assert_type("\"r\"", rooted.rooted_only)
    rooted.r
  end
end

# ---- 2. The mutation census and `rooted?` ----
#
# `::Table::ROWS[k] = 1` names the top-level constant unconditionally, so the sibling
# `Admin::Table::ROWS` a bare spelling would also reach is untouched. The census emitted every lexical
# candidate for it anyway, because the strict render both spellings share drops the root marker — the
# exemption #690 established on the write side, unmirrored on the mutation side.

class Table
  ROWS = {}
  UNROOTED = {}
end

module Admin
  class Table
    ROWS = {}
    UNROOTED = {}
  end

  def self.fill_rooted(key)
    ::Table::ROWS[key] = 1
  end

  def self.fill_unrooted(key)
    Table::UNROOTED[key] = 1
  end

  def self.shapes
    assert_type("true", Admin::Table::ROWS.empty?)
    assert_type("bool", ::Table::ROWS.empty?)

    # Must-still-succeed: an UNROOTED spelling does reach every lexical candidate, so both tables are
    # widened by the one write. Exempting the path arm wholesale satisfies the pair above and fails this.
    assert_type("bool", Admin::Table::UNROOTED.empty?)
    assert_type("bool", ::Table::UNROOTED.empty?)
  end
end
