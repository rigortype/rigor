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

  # Two RBS modules that both declare `probe` with distinguishable return types, for the
  # include-ordering pins below.
  def two_probe_mods
    { "mods.rbs" => <<~RBS }
      module A
        def probe: () -> Integer
      end
      module B
        def probe: () -> String
      end
    RBS
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

    # `include A; include B` chains `Pair → B → A` — the LAST include sits nearer — so when both
    # RBS modules declare the name, B's declaration is the method that runs. Pinned against the
    # pre-#1173 `includes_of` call order, which would have adopted A's.
    it "prefers the LAST include when two RBS modules both declare — MRO order" do
      expect(dumps(<<~RUBY, sig: two_probe_mods)).to eq(["String"])
        class Pair
          include A
          include B

          def go = dump_type(probe)
        end
      RUBY
    end

    # The other half of Ruby's include rule: one statement's argument list lands in WRITTEN order
    # (`include A, B` chains `Pair → A → B`), so A's declaration wins here where the two-statement
    # form above answered B's.
    it "keeps one statement's arguments in written order — `include A, B`" do
      expect(dumps(<<~RUBY, sig: two_probe_mods)).to eq(["Integer"])
        class Pair
          include A, B

          def go = dump_type(probe)
        end
      RUBY
    end

    # A nearer module whose declaration arrives through its OWN RBS `include`: `Pair → B → N → A`,
    # so `N#probe` runs and A's declaration must not be adopted. `ExternalAncestorResolution`
    # `defined_in`-checks each candidate against its own ancestor list — the module case needed
    # that check to look past the `Object` cut-off, which a module's ancestry never reaches.
    it "resolves through the nearer module's own RBS include chain" do
      sig = { "mods.rbs" => <<~RBS }
        module N
          def probe: () -> Integer
        end
        module B
          include N
        end
        module A
          def probe: () -> String
        end
      RBS
      expect(dumps(<<~RUBY, sig: sig)).to eq(["Integer"])
        class Pair
          include A
          include B

          def go = dump_type(probe)
        end
      RUBY
    end

    # The single-include variant of the same shape: `B` declares nothing itself but its RBS
    # `include N` does, and N's declaration is unambiguously the method that runs.
    it "resolves a method the included module itself inherits in RBS" do
      sig = { "mods.rbs" => <<~RBS }
        module N
          def probe: () -> Integer
        end
        module B
          include N
        end
      RBS
      expect(dumps(<<~RUBY, sig: sig)).to eq(["Integer"])
        class Pair
          include B

          def go = dump_type(probe)
        end
      RUBY
    end

    # `include` is a no-op for a module already in the ancestry: `include B` pulls `N` in, so the
    # later `include N` re-positions nothing and the chain is `Pair → B → N` — `B#probe` runs.
    # The pre-guard walk searched the `N` group first (the later statement is nearer in the table)
    # and answered `Integer`.
    it "searches the carrying module's position when a later include is a runtime no-op" do
      sig = { "mods.rbs" => <<~RBS }
        module N
          def probe: () -> Integer
        end
        module B
          include N
          def probe: () -> String
        end
      RBS
      expect(dumps(<<~RUBY, sig: sig)).to eq(["String"])
        class Pair
          include B
          include N

          def go = dump_type(probe)
        end
      RUBY
    end

    # The same re-siting through the superclass edge: `Enumerable` is already in `C`'s ancestry
    # via `Array`, so `include M` does not hoist it — `C → M → Array → Enumerable` and
    # `Array#first` runs, not `Enumerable[String]#first`. The include arm defers to the
    # superclass arm, which answers the plain `Array#first` shape.
    it "does not adopt a resited chain member's declaration over the superclass's own" do
      sig = { "mods.rbs" => <<~RBS }
        module M
          include Enumerable[String]
        end
      RBS
      expect(dumps(<<~RUBY, sig: sig)).to eq(["Dynamic[top]"])
        class C < Array
          include M

          def probe = dump_type(first)
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
          include Comparable
          include M
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

    # The same mark on a SOURCE MODULE inside the chain: `Widen.include(Extra)` outside `Widen`'s
    # body records ENVELOPE_DYNAMIC_MARK on `Widen`, and `Widen` sits between `Counted` and
    # `Comparable` in the MRO — so the arm declines rather than adopt a declaration a dynamically
    # widened nearer ancestor may contradict.
    it "declines when a nearer source module in the chain is dynamically widened" do
      expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"])
        module Extra; end
        module Widen; end
        Widen.include(Extra)

        class Counted
          include Comparable
          include Widen
          def <=>(other) = 0

          def probe = dump_type(clamp(1, 2))
        end
      RUBY
    end

    # ADR-17 through an include edge: the `pre_eval:` patch reopens `M`, which sits nearer than
    # `Comparable`, so the declaration the walk found is not the method that runs.
    it "declines when a pre_eval patch redefines the name on a source module in the chain" do
      result = analyze(
        files: {
          "app.rb" => <<~RUBY,
            require "rigor/testing"
            include Rigor::Testing

            module M; end

            class Counted
              include Comparable
              include M
              def <=>(other) = 0

              def probe = dump_type(clamp(1, 2))
            end
          RUBY
          "patch.rb" => <<~RUBY
            module M
              def clamp(a, b) = 42
            end
          RUBY
        },
        config: { "paths" => %w[app.rb], "pre_eval" => %w[patch.rb] }
      )
      types = result.diagnostics.filter_map do |d|
        d.message.delete_prefix("dump_type: ") if d.message.start_with?("dump_type")
      end
      expect(types).to eq(["Dynamic[top]"])
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
