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
        expect(type).to be_a(Rigor::Type::Union)
        array_member = type.members.grep(Rigor::Type::Nominal).find { |m| m.class_name == "Array" }
        expect(array_member.type_args.first).to be_a(Rigor::Type::Dynamic)
        expect(type.members).to include(Rigor::Type::Combinator.constant_of("x"))
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

    it "contributes nothing for an extend target with no discovered defs (control)" do
      source = "module Registry\n  extend SomeGemModule\nend\nRegistry.helper\n"
      expect(last_statement_type(source).describe(:short)).to eq("Dynamic[top]")
    end
  end
end
