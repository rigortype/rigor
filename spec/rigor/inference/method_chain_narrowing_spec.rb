# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/scope"
require "rigor/type"
require "rigor/inference/narrowing"
require "rigor/inference/scope_indexer"

# Unit-level coverage for the "stable single-hop method-chain
# narrowing" slice (ROADMAP § Future cycles / Type-language /
# engine — "Method-call receiver narrowing across stable
# receivers"). The recorder lives in `Narrowing` (extension to
# `analyse_class_predicate`); the lookup lives in
# `ExpressionTyper#call_type_for` via
# `method_chain_narrowing_for`; the invalidator lives in
# `IndexedNarrowing.invalidate_chain_after_call` and is wired
# into `StatementEvaluator#eval_call`.
#
# Integration coverage of the truthy/falsey edge + Array
# dispatch lives in `spec/integration/fixtures/method_chain_narrowing.rb`.
# This file pins the address-keying + invalidation contract in
# isolation so the slice's soundness story has a stable
# regression surface.
RSpec.describe "Stable single-hop method-chain narrowing" do
  let(:default_scope) { Rigor::Scope.empty }

  def post_scope_for(source)
    program = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: default_scope)
    _type, scope = default_scope.evaluate(program)
    [program, scope, index]
  end

  describe "recorder" do
    it "records `(local, :xs, :last) → Array` on the truthy edge of `if xs.last.is_a?(::Array)`" do
      # `xs` is a method parameter (Dynamic[top]) — the narrowing
      # path widens Dynamic to the asked class, so the recorded
      # carrier is `Nominal[Array]`. A locally-bound `xs` whose
      # `.last` already carries a Tuple subtype would narrow to
      # the more-precise Tuple, not Array, because narrowing
      # never coarsens.
      program, _scope, index = post_scope_for(<<~RUBY)
        def f(xs)
          if xs.last.is_a?(::Array)
            probe_marker = xs.last
          end
        end
      RUBY
      def_node = program.statements.body.first
      if_node = def_node.body.body.first
      probe_assign = if_node.statements.body.first
      entry_scope = index[probe_assign]
      narrowed = entry_scope.method_chain_narrowing(:local, :xs, :last)
      expect(narrowed).not_to be_nil
      expect(narrowed).to be_a(Rigor::Type::Nominal)
      expect(narrowed.class_name).to eq("Array")
    end

    it "records the same shape for an ivar root receiver" do
      program, _scope, index = post_scope_for(<<~RUBY)
        class Holder
          def f
            if @list.last.is_a?(::Array)
              x = @list.last
            end
          end
        end
      RUBY
      # Walk to the assignment inside the method body. With no
      # `@list` seed in the class-ivar accumulator, the ivar
      # reads as `Dynamic[top]` and narrowing produces `Nominal[Array]`.
      class_node = program.statements.body.first
      def_f = class_node.body.body.first
      if_node = def_f.body.body.first
      probe_assign = if_node.statements.body.first
      entry_scope = index[probe_assign]
      narrowed = entry_scope.method_chain_narrowing(:ivar, :@list, :last)
      expect(narrowed).to be_a(Rigor::Type::Nominal)
      expect(narrowed.class_name).to eq("Array")
    end
  end

  describe "stability gates" do
    it "does NOT record narrowing for a chain with positional arguments" do
      program, _scope, index = post_scope_for(<<~RUBY)
        xs = [1, []]
        if xs.first(2).is_a?(::Array)
          y = xs.first(2)
        end
      RUBY
      if_node = program.statements.body[1]
      probe_assign = if_node.statements.body.first
      entry_scope = index[probe_assign]
      expect(entry_scope.method_chain_narrowing(:local, :xs, :first)).to be_nil
    end

    it "does NOT record narrowing for a chain with a block" do
      program, _scope, index = post_scope_for(<<~RUBY)
        xs = [1, []]
        if xs.detect { |e| e.is_a?(Array) }.is_a?(::Array)
          y = xs.detect { |e| e.is_a?(Array) }
        end
      RUBY
      if_node = program.statements.body[1]
      probe_assign = if_node.statements.body.first
      entry_scope = index[probe_assign]
      expect(entry_scope.method_chain_narrowing(:local, :xs, :detect)).to be_nil
    end

    it "does NOT record narrowing for a multi-hop chain (Law of Demeter — A1 scope)" do
      program, _scope, index = post_scope_for(<<~RUBY)
        xs = [[1, 2]]
        if xs.first.last.is_a?(::Integer)
          y = xs.first.last
        end
      RUBY
      if_node = program.statements.body[1]
      probe_assign = if_node.statements.body.first
      entry_scope = index[probe_assign]
      # The inner `xs.first` is not the predicate's outermost
      # receiver, so the recorder does not register it.
      expect(entry_scope.method_chain_narrowing(:local, :xs, :first)).to be_nil
    end
  end

  describe "invalidation" do
    it "drops the chain narrowing when the root variable is rebound" do
      program, _scope, index = post_scope_for(<<~RUBY)
        xs = [1, []]
        if xs.last.is_a?(::Array)
          xs = []
          probe_marker = xs.last
        end
      RUBY
      if_node = program.statements.body[1]
      probe_assign = if_node.statements.body[1] # after `xs = []`
      entry_scope = index[probe_assign]
      expect(entry_scope.method_chain_narrowing(:local, :xs, :last)).to be_nil
    end

    it "drops the chain narrowing when ANY call against the root receiver intervenes" do
      program, _scope, index = post_scope_for(<<~RUBY)
        xs = [1, []]
        if xs.last.is_a?(::Array)
          xs.something
          probe_marker = xs.last
        end
      RUBY
      if_node = program.statements.body[1]
      probe_assign = if_node.statements.body[1]
      entry_scope = index[probe_assign]
      expect(entry_scope.method_chain_narrowing(:local, :xs, :last)).to be_nil
    end

    it "PRESERVES the chain narrowing when a call runs against the chain itself (not the root)" do
      program, _scope, index = post_scope_for(<<~RUBY)
        def f(xs)
          if xs.last.is_a?(::Array)
            xs.last << :y
            probe_marker = xs.last
          end
        end
      RUBY
      def_node = program.statements.body.first
      if_node = def_node.body.body.first
      probe_assign = if_node.statements.body[1]
      entry_scope = index[probe_assign]
      narrowed = entry_scope.method_chain_narrowing(:local, :xs, :last)
      expect(narrowed).to be_a(Rigor::Type::Nominal)
      expect(narrowed.class_name).to eq("Array")
    end
  end

  describe "join semantics" do
    it "keeps only chains present in both join inputs" do
      scope = Rigor::Scope.empty
      array_t = Rigor::Type::Combinator.nominal_of("Array")
      left = scope.with_method_chain_narrowing(:local, :xs, :last, array_t)
      right = scope.with_method_chain_narrowing(:local, :xs, :last, array_t)
      joined = left.join(right)
      expect(joined.method_chain_narrowing(:local, :xs, :last)).not_to be_nil
    end

    it "drops a chain present in only one branch" do
      scope = Rigor::Scope.empty
      array_t = Rigor::Type::Combinator.nominal_of("Array")
      left = scope.with_method_chain_narrowing(:local, :xs, :last, array_t)
      joined = left.join(scope)
      expect(joined.method_chain_narrowing(:local, :xs, :last)).to be_nil
    end
  end
end
