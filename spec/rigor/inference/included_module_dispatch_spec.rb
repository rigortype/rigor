# frozen_string_literal: true

require "spec_helper"

# Issue #1173 — a discovered class's `include M` where M is RBS-known resolves M's instance
# declarations, the include-edge sibling of #527 slice 1's superclass arm.
#
# Ruby inserts an included module into the ancestor chain outright, so adopting the module's RBS
# declaration is the dispatch the runtime performs. The walk lives in
# `RbsDispatch.lookup_method` — `dispatch_one` keys `self`, `instance`, the type-variable map and
# `SelfSubstitute` on the RECEIVER's class name, so `-> self` answers the includer and a
# method-level `[A] (A) -> A` binds its variable from the call's arguments (#1173's headline).
#
# The false-positive boundary mirrors the superclass arm's: a project `def` on the receiver or a
# nearer source ancestor, an outside-the-body `include` mark (#992), or an ADR-17 `pre_eval:` patch
# each mean the declaration found is not the method that runs, and the arm declines.
RSpec.describe "a discovered class resolves calls into an included RBS module (#1173)",
               type: :runner do
  def analyzed(source, prelude: "", sig: {})
    analyze(%(require "rigor/testing"\n#{prelude}include Rigor::Testing\n#{source}), sig: sig)
  end

  def dumps(source, prelude: "", sig: {})
    analyzed(source, prelude: prelude, sig: sig).diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def rules(source, prelude: "")
    analyzed(source, prelude: prelude).diagnostics.map { |d| d.qualified_rule.to_s }
  end

  describe "the included declaration answers" do
    # `clamp(1, 2)` selects `[A] (A, A) -> self | A`: `A` binds to the union of both argument
    # positions (`1 | 2`) and `self` substitutes the receiver — the exact set of inhabitants the
    # runtime can return.
    it "resolves a core module's method on an implicit-self call" do
      expect(dumps(<<~RUBY)).to eq(["1 | 2 | Counted"])
        class Counted
          include Comparable
          def <=>(other) = 0

          def probe
            dump_type(clamp(1, 2))
          end
        end
      RUBY
    end

    it "resolves through an include on a project superclass, in MRO order" do
      expect(dumps(<<~RUBY)).to eq(["1 | 2 | Leaf"])
        class Base
          include Comparable
          def <=>(other) = 0
        end

        class Leaf < Base
          def probe = dump_type(clamp(1, 2))
        end
      RUBY
    end

    it "answers an explicit receiver as well as an implicit self" do
      expect(dumps(<<~RUBY)).to eq(["1 | 2 | Counted"])
        class Counted
          include Comparable
          def <=>(other) = 0
        end

        def probe = dump_type(Counted.new.clamp(1, 2))
      RUBY
    end

    it "binds a method-level type variable from the argument — the #1173 fixture" do
      expect(dumps(<<~RUBY)).to eq(['"hello"', '"hello"'])
        class Fixture
          include Rigor::Testing

          def go
            kept = dump_type("hello")
            dump_type(kept)
          end
        end
      RUBY
    end

    # `Sub < Hash` with `include M` chains `Sub → M → Hash`, so M's `merge` is the method that
    # runs even though `Hash#merge` also declares it. The arm therefore runs before the superclass
    # bridges in `lookup_method`; pinned here so a future reorder cannot silently flip the answer
    # to `Hash[...]`.
    it "prefers a nearer include over a bridged superclass's own declaration — MRO order" do
      mixin_sig = { "m.rbs" => "module M\n  def merge: (*untyped) -> String\nend\n" }
      expect(dumps(<<~RUBY, sig: mixin_sig)).to eq(["String"])
        class Sub < Hash
          include M

          def probe = dump_type(merge({}))
        end
      RUBY
    end
  end

  describe "the declines" do
    it "yields to the receiver's own def" do
      expect(dumps(<<~RUBY)).to eq(["42"])
        class Counted
          include Comparable
          def clamp(a, b) = 42

          def probe = dump_type(clamp(1, 2))
        end
      RUBY
    end

    it "yields to a def on a nearer source ancestor" do
      expect(dumps(<<~RUBY)).to eq(["42"])
        module M
          def clamp(a, b) = 42
        end

        class Counted
          include M
          include Comparable
          def <=>(other) = 0

          def probe = dump_type(clamp(1, 2))
        end
      RUBY
    end

    # Issue #992's surface mark, identical in shape to the superclass arm's pin: a
    # `Klass.include(M)` written outside the class body records ENVELOPE_DYNAMIC_MARK because it can
    # add members the in-body walks never see, so the arm declines rather than adopt a declaration
    # the runtime surface may contradict.
    it "declines a class an outside-the-body include can have widened" do
      expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"])
        class Counted
          def <=>(other) = 0

          def probe = dump_type(clamp(1, 2))
        end
        Counted.include(Comparable)
      RUBY
    end

    # The superclass edge stays declined through this arm: `Prism::Visitor` is a gem RBS *class*,
    # and bridging to a non-core ancestor class is #527's deferred superclass question, not this
    # one's. The walk reports it as the owner and `rbs_module?` declines it.
    it "does not adopt a superclass-owned answer even when an include is also in the walk" do
      expect(dumps(<<~RUBY, prelude: %(require "prism"\n))).to eq(["Dynamic[top]"])
        class MyVisitor < Prism::Visitor
          include Comparable
          def <=>(other) = 0

          def probe = dump_type(visit(nil))
        end
      RUBY
    end
  end
end
