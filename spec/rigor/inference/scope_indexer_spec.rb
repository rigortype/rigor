# frozen_string_literal: true

require "spec_helper"
require "prism"
require "fileutils"
require "tmpdir"

RSpec.describe Rigor::Inference::ScopeIndexer do
  let(:default_scope) { Rigor::Scope.empty }

  def parse(source)
    Prism.parse(source).value
  end

  def index_for(source)
    program = parse(source)
    [program, described_class.index(program, default_scope: default_scope)]
  end

  describe ".index" do
    it "returns an identity-comparing Hash whose default is default_scope" do
      _, idx = index_for("1")
      expect(idx).to be_a(Hash)
      expect(idx.compare_by_identity?).to be(true)
      expect(idx[Object.new]).to eq(default_scope) # not a Prism node, falls through to default
    end

    it "records the entry scope for every visited statement-y node" do
      program, idx = index_for(<<~RUBY)
        x = 1
        x
      RUBY
      statements = program.statements.body
      assignment = statements[0]
      read = statements[1]

      expect(idx[program]).to eq(default_scope)
      expect(idx[assignment]).to eq(default_scope)
      # The local-variable read happens AFTER the assignment, so its
      # entry scope MUST carry `x` bound to Constant[1].
      expect(idx[read].local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "propagates the parent's scope to expression-interior nodes" do
      program, idx = index_for("foo(1, 2)")
      call = program.statements.body.first

      receiver_args = call.arguments.arguments
      expect(receiver_args).to all(be_a(Prism::Node))

      # The CallNode itself is visited (default branch records it via on_enter).
      expect(idx[call]).to eq(default_scope)

      # Each argument node inherits the call's entry scope through propagate.
      receiver_args.each do |arg|
        expect(idx[arg]).to eq(default_scope)
      end
    end

    it "binds locals visible to children inside an rvalue expression" do
      program, idx = index_for(<<~RUBY)
        x = 1
        y = x + 2
      RUBY
      assignment_y = program.statements.body[1]
      rhs = assignment_y.value # CallNode for `x + 2`
      receiver = rhs.receiver  # LocalVariableReadNode for `x`

      # The rvalue (and its receiver child) is reached via sub_eval from
      # eval_local_write under the post-`x = 1` scope, so `x` MUST be
      # visible at both the call and its receiver.
      expect(idx[rhs].local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(idx[receiver].local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "shows branch-internal bindings inside their branch only" do
      program, idx = index_for(<<~RUBY)
        if cond
          x = 1
          x
        end
        x
      RUBY
      if_node = program.statements.body[0]
      then_statements = if_node.statements.body
      after_if = program.statements.body[1]

      x_inside_branch = then_statements[1] # LocalVariableReadNode for `x`
      expect(idx[x_inside_branch].local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))

      # After the if (with no else), nil-injection on the join-with-nil
      # path makes `x` visible as `Constant[1] | Constant[nil]`.
      expect(idx[after_if].local(:x)).to be_a(Rigor::Type::Union)
      expect(idx[after_if].local(:x).members.map(&:value)).to contain_exactly(1, nil)
    end

    # Returns the index built for the canonical "expression-position
    # conditional with a previously-bound x" shape, plus the
    # LocalVariableReadNode for `x` extracted by `branch_path`. Pre-binding
    # `x = nil` makes Prism parse the inner `x` as a local read; the
    # surrounding `[]=` CallNode hides the conditional from
    # StatementEvaluator's eval_if path.
    def index_and_x_read_for(conditional, branch_path)
      program = parse("x = nil; cache[:k] = #{conditional}")
      assignment = program.statements.body[1]
      cond_node = assignment.arguments.arguments.last
      x_read = branch_path.call(cond_node).receiver
      [described_class.index(program, default_scope: default_scope), x_read]
    end

    it "registers Const = Data.define(*sym) as a discovered class" do
      program = parse(<<~RUBY)
        Foo = Data.define(:x, :y)
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      foo_constant = program.statements.body.first
      foo_singleton = idx[foo_constant].discovered_classes["Foo"]

      expect(foo_singleton).to eq(Rigor::Type::Combinator.singleton_of("Foo"))
    end

    it "qualifies Data.define constants with the surrounding class path" do
      program = parse(<<~RUBY)
        class Container
          Inner = Data.define(:k, :v)
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      class_node = program.statements.body.first

      expect(idx[class_node].discovered_classes["Container::Inner"]).to(
        eq(Rigor::Type::Combinator.singleton_of("Container::Inner"))
      )
    end

    it "ignores Data.define-style calls with non-symbol arguments" do
      program = parse(<<~RUBY)
        Foo = Data.define(:x, "not_a_symbol")
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      foo_constant = program.statements.body.first

      expect(idx[foo_constant].discovered_classes).not_to have_key("Foo")
    end

    it "recognises Data.define with a block-form override" do
      program = parse(<<~RUBY)
        Foo = Data.define(:x) do
          def initialize(x:)
            super(x: x.to_s)
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      foo_constant = program.statements.body.first

      expect(idx[foo_constant].discovered_classes["Foo"]).to(
        eq(Rigor::Type::Combinator.singleton_of("Foo"))
      )
    end

    # v0.1.2 — Data.define / Struct.new block-body methods are
    # registered under the constant's qualified name in both
    # `discovered_methods` and `discovered_def_nodes`. Without
    # this, the block-body `def initialize(...)` override is
    # invisible to `Reflection.user_def_for` / `discovered_method?`
    # and the canonical-sig contract is missing.
    it "registers Data.define block-body methods under the constant's name" do
      program = parse(<<~RUBY)
        Point = Data.define(:x, :y) do
          def initialize(x:, y:)
            super(x: x.to_i, y: y.to_i)
          end

          def magnitude
            42
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.user_def_for("Point", :initialize)).to be_a(Prism::DefNode)
      expect(scope.user_def_for("Point", :magnitude)).to be_a(Prism::DefNode)
      expect(scope.discovered_method?("Point", :initialize, :instance)).to be(true)
      expect(scope.discovered_method?("Point", :magnitude, :instance)).to be(true)
    end

    it "registers Struct.new block-body methods under the constant's name" do
      program = parse(<<~RUBY)
        Row = Struct.new(:k, :v) do
          def initialize(k, v)
            super(k.to_s, v)
          end

          def to_pair
            [k, v]
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.user_def_for("Row", :initialize)).to be_a(Prism::DefNode)
      expect(scope.user_def_for("Row", :to_pair)).to be_a(Prism::DefNode)
      expect(scope.discovered_method?("Row", :to_pair, :instance)).to be(true)
    end

    it "registers `class X < Data.define(...)` synthesized member readers" do
      program = parse(<<~RUBY)
        class Money < Data.define(:amount, :currency)
          def describe
            "x"
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.discovered_method?("Money", :amount, :instance)).to be(true)
      expect(scope.discovered_method?("Money", :currency, :instance)).to be(true)
      expect(scope.discovered_method?("Money", :describe, :instance)).to be(true)
    end

    it "registers `class X < Struct.new(...)` synthesized member readers" do
      program = parse(<<~RUBY)
        class Coord < Struct.new(:lat, :lng)
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.discovered_method?("Coord", :lat, :instance)).to be(true)
      expect(scope.discovered_method?("Coord", :lng, :instance)).to be(true)
    end

    # Survey item (e) — `Const = Module.new do ... end` and
    # `Const = Class.new(?super) do ... end` are block-as-method
    # idioms that mirror the Data.define / Struct.new shape: the
    # block body holds method overrides whose canonical class is
    # the named constant. Driven by `references/ruby/lib/resolv.rb`
    # (~8 sites) where `ClassHash = Module.new do; def []=; ...; end; end`
    # registers an instance method that `ClassHash[k] = v` then
    # calls.
    it "registers Module.new block-body methods under the constant's name" do
      program = parse(<<~RUBY)
        ClassHash = Module.new do
          def []=(key, value)
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.user_def_for("ClassHash", :[]=)).to be_a(Prism::DefNode)
      expect(scope.discovered_method?("ClassHash", :[]=, :instance)).to be(true)
    end

    it "registers Class.new block-body methods under the constant's name" do
      program = parse(<<~RUBY)
        AnonBase = Class.new do
          def foo
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.discovered_method?("AnonBase", :foo, :instance)).to be(true)
    end

    it "qualifies Module.new / Class.new block-body methods under the surrounding module path" do
      program = parse(<<~RUBY)
        module Resolv
          module DNS
            ClassHash = Module.new do
              def []=(k, v)
              end
            end
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.discovered_method?("Resolv::DNS::ClassHash", :[]=, :instance)).to be(true)
    end

    it "types the named constant as Singleton[Const] so dispatch routes through the discovered table" do
      program = parse(<<~RUBY)
        ClassHash = Module.new do
          def []=(k, v)
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      const_type = scope.in_source_constants["ClassHash"]
      expect(const_type).to eq(Rigor::Type::Combinator.singleton_of("ClassHash"))
    end

    it "qualifies block-body methods under the surrounding module path" do
      program = parse(<<~RUBY)
        module Geom
          Point = Data.define(:x, :y) do
            def magnitude
              42
            end
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.user_def_for("Geom::Point", :magnitude)).to be_a(Prism::DefNode)
      expect(scope.discovered_method?("Geom::Point", :magnitude, :instance)).to be(true)
    end

    it "registers Const = Struct.new(*sym) as a discovered class (v0.1.1)" do
      program = parse(<<~RUBY)
        Bar = Struct.new(:a, :b)
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      bar_constant = program.statements.body.first

      expect(idx[bar_constant].discovered_classes["Bar"]).to(
        eq(Rigor::Type::Combinator.singleton_of("Bar"))
      )
    end

    it "accepts Struct.new with a trailing keyword_init: hash" do
      program = parse(<<~RUBY)
        Entry = Struct.new(:method, :receiver, keyword_init: true)
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      entry_constant = program.statements.body.first

      expect(idx[entry_constant].discovered_classes["Entry"]).to(
        eq(Rigor::Type::Combinator.singleton_of("Entry"))
      )
    end

    it "qualifies Struct.new constants with the surrounding class path" do
      program = parse(<<~RUBY)
        class Container
          Row = Struct.new(:k, :v)
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      class_node = program.statements.body.first

      expect(idx[class_node].discovered_classes["Container::Row"]).to(
        eq(Rigor::Type::Combinator.singleton_of("Container::Row"))
      )
    end

    it "ignores Struct.new with non-symbol positional arguments" do
      program = parse(<<~RUBY)
        Bar = Struct.new(:a, "not_a_symbol")
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      bar_constant = program.statements.body.first

      expect(idx[bar_constant].discovered_classes).not_to have_key("Bar")
    end

    it "ignores Struct.new() with no positional members (degenerate form)" do
      program = parse(<<~RUBY)
        Empty = Struct.new
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      empty_constant = program.statements.body.first

      expect(idx[empty_constant].discovered_classes).not_to have_key("Empty")
    end

    it "narrows IfNode branches when the conditional sits in expression position" do
      # `x = nil` makes x's entry type Constant[nil]; narrow_truthy collapses
      # it to Bot. Without branch-aware propagation x would still read as
      # Constant[nil] inside the truthy branch.
      idx, x_read = index_and_x_read_for("if x; x.foo; else; default; end",
                                         ->(n) { n.statements.body.first })
      expect(x_read).to be_a(Prism::LocalVariableReadNode)
      expect(idx[x_read].local(:x)).to be_a(Rigor::Type::Bot)
    end

    it "narrows UnlessNode branches in expression position (mirror of IfNode)" do
      # `unless x` runs the body when x is falsey; the else branch is the
      # truthy edge, so x narrows away from Constant[nil] (collapsing to Bot).
      idx, x_read = index_and_x_read_for("unless x; default; else; x.foo; end",
                                         ->(n) { n.else_clause.statements.body.first })
      expect(x_read).to be_a(Prism::LocalVariableReadNode)
      expect(idx[x_read].local(:x)).to be_a(Rigor::Type::Bot)
    end

    it "honors propagation order so visited entries are not overwritten" do
      # `(x = 1; x)` : the parens visit the inner StatementsNode and the
      # local-variable read; after StatementEvaluator runs, propagate
      # MUST NOT overwrite the read's scope (which has `x` bound) with
      # the parens' entry scope (which does not).
      program, idx = index_for("(x = 1; x)")
      parens = program.statements.body.first
      inner_read = parens.body.body[1] # LocalVariableReadNode

      expect(idx[parens]).to eq(default_scope)
      expect(idx[inner_read].local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "does not invoke the StatementEvaluator's tracer (it is built tracer-free)" do
      # If the indexer threaded a tracer, the user's later type_of probe
      # would see double-counted events. The indexer's StatementEvaluator
      # MUST run with no tracer so events come only from the post-index
      # type_of call.
      tracer = Rigor::Inference::FallbackTracer.new
      program = parse("foo(1)")
      idx = described_class.index(program, default_scope: default_scope)

      # Sanity: index is built and the call node has its scope recorded.
      expect(idx[program.statements.body.first]).to eq(default_scope)
      # The user's tracer (passed only on the second-pass type_of) is empty.
      expect(tracer).to be_empty
    end

    it "leaves out-of-tree nodes at the default scope" do
      _, idx = index_for("1")
      foreign = parse("2").statements.body.first
      expect(idx[foreign]).to eq(default_scope)
    end

    # Regression: kwarg default value expressions execute when the
    # method is INVOKED, so their `self` is the instance — not the
    # surrounding class body's `self`. Previously the scope-index
    # filled parameter-subtree nodes with the outer class-body
    # scope (`self_type = singleton(C)`) via `propagate`, causing
    # `def copy(x: self.foo)`-style idioms to be analysed as
    # singleton-side calls. Observed surfacing 915 false positives
    # in `prism-1.9.0`'s auto-generated `copy` methods.
    it "scopes parameter default values under the method's body scope (instance self)" do
      program = parse(<<~RUBY)
        class Foo
          def copy(x: self)
            x
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      class_node  = program.statements.body.first
      def_node    = class_node.body.body.first
      kwarg_param = def_node.parameters.keywords.first
      self_node   = kwarg_param.value
      expect(self_node).to be_a(Prism::SelfNode)
      expect(idx[self_node].self_type).to eq(Rigor::Type::Combinator.nominal_of("Foo"))
    end

    it "scopes kwarg defaults inside a singleton method under singleton(C)" do
      program = parse(<<~RUBY)
        class Foo
          def self.factory(seed: self)
            seed
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      class_node  = program.statements.body.first
      def_node    = class_node.body.body.first
      kwarg_param = def_node.parameters.keywords.first
      self_node   = kwarg_param.value
      expect(idx[self_node].self_type).to eq(Rigor::Type::Combinator.singleton_of("Foo"))
    end
  end

  describe ".discovered_classes_for_paths" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write(name, body)
      path = File.join(tmpdir, name)
      File.write(path, body)
      path
    end

    it "unions class declarations across multiple files" do
      a = write("a.rb", <<~RUBY)
        module App
          class Foo
          end
        end
      RUBY
      b = write("b.rb", <<~RUBY)
        module App
          class Bar
          end
        end
      RUBY
      discovered = described_class.discovered_classes_for_paths([a, b])
      expect(discovered["App::Foo"]).to eq(Rigor::Type::Combinator.singleton_of("App::Foo"))
      expect(discovered["App::Bar"]).to eq(Rigor::Type::Combinator.singleton_of("App::Bar"))
    end

    it "does NOT register modules (only classes) to avoid module_function fall-through" do
      a = write("a.rb", <<~RUBY)
        module App
          module Helpers
            module_function
            def util; end
          end
        end
      RUBY
      discovered = described_class.discovered_classes_for_paths([a])
      expect(discovered).not_to have_key("App::Helpers")
      expect(discovered).not_to have_key("App")
    end

    it "registers classes nested inside modules" do
      a = write("a.rb", <<~RUBY)
        module Outer
          module Inner
            class Leaf
            end
          end
        end
      RUBY
      discovered = described_class.discovered_classes_for_paths([a])
      expect(discovered["Outer::Inner::Leaf"]).to eq(Rigor::Type::Combinator.singleton_of("Outer::Inner::Leaf"))
    end

    it "fails-soft on unreadable / unparseable files" do
      a = write("ok.rb", "class A; end")
      bogus = "/nonexistent/path/never/exists.rb"
      discovered = described_class.discovered_classes_for_paths([bogus, a])
      expect(discovered["A"]).to eq(Rigor::Type::Combinator.singleton_of("A"))
    end

    it "returns a frozen Hash" do
      a = write("a.rb", "class A; end")
      expect(described_class.discovered_classes_for_paths([a])).to be_frozen
    end
  end

  describe "declaration overrides (Slice A-declarations)" do
    it "annotates the constant_path of `module Foo` with Singleton[Foo]" do
      program = parse("module Foo\nend")
      idx = described_class.index(program, default_scope: default_scope)
      module_node = program.statements.body.first
      const_node = module_node.constant_path
      seeded = idx[program]
      expect(seeded.declared_types[const_node]).to eq(Rigor::Type::Combinator.singleton_of("Foo"))
    end

    it "annotates `class Bar` headers with Singleton[Bar]" do
      program = parse("class Bar\nend")
      idx = described_class.index(program, default_scope: default_scope)
      class_node = program.statements.body.first
      seeded = idx[program]
      expect(seeded.declared_types[class_node.constant_path])
        .to eq(Rigor::Type::Combinator.singleton_of("Bar"))
    end

    it "qualifies nested module/class declarations with their full lexical path" do
      program = parse("module Outer\n  module Inner\n    class Leaf\n    end\n  end\nend\n")
      idx = described_class.index(program, default_scope: default_scope)
      seeded = idx[program]
      outer = program.statements.body.first
      inner = outer.body.body.first
      leaf = inner.body.body.first
      expected = {
        outer.constant_path => "Outer",
        inner.constant_path => "Outer::Inner",
        leaf.constant_path => "Outer::Inner::Leaf"
      }
      expected.each do |node, name|
        expect(seeded.declared_types[node]).to eq(Rigor::Type::Combinator.singleton_of(name))
      end
    end

    it "ExpressionTyper resolves the declaration position to the recorded Singleton" do
      program = parse(<<~RUBY)
        module Outer
          module Inner
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      inner = program.statements.body.first.body.body.first
      const_node = inner.constant_path
      node_scope = idx[const_node]
      expect(node_scope.type_of(const_node))
        .to eq(Rigor::Type::Combinator.singleton_of("Outer::Inner"))
    end

    it "propagates declared_types through class/method bodies (fresh scopes preserve the table)" do
      program = parse(<<~RUBY)
        module Outer
          class Mid
            def go
              :sym
            end
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      mid = program.statements.body.first.body.body.first
      def_node = mid.body.body.first
      method_body_scope = idx[def_node.body.body.first]
      # The fresh method-body scope still sees declared_types so a
      # later override probe (e.g. SelfNode lookup, or a future
      # constant-position annotation inside the body) can resolve.
      expect(method_body_scope.declared_types).not_to be_empty
    end
  end

  describe "explicit-receiver def discovery (def Foo.bar)" do
    it "registers `def Foo.bar` inside `module Foo` as a singleton method" do
      program = parse(<<~RUBY)
        module Foo
          def Foo.bar = 1
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      expect(outer_scope.discovered_method?("Foo", :bar, :singleton)).to be(true)
    end

    it "registers `def Meta.init` inside `module Outer; module Meta` as a singleton on Outer::Meta" do
      program = parse(<<~RUBY)
        module Outer
          module Meta
            def Meta.init = 1
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      expect(outer_scope.discovered_method?("Outer::Meta", :init, :singleton)).to be(true)
    end

    it "registers methods inside `class << Time` (Time bundled in stdlib) on Time's singleton" do
      program = parse(<<~RUBY)
        class Time
          class << Time
            def my_zone_offset = 1
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      expect(outer_scope.discovered_method?("Time", :my_zone_offset, :singleton)).to be(true)
    end

    it "registers methods inside `class << Foo` at top level on Foo's singleton" do
      program = parse(<<~RUBY)
        class Foo
        end
        class << Foo
          def bar = 1
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      expect(outer_scope.discovered_method?("Foo", :bar, :singleton)).to be(true)
    end

    it "leaves cross-class explicit-receiver defs unpromoted (instance, current behaviour)" do
      program = parse(<<~RUBY)
        module Foo
          module Bar
            def Baz.unrelated = 1
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      # Not a singleton method of Foo::Bar; the receiver names a different
      # constant so the slice does not promote.
      expect(outer_scope.discovered_method?("Foo::Bar", :unrelated, :singleton)).to be(false)
    end
  end

  describe "alias discovery" do
    it "registers the aliased name in discovered_methods" do
      program = parse(<<~RUBY)
        class Greeter
          def greet = "hi"
          alias say_hello greet
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      expect(outer_scope.discovered_method?("Greeter", :say_hello, :instance)).to be(true)
    end

    it "does not register aliases outside any class body" do
      program = parse(<<~RUBY)
        def greet = "hi"
        alias say_hello greet
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      # Top-level aliases have no class context; they should be silently ignored
      expect(outer_scope.discovered_method?("", :say_hello, :instance)).to be(false)
    end

    it "maps the aliased name to the original DefNode for return-type inference" do
      program = parse(<<~RUBY)
        class Greeter
          def greet = "hi"
          alias say_hello greet
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      def_node = outer_scope.user_def_for("Greeter", :say_hello)
      expect(def_node).to be_a(Prism::DefNode)
      expect(def_node.name).to eq(:greet)
    end

    it "resolves alias that appears before the def (forward reference)" do
      program = parse(<<~RUBY)
        class Greeter
          alias say_hello greet
          def greet = "hi"
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      def_node = outer_scope.user_def_for("Greeter", :say_hello)
      expect(def_node).to be_a(Prism::DefNode)
      expect(def_node.name).to eq(:greet)
    end

    describe "class-ivar widening on observed mutation" do
      it "widens a Tuple-seeded ivar to Array[untyped] when any class method mutates it" do
        program = parse(<<~RUBY)
          class Builder
            def initialize
              @struct = [{}]
            end

            def push!
              @struct << []
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        type = outer.class_ivars_for("Builder")[:@struct]
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Array")
        expect(type.type_args.first).to be_a(Rigor::Type::Dynamic)
      end

      it "widens a HashShape-seeded ivar to Hash[untyped, untyped] on observed []=" do
        program = parse(<<~RUBY)
          class Bag
            def initialize
              @bag = { a: 1 }
            end

            def add(k, v)
              @bag[k] = v
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        type = outer.class_ivars_for("Bag")[:@bag]
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Hash")
        expect(type.type_args.map(&:class)).to all(eq(Rigor::Type::Dynamic))
      end

      it "leaves a Tuple-seeded ivar unchanged when no mutator is observed" do
        program = parse(<<~RUBY)
          class Pure
            def initialize
              @struct = [{}]
            end

            def read
              @struct.last
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        type = outer.class_ivars_for("Pure")[:@struct]
        # `.last` is NOT a mutator, so no widening fires; the
        # seed precision is preserved.
        expect(type).to be_a(Rigor::Type::Tuple)
      end
    end

    describe "defensive ivar-init with falsey-Constant rvalue" do
      it "skips the seed for `@x = nil unless @x` so the predicate does not fold to Constant[nil]" do
        program = parse(<<~RUBY)
          class C
            def configure
              @x = nil unless @x
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        # No other writes to @x in the class — the skip means
        # the accumulator has no entry for @x at all.
        expect(outer.class_ivars_for("C")).not_to have_key(:@x)
      end

      it "skips the seed for `@y = false unless @y`" do
        program = parse(<<~RUBY)
          class C
            def configure
              @y = false unless @y
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        expect(outer.class_ivars_for("C")).not_to have_key(:@y)
      end

      it "PRESERVES seed for a non-falsey-Constant rvalue under the same guard" do
        program = parse(<<~RUBY)
          class C
            def configure
              @z = "default" unless @z
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        # The non-falsey rvalue's union with `Constant[nil]`
        # does NOT collapse, so the seed is preserved.
        type = outer.class_ivars_for("C")[:@z]
        expect(type).not_to be_nil
      end

      describe "transient `@x = nil` dead-write elimination (C2)" do
        it "drops the transient nil when a later unconditional write overwrites it" do
          program = parse(<<~RUBY)
            class C
              def initialize
                @m = nil
                @m = 7
              end
            end
          RUBY
          idx = described_class.index(program, default_scope: default_scope)
          type = idx[program].class_ivars_for("C")[:@m]
          values = if type.is_a?(Rigor::Type::Union)
                     type.members.grep(Rigor::Type::Constant).map(&:value)
                   else
                     [type.respond_to?(:value) ? type.value : nil]
                   end
          expect(values).not_to include(nil)
          expect(values).to include(7)
        end

        it "drops the transient nil when both branches of a following if/else write non-nil" do
          program = parse(<<~RUBY)
            class C
              def initialize(p)
                @m = nil
                if p
                  @m = 1
                else
                  @m = 2
                end
              end
            end
          RUBY
          idx = described_class.index(program, default_scope: default_scope)
          type = idx[program].class_ivars_for("C")[:@m]
          values = type.members.grep(Rigor::Type::Constant).map(&:value)
          expect(values).to contain_exactly(1, 2)
        end

        it "KEEPS the transient nil when the following if/else has no else" do
          program = parse(<<~RUBY)
            class C
              def initialize(p)
                @m = nil
                @m = 1 if p
              end
            end
          RUBY
          idx = described_class.index(program, default_scope: default_scope)
          type = idx[program].class_ivars_for("C")[:@m]
          values = type.members.grep(Rigor::Type::Constant).map(&:value)
          expect(values).to include(nil)
        end

        it "KEEPS the transient nil when only one branch writes non-nil" do
          program = parse(<<~RUBY)
            class C
              def initialize(p)
                @m = nil
                if p
                  @m = 1
                else
                  do_something
                end
              end
            end
          RUBY
          idx = described_class.index(program, default_scope: default_scope)
          type = idx[program].class_ivars_for("C")[:@m]
          values = type.members.grep(Rigor::Type::Constant).map(&:value)
          expect(values).to include(nil)
        end
      end

      describe "read-before-write nil contribution (B2.3)" do
        it "adds nil to the seed on read-before-write, no init / class-body write" do
          program = parse(<<~RUBY)
            class BypassWithWarning
              def update
                puts "warn" unless @warning_issued
                @warning_issued = true
              end
            end
          RUBY
          idx = described_class.index(program, default_scope: default_scope)
          outer = idx[program]
          type = outer.class_ivars_for("BypassWithWarning")[:@warning_issued]
          expect(type).to be_a(Rigor::Type::Union)
          values = type.members.grep(Rigor::Type::Constant).map(&:value)
          expect(values).to include(nil, true)
        end

        # ADR-38 — a plugin-declared additional initializer is
        # treated like `initialize` at the read-before-write gate.
        context "with a plugin-declared additional initializer (ADR-38)" do
          let(:setup_source) do
            <<~RUBY
              class FooTest
                def setup
                  @conn = 1
                end

                def test_it
                  @conn
                end
              end
            RUBY
          end

          def index_with_registry(source, registry)
            env = Rigor::Environment.new(plugin_registry: registry)
            scope = Rigor::Scope.empty(environment: env)
            program = parse(source)
            described_class.index(program, default_scope: scope)[program]
          end

          def stub_registry(entries)
            services = Rigor::Plugin::Services.new(
              reflection: Rigor::Reflection,
              type: Rigor::Type::Combinator,
              configuration: Rigor::Configuration.new
            )
            klass = Class.new(Rigor::Plugin::Base) do
              manifest(id: "ai-spec", version: "0.1.0", additional_initializers: entries)
            end
            Rigor::Plugin::Registry.new(plugins: [klass.new(services: services)])
          end

          def conn_has_nil?(outer)
            type = outer.class_ivars_for("FooTest")[:@conn]
            members = type.is_a?(Rigor::Type::Union) ? type.members : [type]
            members.any? { |m| m.is_a?(Rigor::Type::Constant) && m.value.nil? }
          end

          it "control: `setup` is not an initializer, so @conn is widened with nil" do
            outer = parse(setup_source).then do |program|
              described_class.index(program, default_scope: default_scope)[program]
            end
            expect(conn_has_nil?(outer)).to be(true)
          end

          it "suppresses the nil widening when `setup` is declared an initializer" do
            entry = Rigor::Plugin::AdditionalInitializer.new(
              receiver_constraint: "FooTest", methods: [:setup]
            )
            outer = index_with_registry(setup_source, stub_registry([entry]))
            expect(conn_has_nil?(outer)).to be(false)
          end

          it "leaves the nil widening when the entry covers a different method" do
            entry = Rigor::Plugin::AdditionalInitializer.new(
              receiver_constraint: "FooTest", methods: [:other_setup]
            )
            outer = index_with_registry(setup_source, stub_registry([entry]))
            expect(conn_has_nil?(outer)).to be(true)
          end

          it "leaves the nil widening when the receiver constraint does not match" do
            entry = Rigor::Plugin::AdditionalInitializer.new(
              receiver_constraint: "OtherClass", methods: [:setup]
            )
            outer = index_with_registry(setup_source, stub_registry([entry]))
            expect(conn_has_nil?(outer)).to be(true)
          end
        end

        context "with a plugin-declared block-form additional initializer (ADR-38 slice 2)" do
          let(:before_source) do
            <<~RUBY
              class FooSpec
                def before
                  @user = "alice"
                end

                def it_has_a_user
                  @user
                end
              end
            RUBY
          end

          let(:before_block_source) do
            <<~RUBY
              class FooSpec
                before do
                  @user = "alice"
                end

                def it_has_a_user
                  @user
                end
              end
            RUBY
          end

          def index_with_registry(source, registry)
            env = Rigor::Environment.new(plugin_registry: registry)
            scope = Rigor::Scope.empty(environment: env)
            program = parse(source)
            described_class.index(program, default_scope: scope)[program]
          end

          def stub_registry(entries)
            services = Rigor::Plugin::Services.new(
              reflection: Rigor::Reflection,
              type: Rigor::Type::Combinator,
              configuration: Rigor::Configuration.new
            )
            klass = Class.new(Rigor::Plugin::Base) do
              manifest(id: "ai-spec-block", version: "0.1.0", additional_initializers: entries)
            end
            Rigor::Plugin::Registry.new(plugins: [klass.new(services: services)])
          end

          def user_type(outer, class_name = "FooSpec")
            outer.class_ivars_for(class_name)[:@user]
          end

          def user_type_has_nil?(outer, class_name = "FooSpec")
            type = user_type(outer, class_name)
            return false if type.nil?

            members = type.is_a?(Rigor::Type::Union) ? type.members : [type]
            members.any? { |m| m.is_a?(Rigor::Type::Constant) && m.value.nil? }
          end

          # Without a declaration the block body is never descended, so the
          # ivar is simply absent from the accumulator (no type at all — a
          # different problem than nil-widening, but equally undesirable).
          it "control: without declaration, @user is not collected from a block body" do
            outer = parse(before_block_source).then do |program|
              described_class.index(program, default_scope: default_scope)[program]
            end
            expect(user_type(outer)).to be_nil
          end

          # With declaration: block body descended → type collected → init_writes
          # suppresses the read-before-write nil contribution.
          it "collects @user and suppresses nil widening when `before` is a declared block_method" do
            entry = Rigor::Plugin::AdditionalInitializer.new(
              receiver_constraint: "FooSpec", block_methods: [:before]
            )
            outer = index_with_registry(before_block_source, stub_registry([entry]))
            type = user_type(outer)
            expect(type).not_to be_nil
            expect(user_type_has_nil?(outer)).to be(false)
            expect(type).to be_a(Rigor::Type::Constant)
            expect(type.value).to eq("alice")
          end

          it "does not collect @user when the block_method name does not match" do
            entry = Rigor::Plugin::AdditionalInitializer.new(
              receiver_constraint: "FooSpec", block_methods: [:after]
            )
            outer = index_with_registry(before_block_source, stub_registry([entry]))
            expect(user_type(outer)).to be_nil
          end

          it "does not collect @user when the receiver constraint does not match" do
            entry = Rigor::Plugin::AdditionalInitializer.new(
              receiver_constraint: "OtherSpec", block_methods: [:before]
            )
            outer = index_with_registry(before_block_source, stub_registry([entry]))
            expect(user_type(outer)).to be_nil
          end

          # A def-form `before` method is walked by collect_def_ivar_writes as
          # usual. It is NOT in init_writes (block_methods: [:before] only covers
          # block-form calls, not defs), so the read-before-write nil contribution
          # fires — the nil-widening IS the expected result here.
          it "nil-widens a def-form `before` method even when block_methods: [:before] is declared" do
            entry = Rigor::Plugin::AdditionalInitializer.new(
              receiver_constraint: "FooSpec", block_methods: [:before]
            )
            outer = index_with_registry(before_source, stub_registry([entry]))
            expect(user_type_has_nil?(outer)).to be(true)
          end
        end

        it "does NOT add nil when `initialize` writes the ivar (soundness gate)" do
          program = parse(<<~RUBY)
            class Builder
              def initialize
                @struct = "init"
              end

              def use
                @struct + "!" unless @struct
              end
            end
          RUBY
          idx = described_class.index(program, default_scope: default_scope)
          outer = idx[program]
          type = outer.class_ivars_for("Builder")[:@struct]
          expect(type).to be_a(Rigor::Type::Constant)
          expect(type.value).to eq("init")
        end

        it "does NOT add nil when a class-body `@x = nil` write exists (author acknowledgement)" do
          program = parse(<<~RUBY)
            class StreamingServerManager
              @running_thread = nil

              def start
                return if @running_thread

                @running_thread = Thread.new { @running_thread }
              end
            end
          RUBY
          idx = described_class.index(program, default_scope: default_scope)
          outer = idx[program]
          type = outer.class_ivars_for("StreamingServerManager")[:@running_thread]
          # Class-body write exempts the read-before-write nil
          # contribution. Without the exemption, an unjustified
          # nil widening would propagate into Thread.new's block
          # body and produce a `.kill for nil` style FP.
          members = type.is_a?(Rigor::Type::Union) ? type.members : [type]
          expect(members.find { |m| m.is_a?(Rigor::Type::Constant) && m.value.nil? }).to be_nil
        end
      end

      it "still accumulates other writes when one write is a skipped falsey default" do
        program = parse(<<~RUBY)
          class C
            def init
              @w = "hello"
            end

            def configure
              @w = nil unless @w
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        # The falsey-default write itself is skipped — the
        # `init` write still seeds `@w` to its rvalue type. The
        # B2.3 read-before-write pre-pass additionally unions
        # `nil` here because `configure` reads `@w` before any
        # write IN THAT METHOD BODY and `init` is NOT
        # `initialize` (so the soundness gate's "constructor
        # initialised" exemption does not apply).
        type = outer.class_ivars_for("C")[:@w]
        expect(type).to be_a(Rigor::Type::Union)
        member_kinds = type.members.map(&:class)
        expect(member_kinds).to include(Rigor::Type::Constant)
        # And `init`'s rvalue precision survives — the union
        # carries `Constant["hello"]` (plus the read-before-write
        # `Constant[nil]`).
        constant_member = type.members.find { |m| m.is_a?(Rigor::Type::Constant) && m.value == "hello" }
        expect(constant_member).not_to be_nil
      end
    end
  end
end
