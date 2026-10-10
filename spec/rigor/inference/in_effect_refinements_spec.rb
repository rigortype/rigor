# frozen_string_literal: true

require "spec_helper"

# A query and its source, answering at the first occurrence of a marker string.
InEffectRefinementsAtMarker = Struct.new(:refinements, :source) do
  def offset(marker) = source.index(marker) || raise("no #{marker.inspect} in the source")

  def at(marker, declared = Rigor::Inference::InEffectRefinements::EMPTY, &)
    refinements.at(offset(marker), declared, &)
  end
end

# Issue #1673 (ADR-121 WD1) — the ordered in-effect refinements of one file, which the check rules and the typer
# both read.
RSpec.describe Rigor::Inference::InEffectRefinements do
  let(:unknown) { described_class::UNKNOWN }

  # A query over `source` whose `at(marker, …)` answers at the first occurrence of `marker`.
  def query(source)
    InEffectRefinementsAtMarker.new(described_class.new(Prism.parse(source).value), source)
  end

  describe "lexical `using`" do
    it "keeps a re-activated module at its first position, so `using A; using B; using A` leaves B last" do
      refinements = query(<<~RUBY)
        using A
        using B
        using A
        :probe
      RUBY

      expect(refinements.at(":probe")).to eq(%w[A B])
    end

    it "orders two modules refining the same method by textual order" do
      refinements = query(<<~RUBY)
        module First; refine(String) { def shout = 1 }; end
        module Second; refine(String) { def shout = 2 }; end
        using Second
        using First
        :probe
      RUBY

      expect(refinements.at(":probe")).to eq(%w[Second First])
    end

    it "takes effect after the call and ends with the body that holds it" do
      refinements = query(<<~RUBY)
        :before
        class Box
          using Inner
          :inside
        end
        :after
      RUBY

      expect(refinements.at(":before")).to be_empty
      expect(refinements.at(":inside")).to eq(%w[Inner Box::Inner])
      expect(refinements.at(":after")).to be_empty
    end

    it "appends a nested class body's `using`s to the file's list, each spelling's candidates innermost last" do
      refinements = query(<<~RUBY)
        using A
        class Box
          using B
          :inside
        end
        :outside
      RUBY

      expect(refinements.at(":inside")).to eq(%w[A B Box::B])
      expect(refinements.at(":outside")).to eq(%w[A])
    end

    it "ignores a `using` inside a `def`, which raises in Ruby" do
      refinements = query(<<~RUBY)
        def m
          using A
          :inside
        end
        :after
      RUBY

      expect(refinements.at(":inside")).to be_empty
      expect(refinements.at(":after")).to be_empty
    end

    it "puts a `using`'d module's included modules ahead of it through the caller's expansion" do
      refinements = query(<<~RUBY)
        using Base
        using Outer
        :probe
      RUBY
      expansion = { "Outer" => %w[Base Mixin Outer], "Base" => %w[Base] }

      expect(refinements.at(":probe") { |name| expansion.fetch(name) }).to eq(%w[Base Mixin Outer])
    end

    it "contributes the unknown marker where the expansion cannot tell" do
      refinements = query(<<~RUBY)
        using A
        :probe
      RUBY

      expect(refinements.at(":probe") { nil }).to eq([unknown])
    end
  end

  describe "a `refine` block" do
    it "has its own module in effect after the enclosing `using`s" do
      refinements = query(<<~RUBY)
        using A
        module Shout
          refine String do
            :inside
          end
          :beside
        end
      RUBY

      expect(refinements.at(":inside")).to eq(%w[A Shout])
      expect(refinements.at(":beside")).to eq(%w[A])
    end

    it "names the module a `Module.new` constant write creates, and nothing it cannot name" do
      refinements = query(<<~RUBY)
        module Outer
          Named = Module.new do
            refine(String) { :named }
          end
          [1].each do
            refine(String) { :blocked }
          end
          Shape = Struct.new(:a) do
            refine(String) { :struct }
          end
        end
      RUBY

      expect(refinements.at(":named")).to eq(%w[Outer::Named])
      expect(refinements.at(":blocked")).to eq([unknown])
      # Issue #1689 — a `Struct.new` block's `self` is a class, so its `refine` is not `Module#refine`.
      expect(refinements.at(":struct")).to eq([])
    end

    # Issue #1689 — `Class` undefines `refine`, so where `self` is known to be a class the call is the class's own
    # method: it activates nothing, and its defs are not refinement defs.
    context "when `self` is known to be a class" do
      let(:source) do
        <<~RUBY
          class Widget < Base
            refine(String) { def in_class = :in_class }
            class << self
              refine(String) { :in_singleton }
            end
            [1].each do
              refine(String) { :in_block }
            end
          end
          Made = Class.new do
            refine(String) { :class_new }
          end
          Class.new { refine(String) { :anonymous } }
          Point = Data.define(:x) do
            refine(String) { :data }
          end
          module Shout
            refine(String) { :in_module }
          end
        RUBY
      end
      let(:root) { Prism.parse(source).value }
      let(:refinements) { described_class.new(root) }
      let(:calls) do
        found = []
        Rigor::Source::NodeWalker.each(root) do |node|
          found << node if node.is_a?(Prism::CallNode) && node.name == :refine
        end
        found
      end

      it "activates nothing there, and a `refine` in a nested block is still a refine block" do
        at = InEffectRefinementsAtMarker.new(refinements, source)

        expect(%w[:in_class :in_singleton :class_new :anonymous :data].map { |marker| at.at(marker) }).to all(eq([]))
        # A block may run under another `self`, so a `refine` in one stays a refine block of an unnamed module.
        expect(at.at(":in_block")).to eq([unknown])
        expect(at.at(":in_module")).to eq(%w[Shout])
      end

      it "answers class_body_refine? for exactly those calls, and records none of their defs" do
        answers = calls.to_h { |call| [call.block.body.body.first.slice[/:\w+/], refinements.class_body_refine?(call)] }

        expect(answers).to eq(
          ":in_class" => true, ":in_singleton" => true, ":in_block" => false, ":class_new" => true,
          ":anonymous" => true, ":data" => true, ":in_module" => false
        )
        expect(refinements.refinement_def?(calls.first.block.body.body.first)).to be(false)
      end
    end

    it "records the defs the body defines on the refined class" do
      source = <<~RUBY
        module Shout
          refine(String) { def shout = upcase }
        end
        def shout = 1
      RUBY
      refinements = query(source).refinements
      defs = Prism.parse(source).value.statements.body
      refined = defs.first.body.body.first.block.body.body.first

      # A def node is identified by offset, so a re-parse of the same source answers alike.
      expect(refinements.refinement_def?(refined)).to be(true)
      expect(refinements.refinement_def?(defs.last)).to be(false)
    end
  end

  describe "a non-constant `using`" do
    it "contributes the unknown marker throughout its file" do
      refinements = query(<<~RUBY)
        :before
        using Module.new { refine(String) { def shout = 1 } }
        :after
      RUBY

      expect(refinements.at(":before")).to eq([unknown])
      expect(refinements.at(":after")).to eq([unknown])
    end
  end

  describe "block sources" do
    it "appends a block's declared modules after its lexical list, each once" do
      refinements = query(<<~RUBY)
        using A
        :probe
      RUBY

      expect(refinements.at(":probe", %w[B A C])).to eq(%w[A B C])
    end
  end

  # Issue #1666 — a Proc literal that is directly the receiver of `Proc#refined`.
  describe "a `Proc#refined` literal" do
    it "puts the arguments in effect over the literal's body only, after its lexical list" do
      refinements = query(<<~RUBY)
        using A
        :before
        ->(s) { :lambda }.refined(B, C)
        proc { :proc }.refined(B)
        lambda { :kernel_lambda }.refined(B)
        Proc.new { :proc_new }.refined(B)
        ::Proc.new { :rooted_proc_new }.refined(B)
        :after
      RUBY

      expect(refinements.at(":lambda")).to eq(%w[A B C])
      %w[:proc :kernel_lambda :proc_new :rooted_proc_new].each do |marker|
        expect(refinements.at(marker)).to eq(%w[A B])
      end
      expect(refinements.at(":before")).to eq(%w[A])
      expect(refinements.at(":after")).to eq(%w[A])
    end

    it "orders a `.refined` chain in call order, and lets a nested block and literal inherit" do
      refinements = query(<<~RUBY)
        proc {
          [1].map { :nested_block }
          proc { :inner }.refined(C, A)
          :outer
        }.refined(A).refined(B)
      RUBY

      expect(refinements.at(":outer")).to eq(%w[A B])
      expect(refinements.at(":nested_block")).to eq(%w[A B])
      expect(refinements.at(":inner")).to eq(%w[A B C])
    end

    it "reads a chain through parentheses and `dup` / `clone`, and a `Kernel`-qualified literal" do
      refinements = query(<<~RUBY)
        (proc { :parens }.refined(A)).refined(B)
        (-> { :paren_literal }).refined(A)
        proc { :copied }.dup.refined(A).clone.refined(B)
        Kernel.proc { :kernel }.refined(A)
        ::Kernel.lambda { :rooted_kernel }.refined(A)
        proc { :tapped }.tap {}.refined(A)
        Other.proc { :other }.refined(A)
        proc { :dup_with_argument }.dup(1).refined(A)
      RUBY

      expect(refinements.at(":parens")).to eq(%w[A B])
      expect(refinements.at(":copied")).to eq(%w[A B])
      %w[:paren_literal :kernel :rooted_kernel].each { |marker| expect(refinements.at(marker)).to eq(%w[A]) }
      %w[:tapped :other :dup_with_argument].each { |marker| expect(refinements.at(marker)).to be_empty }
    end

    it "contributes the unknown marker over the literal's body for an argument that is not a constant" do
      refinements = query(<<~RUBY)
        def m(mod) = proc { :refined }.refined(A, mod)
        :outside
      RUBY

      expect(refinements.at(":refined")).to eq(["A", unknown])
      expect(refinements.at(":outside")).to be_empty
      expect(refinements.refinements.refinement_active?(refinements.offset(":outside"), %w[A])).to be(false)
    end

    it "activates nothing for a Proc that is not a literal receiver" do
      refinements = query(<<~RUBY)
        l = -> { :held }
        l.refined(A)
        run { :passed }.refined(A)
        proc(&l).refined(A)
        Other.new { :other_new }.refined(A)
        proc { :bare }.refined
      RUBY

      %w[:held :passed :other_new :bare].each { |marker| expect(refinements.at(marker)).to be_empty }
    end
  end

  describe "#for_node" do
    it "answers a node of its own file by position and another file's node with no lexical refinement" do
      source = <<~RUBY
        using A
        :probe
      RUBY
      root = Prism.parse(source).value
      refinements = described_class.new(root)
      own = root.statements.body.last
      foreign = Prism.parse(source).value.statements.body.last

      expect(refinements.for_node(own)).to eq(%w[A])
      expect(refinements.for_node(foreign)).to be_empty
      expect(refinements.for_node(foreign, %w[B])).to eq(%w[B])
    end
  end

  describe "the derived check-rule answers" do
    it "keeps the silencing answers broader than the list inside a `refine` block and under the unknown marker" do
      refinements = query(<<~RUBY)
        module Shout
          refine(String) { :inside }
        end
        using Shout
        :after
      RUBY
      inside = refinements.offset(":inside")
      after = refinements.offset(":after")

      query = refinements.refinements
      expect(query.refinement_active?(inside, %w[Unrelated])).to be(true)
      expect(query.refinement_active?(after, %w[Unrelated])).to be(false)
      expect(query.refinement_active?(after, %w[Shout])).to be(true)
      expect(query.any_at?(after)).to be(true)
      expect(query.any_at?(0)).to be(false)
    end
  end

  describe "Scope#in_effect_refinements" do
    it "reads the query the file's index stamps, with each `using` expanded through the file's includes" do
      source = <<~RUBY
        module Mixin
          refine(String) { def shout = 1 }
        end
        module Outer
          include Mixin
          refine(String) { def shout = 2 }
        end
        using Outer
        "x".shout
      RUBY
      root = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)
      call = root.statements.body.last

      expect(index[call].in_effect_refinements(call)).to eq(%w[Mixin Outer])
      expect(Rigor::Scope.empty.in_effect_refinements(call)).to be_empty
    end

    # Ruby 4.0.5 prints `:Pre`: a prepended module is activated after the module that prepends it.
    it "activates a `using`'d module's prepended modules after it, so the prepended one wins" do
      source = <<~RUBY
        module Inc1; refine(String) { def w = :Inc1 }; end
        module Pre; refine(String) { def w = :Pre }; end
        module Top
          include Inc1
          prepend Pre
          refine(String) { def w = :Top }
        end
        using Top
        "x".w
      RUBY
      root = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)
      call = root.statements.body.last

      expect(index[call].in_effect_refinements(call)).to eq(%w[Inc1 Top Pre])
    end

    # Ruby 4.0.5 prints `:box`: the lexical lookup finds `Box::Inner` before the top-level `Inner`.
    it "lets the innermost spelling of a `using`'s constant win" do
      source = <<~RUBY
        module Inner; refine(String) { def w = :top }; end
        class Box
          module Inner; refine(String) { def w = :box }; end
          using Inner
          "x".w
        end
      RUBY
      root = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)
      call = root.statements.body.last.body.body.last

      expect(index[call].in_effect_refinements(call).last).to eq("Box::Inner")
    end
  end

  # ADR-121 WD7 — which modules a `using` puts in the list, and which of them the readers treat as opaque.
  describe "declared candidates and opaque modules" do
    def scope_at_last(source)
      root = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)
      call = root.compact_child_nodes.first.body.last
      call = call.body.body.last while call.is_a?(Prism::ModuleNode)
      [index[call], call, root]
    end

    # Critique F1, on Ruby 4.0.5: with a top-level `Bar` refining `String#center` and a `Foo::Bar` declared in another
    # file, `module Foo; using Bar; "x".center(1, 2, 3); end` prints `:bar` when `foo.rb` is required first and raises
    # `ArgumentError` when `foo_bar.rb` is, so which `Bar` the `using` names is not a fact and both stay listed.
    it "keeps every declared candidate, drops undeclared ones, and lets an undeclared spelling enter alone" do
      scope, call, = scope_at_last(<<~RUBY)
        module Ext; refine(String) { def shout = 1 }; end
        module Bar; refine(String) { def w = 1 }; end
        module Foo
          module Bar; refine(String) { def w = 2 }; end
          using Ext
          using Bar
          using GemRef
          "x".w
        end
      RUBY

      expect(scope.in_effect_refinements(call)).to eq(%w[Ext Bar Foo::Bar GemRef])
    end

    it "drops a core module a `using`'d module includes, and lists any other module it includes but no file declares" do
      scope, call, = scope_at_last(<<~RUBY)
        module A
          include Comparable
          include Helpers
          refine(String) { def shout = 1 }
        end
        using A
        "x".shout
      RUBY

      expect(scope.in_effect_refinements(call)).to eq(%w[Helpers A])
    end

    it "treats a module no file declares as opaque, and a project or core module as not" do
      scope, = scope_at_last(<<~RUBY)
        module Ext; refine(String) { def shout = 1 }; end
        module Plain; end
        Object.const_set(:Made, Module.new)
        :probe
      RUBY

      expect(%w[Ext Plain Comparable Kernel GemRef Made].map { |name| described_class.opaque_module?(scope, name) })
        .to eq([false, false, false, false, true, true])
    end

    # Ruby 4.0.5: `def self.setup = refine(String) { … }` refines for `M`; `def setup` there refines for whichever
    # module extends `M` and calls it, so the walk cannot name the module and every module may be the one.
    it "treats a module with an unreadable refine as opaque, and every module under an unattributable one" do
      tail = "\nend\nmodule P; end\n:probe\n"
      self_setup, = scope_at_last("module M\n  def self.setup = refine(String) { def x = 1 }#{tail}")
      instance_setup, = scope_at_last("module M\n  def setup = refine(String) { def x = 1 }#{tail}")

      expect(%w[M P].map { |name| described_class.opaque_module?(self_setup, name) }).to eq([true, false])
      expect(%w[M P].map { |name| described_class.opaque_module?(instance_setup, name) }).to eq([true, true])
    end

    it "gives the check rules' list and the typer's list the same entries" do
      scope, call, root = scope_at_last(<<~RUBY)
        module Bar; include Helpers; refine(String) { def w = 1 }; end
        module Foo
          module Bar; refine(String) { def w = 2 }; end
          using Bar
          using GemRef
          "x".w
        end
      RUBY
      stamped = scope.discovery.in_effect_refinements
      offset = call.location.start_offset
      own = Rigor::Analysis::CheckRules::LexicalMethodSites.new(root).refinements
      shared = Rigor::Analysis::CheckRules::LexicalMethodSites.new(root, stamped).refinements

      typer = scope.in_effect_refinements(call, described_class::EMPTY)
      expect(typer).to eq(%w[Helpers Bar Foo::Bar GemRef])
      expect(described_class.lexical_list(scope, own, offset)).to eq(typer)
      expect(described_class.lexical_list(scope, shared, offset)).to eq(typer)
    end
  end
end
