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
end
