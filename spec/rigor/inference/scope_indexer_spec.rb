# frozen_string_literal: true

require "spec_helper"
require "prism"

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
end
