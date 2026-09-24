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
      # The local-variable read happens AFTER the assignment, so its entry scope MUST carry `x` bound to Constant[1].
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

    it "shadows an outer local inside a block the evaluator never entered" do
      program, idx = index_for(<<~RUBY)
        o = "s"
        k = 2
        show([1].map { |o| o + k })
        [1].map { |o| o }
      RUBY
      value_block = program.statements.body[2].arguments.arguments.first.block
      sum = value_block.body.body.first
      statement_read = program.statements.body[3].block.body.body.first

      # The argument's block reaches the index only through `propagate`. Its parameter is a new variable, so the
      # outer `o` MUST NOT be visible inside it, while the captured `k` keeps its enclosing binding.
      expect(idx[sum.receiver].local(:o)).to eq(Rigor::Type::Combinator.untyped)
      expect(idx[sum.arguments.arguments.first].local(:k)).to eq(Rigor::Type::Combinator.constant_of(2))
      # A statement-level block is entered, and its parameter keeps the signature's element type.
      expect(idx[statement_read].local(:o)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "shadows a local the unentered block's body introduces, not only its parameters" do
      # No outer `z` exists in the source, so Ruby makes the body's `z` the block's own local. The seeded binding
      # stands in for a name the scope binds for a non-lexical reason; the block's local table MUST still win.
      seeded = Rigor::Scope.empty.with_local(:z, Rigor::Type::Combinator.constant_of("s"))
      program = parse("show([1].map { |e| z = e; z })")
      idx = described_class.index(program, default_scope: seeded)
      z_read = program.statements.body.first.arguments.arguments.first.block.body.body[1]

      expect(z_read).to be_a(Prism::LocalVariableReadNode)
      expect(idx[z_read].local(:z)).to eq(Rigor::Type::Combinator.untyped)
    end

    it "binds locals visible to children inside an rvalue expression" do
      program, idx = index_for(<<~RUBY)
        x = 1
        y = x + 2
      RUBY
      assignment_y = program.statements.body[1]
      rhs = assignment_y.value # CallNode for `x + 2`
      receiver = rhs.receiver  # LocalVariableReadNode for `x`

      # The rvalue (and its receiver child) is reached via sub_eval from eval_local_write under the post-`x = 1` scope,
      # so `x` MUST be visible at both the call and its receiver.
      expect(idx[rhs].local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(idx[receiver].local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "materialises program-wide globals directly into the top-level seeded scope (Slice 7 phase 6)" do
      # Distinct from a read reached VIA the `program_globals` accumulator (a def body's entry scope): this pins the
      # top-level seeded scope's OWN `.global` map, which top-level / CLI-probe reads consult directly without going
      # through the accumulator.
      program, idx = index_for(<<~RUBY)
        $verbose = true
        $verbose
      RUBY

      expect(idx[program].global(:$verbose)).to eq(Rigor::Type::Combinator.constant_of(true))
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

      # After the if (with no else), nil-injection on the join-with-nil path makes `x` visible as `Constant[1] |
      # Constant[nil]`.
      expect(idx[after_if].local(:x)).to be_a(Rigor::Type::Union)
      expect(idx[after_if].local(:x).members.map(&:value)).to contain_exactly(1, nil)
    end

    # Returns the index built for the canonical "expression-position conditional with a previously-bound x" shape, plus
    # the LocalVariableReadNode for `x` extracted by `branch_path`. Pre-binding `x = nil` makes Prism parse the inner
    # `x` as a local read; the surrounding `[]=` CallNode hides the conditional from StatementEvaluator's eval_if path.
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

    # v0.1.2 — Data.define / Struct.new block-body methods are registered under the constant's qualified name in both
    # `discovered_methods` and `discovered_def_nodes`. Without this, the block-body `def initialize(...)` override is
    # invisible to `Reflection.user_def_for` / `discovered_method?` and the canonical-sig contract is missing.
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

    # Module-singleton call resolution (ADR-57 follow-up) — singleton-side def-node table that
    # `ExpressionTyper#try_singleton_method_inference` re-types against a `Singleton[X]` receiver.
    it "records `def self.x` / `def Foo.x` / `class << self` singleton def-nodes" do
      program = parse(<<~RUBY)
        module Util
          def self.triple(x) = x * 3
        end
        class Calc
          def self.double(x) = x * 2
          def instance_only = 1
        end
        module Meta
          class << self
            def helper(y) = y
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.singleton_def_for("Util", :triple)).to be_a(Prism::DefNode)
      expect(scope.singleton_def_for("Calc", :double)).to be_a(Prism::DefNode)
      expect(scope.singleton_def_for("Meta", :helper)).to be_a(Prism::DefNode)
      # Instance defs stay out of the singleton table.
      expect(scope.singleton_def_for("Calc", :instance_only)).to be_nil
      # ...and instance lookups don't see singleton defs.
      expect(scope.user_def_for("Util", :triple)).to be_nil
    end

    it "records `module_function` methods as singleton def-nodes (bare and named forms)" do
      program = parse(<<~RUBY)
        module Bare
          module_function

          def quad(x) = x * 4
        end
        module Named
          def half(x) = x / 2
          module_function :half
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.singleton_def_for("Bare", :quad)).to be_a(Prism::DefNode)
      expect(scope.singleton_def_for("Named", :half)).to be_a(Prism::DefNode)
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

    # Survey item (e) — `Const = Module.new do ... end` and `Const = Class.new(?super) do ... end` are block-as-method
    # idioms that mirror the Data.define / Struct.new shape: the block body holds method overrides whose canonical class
    # is the named constant. Driven by `references/ruby/lib/resolv.rb` (~8 sites) where `ClassHash = Module.new do; def
    # []=; ...; end; end` registers an instance method that `ClassHash[k] = v` then calls.
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

    # #319 — the same idiom away from constant-write position. There is no constant to key the body's methods by, so
    # the call site supplies a synthetic name; without it the whole body was walked in the ENCLOSING scope, and at file
    # top level that meant `def initialize` never reached the class the call returns.
    it "registers an anonymous Class.new block body under the call site's synthetic name" do
      program = parse(<<~RUBY)
        observer = Class.new do
          attr_reader :count

          def initialize(bucket)
            @bucket = bucket
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]
      name = Rigor::Inference::AnonymousMetaClass.name_for(program.statements.body.first.value)

      expect(scope.discovered_method?(name, :initialize, :instance)).to be(true)
      expect(scope.discovered_method?(name, :count, :instance)).to be(true)
      expect(scope.user_def_for(name, :initialize)).to be_a(Prism::DefNode)
    end

    it "keeps a nested anonymous Module.new body out of the enclosing class's method table" do
      program = parse(<<~RUBY)
        class Host
          def build
            Module.new do
              def helper
              end
            end
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]

      expect(scope.discovered_method?("Host", :helper, :instance)).to be(false)
    end

    it "records the superclass a Class.new(Parent) block form was given" do
      program = parse(<<~RUBY)
        klass = Class.new(StandardError) do
          def alpha
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]
      name = Rigor::Inference::AnonymousMetaClass.name_for(program.statements.body.first.value)

      expect(scope.superclass_of(name)).to eq("StandardError")
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
      # `x = nil` makes x's entry type Constant[nil]; narrow_truthy collapses it to Bot. Without branch-aware
      # propagation x would still read as Constant[nil] inside the truthy branch.
      idx, x_read = index_and_x_read_for("if x; x.foo; else; default; end",
                                         ->(n) { n.statements.body.first })
      expect(x_read).to be_a(Prism::LocalVariableReadNode)
      expect(idx[x_read].local(:x)).to be_a(Rigor::Type::Bot)
    end

    it "narrows UnlessNode branches in expression position (mirror of IfNode)" do
      # `unless x` runs the body when x is falsey; the else branch is the truthy edge, so x narrows away from
      # Constant[nil] (collapsing to Bot).
      idx, x_read = index_and_x_read_for("unless x; default; else; x.foo; end",
                                         ->(n) { n.else_clause.statements.body.first })
      expect(x_read).to be_a(Prism::LocalVariableReadNode)
      expect(idx[x_read].local(:x)).to be_a(Rigor::Type::Bot)
    end

    it "honors propagation order so visited entries are not overwritten" do
      # `(x = 1; x)` : the parens visit the inner StatementsNode and the local-variable read; after StatementEvaluator
      # runs, propagate MUST NOT overwrite the read's scope (which has `x` bound) with the parens' entry scope (which
      # does not).
      program, idx = index_for("(x = 1; x)")
      parens = program.statements.body.first
      inner_read = parens.body.body[1] # LocalVariableReadNode

      expect(idx[parens]).to eq(default_scope)
      expect(idx[inner_read].local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "does not invoke the StatementEvaluator's tracer (it is built tracer-free)" do
      # If the indexer threaded a tracer, the user's later type_of probe would see double-counted events. The indexer's
      # StatementEvaluator MUST run with no tracer so events come only from the post-index type_of call.
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

    # Regression: kwarg default value expressions execute when the method is INVOKED, so their `self` is the instance —
    # not the surrounding class body's `self`. Previously the scope-index filled parameter-subtree nodes with the outer
    # class-body scope (`self_type = singleton(C)`) via `propagate`, causing `def copy(x: self.foo)`-style idioms to be
    # analysed as singleton-side calls. Observed surfacing 915 false positives in `prism-1.9.0`'s auto-generated `copy`
    # methods.
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

    it "registers modules on the same terms as classes (ADR-57 WD3)" do
      a = write("a.rb", <<~RUBY)
        module App
          module Helpers
            module_function
            def util; end
          end
        end
      RUBY
      discovered = described_class.discovered_classes_for_paths([a])
      expect(discovered["App"]).to eq(Rigor::Type::Combinator.singleton_of("App"))
      expect(discovered["App::Helpers"]).to eq(Rigor::Type::Combinator.singleton_of("App::Helpers"))
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

  describe ".discovered_project_index_for_paths (single-parse combined pre-pass)" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write(name, body)
      path = File.join(tmpdir, name)
      File.write(path, body)
      path
    end

    def fixture_paths
      a = write("a.rb", <<~RUBY)
        module App
          class Base
            def shared; end
          end
          Point = Data.define(:x, :y)
        end
      RUBY
      b = write("b.rb", <<~RUBY)
        module App
          class Child < Base
            include Comparable
            attr_reader :name
            def self.build = new
          end
        end
      RUBY
      [a, b]
    end

    it "returns the same classes + def_index the two separate passes produce" do
      paths = fixture_paths
      combined = described_class.discovered_project_index_for_paths(paths)
      di = combined.fetch(:def_index)
      sep_def = described_class.discovered_def_index_for_paths(paths)

      expect(combined.fetch(:classes)).to eq(described_class.discovered_classes_for_paths(paths))
      # String/symbol-valued tables compare directly (value-equal across parses).
      %i[def_sources superclasses includes class_sources method_visibilities methods
         data_member_layouts struct_member_layouts].each do |key|
        expect(di[key]).to eq(sep_def[key]), "def_index[#{key}] mismatch"
      end
      # Node-bearing tables: Prism nodes from two independent parses are not `==`, so compare the
      # class -> method-name key structure instead.
      %i[def_nodes singleton_def_nodes].each do |key|
        expect(di[key].transform_values(&:keys)).to eq(sep_def[key].transform_values(&:keys)), "#{key} mismatch"
      end
    end

    it "parses each file exactly once (vs twice for the two separate passes)" do
      paths = fixture_paths

      allow(Prism).to receive(:parse).and_call_original
      described_class.discovered_project_index_for_paths(paths)
      # One combined walk = one parse per file.
      expect(Prism).to have_received(:parse).exactly(paths.size).times

      RSpec::Mocks.space.proxy_for(Prism).reset
      allow(Prism).to receive(:parse).and_call_original
      described_class.discovered_classes_for_paths(paths)
      described_class.discovered_def_index_for_paths(paths)
      # The two separate passes parse every file twice.
      expect(Prism).to have_received(:parse).exactly(paths.size * 2).times
    end

    it "fails-soft on unreadable / unparseable files (contributes nothing to either table)" do
      a = write("ok.rb", "class A; def m; end; end")
      bogus = "/nonexistent/path/never/exists.rb"
      combined = described_class.discovered_project_index_for_paths([bogus, a])

      expect(combined.fetch(:classes)["A"]).to eq(Rigor::Type::Combinator.singleton_of("A"))
      expect(combined.fetch(:def_index)[:def_nodes]).to have_key("A")
    end

    it "freezes the classes table and each def_index sub-table (matching the two separate passes)" do
      paths = fixture_paths
      combined = described_class.discovered_project_index_for_paths(paths)
      expect(combined.fetch(:classes)).to be_frozen
      expect(combined.fetch(:def_index)[:def_nodes]).to be_frozen
      expect(combined.fetch(:def_index)[:superclasses]).to be_frozen
    end
  end

  describe "declaration_signature parts (ADR-89 WD1)" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write(name, body)
      path = File.join(tmpdir, name)
      File.write(path, body)
      path
    end

    it "joins a multi-module include list with a comma (append_ancestry_signature)" do
      path = write("a.rb", <<~RUBY)
        module ModA; end
        module ModB; end

        class Foo
          include ModA
          include ModB
        end
      RUBY
      file_index = described_class.discovered_project_index_for_paths([path]).fetch(:def_index)
      parts = []
      described_class.append_ancestry_signature(parts, file_index)
      expect(parts).to include("i:Foo=ModA,ModB")
    end

    it "joins a multi-parameter signature with a comma (parameter_signature)" do
      path = write("a.rb", <<~RUBY)
        class Foo
          def bar(x, y:, z: 1)
            x
          end
        end
      RUBY
      program = parse(File.read(path))
      idx = described_class.index(program, default_scope: default_scope)
      def_node = idx[program].user_def_for("Foo", :bar)
      expect(described_class.parameter_signature(def_node)).to eq("(r:x,kr:y,ko:z)")
    end
  end

  describe ".discovered_project_index_incremental (ADR-85 WD2 fold path)" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write(name, body)
      path = File.join(tmpdir, name)
      File.write(path, body)
      path
    end

    it "Set-unions class_sources across files that reopen the same class (fold_ancestry_tables)" do
      a = write("a.rb", "class Shared\n  include Comparable\nend\n")
      b = write("b.rb", "class Shared\n  include Enumerable\nend\n")

      combined = described_class.discovered_project_index_incremental([a, b], seed_bundles: {})
      di = combined.fetch(:def_index)

      expect(di[:class_sources]["Shared"]).to eq(Set[a, b])
      expect(di[:includes]["Shared"]).to contain_exactly("Comparable", "Enumerable")
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
      # The fresh method-body scope still sees declared_types so a later override probe (e.g. SelfNode lookup, or a
      # future constant-position annotation inside the body) can resolve.
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

    # #320 — the private-singleton-object idiom. Ruby evaluates the assignment, then opens the singleton of the
    # resulting object, which is the object the constant now holds; the body's methods are therefore reachable as
    # `Merger.<name>` exactly as for a body opened on a plain constant read.
    it "registers methods inside `class << Merger = Object.new` on the written constant's singleton" do
      program = parse(<<~RUBY)
        class << Merger = Object.new
          def merge_attributes!(a, b) = a
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      expect(outer_scope.discovered_method?("Merger", :merge_attributes!, :singleton)).to be(true)
    end

    it "registers a `class << Outer::Merger = Object.new` body on the written constant path" do
      program = parse(<<~RUBY)
        class << Outer::Merger = Object.new
          def call = 1
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      expect(outer_scope.discovered_method?("Outer::Merger", :call, :singleton)).to be(true)
    end

    it "leaves a `class << local = Object.new` body unregistered (no constant to key on)" do
      program = parse(<<~RUBY)
        class << merger = Object.new
          def call = 1
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      outer_scope = idx[program]
      expect(outer_scope.discovered_method?("merger", :call, :singleton)).to be(false)
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
      # Not a singleton method of Foo::Bar; the receiver names a different constant so the slice does not promote.
      expect(outer_scope.discovered_method?("Foo::Bar", :unrelated, :singleton)).to be(false)
    end
  end

  # #239 — the `discovered_methods` table is keyed by method NAME, so a class that defines one name on both sides
  # (`def helper` plus a `class << self` twin) used to record whichever `def` the walk reached last and lose the
  # other. `Scope#discovered_method?` then answered false for a method the source plainly defines, and the
  # undefined-method rule fired on correct Ruby.
  describe "a name defined on both the instance and singleton side" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write(name, body)
      path = File.join(tmpdir, name)
      File.write(path, body)
      path
    end

    it "records both kinds for a `class << self` twin, whichever order they appear in" do
      %w[singleton_first instance_first].each do |order|
        singleton = "class << self\n    def helper(value) = value\n  end"
        instance = "def helper(value) = value"
        body = order == "singleton_first" ? [singleton, instance] : [instance, singleton]
        program = parse("class Collides\n  #{body.join("\n  ")}\nend\n")
        scope = described_class.index(program, default_scope: default_scope)[program]

        expect(scope.discovered_method?("Collides", :helper, :instance)).to be(true), order
        expect(scope.discovered_method?("Collides", :helper, :singleton)).to be(true), order
      end
    end

    it "records both kinds for a `def self.` twin" do
      program = parse(<<~RUBY)
        class Collides
          def helper(value) = value
          def self.helper(value) = value
        end
      RUBY
      scope = described_class.index(program, default_scope: default_scope)[program]

      expect(scope.discovered_method?("Collides", :helper, :instance)).to be(true)
      expect(scope.discovered_method?("Collides", :helper, :singleton)).to be(true)
    end

    it "records both kinds when an attr_accessor collides with a singleton def of the same name" do
      program = parse(<<~RUBY)
        class Collides
          attr_accessor :helper
          def self.helper = 1
        end
      RUBY
      scope = described_class.index(program, default_scope: default_scope)[program]

      expect(scope.discovered_method?("Collides", :helper, :instance)).to be(true)
      expect(scope.discovered_method?("Collides", :helper, :singleton)).to be(true)
    end

    it "keeps a single kind for a name defined on one side only" do
      program = parse("class Solo\n  def helper(value) = value\nend\n")
      scope = described_class.index(program, default_scope: default_scope)[program]

      expect(scope.discovered_method?("Solo", :helper, :instance)).to be(true)
      expect(scope.discovered_method?("Solo", :helper, :singleton)).to be(false)
    end

    it "unions the two kinds across files in the cross-file index" do
      # The cross-file table subtracts names that have an instance `def` (the ADR-17 monkey-patch contract), but the
      # singleton half comes from a definition that rule never covered, so it must survive the subtraction.
      paths = [
        write("a.rb", "class Cross\n  def helper(value) = value\nend\n"),
        write("b.rb", "class Cross\n  class << self\n    def helper(value) = value\n  end\nend\n")
      ]
      index = described_class.discovered_project_index_for_paths(paths)

      expect(index[:def_index][:methods]["Cross"][:helper]).to eq(:singleton)
    end

    it "drops an instance-only name from the cross-file index, as before" do
      paths = [write("a.rb", "class Solo\n  def helper(value) = value\nend\n")]
      index = described_class.discovered_project_index_for_paths(paths)

      expect(index[:def_index][:methods]["Solo"]).to be_nil
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
        # `.last` is NOT a mutator, so no widening fires; the seed precision is preserved.
        expect(type).to be_a(Rigor::Type::Tuple)
      end

      it "widens only the Tuple member of a Union-seeded ivar (sibling writes of different shapes)" do
        program = parse(<<~RUBY)
          class Multi
            def initialize
              @data = [1]
            end

            def reset
              @data = :x
            end

            def push!
              @data << 2
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        type = outer.class_ivars_for("Multi")[:@data]
        expect(type).to be_a(Rigor::Type::Union)
        array_member = type.members.grep(Rigor::Type::Nominal).find { |m| m.class_name == "Array" }
        expect(array_member.type_args.first).to be_a(Rigor::Type::Dynamic)
        expect(type.members).to include(Rigor::Type::Combinator.constant_of(:x))
      end

      # `<<` is a String mutator as well as an Array one, and `"x" << 2` appends a codepoint at runtime, so the
      # String member widens beside the Tuple one rather than keeping a value the append falsified.
      it "widens a String-literal member of a Union-seeded ivar under a mutator both classes share" do
        program = parse(<<~RUBY)
          class Multi
            def initialize
              @data = [1]
            end

            def reset
              @data = "x"
            end

            def push!
              @data << 2
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        type = outer.class_ivars_for("Multi")[:@data]
        expect(type.members).to include(Rigor::Type::Combinator.nominal_of("String"))
        expect(type.members).not_to include(Rigor::Type::Combinator.constant_of("x"))
      end
    end

    describe "ivar escape through a self-call return" do
      it "widens an ivar mutated through the alias a sibling method returned" do
        program = parse(<<~RUBY)
          class Rows
            def initialize
              @path_rows = {}
            end

            def bucket_for(kind)
              return @path_rows if kind == :path

              {}
            end

            def absorb(kind, key)
              (bucket_for(kind)[key] ||= {})["m"] = 1
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        type = idx[program].class_ivars_for("Rows")[:@path_rows]
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Hash")
      end

      it "widens through a tail-position return, not only an explicit `return`" do
        program = parse(<<~RUBY)
          class Rows
            def initialize
              @rows = []
            end

            def bucket
              @rows
            end

            def absorb(x)
              bucket << x
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        type = idx[program].class_ivars_for("Rows")[:@rows]
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Array")
      end

      it "leaves the shape alone when the callee returns a VALUE from the ivar rather than the ivar" do
        program = parse(<<~RUBY)
          class Rows
            def initialize
              @rows = { a: 1 }
            end

            def at(key)
              @rows[key]
            end

            def absorb(key)
              at(key) << 1
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        expect(idx[program].class_ivars_for("Rows")[:@rows]).to be_a(Rigor::Type::HashShape)
      end

      it "leaves the shape alone when the mutation receiver is an explicit receiver, not self" do
        program = parse(<<~RUBY)
          class Rows
            def initialize
              @rows = { a: 1 }
            end

            def bucket
              @rows
            end

            def absorb(other, key)
              other.bucket[key] = 1
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        expect(idx[program].class_ivars_for("Rows")[:@rows]).to be_a(Rigor::Type::HashShape)
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
        # No other writes to @x in the class — the skip means the accumulator has no entry for @x at all.
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
        # The non-falsey rvalue's union with `Constant[nil]` does NOT collapse, so the seed is preserved.
        type = outer.class_ivars_for("C")[:@z]
        expect(type).not_to be_nil
      end

      # #1175 — compound ivar writes (`@x ||= v` / `@x &&= v` / `@x op= v`) contribute to the
      # class-ivar seed. ADR-58 § WD5 deferred the `||=` seed with a reopen clause; Rigor's own
      # `unit_scan.rb` surfaced the shape it was waiting on: `@dispatch_top_level ||= true` was
      # invisible to the pre-pass, the ivar kept `Constant[false]` from `initialize`, and
      # `unless @dispatch_top_level` folded always-falsey — a live
      # `flow.always-truthy-condition` false positive.
      describe "compound ivar writes (#1175)" do
        def seed_members(program, klass, ivar)
          idx = described_class.index(program, default_scope: default_scope)
          type = idx[program].class_ivars_for(klass)[ivar]
          return [] if type.nil?

          type.is_a?(Rigor::Type::Union) ? type.members : [type]
        end

        it "seeds `@flag ||= true` alongside the initialize write so `unless @flag` stays live" do
          program = parse(<<~RUBY)
            class C
              def initialize
                @flag = false
                @depth = 0
              end
              def mark
                @flag ||= true if @depth.zero?
              end
            end
          RUBY
          values = seed_members(program, "C", :@flag).grep(Rigor::Type::Constant).map(&:value)
          expect(values).to include(true, false, nil)
        end

        it "seeds a `||=`-only ivar as the rvalue union nil — the memo idiom's pre-write state" do
          program = parse(<<~RUBY)
            class C
              def memo
                @m ||= []
              end
            end
          RUBY
          members = seed_members(program, "C", :@m)
          expect(members.grep(Rigor::Type::Constant).map(&:value)).to include(nil)
          expect(members.any?(Rigor::Type::Tuple)).to be(true)
        end

        it "skips `@x ||= <falsey literal>` — the write can only leave the ivar falsey" do
          program = parse(<<~RUBY)
            class C
              def configure
                @x ||= false
                @y ||= nil
              end
            end
          RUBY
          idx = described_class.index(program, default_scope: default_scope)
          expect(idx[program].class_ivars_for("C")).not_to have_key(:@x)
          expect(idx[program].class_ivars_for("C")).not_to have_key(:@y)
        end

        it "skips a `||=` guard, whose rvalue never stores a value, beside a write that does" do
          # `@settings ||= raise ...` leaves the ivar as it found it or raises. Seeded as `nil`, an
          # instance method read its own guard as provably raising, and sig-gen declared `-> bot`.
          program = parse(<<~RUBY)
            class C
              def settings = (@settings ||= raise("boot first"))
              def token = (@token ||= raise("unset"))
              def refresh
                @token = "t"
              end
            end
          RUBY
          ivars = described_class.index(program, default_scope: default_scope)[program].class_ivars_for("C")
          expect(ivars).not_to have_key(:@settings)
          expect(ivars[:@token]).to eq(Rigor::Type::Combinator.constant_of("t"))
        end

        it "seeds `@x &&= v` as the rvalue — the write only runs on an already-truthy ivar" do
          program = parse(<<~RUBY)
            class C
              def initialize
                @token = "init"
              end
              def refresh
                @token &&= "refreshed"
              end
            end
          RUBY
          values = seed_members(program, "C", :@token).grep(Rigor::Type::Constant).map(&:value)
          expect(values).to include("init", "refreshed")
        end

        it "keeps the `&&=` contribution when the seeding write comes later in source order" do
          program = parse(<<~RUBY)
            class C
              def refresh
                @token &&= "refreshed"
              end
              def initialize
                @token = "init"
              end
            end
          RUBY
          values = seed_members(program, "C", :@token).grep(Rigor::Type::Constant).map(&:value)
          expect(values).to include("init", "refreshed")
        end

        it "does not seed an `&&=`-only ivar — the write cannot give the ivar its first value" do
          # Seeded as the rvalue, `if (@token &&= 1)` folded always-truthy on an ivar that is `nil` at runtime.
          program = parse(<<~RUBY)
            class C
              def refresh
                @token &&= 1
                @guard &&= raise("unset")
              end
            end
          RUBY
          idx = described_class.index(program, default_scope: default_scope)
          expect(idx[program].class_ivars_for("C")).not_to have_key(:@token)
          expect(idx[program].class_ivars_for("C")).not_to have_key(:@guard)
        end

        it "seeds `@x += v` as the widened dispatch result, not a pinned literal" do
          program = parse(<<~RUBY)
            class C
              def initialize
                @depth = 0
              end
              def enter
                @depth += 1
              end
            end
          RUBY
          members = seed_members(program, "C", :@depth)
          # `Constant[0] + Constant[1]` would fold to `Constant[1]`; the seed must carry the
          # widened `Integer`, not pin the ivar to a literal.
          expect(members.any? do |m|
            m.is_a?(Rigor::Type::Nominal) && m.class_name == "Integer"
          end).to be(true)
        end

        it "falls back to the widened rvalue when `op=` is the only write" do
          program = parse(<<~RUBY)
            class C
              def enter
                @depth += 1
              end
            end
          RUBY
          type = described_class.index(program, default_scope: default_scope)[program]
                                .class_ivars_for("C")[:@depth]
          expect(type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
        end
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

      describe "ctor definite assignment through same-class calls (WD3)" do
        def ivar_values(program, klass, ivar)
          idx = described_class.index(program, default_scope: default_scope)
          type = idx[program].class_ivars_for(klass)[ivar]
          members = type.is_a?(Rigor::Type::Union) ? type.members : [type]
          members.grep(Rigor::Type::Constant).map(&:value)
        end

        it "drops the seed nil when an unconditional same-class call assigns the ivar" do
          program = parse(<<~RUBY)
            class A
              def initialize
                @a = nil
                setup
              end
              def setup
                @a = 1
              end
            end
          RUBY
          expect(ivar_values(program, "A", :@a)).not_to include(nil)
        end

        it "drops the seed nil for the ipaddr shape (then=call, else=direct write)" do
          program = parse(<<~RUBY)
            class F
              def initialize(p)
                @m = nil
                if p
                  mask!(p)
                else
                  @m = 5
                end
              end
              def mask!(x)
                @m = x
              end
            end
          RUBY
          expect(ivar_values(program, "F", :@m)).not_to include(nil)
        end

        it "drops the seed nil when the callee assigns on both arms of an if/else and raises otherwise" do
          program = parse(<<~RUBY)
            class C
              def initialize
                @a = nil
                setup
              end
              def setup
                if cond
                  @a = 1
                else
                  raise "x"
                end
              end
            end
          RUBY
          expect(ivar_values(program, "C", :@a)).not_to include(nil)
        end

        it "KEEPS the seed nil when the same-class call is conditional" do
          program = parse(<<~RUBY)
            class B
              def initialize(c)
                @a = nil
                setup if c
              end
              def setup
                @a = 1
              end
            end
          RUBY
          expect(ivar_values(program, "B", :@a)).to include(nil)
        end

        it "KEEPS the seed nil when the same-class call runs through a block" do
          program = parse(<<~RUBY)
            class E
              def initialize
                @a = nil
                3.times { setup }
              end
              def setup
                @a = 1
              end
            end
          RUBY
          expect(ivar_values(program, "E", :@a)).to include(nil)
        end

        it "KEEPS the seed nil when the callee only assigns on one branch" do
          program = parse(<<~RUBY)
            class D
              def initialize
                @a = nil
                setup
              end
              def setup
                @a = 1 if cond
              end
            end
          RUBY
          expect(ivar_values(program, "D", :@a)).to include(nil)
        end

        it "KEEPS the seed nil when the call target is an unresolved (non-same-class) method" do
          program = parse(<<~RUBY)
            class G
              def initialize
                @a = nil
                helper.setup
              end
            end
          RUBY
          expect(ivar_values(program, "G", :@a)).to include(nil)
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

        # ADR-38 — a plugin-declared additional initializer is treated like `initialize` at the read-before-write gate.
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

          # Without a declaration the block body is never descended, so the ivar is simply absent from the accumulator
          # (no type at all — a different problem than nil-widening, but equally undesirable).
          it "control: without declaration, @user is not collected from a block body" do
            outer = parse(before_block_source).then do |program|
              described_class.index(program, default_scope: default_scope)[program]
            end
            expect(user_type(outer)).to be_nil
          end

          # With declaration: block body descended → type collected → init_writes suppresses the read-before-write nil
          # contribution.
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

          # A def-form `before` method is walked by collect_def_ivar_writes as usual. It is NOT in init_writes
          # (block_methods: [:before] only covers block-form calls, not defs), so the read-before-write nil contribution
          # fires — the nil-widening IS the expected result here.
          it "nil-widens a def-form `before` method even when block_methods: [:before] is declared" do
            entry = Rigor::Plugin::AdditionalInitializer.new(
              receiver_constraint: "FooSpec", block_methods: [:before]
            )
            outer = index_with_registry(before_source, stub_registry([entry]))
            expect(user_type_has_nil?(outer)).to be(true)
          end

          # #681 — the block-form census scope is built from a self type alone like the three others, so
          # it too has to carry the declaration's `Module.nesting`. This is the only one of the four that
          # needs a plugin to be reachable at all, hence a unit example rather than a fixture arm.
          # Written as a compact / nested pair: the compact body's nesting is
          # `[Admin::CompactSpec]`, so `Post` there names `::Post`, while the nested spelling reaches
          # `Admin::Post`. Peeling the qualified name answers `Admin::Post` for both.
          def compact_and_nested_post_types
            source = <<~RUBY
              class Post; end
              module Admin
                class Post; end
              end

              class Admin::CompactSpec
                before { @post = Post }
              end

              module Admin
                class NestedSpec
                  before { @post = Post }
                end
              end
            RUBY
            names = %w[Admin::CompactSpec Admin::NestedSpec]
            entries = names.map do |name|
              Rigor::Plugin::AdditionalInitializer.new(receiver_constraint: name, block_methods: [:before])
            end
            outer = index_with_registry(source, stub_registry(entries))
            names.map { |name| outer.class_ivars_for(name)[:@post] }
          end

          it "records the block's rvalue under the nesting of the declaration the block sits in" do
            compact, nested = compact_and_nested_post_types
            expect(compact).to be_a(Rigor::Type::Singleton)
            expect(compact.class_name).to eq("Post")
            expect(nested).to be_a(Rigor::Type::Singleton)
            expect(nested.class_name).to eq("Admin::Post")
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
          # Class-body write exempts the read-before-write nil contribution. Without the exemption, an unjustified nil
          # widening would propagate into Thread.new's block body and produce a `.kill for nil` style FP.
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
        # The falsey-default write itself is skipped — the `init` write still seeds `@w` to its rvalue type. The B2.3
        # read-before-write pre-pass additionally unions `nil` here because `configure` reads `@w` before any write IN
        # THAT METHOD BODY and `init` is NOT `initialize` (so the soundness gate's "constructor initialised" exemption
        # does not apply).
        type = outer.class_ivars_for("C")[:@w]
        expect(type).to be_a(Rigor::Type::Union)
        member_kinds = type.members.map(&:class)
        expect(member_kinds).to include(Rigor::Type::Constant)
        # And `init`'s rvalue precision survives — the union carries `Constant["hello"]` (plus the read-before-write
        # `Constant[nil]`).
        constant_member = type.members.find { |m| m.is_a?(Rigor::Type::Constant) && m.value == "hello" }
        expect(constant_member).not_to be_nil
      end
    end

    describe "parallel / multiple-assignment ivar targets (N1)" do
      it "records an array-literal RHS ivar slot at its tuple position" do
        program = parse(<<~RUBY)
          class F
            def lit
              @a, @b = 1, "s"
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        a = outer.class_ivars_for("F")[:@a]
        b = outer.class_ivars_for("F")[:@b]
        expect(a).to be_a(Rigor::Type::Constant)
        expect(a.value).to eq(1)
        expect(b).to be_a(Rigor::Type::Constant)
        expect(b.value).to eq("s")
      end

      it "records the unknown floor (Dynamic, NOT nil) for an unanalyzable multi-write RHS" do
        program = parse(<<~RUBY)
          class B
            def start(cmd)
              @i, @o, @e, @thr = Open3.popen3(cmd)
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        type = outer.class_ivars_for("B")[:@thr]
        # An unanalyzable parallel assignment means *unknown*, not nil — the sound floor is Dynamic[top]. A pure-nil
        # seed here is the N1 bug (it false-fires `@thr.alive?` undefined-for-nil).
        expect(type).to be_a(Rigor::Type::Dynamic)
      end

      it "records the only-write ivar so it is not absent from the union" do
        program = parse(<<~RUBY)
          class E
            def s(x, y)
              @p, @q = x, y
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        expect(outer.class_ivars_for("E")).to have_key(:@p)
        expect(outer.class_ivars_for("E")).to have_key(:@q)
      end

      it "recurses into a nested destructure target" do
        program = parse(<<~RUBY)
          class C
            def nest(x)
              (@a, @b), @c = x
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        %i[@a @b @c].each do |name|
          expect(outer.class_ivars_for("C")).to have_key(name)
        end
      end

      it "unions a multi-write slot with an existing single-write seed" do
        program = parse(<<~RUBY)
          class G
            def init
              @x = 1
            end

            def swap(y)
              old, @x = @x, y
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        type = outer.class_ivars_for("G")[:@x]
        # `@x` is written by both a single write (Constant[1]) and a multi-write (Dynamic from `y`) — the union carries
        # both.
        expect(type).to be_a(Rigor::Type::Union)
      end

      # WD5 — the massign target of `initialize` is an `InstanceVariableTargetNode`, not an
      # `InstanceVariableWriteNode`, so `detect_read_before_write` used to miss it: `@m` was absent from `init_writes`
      # and, being read-before-write in a sibling method, `contribute_read_before_write_nil!` unioned a spurious `nil`,
      # masking the recorded `Tuple[]` as `T | nil`. The ctor massign must count as an init write.
      it "does not union a spurious nil for an initialize massign read cross-method" do
        program = parse(<<~RUBY)
          class H
            def initialize
              @m, @n = [], []
            end

            def use
              @m
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        type = outer.class_ivars_for("H")[:@m]
        expect(type).to be_a(Rigor::Type::Tuple)
        expect(type).not_to be_a(Rigor::Type::Union)
      end

      # Issue #1110 — the seed decomposes by `MultiTargetBinder`'s rules and drops the marks, recording what
      # `@first = xs.first` records: an `Array[T]` fixed slot seeds `T`, not `T | nil`.
      it "records an Array[T] RHS as T per fixed slot and Array[T] for the rest" do
        program = parse(<<~RUBY)
          class K
            def initialize
              @first, *@rest = rand(10).digits
            end
          end
        RUBY
        ivars = described_class.index(program, default_scope: default_scope)[program].class_ivars_for("K")
        integer = Rigor::Type::Combinator.nominal_of("Integer")
        expect(ivars[:@first]).to eq(integer)
        expect(ivars[:@rest]).to eq(Rigor::Type::Combinator.nominal_of("Array", type_args: [integer]))
      end

      it "records a Tuple RHS rest as the middle elements and keeps a present optional slot's nil" do
        program = parse(<<~RUBY)
          class L
            def initialize(flag)
              @a, *@mid, @z = 1, 2, 3, 4
              @p, @q = [1, flag ? "s" : nil]
            end
          end
        RUBY
        ivars = described_class.index(program, default_scope: default_scope)[program].class_ivars_for("L")
        two, three = [2, 3].map { |v| Rigor::Type::Combinator.constant_of(v) }
        expect(ivars[:@mid]).to eq(Rigor::Type::Combinator.tuple_of(two, three))
        expect(ivars[:@z]).to eq(Rigor::Type::Combinator.constant_of(4))
        # The seed carries no optimistic mark, so the ADR-57 softening would make a sibling's `if @q` fold.
        expect(ivars[:@q]).to eq(Rigor::Type::Combinator.union(Rigor::Type::Combinator.constant_of("s"),
                                                               Rigor::Type::Combinator.constant_of(nil)))
      end

      it "wraps a value with no implicit to_ary as [rhs], padding the later slot with nil" do
        program = parse(<<~RUBY)
          class M
            def initialize
              @a, @b = 1
            end
          end
        RUBY
        ivars = described_class.index(program, default_scope: default_scope)[program].class_ivars_for("M")
        expect(ivars[:@a]).to eq(Rigor::Type::Combinator.constant_of(1))
        expect(ivars[:@b]).to eq(Rigor::Type::Combinator.constant_of(nil))
      end

      it "keeps an unanalyzable initialize massign read as Dynamic (no spurious nil) cross-method" do
        program = parse(<<~RUBY)
          class I
            def initialize(src)
              @a, @b = some_untyped_call(src)
            end

            def use
              @a
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        type = outer.class_ivars_for("I")[:@a]
        # Unanalyzable RHS floors to Dynamic; the read-before-write gate must not re-inject nil on top of it.
        expect(type).to be_a(Rigor::Type::Dynamic)
      end

      it "counts a nested massign target as an init write cross-method" do
        program = parse(<<~RUBY)
          class J
            def initialize(x)
              (@a, @b), @c = x
            end

            def use
              @a
            end
          end
        RUBY
        idx = described_class.index(program, default_scope: default_scope)
        outer = idx[program]
        type = outer.class_ivars_for("J")[:@a]
        # `@a` is a nested target; unanalyzable slot floors to Dynamic, and the ctor write must suppress the nil union.
        expect(type).to be_a(Rigor::Type::Dynamic)
      end
    end
  end

  # T1 — cross-file `Const = Class.new(Super)` discovery so a rescue / const reference in a sibling file resolves to the
  # project class.
  describe ".discovered_classes_for_paths with Class.new constants" do
    def with_files(files)
      Dir.mktmpdir do |dir|
        paths = files.map do |name, source|
          path = File.join(dir, name)
          File.write(path, source)
          path
        end
        yield described_class.discovered_classes_for_paths(paths)
      end
    end

    it "types a Const = Class.new(Super) as Singleton[Super] under the namespace" do
      files = {
        "a.rb" => <<~RUBY
          module M
            class Error < ::StandardError; end
            SyntaxError = Class.new(Error)
          end
        RUBY
      }
      with_files(files) do |discovered|
        expect(discovered["M::SyntaxError"]).to eq(Rigor::Type::Combinator.singleton_of("M::Error"))
      end
    end

    it "resolves the superclass across two files in the same namespace" do
      files = {
        "a.rb" => "module M\n  class Error < ::StandardError; end\n  SyntaxError = Class.new(Error)\nend\n",
        "b.rb" => "module M\n  class Other; end\nend\n"
      }
      with_files(files) do |discovered|
        expect(discovered["M::SyntaxError"]).to eq(Rigor::Type::Combinator.singleton_of("M::Error"))
      end
    end

    it "types a bare Class.new as Singleton[Const] itself" do
      with_files({ "a.rb" => "module M\n  Anon = Class.new\nend\n" }) do |discovered|
        expect(discovered["M::Anon"]).to eq(Rigor::Type::Combinator.singleton_of("M::Anon"))
      end
    end

    it "keeps a literal superclass name when it is not a discovered class" do
      with_files({ "a.rb" => "module M\n  MyErr = Class.new(RuntimeError)\nend\n" }) do |discovered|
        expect(discovered["M::MyErr"]).to eq(Rigor::Type::Combinator.singleton_of("RuntimeError"))
      end
    end

    it "records the block form under the constant's OWN name, not its superclass's" do
      with_files({ "a.rb" => "module M\n  Blk = Class.new(Object) do\n    def x; end\n  end\nend\n" }) do |discovered|
        # A block body declares methods of its own, so the constant cannot borrow `Object`'s identity the way a
        # block-less `Class.new(Super)` does — the same answer the per-file `meta_new_constant_type` gives.
        expect(discovered["M::Blk"]).to eq(Rigor::Type::Combinator.singleton_of("M::Blk"))
      end
    end

    # Issue #271 — the Data/Struct constant-write forms belong in the SAME table. Left out, a nested `Result` was
    # invisible cross-file and Ruby's lexical walk continued to the parent namespace's same-named sibling, which is a
    # `call.undefined-method` false positive when that sibling is RBS-known (see
    # spec/rigor/analysis/nested_data_constant_cross_file_spec.rb).
    it "records a Const = Data.define(*sym) under its own qualified name" do
      with_files({ "a.rb" => "module M\n  class F\n    Result = Data.define(:digest)\n  end\nend\n" }) do |discovered|
        expect(discovered["M::F::Result"]).to eq(Rigor::Type::Combinator.singleton_of("M::F::Result"))
      end
    end

    it "records the Data.define block form, so a nested Result outranks a parent-namespace sibling" do
      files = {
        "a.rb" => <<~RUBY
          module M
            class Result; end

            class F
              Result = Data.define(:digest) do
                def opaque? = digest.nil?
              end
            end
          end
        RUBY
      }
      with_files(files) do |discovered|
        expect(discovered["M::F::Result"]).to eq(Rigor::Type::Combinator.singleton_of("M::F::Result"))
        expect(discovered["M::Result"]).to eq(Rigor::Type::Combinator.singleton_of("M::Result"))
      end
    end

    it "records a Const = Struct.new(*sym) under its own qualified name" do
      with_files({ "a.rb" => "module M\n  Row = Struct.new(:a, :b)\nend\n" }) do |discovered|
        expect(discovered["M::Row"]).to eq(Rigor::Type::Combinator.singleton_of("M::Row"))
      end
    end
  end

  # Issue #528 — every proper prefix of a discovered compact class name is a namespace module that
  # provably exists at runtime (Zeitwerk derives it from the directory; mastodon never writes
  # `module Api`). The prefixes join the discovered-classes table so bare namespace reads — and the
  # inner ConstantReadNodes of resolving constant paths — type as singletons.
  describe "namespace-prefix synthesis" do
    it "registers each proper prefix of a compact class declaration" do
      _, idx = index_for("class Api::V1::AccountsController
end
Api
")
      scope = idx[parse("x").statements.body.first]
      classes = scope.discovered_classes
      expect(classes.keys).to include("Api", "Api::V1", "Api::V1::AccountsController")
      expect(classes["Api"].describe(:short)).to eq("singleton(Api)")
    end

    it "never overwrites an explicitly declared namespace" do
      source = "module Api
  VERSION = 1
end
class Api::V1::AccountsController
end
"
      _, idx = index_for(source)
      scope = idx[parse("x").statements.body.first]
      expect(scope.discovered_classes["Api"].describe(:short)).to eq("singleton(Api)")
    end

    it "leaves a genuinely unknown constant unresolved (control)" do
      program, idx = index_for("class Api::V1::AccountsController
end
Unrelated
")
      read = program.statements.body.last
      expect(idx[read].type_of(read).describe(:short)).to eq("Dynamic[top]")
    end
  end

  # Issue #526 — `extend M` / `extend self` / bare `module_function` fold the module's instance defs
  # onto the extender's singleton, so `C.helper` resolves (existence AND call-site return inference,
  # with `self = Singleton[C]` exactly as Ruby binds).
  describe "extend-family singleton fold" do
    def last_statement_type(source)
      program = parse(source)
      idx = described_class.index(program, default_scope: default_scope)
      node = program.statements.body.last
      idx[node].type_of(node)
    end

    it "resolves a call through `extend M` with the module def's inferred return" do
      source = "module Tools\n  def label\n    \"tool\"\n  end\nend\n" \
               "module Registry\n  extend Tools\nend\n" \
               "Registry.label\n"
      expect(last_statement_type(source).describe).to eq('"tool"')
    end

    it "resolves `extend self` and the bare `module_function` toggle" do
      extend_self = "module Host\n  extend self\n  def on_jruby?\n    false\n  end\nend\nHost.on_jruby?\n"
      expect(last_statement_type(extend_self).describe).to eq("false")

      module_function_toggle = "module Util\n  module_function\n\n  def message(text)\n    text\n  end\nend\n" \
                               "Util.message(:hi)\n"
      expect(last_statement_type(module_function_toggle).describe).to eq(":hi")
    end

    it "keeps a genuine `def self.` winning over the folded module def (control)" do
      source = "module Tools\n  def label\n    \"tool\"\n  end\nend\n" \
               "module Registry\n  extend Tools\n  def self.label\n    :own\n  end\nend\n" \
               "Registry.label\n"
      expect(last_statement_type(source).describe).to eq(":own")
    end

    it "gives the FIRST argument of one `extend A, B` call precedence (#1097)" do
      # `extend A, B` makes A the nearer singleton ancestor — `extend_features` prepends each
      # argument in turn, so the table must keep call order within a single statement.
      source = <<~RUBY
        module Farther
          def label
            :farther
          end
        end
        module Nearer
          def label
            :nearer
          end
        end
        module Registry
          extend Nearer, Farther
        end
        Registry.label
      RUBY
      expect(last_statement_type(source).describe).to eq(":nearer")
    end

    it "gives a LATER `extend` statement precedence over an earlier one (#1097)" do
      # `extend A; extend B` puts B nearer — each statement prepends its own argument list.
      source = <<~RUBY
        module Earlier
          def label
            :earlier
          end
        end
        module Later
          def label
            :later
          end
        end
        module Registry
          extend Earlier
          extend Later
        end
        Registry.label
      RUBY
      expect(last_statement_type(source).describe).to eq(":later")
    end

    it "folds `include` inside `class << self`'s eval block — the singleton's own body (#1097)" do
      # `class_eval` with no receiver inside `class << self` runs the block as the SINGLETON
      # class's body, so `include Tools` lands on C's singleton ancestry exactly like a literal
      # `include` there — C.label resolves.
      source = "module Tools\n  def label\n    \"tool\"\n  end\nend\n" \
               "class C\n  class << self\n    class_eval { include Tools }\n  end\nend\n" \
               "C.label\n"
      expect(last_statement_type(source).describe).to eq('"tool"')
    end

    it "does not fold `extend` inside `class << self`'s eval block — it lands on the metaclass" do
      # `extend` inside the singleton's eval body extends the singleton's OWN singleton (the
      # metaclass squared) — `C.label` does not resolve, so no edge may be recorded.
      source = "module Tools\n  def label\n    \"tool\"\n  end\nend\n" \
               "class C\n  class << self\n    class_eval { extend Tools }\n  end\nend\n" \
               "C.label\n"
      expect(last_statement_type(source).describe(:short)).to eq("Dynamic[top]")
    end

    it "folds `module_function()` — empty parens are the bare toggle (#1097)" do
      source = "module Util\n  module_function()\n  def message(text)\n    text\n  end\nend\n" \
               "Util.message(:hi)\n"
      expect(last_statement_type(source).describe).to eq(":hi")
    end

    it "contributes nothing for an extend target with no discovered defs (control)" do
      source = "module Registry\n  extend SomeGemModule\nend\nRegistry.helper\n"
      expect(last_statement_type(source).describe(:short)).to eq("Dynamic[top]")
    end
  end

  # #1097 — inside a `*_eval` / `*_exec` block, `Module.nesting` stays LEXICAL while `def`
  # binds to the receiver: the discovery walks carry both contexts — declarations and
  # constant writes file under the enclosing namespace, def-ish leaves under the receiver.
  describe "eval-block dual context (#1097)" do
    def methods_for(source)
      described_class.build_methods_and_def_nodes(parse(source)).first
    end

    it "files a `class` declaration inside an eval block under the LEXICAL namespace" do
      # `X.class_eval { class Inner }` inside `module M` opens `M::Inner` — `Module.nesting`
      # does not change in an eval block — so `def h` inside belongs to `M::Inner`, not `X::Inner`.
      table = methods_for(<<~RUBY)
        class X; end
        module M
          X.class_eval do
            class Inner
              def h; end
            end
          end
        end
      RUBY
      expect(table).to include("M::Inner" => { h: :instance })
      expect(table).not_to have_key("X::Inner")
    end

    it "files a meta-new constant write inside an eval block under the lexical namespace" do
      table = methods_for(<<~RUBY)
        class X; end
        module M
          X.class_eval do
            K = Class.new do
              def h; end
            end
          end
        end
      RUBY
      expect(table).to include("M::K" => { h: :instance })
      expect(table).not_to have_key("X::K")
    end

    it "records `class << self` inside an eval block on the RECEIVER's singleton" do
      # self inside `X.class_eval` is X, so `class << self` opens X's singleton — `def m` is X.m.
      table = methods_for(<<~RUBY)
        class X; end
        module M
          X.class_eval do
            class << self
              def m; end
            end
          end
        end
      RUBY
      expect(table).to include("X" => { m: :singleton })
      expect(table).not_to have_key("M")
    end

    it "gives a def inside an eval-nested declaration the LEXICAL owner in deferred ranges" do
      ranges = described_class.build_deferred_ranges(parse(<<~RUBY))
        class X; end
        module M
          X.class_eval do
            class Inner
              def h; end
            end
          end
        end
      RUBY
      h_rows = ranges.select { |row| row[2] == :h }
      expect(h_rows.map(&:last)).to eq(["M::Inner"])
    end

    it "attributes `def self.x` inside an eval block to the receiver in every table" do
      source = <<~RUBY
        class X; end
        module M
          X.class_eval do
            def self.g; end
          end
        end
      RUBY
      program = parse(source)
      expect(methods_for(source)).to include("X" => { g: :singleton })
      singleton_defs = described_class.build_discovered_singleton_def_nodes(program)
      expect(singleton_defs.fetch("X")).to have_key(:g)
      expect(singleton_defs).not_to have_key("M")
    end

    it "files `def` inside `instance_eval`/`instance_exec` on the receiver's singleton" do
      # MRI: `X.instance_eval { def m }` defines X.m — the default definee is the receiver's
      # singleton, unlike `class_eval` where defs land on the instance surface. Nested evals
      # and `class << self` keep the same binding; nothing leaks to the lexical `M`.
      source = <<~RUBY
        class X; end
        class Y; end
        module M
          X.instance_eval do
            def m; end
            def self.s; end
            class << self
              def deep; end
            end
          end
          Y.instance_exec { def n; end }
        end
      RUBY
      program = parse(source)
      table = methods_for(source)
      expect(table["X"]).to include(m: :singleton, s: :singleton, deep: :singleton)
      expect(table["Y"]).to include(n: :singleton)
      expect(table).not_to have_key("M")

      singleton_defs = described_class.build_discovered_singleton_def_nodes(program)
      expect(singleton_defs.fetch("X")).to include(:m, :s, :deep)
      expect(singleton_defs.fetch("Y")).to have_key(:n)
      expect(singleton_defs).not_to have_key("M")
    end

    it "keeps receiver-as-module calls inside `instance_eval` on the instance surface" do
      # `attr_reader`, `define_method` and `alias_method` send a message TO the receiver —
      # they act on X's instance surface even though `def` moves to the singleton.
      source = <<~RUBY
        class X
          def base; end
        end
        module M
          X.instance_eval do
            attr_reader :a
            define_method(:dm) { }
            alias_method :copy, :base
            private :a
          end
        end
      RUBY
      expect(methods_for(source)["X"]).to include(a: :instance, dm: :instance, copy: :instance)
      visibilities = described_class.build_discovered_method_visibilities(parse(source))
      expect(visibilities.fetch("X")).to include(a: :private)
    end

    it "does not record a keyword `alias` inside `instance_eval` as an instance alias" do
      # The `alias` keyword binds on the receiver's singleton like `def`; only
      # `alias_method` — a call on the receiver-as-module — is an instance alias.
      aliases = described_class.send(:collect_class_alias_map, parse(<<~RUBY), [], {})
        class X; end
        module M
          X.instance_eval do
            alias kw base
            alias_method :mc, :base
          end
        end
      RUBY
      expect(aliases.fetch("X", {})).to include(mc: :base)
      expect(aliases.fetch("X", {})).not_to have_key(:kw)
    end

    it "declines `def` inside `class <<` + `instance_eval` — the unnameable metaclass" do
      # MRI: `class << S; instance_eval` re-evaluates the SAME singleton self, so a `def`
      # binds on the singleton's own singleton — `#<Class:#<Class:S>>` — which nothing
      # names, while `define_method` stays on the singleton's instance surface (`S.dm`).
      table = methods_for(<<~RUBY)
        class S
          class << self
            instance_eval { def meta; end }
            instance_eval { define_method(:dm) {} }
          end
        end
      RUBY
      expect(table.fetch("S", {})).to include(dm: :singleton)
      expect(table.fetch("S", {})).not_to have_key(:meta)
      singleton_defs = described_class.build_discovered_singleton_def_nodes(parse(<<~RUBY))
        class S
          class << self
            instance_eval { def meta; end }
          end
        end
      RUBY
      expect(singleton_defs.fetch("S", {})).not_to have_key(:meta)
    end

    it "keeps `include` but declines `extend` inside `class <<` + `instance_eval`" do
      # `include` mixes into `#<Class:S>` — S's singleton-ancestor edge, like `class_eval`
      # there. `extend` targets `#<Class:#<Class:S>>`, which nothing names.
      extends = described_class.build_discovered_extends(parse(<<~RUBY))
        module M2; end
        module M3; end
        class S
          class << self
            instance_eval { include M2 }
            instance_eval { extend M3 }
          end
        end
      RUBY
      expect(extends["S"]).to eq(["M2"])
      expect(extends).not_to have_key("M3")
    end

    it "does not file a `def` under an unnameable cref at `<toplevel>`" do
      # `class << obj` opens a singleton nothing names; a `def` or a `class self::Q` inside
      # belongs to `#<Class:obj>`-side objects — recording them under `<toplevel>` would let
      # an implicit-self call resolve a method Ruby never installed there.
      _methods, def_nodes = described_class.build_methods_and_def_nodes(parse(<<~RUBY))
        class C2
          class << obj
            def s1; end
            class self::Q
              def m2; end
            end
          end
        end
      RUBY
      expect(def_nodes.fetch("<toplevel>", {})).to be_empty
      expect(def_nodes.fetch("C2", {})).to be_empty
    end

    it "declines a container-wrapped `def` inside `class <<` + `instance_eval`" do
      # The `if` keeps the def off the eval body's statement list — it must not slip
      # past the `:unnameable` gate through the generic singleton-defs descent.
      defs = described_class.build_discovered_singleton_def_nodes(parse(<<~RUBY))
        class S
          class << self
            instance_eval { if true; def meta; end; end }
            instance_eval { begin; def meta2; end; end }
          end
        end
      RUBY
      expect(defs.fetch("S", {})).to be_empty
    end

    it "resolves `self::` receivers against a named eval receiver below `class <<`" do
      # `X.class_eval` rebinds `self` to X even under a singleton cref — a `self::`
      # receiver or header anchors on X, not on the singleton that names nothing.
      table = methods_for(<<~RUBY)
        class X
          class Y; end
        end
        class S
          class << self
            X.class_eval do
              self::Y.class_eval do
                class self::D < Object
                  def m; end
                end
              end
            end
          end
        end
      RUBY
      expect(table).to have_key("X::Y::D")
    end

    it "threads `self::`-anchored nestings through an eval below `class <<`" do
      nestings = described_class.build_def_nestings(parse(<<~RUBY))
        class X
          class Y; end
        end
        class S
          class << self
            X.class_eval do
              self::Y.class_eval do
                class self::D
                  def m; Inner; end
                end
              end
            end
          end
        end
      RUBY
      expect(nestings.values).to include(["X::Y::D", "S"])
    end

    it "does not file a named visibility call inside `class <<` as instance-side" do
      # `private :x` inside `class <<` (or a receiver-eval body on a singleton self)
      # marks the SINGLETON method — the instance-visibility table cannot express it.
      visibilities = described_class.build_discovered_method_visibilities(parse(<<~RUBY))
        class S
          def x; end
          class << self
            def x; end
            private :x
            instance_eval { private :x }
          end
        end
      RUBY
      expect(visibilities["S"]).to eq({ x: :public })
    end

    it "files `module_function` rows ownerless inside `class <<` + `instance_eval`" do
      ranges = described_class.build_deferred_ranges(parse(<<~RUBY))
        class S
          class << self
            instance_eval do
              module_function :meta
              module_function def mf; end
            end
          end
        end
      RUBY
      expect(ranges.map(&:last).uniq).to eq([nil])
    end

    it "does not copy a `module_function`-named def onto `S` inside `class <<` + `instance_eval`" do
      # `module_function :meta` retro-marks the sibling `def meta` — that def binds on the
      # metaclass, so the singleton-defs table must not file it under `S`.
      defs = described_class.build_discovered_singleton_def_nodes(parse(<<~RUBY))
        class S
          class << self
            instance_eval do
              def meta; end
              module_function :meta
            end
          end
        end
      RUBY
      expect(defs.fetch("S", {})).to be_empty
    end

    it "records a `self::`-anchored Data/Struct layout through an eval below `class <<`" do
      data = described_class.build_data_member_layouts(parse(<<~RUBY))
        class X; end
        class S
          class << self
            X.class_eval do
              class self::D < Data.define(:a)
              end
            end
          end
        end
      RUBY
      expect(data["X::D"]).to eq([:a])
    end

    it "resolves an eval receiver through the file's own nesting declarations" do
      # MRI: `X` inside `class S` names `S::X` whenever the scope declares it —
      # `Module.nesting` order, innermost first — so the eval body's facts file
      # under `S::X`, not the same-named top-level class.
      methods, = described_class.build_methods_and_def_nodes(parse(<<~RUBY))
        class X; end
        class S
          class X; end
          class T
            X.class_eval { def m; end }
          end
          X.class_eval { def n; end }
        end
      RUBY
      expect(methods.fetch("S::X")).to include(m: :instance, n: :instance)
      expect(methods.fetch("X", {})).to be_empty
    end

    it "keeps an unshadowed or rooted eval receiver as written" do
      # `S::X` is undeclared here: `X` falls through to the top-level name, and
      # `::X` names the top level outright — no lexical walk reaches `S::X`.
      methods, = described_class.build_methods_and_def_nodes(parse(<<~RUBY))
        class X; end
        class S
          X.class_eval { def m; end }
          ::X.class_eval { def r; end }
        end
      RUBY
      expect(methods.fetch("X")).to include(m: :instance, r: :instance)
      expect(methods).not_to have_key("S::X")
    end

    it "resolves a `class <<` operand through the file's nesting declarations" do
      # `class << X` inside `class S` opens the singleton of `S::X` when that
      # constant exists — the operand follows the same lexical lookup an
      # eval-family receiver does.
      defs = described_class.build_discovered_singleton_def_nodes(parse(<<~RUBY))
        class X; end
        class S
          class X; end
          class << X
            def sm; end
          end
        end
      RUBY
      expect(defs.fetch("S::X", {})).to have_key(:sm)
      expect(defs.fetch("X", {})).to be_empty
    end

    it "keeps `@@x` inside a `def` in a meta-new or eval block on the lexical cref" do
      # MRI: `Module.nesting` is unchanged by `self` rebinding, so `@@x` inside a method
      # defined in `K = Class.new { }` or `X.class_eval { }` belongs to the LEXICAL
      # class C — never to K or X.
      cvars = described_class.build_class_cvar_index(parse(<<~RUBY), Rigor::Scope.empty)
        class X; end
        class C
          K = Class.new do
            def a = (@@va = 1)
          end
          X.class_eval do
            def b = (@@vb = 2)
          end
          X.instance_eval do
            def c = (@@vc = 3)
          end
        end
      RUBY
      expect(cvars.fetch("C")).to include(:@@va, :@@vb, :@@vc)
      expect(cvars).not_to have_key("K")
      expect(cvars).not_to have_key("X")
    end

    it "resolves a `self` / bare / `self::` eval receiver against the ENCLOSING eval's self" do
      # Inside `Y.class_eval` self IS Y — a nested `self.class_eval`, bare `class_eval`, or
      # `self::X.class_eval` re-opens Y (or Y::X), never the lexical `module M`.
      table = methods_for(<<~RUBY)
        class Y; end
        module M
          Y.class_eval do
            self.class_eval { def h1; end }
            class_eval { def h2; end }
            self::X.class_eval { def h3; end }
            self::F::G.class_eval { def h4; end }
          end
        end
      RUBY
      expect(table).to include(
        "Y" => { h1: :instance, h2: :instance },
        "Y::X" => { h3: :instance },
        "Y::F::G" => { h4: :instance }
      )
      expect(table).not_to have_key("M")
      expect(table).not_to have_key("M::X")
    end

    it "resolves a constant eval receiver through the write site's LEXICAL nesting, not the eval self" do
      # `Y` inside `M::Y.class_eval` at top level is the TOP-LEVEL `Y` — constant
      # lookup in an eval body stays lexical, and a class is never a member of its own
      # constant table.
      table = methods_for(<<~RUBY)
        module M
          class Y; end
        end
        class Y; end
        M::Y.class_eval do
          Y.class_eval { def m; end }
        end
      RUBY
      expect(table).to include("Y" => { m: :instance })
      expect(table.fetch("M::Y", {})).not_to have_key(:m)
    end

    it "resolves a constant eval receiver through nesting inside a foreign eval body" do
      # `Y` written in `M::Y`'s body resolves via `Module.nesting` to `M::Y`, even
      # though the enclosing eval's self is `Z`.
      table = methods_for(<<~RUBY)
        class Z; end
        module M
          class Y
            Z.class_eval do
              Y.class_eval { def m; end }
            end
          end
        end
      RUBY
      expect(table).to include("M::Y" => { m: :instance })
      expect(table).not_to have_key("Y")
    end

    it "opens a `class <<` operand through the lexical nesting inside an eval body" do
      # `class << Y` inside `M::Y.class_eval` at top level opens the TOP-LEVEL `Y`'s
      # singleton — the same lexical resolution an eval receiver gets.
      table = methods_for(<<~RUBY)
        module M
          class Y; end
        end
        class Y; end
        M::Y.class_eval do
          class << Y
            def s; end
          end
        end
      RUBY
      expect(table).to include("Y" => { s: :singleton })
      expect(table.fetch("M::Y", {})).not_to have_key(:s)
    end

    it "declines a `self::` eval receiver inside a `class <<` body" do
      # Inside `class << self` self is the singleton — `self::X` raises NameError at
      # runtime unless the constant lives on that singleton — so the receiver declines
      # rather than filing the block under a class it never opened.
      table = described_class.build_discovered_includes(parse(<<~RUBY))
        module T; end
        module M
          Y.class_eval do
            class << self
              self::X.class_eval { include T }
            end
          end
        end
      RUBY
      expect(table).not_to have_key("Y::X")
      expect(table).not_to have_key("M::X")
    end

    it "keys a `self::` receiver under `Object` as the bare top-level name" do
      table = methods_for(<<~RUBY)
        Object.class_eval do
          self::X.class_eval { def m; end }
        end
      RUBY
      expect(table).to include("X" => { m: :instance })
      expect(table).not_to have_key("Object::X")
    end

    it "declines `self::` and bare constant writes inside a `class <<` body" do
      # Both forms write the singleton's own constant table — `#<Class:Y>::X` — a name
      # nothing else can produce, so neither files under `Y` nor retracts `X`.
      writes = described_class.send(:constant_writes_for_file, parse(<<~RUBY))
        class Y
          class << self
            self::X = 1
            W = 2
          end
        end
      RUBY
      expect(writes).to be_empty
    end

    it "declines `self::` constant writes inside `class <<` in the typed table" do
      program = parse(<<~RUBY)
        class Y
          class << self
            self::X = 1
            W = 2
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]
      expect(scope.in_source_constants).not_to have_key("Y::X")
      expect(scope.in_source_constants).not_to have_key("Y::W")
    end

    it "files defs inside `class << <non-constant>` under no class rather than the enclosing one" do
      # `class << obj` opens `obj`'s singleton — `def h` binds `obj.h`, never `Y#h`.
      table = methods_for(<<~RUBY)
        class Y
          class << obj
            def h; end
          end
        end
      RUBY
      expect(table.fetch("Y", {})).not_to have_key(:h)
    end

    it "declines a `self::` eval receiver inside `class << <non-constant>`" do
      table = described_class.build_discovered_includes(parse(<<~RUBY))
        module T; end
        class Y
          class << obj
            self::X.class_eval { include T }
          end
        end
      RUBY
      expect(table).not_to have_key("Y::X")
    end

    it "declines bare writes inside eval/meta blocks under `class <<` — cref never rebinds" do
      # `Module.nesting` stays lexical through every block: the write lands on
      # `#<Class:C>::X`, a name nothing else can produce, in each form.
      writes = described_class.send(:constant_writes_for_file, parse(<<~RUBY))
        class Foo; end
        class C
          class << self
            Foo.class_eval { X = 1 }
            obj.instance_eval { Y = 1 }
            K = Class.new { Z = 1 }
          end
        end
      RUBY
      expect(writes.keys).to be_empty
    end

    it "declines `self::` writes inside a meta-new block under `class <<`" do
      # `K` itself is unnameable, so the block's anonymous class is too — `self::Y`
      # there cannot be spelled `C::K::Y`.
      writes = described_class.send(:constant_writes_for_file, parse(<<~RUBY))
        class C
          class << self
            K = Class.new { self::Y = 1 }
          end
        end
      RUBY
      expect(writes.keys).to be_empty
    end

    it "files defs inside an eval-nested `self::` receiver under `class <<` nowhere" do
      # `self::X` reads the singleton's constant table — NameError unless `X` lives
      # there — never `C`, so `def h` must not land on `C`.
      table = methods_for(<<~RUBY)
        class C
          class << self
            self::X.class_eval { def h; end }
          end
        end
      RUBY
      expect(table.fetch("C", {})).not_to have_key(:h)
    end

    it "files a `class` declaration inside `class <<` nowhere — the pushed cref is the singleton's" do
      # `class D` under `class <<` reopens `#<Class:C>::D`; `class ::T` re-anchors
      # at the top level and stays nameable.
      table = methods_for(<<~RUBY)
        class C
          class << self
            class D
              def m; end
            end
            class ::T
              def n; end
            end
          end
        end
      RUBY
      expect(table).not_to have_key("C::D")
      expect(table.fetch("T", {})).to have_key(:n)
    end

    it "files a `class` declaration inside `class << Foo` nowhere — the pushed cref is Foo's singleton's" do
      table = methods_for(<<~RUBY)
        class Foo; end
        class C
          class << Foo
            class D
              def m; end
            end
          end
        end
      RUBY
      expect(table).not_to have_key("Foo::D")
      expect(table).not_to have_key("C::D")
    end

    it "files a `class` declaration inside an eval block under `class <<` nowhere" do
      # `Foo.class_eval { class D }` — nesting stays `[#<Class:C>, C]` — opens
      # `#<Class:C>::D`, not `Foo::D` or `C::D`.
      table = methods_for(<<~RUBY)
        class Foo; end
        class C
          class << self
            Foo.class_eval { class D; def m; end }
          end
        end
      RUBY
      expect(table).not_to have_key("C::D")
      expect(table).not_to have_key("Foo::D")
    end

    it "declines `self::` and bare constant writes inside `class <<` in the typed table" do
      program = parse(<<~RUBY)
        class C
          class << self
            self::X = 1
            W = 2
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]
      expect(scope.in_source_constants).not_to have_key("C::X")
      expect(scope.in_source_constants).not_to have_key("C::W")
    end

    it "attributes `extend` inside a nested `self.class_eval` block to the enclosing receiver" do
      table = described_class.build_discovered_extends(parse(<<~RUBY))
        module T; end
        module M
          Y.class_eval do
            self.class_eval { extend T }
          end
        end
      RUBY
      expect(table).to include("Y" => ["T"])
      expect(table).not_to have_key("M")
    end

    it "attributes `include` inside a `self::`-receiver eval block to the resolved owner" do
      table = described_class.build_discovered_includes(parse(<<~RUBY))
        module T; end
        module M
          Y.class_eval do
            self::X.class_eval { include T }
          end
        end
      RUBY
      expect(table).to include("Y::X" => ["T"])
      expect(table).not_to have_key("M")
    end

    it "declines a `self::` eval receiver nested in a bare eval under `class <<`" do
      # The bare `class_eval` keeps the singleton's body — `self::X` inside still
      # raises NameError at runtime — so the inner receiver declines rather than
      # re-anchoring to `C`.
      table = described_class.build_discovered_extends(parse(<<~RUBY))
        module T; end
        class C
          class << self
            class_eval { self::X.class_eval { extend T } }
          end
        end
      RUBY
      expect(table).not_to have_key("C::X")
      expect(table).not_to have_key("X")
    end

    it "declines a `self::` eval receiver inside a `class` declaration under `class <<`" do
      # `class D` opens `#<Class:C>::D` — `self` inside is that unnameable class, so
      # `self::X` there cannot be spelled `C::D::X`.
      table = described_class.build_discovered_includes(parse(<<~RUBY))
        module T; end
        class C
          class << self
            class D
              self::X.class_eval { include T }
            end
          end
        end
      RUBY
      expect(table).not_to have_key("X")
      expect(table).not_to have_key("C::D::X")
      expect(table).not_to have_key("D::X")
    end

    it "declines a `self::` eval receiver inside an opaque eval body" do
      # `obj.instance_eval`'s self is the receiver object — `self::X` resolves on its
      # singleton, a table nothing names — never `C::X`.
      table = described_class.build_discovered_includes(parse(<<~RUBY))
        module T; end
        class C
          obj.instance_eval { self::X.class_eval { include T } }
        end
      RUBY
      expect(table).not_to have_key("C::X")
      expect(table).not_to have_key("X")
    end

    it "declines a bare eval receiver under `class << <non-self>`" do
      # `class << Foo`'s `class_eval` runs the block on `#<Class:Foo>` — `extend` lands
      # on its own singleton, a surface nothing names — never `C`'s.
      table = described_class.build_discovered_extends(parse(<<~RUBY))
        module T; end
        class Foo; end
        class C
          class << Foo
            class_eval { extend T }
            class_eval { module_function }
          end
        end
      RUBY
      expect(table).not_to have_key("C")
      expect(table).not_to have_key("Foo")
    end

    it "attributes `extend` inside a meta-new block to the block's class" do
      # `K = Class.new { extend M }` extends `K` — the enclosing class's singleton is
      # untouched.
      table = described_class.build_discovered_extends(parse(<<~RUBY))
        module T; end
        class C
          K = Class.new { extend T }
        end
      RUBY
      expect(table).to include("C::K" => ["T"])
      expect(table).not_to have_key("C")
    end

    it "attributes `include` inside a meta-new block to the block's class" do
      table = described_class.build_discovered_includes(parse(<<~RUBY))
        module T; end
        class C
          K = Class.new { include T }
        end
      RUBY
      expect(table).to include("C::K" => ["T"])
      expect(table).not_to have_key("C")
    end

    it "declines meta-new mixin calls under `class <<`" do
      # `K` lands on the singleton's constant table — unnameable — so the block's
      # class owns nothing the tables can key.
      extends = described_class.build_discovered_extends(parse(<<~RUBY))
        module T; end
        class C
          class << self
            K = Class.new { extend T }
          end
        end
      RUBY
      includes = described_class.build_discovered_includes(parse(<<~RUBY))
        module T; end
        class C
          class << self
            K = Class.new { include T }
          end
        end
      RUBY
      expect(extends).not_to have_key("C::K")
      expect(extends).not_to have_key("C")
      expect(includes).not_to have_key("C::K")
      expect(includes).not_to have_key("C")
    end

    it "files `class D` under `class <<` nowhere in the superclass and def-nesting tables" do
      # `#<Class:C>::D`'s ancestry and the defs' `Module.nesting` would publish a `C::D`
      # rung MRI never creates.
      program = parse(<<~RUBY)
        class C
          class << self
            class D < Base
              def m; end
            end
          end
        end
      RUBY
      supers, header_nestings = described_class.build_superclass_tables(program)
      expect(supers).not_to have_key("C::D")
      expect(header_nestings).not_to have_key("C::D")
      nestings = described_class.build_def_nestings(program)
      def_node = program.statements.body.first.body.body.first.body.body.first.body.body.first
      expect(nestings[def_node]).to eq(["C"])
    end

    it "files meta-new member layouts under `class <<` nowhere" do
      data = described_class.build_data_member_layouts(parse(<<~RUBY))
        class C
          class << self
            K = Data.define(:x)
            class D < Data.define(:y); end
          end
        end
      RUBY
      struct = described_class.build_struct_member_layouts(parse(<<~RUBY))
        class C
          class << self
            K = Struct.new(:x)
            class D < Struct.new(:y); end
          end
        end
      RUBY
      expect(data).not_to have_key("C::K")
      expect(data).not_to have_key("C::D")
      expect(struct).not_to have_key("C::K")
      expect(struct).not_to have_key("C::D")
    end

    it "files `class D` method defs under `class <<` nowhere in the class-def table" do
      defs = described_class.collect_class_method_defs(parse(<<~RUBY))
        class C
          class << self
            class D
              def m; end
            end
          end
        end
      RUBY
      expect(defs).not_to have_key("C::D")
    end

    it "names the owner of a `self::X.class_eval` block from the enclosing namespace" do
      # `self::X` inside `module M` resolves to `M::X` — the eval block's defs land there.
      table = methods_for(<<~RUBY)
        module M
          self::X.class_eval do
            def h; end
          end
        end
      RUBY
      expect(table).to include("M::X" => { h: :instance })
      expect(table).not_to have_key("M")
    end

    it "attributes a bare `private` toggle inside an eval block to the receiver's table" do
      table = described_class.build_discovered_method_visibilities(parse(<<~RUBY))
        class X; end
        module M
          X.class_eval do
            private
            def f; end
          end
        end
      RUBY
      expect(table).to include("X" => { f: :private })
      expect(table).not_to have_key("M")
    end

    it "declines `class D` under `class <<` in the per-file declaration tables" do
      # `class D` opens `#<Class:C>::D` — a real class nothing can name — so neither the
      # identity table nor `discovered_classes` may publish `C::D` (a `known_namespace?`
      # hit there would cross-contaminate every `D`-family resolution in the project).
      program = parse(<<~RUBY)
        class C
          class << self
            class D
            end
            class ::T
            end
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      scope = idx[program.statements.body.first]
      expect(scope.discovered_classes).not_to have_key("C::D")
      expect(scope.discovered_classes).to have_key("T")
      d_class = program.statements.body.first.body.body.first.body.body.first
      expect(idx[program].declared_types).not_to have_key(d_class.constant_path)
    end

    it "declines `class D` under `class <<` in the cross-file discovery tables" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "class C\n  class << self\n    class D; end\n    class ::T; end\n  end\nend\n")
        discovered = described_class.discovered_classes_for_paths([a])
        expect(discovered).not_to have_key("C::D")
        expect(discovered).to have_key("T")

        combined = described_class.discovered_project_index_incremental([a], seed_bundles: {})
        expect(combined.fetch(:def_index)[:class_sources]).not_to have_key("C::D")
      end
    end

    it "declines `K = Class.new` under `class <<` in the discovery tables" do
      # The write lands on the singleton's constant table — `#<Class:C>::K` names nothing.
      program = parse(<<~RUBY)
        class C
          class << self
            K = Class.new { def m; end }
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      expect(idx[program.statements.body.first].discovered_classes).not_to have_key("C::K")
    end

    it "keeps the `class <<` expression in the enclosing cref" do
      # `class << (class D; self; end)` — the expression declares `C::D` in the
      # enclosing namespace before the singleton body opens.
      table = methods_for(<<~RUBY)
        class C
          class << (class D
                      def m; end
                      self
                    end)
          end
        end
      RUBY
      expect(table).to include("C::D" => { m: :instance })
    end

    it "files `def` inside `class << self` nested in `class <<` nowhere" do
      # `self` inside `class << self` IS the singleton — `class << self` there opens
      # `#<Class:#<Class:C>>`, a surface nothing names — not `C.m`.
      table = methods_for(<<~RUBY)
        class C
          class << self
            class << self
              def m; end
            end
          end
        end
      RUBY
      expect(table.fetch("C", {})).not_to have_key(:m)
    end

    it "declines `extend` inside `instance_eval` on an unnameable receiver" do
      # `obj.instance_eval { extend T }` extends obj's singleton — never `C`'s.
      table = described_class.build_discovered_extends(parse(<<~RUBY))
        module T; end
        class C
          obj.instance_eval { extend T }
        end
      RUBY
      expect(table).not_to have_key("C")
    end

    it "attributes mixin calls inside `instance_eval` on a named receiver" do
      # `X.instance_eval { extend T }` extends `X` — the receiver resolution is the
      # eval walk's; only `def` rebinding differs.
      extends = described_class.build_discovered_extends(parse(<<~RUBY))
        module T; end
        class X; end
        class C
          X.instance_eval { extend T }
        end
      RUBY
      includes = described_class.build_discovered_includes(parse(<<~RUBY))
        module T; end
        class X; end
        class C
          X.instance_eval { include T }
        end
      RUBY
      expect(extends).to include("X" => ["T"])
      expect(extends).not_to have_key("C")
      expect(includes).to include("X" => ["T"])
      expect(includes).not_to have_key("C")
    end

    it "declines `extend` inside a `define_method` body and an unnamed `Class.new` block" do
      table = described_class.build_discovered_extends(parse(<<~RUBY))
        module T; end
        class C
          define_method(:m) { extend T }
          x = Class.new { extend T }
        end
      RUBY
      expect(table).not_to have_key("C")
    end

    it "walks a meta-new call's arguments in the enclosing context" do
      # `Class.new(X.class_eval { extend T })` — the eval inside the ARGUMENT still
      # extends X; only the block is the new class's body.
      table = described_class.build_discovered_extends(parse(<<~RUBY))
        module T; end
        class X; end
        class C
          K = Class.new(X.class_eval { extend T }) { def m; end }
        end
      RUBY
      expect(table).to include("X" => ["T"])
    end

    it "keys a path write inside `class D` under `class <<` as written, never `C::D`-qualified" do
      # `Foo::BAR` inside `#<Class:C>::D` resolves `Foo` through `[C, Object]` — the census
      # keys the write AS WRITTEN; what it must never fabricate is a `C::D::Foo::BAR` rung.
      writes = described_class.send(:constant_writes_for_file, parse(<<~RUBY))
        class C
          class << self
            class D
              Foo::BAR = 1
            end
          end
        end
      RUBY
      expect(writes.keys).to include("Foo::BAR")
      expect(writes.keys).not_to include("C::D::Foo::BAR")
    end

    it "keeps a ROOTED meta-new class's whole body nameable under `class <<`" do
      # `::K` lands at the top level — the block is `K`'s ordinary class body: member,
      # mixin, visibility, `def`, and `self::V` facts all file under `K`.
      source = <<~RUBY
        module I; end
        module E; end
        class C
          class << self
            ::K = Struct.new(:x) do
              include I
              extend E
              private
              def m = x
              self::V = 1
            end.freeze
          end
        end
      RUBY
      methods, def_nodes = described_class.build_methods_and_def_nodes(parse(source))
      expect(methods.fetch("K", {})).to include(m: :instance, x: :instance)
      expect(def_nodes.fetch("K", {})).to have_key(:m)
      expect(described_class.build_discovered_includes(parse(source))).to include("K" => ["I"])
      expect(described_class.build_discovered_extends(parse(source))).to include("K" => ["E"])
      visibility = described_class.build_discovered_method_visibilities(parse(source))
      expect(visibility.fetch("K", {})).to include(m: :private)
      struct = described_class.build_struct_member_layouts(parse(source))
      expect(struct.fetch("K", {}).fetch(:members, [])).to include(:x)
    end

    it "keys `self::V` inside a rooted meta-new block under the class it names" do
      # `self` inside `::K = Struct.new do … end` is `K` — `self::V` writes `K::V`.
      writes = described_class.send(:constant_writes_for_file, parse(<<~RUBY))
        class C
          class << self
            ::K = Struct.new(:x) do
              self::V = 1
            end.freeze
          end
        end
      RUBY
      expect(writes.keys).to include("K::V")
    end

    it "discovers `::K = Class.new` under `class <<` in both discovery tables" do
      # `resolve_meta_factory_call` only unwraps to a Data/Struct factory — a bare
      # `Class.new` is recognised by `meta_new_constant_rvalue?` directly, and a
      # `::`-rooted write stays nameable below the singleton.
      source = "class C\n  class << self\n    ::K = Class.new { def m = 1 }\n  end\nend\n"
      idx = described_class.index(parse(source), default_scope: default_scope)
      expect(idx[parse(source).statements.body.first].discovered_classes).to have_key("K")

      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, source)
        expect(described_class.discovered_classes_for_paths([a])).to have_key("K")
      end
    end

    it "keeps explicit-base meta-new writes nameable under `class <<`" do
      # `C::K2` and `Foo::F` resolve their base lexically — the write lands on the
      # spelled path, not the singleton's table.
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, <<~RUBY)
          class Foo; end
          class C
            class << self
              ::K = Class.new
              C::K2 = Class.new
              Foo::F = Class.new
              K3 = Class.new
            end
          end
        RUBY
        discovered = described_class.discovered_classes_for_paths([a])
        expect(discovered).to have_key("K")
        expect(discovered).to have_key("C::C::K2") # compact-header approximation, same as outside
        expect(discovered).to have_key("C::Foo::F")
        expect(discovered).not_to have_key("C::K3")
      end
    end

    it "keeps explicit-base class headers nameable under `class <<`" do
      # `class C::CD` resolves `C` lexically — nameable under the same compact-header
      # approximation the non-singleton walk uses; `class self::D` lands on the
      # singleton and stays unnameable.
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, <<~RUBY)
          class C
            class << self
              class C::CD; end
              class self::SD; end
              class Bare; end
            end
          end
        RUBY
        discovered = described_class.discovered_classes_for_paths([a])
        expect(discovered).to have_key("C::C::CD")
        expect(discovered).not_to have_key("C::SD")
        expect(discovered).not_to have_key("C::Bare")
      end
    end

    it "declines `self::`-anchored meta-new writes under `class <<`" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "class C\n  class << self\n    self::K = Class.new\n  end\nend\n")
        discovered = described_class.discovered_classes_for_paths([a])
        expect(discovered).not_to have_key("C::K")
        expect(discovered).not_to have_key("K")
      end
    end

    it "records aliases inside a rooted declaration under `class <<`" do
      # `class ::K` re-anchors — `alias copied original` inside belongs to `K`.
      program = parse(<<~RUBY)
        class C
          class << self
            class ::K
              def original = :ok
              alias copied original
            end
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      def_node = idx[program].user_def_for("K", :copied)
      expect(def_node).to be_a(Prism::DefNode)
      expect(def_node.name).to eq(:original)
    end

    it "does not record singleton-body aliases under the enclosing class" do
      # `alias` directly under `class <<` binds on `#<Class:C>` — the map files nothing.
      program = parse(<<~RUBY)
        class C
          class << self
            def original = :ok
            alias copied original
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      expect(idx[program].user_def_for("C", :copied)).to be_nil
    end

    it "keeps meta-new block declarations under the enclosing cref — self rebinds, nesting does not" do
      # `Module.nesting` inside `Class.new { }` stays lexical: `class Inner` below
      # `class <<` lands on `#<Class:C>` (unnameable), `class C::CD` re-anchors at
      # the compact-header name, and `def`/`include` attribute to the class the
      # write names. `class self::SX` resolves `self` to the class the write
      # names — `K::SX` — even below an unnameable cref, because a `self::` header
      # anchors on the rebound self, not the lexical prefix.
      program = parse(<<~RUBY)
        module I; end
        class C
          class << self
            ::K = Class.new do
              include I
              def m; end
              class Inner; def n; end; end
              class C::CD; def p; end; end
              class self::SX; def q; end; end
            end
          end
        end
      RUBY
      methods, = described_class.build_methods_and_def_nodes(program)
      expect(methods.keys).to contain_exactly("K", "C::C::CD", "K::SX")
      expect(methods["K"].keys).to eq([:m])
      expect(methods["K::SX"].keys).to eq([:q])

      includes = described_class.build_discovered_includes(program)
      expect(includes).to eq("K" => ["I"])

      idx = described_class.index(program, default_scope: default_scope)
      klass = program.statements.body[1]
      expect(idx[klass].discovered_classes).to have_key("K")
      expect(idx[klass].discovered_classes).not_to have_key("K::Inner")
      expect(idx[klass].discovered_classes).not_to have_key("C::Inner")
    end

    it "records meta-new block defs and aliases under the class the write names" do
      # `def`/`alias` inside `::K = Class.new` below `class <<` bind on K — self is
      # the named class even though the cref stays the singleton's.
      program = parse(<<~RUBY)
        class C
          class << self
            ::K = Class.new do
              def original = :ok
              alias copied original
              def m; @x = 1; end
            end
          end
        end
      RUBY
      defs = described_class.collect_class_method_defs(program)
      expect(defs.keys).to eq(["K"])

      idx = described_class.index(program, default_scope: default_scope)
      expect(idx[program].user_def_for("K", :copied)).not_to be_nil
      expect(idx[program].user_def_for("C", :copied)).to be_nil
    end

    it "keeps an unnameable meta-new block's defs ownerless under `class <<`" do
      # `K = Class.new` names nothing below the singleton — `def m` belongs to the
      # anonymous class and files nowhere.
      program = parse(<<~RUBY)
        class C
          class << self
            K = Class.new { def m = 1 }
          end
        end
      RUBY
      methods, = described_class.build_methods_and_def_nodes(program)
      expect(methods).to be_empty
      expect(described_class.collect_class_method_defs(program)).to be_empty
    end

    it "anchors self:: declarations and writes inside a meta-new block on the rebound self" do
      # `self` inside `K = Class.new { }` is K itself, so `class self::SX` and
      # `self::W = Class.new` name `C::K::SX` and `C::K::W` — the lexical prefix
      # would fabricate `C::SX`/`C::W`, and declining loses real classes.
      program = parse(<<~RUBY)
        class C
          K = Class.new do
            class self::SX; def q; end; end
            self::W = Class.new { def w; end }
            def m; end
          end
        end
      RUBY
      methods, = described_class.build_methods_and_def_nodes(program)
      expect(methods["C::K::SX"]&.keys).to eq([:q])
      expect(methods["C::K::W"]&.keys).to eq([:w])
      expect(methods).not_to have_key("C::SX")
      expect(methods).not_to have_key("C::W")

      idx = described_class.index(program, default_scope: default_scope)
      klass = program.statements.body.first
      expect(idx[klass].discovered_classes).to have_key("C::K::SX")
      expect(idx[klass].discovered_classes).to have_key("C::K::W")
    end

    it "attributes `class <<` inside a meta-new block to the written class's singleton" do
      # `class << self` inside `K = Class.new` opens `#<Class:K>` — its defs are
      # K's singleton methods, not instance defs of K or C.
      program = parse(<<~RUBY)
        class C
          K = Class.new do
            class << self
              def s = 1
            end
          end
        end
      RUBY
      idx = described_class.index(program, default_scope: default_scope)
      expect(idx[program].singleton_def_for("C::K", :s)).to be_a(Prism::DefNode)
      expect(idx[program].user_def_for("C::K", :s)).to be_nil
      expect(idx[program].user_def_for("C", :s)).to be_nil
      expect(described_class.collect_class_method_defs(program)).to be_empty
    end

    it "keeps anonymous factory blocks inside a meta-new body off the enclosing class" do
      # A bare `Class.new { }` inside `K = Class.new` is a second unnameable
      # class — its defs bind nowhere nameable, not on C and not on K.
      program = parse(<<~RUBY)
        class C
          K = Class.new do
            Class.new { def anon = 1 }
            Class.new do
              def original = :ok
              alias copied original
            end
          end
        end
      RUBY
      expect(described_class.collect_class_method_defs(program)).to be_empty
      idx = described_class.index(program, default_scope: default_scope)
      expect(idx[program].user_def_for("C", :anon)).to be_nil
      expect(idx[program].user_def_for("C::K", :anon)).to be_nil
      expect(idx[program].user_def_for("C", :copied)).to be_nil
      expect(idx[program].user_def_for("C::K", :copied)).to be_nil
    end

    it "records or-write and path-write meta-new mixin owners" do
      # `K ||= Class.new` and `Holder::K = Class.new` name their class when the
      # rvalue runs, so `include` inside mixes into that class — defs land there
      # too, so the mixin tables must not split the attribution.
      program = parse(<<~RUBY)
        module I; end
        module J; end
        class C
          K ||= Class.new { include I; def k = 1 }
          Holder::M = Class.new { include J; def m = 2 }
        end
      RUBY
      includes = described_class.build_discovered_includes(program)
      expect(includes).to eq("C::K" => ["I"], "C::Holder::M" => ["J"])

      methods, = described_class.build_methods_and_def_nodes(program)
      expect(methods["C::K"]&.keys).to eq([:k])
      expect(methods["C::Holder::M"]&.keys).to eq([:m])
    end

    it "declines a dynamic-base path write's meta-new block rather than guessing" do
      # `var::K = Class.new` writes whatever `var` holds — no source spelling
      # reaches the class — so its defs and the write itself file nowhere rather
      # than fabricating `C::K`.
      program = parse(<<~RUBY)
        class C
          var = something
          var::K = Class.new { def leak = 1 }
        end
      RUBY
      methods, = described_class.build_methods_and_def_nodes(program)
      expect(methods).to be_empty
      idx = described_class.index(program, default_scope: default_scope)
      klass = program.statements.body.first
      expect(idx[klass].discovered_classes).not_to have_key("C::K")
    end
  end

  # #682 — the per-declaration table `Scope#ancestor_name_candidates` reads. It records the nesting the
  # HEADER is written in, so the two spellings of one qualified name are distinguishable afterwards, which
  # is exactly what the peel it replaces could not do.
  describe ".build_superclass_tables" do
    def unkeyed = Rigor::Scope::DiscoveryIndex::UNKEYED_HEADER_NESTING

    def header_nestings(source)
      described_class.build_superclass_tables(parse(source)).last
    end

    # #728 — the chain the ancestor spelled `raw` resolves in. `raw` defaults to the UNKEYED entry, the
    # union over every ancestor-naming site, which is what a name no site wrote falls back to.
    def chain_for(source, class_name, raw = unkeyed)
      header_nestings(source).fetch(class_name)[raw]
    end

    it "records an empty header nesting for a compact declaration written at the top level" do
      expect(header_nestings("class Admin::Widget < Base; end"))
        .to eq({ "Admin::Widget" => { unkeyed => [], "Base" => [] } })
    end

    it "records the enclosing namespace for the nested spelling of the same class" do
      table = header_nestings("module Admin
  class Widget < Base; end
end
")
      expect(table).to eq({ "Admin::Widget" => { unkeyed => ["Admin"], "Base" => ["Admin"] } })
    end

    it "records one entry per declaration keyword for a doubly nested declaration" do
      source = "module A
  module B
    class C < Base; end
  end
end
"
      expect(chain_for(source, "A::B::C", "Base")).to eq(["A::B", "A"])
    end

    # #708 review — a site that writes NO ancestor name has no ancestor for its cref to govern, so it
    # contributes nothing. Recording it anyway is what let a rooted reopen inside another namespace put a
    # foreign chain ahead of the right one for a class it named no ancestor of.
    it "records nothing for a declaration that writes no ancestor name" do
      expect(header_nestings("module Admin\n  class Widget; end\nend\n")).to eq({})
    end

    it "records a site whose only ancestor name is a mixin call, keyed by the module it names" do
      source = "module Admin\n  class Widget\n    include Trackable\n  end\nend\n"
      expect(chain_for(source, "Admin::Widget", "Trackable")).to eq(["Admin"])
    end

    # #708 — a rooted header resets the class's NAME but not the cref its superclass name resolves in:
    # Ruby evaluates `Base` there at `Module.nesting == [Outer]`.
    it "keys a rooted declaration by its reset name and keeps the enclosing cref for its ancestors" do
      source = "module Outer
  class ::Rooted::Bar < Base; end
end
"
      expect(chain_for(source, "Rooted::Bar", "Base")).to eq(["Outer"])
      expect(header_nestings(source)).not_to have_key("Outer::Rooted::Bar")
    end

    it "still records the as-written superclass beside it" do
      supers = described_class.build_superclass_tables(parse("class Admin::Widget < Base; end")).first
      expect(supers).to eq({ "Admin::Widget" => "Base" })
    end

    # Rails' own `ActiveRecord::Relation` is the corpus case: the library declares it inside
    # `module ActiveRecord` and a test file reopens it as the compact `class ActiveRecord::Relation`.
    # Last-writer-wins hands the library site the test file's EMPTY chain and its nine `include`s stop
    # resolving — the false-positive direction. The reopen names no ancestor, so it records no chain at all
    # and the declaring site's survives by construction rather than by a merge rule.
    it "keeps the declaring site's chain when a later site reopens the class and names no ancestor" do
      source = "module Admin\n  class Widget\n    include Trackable\n  end\nend\nclass Admin::Widget; end\n"
      expect(chain_for(source, "Admin::Widget", "Trackable")).to eq(["Admin"])
      expect(chain_for(source, "Admin::Widget")).to eq(["Admin"])
    end

    # #728 — the defect the per-name keying exists for, at the table. Both sites name an ancestor, so both
    # are recorded; a single chain per class then gives the top-level site's `Base` the reopen's `["Outer"]`
    # and resolves it as `Outer::Base`, which is a WRONG class rather than a wider list.
    it "gives each site's ancestor name that site's own chain when the sites disagree" do
      source = "class Foo < Base; end\nmodule Outer\n  class ::Foo\n    include Helper\n  end\nend\n"
      expect(chain_for(source, "Foo", "Base")).to eq([])
      expect(chain_for(source, "Foo", "Helper")).to eq(["Outer"])
    end

    # The unkeyed entry stays the pre-#728 per-class union, because it is what answers a name neither site
    # wrote — the mixin `walk_class_includes` attributes to a class from outside its declaration.
    it "unions every ancestor-naming site under the unkeyed entry" do
      source = "class Foo < Base; end\nmodule Outer\n  class ::Foo\n    include Helper\n  end\nend\n"
      expect(chain_for(source, "Foo")).to eq(["Outer"])
    end

    it "unions two sites that write the SAME ancestor name, most-qualified first" do
      source = "module A\n  module B\n    class C\n      include M\n    end\n  end\nend\n" \
               "module A\n  class B::C\n    include M\n  end\nend\n"
      expect(chain_for(source, "A::B::C", "M")).to eq(["A::B", "A"])
    end

    # A mixin call the walk cannot render an argument for still marks the site as ancestor-naming, so the
    # site's chain reaches the unkeyed entry that such a name is answered from.
    it "records a chain for a site whose only mixin argument is dynamic" do
      source = "module A\n  class Widget\n    include helper_module\n  end\nend\n"
      expect(chain_for(source, "A::Widget")).to eq(["A"])
    end
  end

  # #708 review — the mutation census's two arms key on DIFFERENT TABLES. A `@@x` keys on the declaration
  # prefix because that is the join key with `build_class_cvar_index`, which derives its own from the same
  # `declaration_prefix`; a constant name resolves through the whole `Module.nesting` ladder, whose outer
  # rungs a rooted header drops from the prefix while Ruby keeps them. (The innermost entry is the same
  # value either way — the tables are what differ.) Threading one value for both is how the cvar arm came
  # to reference a parameter that no longer existed — a NameError
  # inside the discovery pre-pass, which the runner converts into a single `internal analyzer error` and
  # DISCARDS every real diagnostic in the file. Nothing in this repository mutates a `@@` receiver, so the
  # whole suite, the self-check and the corpus were all green over it.
  describe ".collect_literal_receiver_mutations" do
    define_method(:census) { |source| described_class.send(:collect_literal_receiver_mutations, parse(source)) }

    it "records a class-variable index write under the class that owns it" do
      result = census("class A\n  @@t = {}\n  def self.put(k) = @@t[k] = 1\nend\n")
      expect(result[:cvars]).to eq({ "A" => Set[:@@t] })
    end

    it "records a class-variable shovel under a nested class" do
      result = census("module M\n  class A\n    @@l = []\n    def self.add(v) = @@l << v\n  end\nend\n")
      expect(result[:cvars]).to eq({ "M::A" => Set[:@@l] })
    end

    # The rooted arm, and the reason the two facts cannot share a parameter: the cvar keys by the RESET
    # class name while the constant below keys through the UNRESET nesting, from the same body.
    it "keys a rooted class's cvar by its reset name while its constant reaches the enclosing nesting" do
      result = census("module Outer\n  TABLE = {}\n  class ::Rooted\n    @@seen = {}\n    " \
                      "def self.fill(k) = @@seen[k] = 1\n    def self.mark(k) = TABLE[k] = 1\n  end\nend\n")
      expect(result[:cvars]).to eq({ "Rooted" => Set[:@@seen] })
      expect(result[:constants]).to include("Outer::TABLE")
    end

    it "records nothing for a class variable mutated at the top level" do
      expect(census("@@t = {}\n@@t[:k] = 1\n")[:cvars]).to be_empty
    end

    # #703 — the third arm of the alignment #690 made on the write side. `::Table::ROWS` names the top
    # level unconditionally, so the `Admin::Table::ROWS` a bare spelling would also reach is a different
    # constant and keeps its empty-shape fold. The two spellings are indistinguishable by name alone —
    # the strict render they share drops the root marker — so the exemption has to be taken from the
    # node, exactly as `constant_path_write_key` takes it.
    it "records only the rooted candidate for a rooted path receiver" do
      result = census("module Admin\n  def self.fill(k) = ::Table::ROWS[k] = 1\nend\n")
      expect(result[:constants]).to eq(Set["Table::ROWS"])
    end

    # Must-still-record: the unrooted spelling from the same body reaches every lexical candidate, which
    # is what the arm above may not be allowed to have taken away.
    it "still records every lexical candidate for an unrooted path receiver" do
      result = census("module Admin\n  def self.fill(k) = Table::ROWS[k] = 1\nend\n")
      expect(result[:constants]).to eq(Set["Admin::Table::ROWS", "Table::ROWS"])
    end
  end

  # The census names what a call mutated, not what it stored, so a widened entry stops claiming its contents are
  # complete: each carrier member of it, `Union` members included, is unpinned inside the `Dynamic` wrapper. Asserted
  # on the tables because a read declines to project a `Union` facet at all, so no read tells the two apart there.
  # The read-side face is `spec/rigor/inference/mutated_constant_census_spec.rb`.
  describe "census widening of a mutated entry" do
    it "unpins each carrier member of a mutated constant, and leaves an unmutated twin exact" do
      program = parse(<<~RUBY)
        V = ENV["X"] ? { a: 1 } : [1]
        V << 2
        W = ENV["X"] ? { a: 1 } : [1]
      RUBY
      table = described_class.index(program, default_scope: default_scope)[program.statements.body.first]
                             .in_source_constants

      expect(table["V"].describe).to eq("Dynamic[Array[1 | Dynamic[top]] | { a: 1, ... }]")
      expect(table["W"].describe).to eq("[1] | { a: 1 }")
    end

    it "opens a mutated class variable's shape, and leaves an unmutated twin closed" do
      program = parse(<<~RUBY)
        class C
          def init = (@@h = { a: 1 }) && (@@k = { a: 1 })
          def mutate = @@h.default = 0
        end
      RUBY
      cvars = described_class.index(program, default_scope: default_scope)[program.statements.body.first]
                             .class_cvars_for("C")

      expect(cvars[:@@h].describe).to eq("Dynamic[{ a: 1, ... }]")
      expect(cvars[:@@k].describe).to eq("{ a: 1 }")
    end

    # An RBS overload join over an untyped argument wraps its candidates before the census sees them, so the facet of
    # an entry that is already `Dynamic` is unpinned too. The overload set is RBS's, so the members are asserted by
    # kind rather than spelled out.
    it "unpins the facet of an entry that is already Dynamic" do
      program = parse(<<~RUBY)
        X = 7.divmod(UNRESOLVED)
        X << 1
        Y = 7.divmod(UNRESOLVED)
      RUBY
      table = described_class.index(program, default_scope: default_scope)[program.statements.body.first]
                             .in_source_constants

      expect(table["X"].static_facet.members).to all(be_a(Rigor::Type::Nominal))
      expect(table["Y"].static_facet.members).to all(be_a(Rigor::Type::Tuple))
    end

    # `clear` empties a `non-empty-array`, so the removal is not kept. What is left is an ordinary nominal: a
    # value-pinned element gains the arm, and a class-level one keeps its claim.
    it "drops a removal a mutation can falsify, and unpins what is left as a nominal" do
      combinator = Rigor::Type::Combinator
      pinned = combinator.non_empty_array(combinator.constant_of(1))
      classed = combinator.non_empty_array(combinator.nominal_of("Integer"))

      expect(described_class.send(:census_mutated_type, pinned).describe).to eq("Dynamic[Array[1 | Dynamic[top]]]")
      expect(described_class.send(:census_mutated_type, classed).describe).to eq("Dynamic[Array[Integer]]")
    end
  end

  # Issue #1123 — the instance-side prepend table: `{class => [module names, as written]}` in
  # instance-ancestor SEARCH order. It adds the prepend ORDER and KIND the include table cannot carry
  # (that one keeps every mixin in search order since #1173 — prepends ahead of includes — but is read
  # as a set by the arity / visibility / reflection consumers), and
  # `Scope#user_def_through_ancestors` searches it ahead of the class's own `def`s.
  describe ".build_discovered_prepends" do
    it "records an in-body `prepend` in both tables" do
      program = parse(<<~RUBY)
        module T; end
        class C
          prepend T
        end
      RUBY
      expect(described_class.build_discovered_prepends(program)).to eq("C" => ["T"])
      expect(described_class.build_discovered_includes(program)).to eq("C" => ["T"])
    end

    it "orders two statements nearest-first, and one statement's arguments in call order" do
      # `prepend A; prepend B` searches B first; `prepend A, B` makes A the nearer of the two. Since
      # #1173 the include table keeps the same search order — prepends sort ahead of includes there,
      # matching where Ruby puts them (before the class itself).
      program = parse(<<~RUBY)
        module A; end
        module B; end
        class Two
          prepend A
          prepend B
        end
        class One
          prepend A, B
        end
      RUBY
      expect(described_class.build_discovered_prepends(program)).to eq("Two" => %w[B A], "One" => %w[A B])
      expect(described_class.build_discovered_includes(program)).to eq("Two" => %w[B A], "One" => %w[A B])
    end

    it "orders `include` statements nearest-first, and one statement's arguments in written order" do
      # #1173 — `include A; include B` searches B first (Ruby's later-include-wins); `include A, B`
      # keeps `["A", "B"]` because one statement's argument list lands as a unit ahead of the earlier
      # statements'. The pre-#1173 call-order list answered `["A", "B"]` for both.
      program = parse(<<~RUBY)
        module A; end
        module B; end
        class Two
          include A
          include B
        end
        class One
          include A, B
        end
      RUBY
      expect(described_class.build_discovered_includes(program)).to eq("Two" => %w[B A], "One" => %w[A B])
    end

    it "orders a mix of prepend and include the way the runtime ancestry does" do
      # `prepend` lands before the class itself, `include` after it, so both spellings and both
      # statement orders search the prepended module first.
      program = parse(<<~RUBY)
        module I; end
        module P; end
        class A
          include I
          prepend P
        end
        class B
          prepend P
          include I
        end
      RUBY
      expect(described_class.build_discovered_includes(program)).to eq("A" => %w[P I], "B" => %w[P I])
    end

    it "records the `Recv.prepend(Mod)` call form under the receiver in both tables" do
      program = parse(<<~RUBY)
        module T; end
        class C; end
        C.prepend(T)
      RUBY
      expect(described_class.build_discovered_prepends(program)).to eq("C" => ["T"])
      # The call form is the same ancestry edge as the declaration form, so the set-shaped include table
      # carries it too — otherwise the two spellings of one edge would answer differently for arity,
      # visibility and undefined-method suppression.
      expect(described_class.build_discovered_includes(program)).to eq("C" => ["T"])
    end

    it "leaves the `Recv.include(Mod)` call form unrecorded" do
      # Deliberately out of scope: no ordering question is open for it, and recording it would change what
      # every consumer says about the class (see the walk's comment).
      program = parse(<<~RUBY)
        module T; end
        class C; end
        C.include(T)
      RUBY
      expect(described_class.build_discovered_prepends(program)).to be_empty
      expect(described_class.build_discovered_includes(program)).to be_empty
    end

    it "resolves an unqualified call-form receiver through the nesting the file declares" do
      program = parse(<<~RUBY)
        module Api
          module T; end
          class C; end
          C.prepend(T)
        end
      RUBY
      expect(described_class.build_discovered_prepends(program)).to eq("Api::C" => ["T"])
    end

    it "declines a call-form receiver that names no static class" do
      program = parse(<<~RUBY)
        module T; end
        klass = Class.new
        klass.prepend(T)
      RUBY
      expect(described_class.build_discovered_prepends(program)).to be_empty
    end

    it "records a `prepend` written inside an eval block against the block's receiver" do
      program = parse(<<~RUBY)
        module T; end
        class C; end
        C.instance_eval { prepend T }
      RUBY
      expect(described_class.build_discovered_prepends(program)).to eq("C" => ["T"])
    end
  end

  # Issue #617 — a constant compound write reads a name the census sees bound as `Dynamic[top]`, and a name a file
  # writes only through `||=` is the memoization idiom rather than a binding, so it carries its own descriptor.
  describe "the publication census's memo descriptor" do
    def census(source) = described_class.send(:constant_writes_for_file, parse(source))

    it "files a name written only through `||=` as a memo, bare or as a path, however often" do
      expect(census(<<~RUBY)).to eq("A" => :memo, "Conf::B" => :memo)
        def a = (A ||= {})
        def again = (A ||= {})
        def b = (Conf::B ||= [])
      RUBY
    end

    it "files every other form, and a memo the same file also writes another way, as unpublishable" do
      writes = census(<<~RUBY)
        A ||= 1
        A += 1
        B &&= 1
        C ||= 1
        C = 2
        D = 1
        D ||= 2
        E += 1
      RUBY
      expect(writes).to eq(%w[A B C D E].to_h { |name| [name, :unpublishable] })
    end

    it "renders the memo in the declaration signature apart from an unpublishable write" do
      parts = []
      described_class.append_constant_signature(
        parts, constant_writes: { "A" => { "a.rb" => :memo }, "B" => { "a.rb" => :unpublishable } }
      )
      expect(parts).to eq(["k:A=||", "k:B=?"])
    end
  end
end
