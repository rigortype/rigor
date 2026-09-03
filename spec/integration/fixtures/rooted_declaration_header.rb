require "rigor/testing"
include Rigor::Testing

# A ROOTED declaration header (https://github.com/rigortype/rigor/issues/708).
#
# `::` re-anchors a `class` / `module` header at the top level exactly as it
# re-anchors a constant reference, but every walk that built a qualified name
# from a header read only the RENDERED name — which drops the root marker by
# contract — and appended it to the enclosing prefix. `class ::Rooted::Bar`
# inside `module Outer` was filed as `Outer::Rooted::Bar` and its body's
# `Module.nesting` recorded as `["Outer::Rooted::Bar", "Outer"]` where Ruby
# gives `[Rooted::Bar, Outer]`.
#
# Two things move, and they move in opposite directions, which is why each has
# its own arm below: the class's own NAME resets to the top level, while the
# enclosing `Module.nesting` entries stay beneath it as live rungs. An
# implementation that reset both would pass every `by_own_*` assertion and fail
# `by_enclosing_constant`; one that reset neither is master.
#
# The single-segment case (https://github.com/rigortype/rigor/issues/638) is
# the load-bearing one and is asserted through a DIAGNOSTIC rather than a type:
# `class ::Foo` inside `module MyApp` indexed as `MyApp::Foo` is not merely
# mis-keyed but undiscoverable under the name every caller writes, so `Foo.new`
# typed opaque and the whole chain after it reported NOTHING. The two `.nope`
# lines at the bottom are the must-fire arms.

class Rooted
  class Bar
    MARK = :top_bar_mark
  end
end

module Outer
  MARK = :outer_mark
  OUTER_ONLY = :outer_only

  class Rooted
    class Bar
      MARK = :outer_bar_mark
    end
  end

  # ROOTED. Ruby names this class `Rooted::Bar` and its nesting is
  # `[Rooted::Bar, Outer]`.
  class ::Rooted::Bar
    def by_own_constant
      assert_type(':top_bar_mark', MARK)
    end

    # The enclosing rung is still live: `Outer` sits beneath the reset entry, so
    # a name only `Outer` owns still resolves. Resetting the whole chain would
    # answer `Dynamic[top]` here.
    def by_enclosing_constant
      assert_type(':outer_only', OUTER_ONLY)
    end

    # Declared HERE, so a reader outside can only reach it if the header's reset
    # put the method on `Rooted::Bar` rather than on `Outer::Rooted::Bar`.
    def rooted_mark = MARK
  end

  # NON-ROOTED twin, and the must-stay-unchanged arm: the same compact spelling
  # without `::` names `Outer::Rooted::Bar`, whose own `MARK` is the shadow.
  class Rooted::Bar
    def by_own_constant
      assert_type(':outer_bar_mark', MARK)
    end
  end
end

# The def-node walk's answer, read from OUTSIDE the declaration: inferring
# `rooted_mark`'s return re-walks the callee body from the receiver's type
# alone, so this arm passes only if the two nesting walks agree about the rooted
# header. On master the def was recorded under `Outer::Rooted::Bar` and this
# receiver reached neither the method nor the constant.
class Reader
  def read
    assert_type(':top_bar_mark', Rooted::Bar.new.rooted_mark)
  end
end

# Single segment (#638). `Plain` is the twin that was never mis-keyed.
module MyApp
  class ::Foo
    def foo_mark = :foo_ok
  end

  class Plain
    def plain_mark = :plain_ok
  end
end

assert_type(':foo_ok', Foo.new.foo_mark)
assert_type(':plain_ok', MyApp::Plain.new.plain_mark)

# The reported symptom, as a diagnostic. Both receivers are discoverable under
# the name written here, so the Symbol each `*_mark` returns answers `nope` with
# `call.undefined-method`. On master the rooted half resolved to nothing and
# this line reported nothing at all.
Foo.new.foo_mark.nope
MyApp::Plain.new.plain_mark.nope

# #708 review — the CENSUS walks under a rooted header. Everything above reaches
# the declaration walk only; these shapes reach the walks that used to derive
# `Module.nesting` by truncating the qualified prefix, which a rooted header
# resets. `Outer2` is absent from that prefix entirely, so each of these reached
# the TOP-LEVEL `Sentinel2` and drew a false `undefined-method` on correct Ruby,
# where master reports none.
#
# The discriminating value is a CLASS rather than a namespace-level value
# constant: this harness runs the fixture under `Scope.empty`, which seeds no
# cross-file constant publication, so a value constant reads `Dynamic[top]` here
# for the rooted and non-rooted spellings alike and could not tell them apart.
class Sentinel2
  def tag = :top_sentinel
end

class Base2
  def who = :top_base2
end

module Outer2
  TABLE = {}
  TWIN = {}

  class Sentinel2
    def tag = :outer_sentinel
  end

  class Base2
    def who = :outer2_base
  end

  class ::Rooted2
    DEFAULT = Sentinel2 # constant-write census

    class Inner < Base2
      def by_inherited = assert_type(':outer2_base', who)
    end

    def initialize
      @v = Sentinel2.new # instance-variable census
    end

    def by_default = assert_type(':outer_sentinel', DEFAULT.new.tag)
    def by_ivar = assert_type(':outer_sentinel', @v.tag)
    def by_def_body = assert_type(':outer_sentinel', Sentinel2.new.tag)

    # Mutation census: the bare mutated constant names `Outer2::TABLE`, so the
    # closed empty shape must widen and `.empty?` must not fold to `true`.
    def self.fill = TABLE[:k] = 1
  end

  # The must-still-succeed twin: the same shapes under a NON-rooted header.
  class Plain2
    DEFAULT = Sentinel2

    class Inner < Base2
      def by_inherited = assert_type(':outer2_base', who)
    end

    def initialize
      @v = Sentinel2.new
    end

    def by_default = assert_type(':outer_sentinel', DEFAULT.new.tag)
    def by_ivar = assert_type(':outer_sentinel', @v.tag)
    def self.fill = TWIN[:k] = 1
  end
end

Rooted2.fill
Outer2::Plain2.fill
assert_type('bool', Outer2::TABLE.empty?)
assert_type('bool', Outer2::TWIN.empty?)
assert_type(':outer2_base', Rooted2::Inner.new.who)
assert_type(':outer2_base', Outer2::Plain2::Inner.new.who)

# The must-fire pair for the rooted body: master reported nothing on the first,
# because the receiver never resolved under the name written here.
Rooted2::Inner.new.who.nope
Outer2::Plain2::Inner.new.who.nope
