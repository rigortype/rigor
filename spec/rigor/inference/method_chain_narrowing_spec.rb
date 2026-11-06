# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/scope"
require "rigor/type"
require "rigor/inference/narrowing"
require "rigor/inference/scope_indexer"

# Unit-level coverage for stable single-hop method-chain narrowing. The recorder lives in `Narrowing` (extension to
# `analyse_class_predicate`); the lookup lives in `ExpressionTyper#call_type_for` via `method_chain_narrowing_for`; the
# invalidator lives in `IndexedNarrowing.invalidate_chain_after_call` and is wired into `StatementEvaluator#eval_call`.
#
# Integration coverage of the truthy/falsey edge + Array dispatch lives in
# `spec/integration/fixtures/method_chain_narrowing.rb`. This file pins the address-keying + invalidation contract in
# isolation so the slice's soundness story has a stable regression surface.
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
      # `xs` is a method parameter (Dynamic[top]) — the narrowing path widens Dynamic to the asked class, so the
      # recorded carrier is `Nominal[Array]`. A locally-bound `xs` whose `.last` already carries a Tuple subtype would
      # narrow to the more-precise Tuple, not Array, because narrowing never coarsens.
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
      # Walk to the assignment inside the method body. With no `@list` seed in the class-ivar accumulator, the ivar
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
      # The inner `xs.first` is not the predicate's outermost receiver, so the recorder does not register it.
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

  # Issue #2691 — a rescue clause runs after any prefix of the `begin` body
  # raised, so the indexed and method-chain facts the pre-begin scope holds
  # survive into it only where the body's own evaluation left them standing:
  # a call on the fact's root receiver, a `[]=` or mutator on its collection,
  # or an index-target store invalidates them exactly as it does on the
  # straight-line path.
  describe "rescue clause entry" do
    let(:string_nominal) { Rigor::Type::Combinator.nominal_of("String") }
    let(:array_nominal) { Rigor::Type::Combinator.nominal_of("Array") }

    # The scope recorded at the `@x.r` read inside the rescue clause — the
    # last `@x.r` call the source holds. An ivar root needs no assignment in
    # the source, so `@x` reads as `InstanceVariableReadNode` throughout.
    def rescue_chain_read_scope(source, base_scope: default_scope)
      program = Prism.parse(source).value
      reads = {}
      on_enter = lambda do |node, s|
        next unless node.is_a?(Prism::CallNode) && node.name == :r &&
                    node.receiver.is_a?(Prism::InstanceVariableReadNode) && node.receiver.name == :@x

        reads[node] = s
      end
      Rigor::Inference::StatementEvaluator.new(scope: base_scope, on_enter: on_enter,
                                               widen_clauses: true).evaluate(program)
      reads.max_by { |node, _| node.location.start_offset }.last
    end

    it "drops an `is_a?` chain fact the body's `@x.r = nil` call invalidated" do
      scope = rescue_chain_read_scope(<<~RUBY)
        def f
          return unless @x.r.is_a?(String)
          begin
            @x.r = nil
            raise "x"
          rescue
            probe = @x.r
          end
        end
      RUBY
      expect(scope.method_chain_narrowing(:ivar, :@x, :r)).to be_nil
    end

    it "keeps the chain fact when the body calls nothing on its root" do
      scope = rescue_chain_read_scope(<<~RUBY)
        def f
          return unless @x.r.is_a?(String)
          begin
            y = 1
            raise "x"
          rescue
            probe = @x.r
          end
        end
      RUBY
      expect(scope.method_chain_narrowing(:ivar, :@x, :r)).to eq(string_nominal)
    end

    # Issue #2691's truthiness chain fact: #2692's truthiness and `nil?`
    # guards record into the same `method_chain_narrowings` table the
    # `is_a?` guard above does, so the clause-entry rule cannot tell the
    # producers apart. The fact is installed directly — no truthiness
    # producer exists on master yet — and pinned the same way.
    it "drops a truthiness chain fact the body's call invalidated" do
      base = default_scope.with_ivar(:@x, Rigor::Type::Combinator.untyped)
                          .with_method_chain_narrowing(:ivar, :@x, :r, string_nominal)
      scope = rescue_chain_read_scope(<<~RUBY, base_scope: base)
        begin
          @x.r = nil
          raise "x"
        rescue
          probe = @x.r
        end
      RUBY
      expect(scope.method_chain_narrowing(:ivar, :@x, :r)).to be_nil
    end

    it "drops an indexed narrowing the body's `[]=` write invalidated" do
      program = Prism.parse(<<~RUBY).value
        begin
          @h[:k] = nil
          raise "x"
        rescue
          probe = @h[:k]
        end
      RUBY
      reads = {}
      on_enter = lambda do |node, s|
        reads[node] = s if node.is_a?(Prism::CallNode) && node.name == :[]
      end
      base = default_scope.with_ivar(:@h, Rigor::Type::Combinator.untyped)
                          .with_indexed_narrowing(:ivar, :@h, :k, array_nominal)
      Rigor::Inference::StatementEvaluator.new(scope: base, on_enter: on_enter,
                                               widen_clauses: true).evaluate(program)
      read = reads.keys.max_by { |node| node.location.start_offset }
      expect(reads[read].indexed_narrowing(:ivar, :@h, :k)).to be_nil
    end

    # The scope recorded at the `@h[:k]` read inside the rescue clause — the
    # last `:[]` call the source holds.
    def rescue_indexed_read_scope(source, base_scope: default_scope)
      program = Prism.parse(source).value
      reads = {}
      on_enter = lambda do |node, s|
        reads[node] = s if node.is_a?(Prism::CallNode) && node.name == :[]
      end
      Rigor::Inference::StatementEvaluator.new(scope: base_scope, on_enter: on_enter,
                                               widen_clauses: true).evaluate(program)
      reads.max_by { |node, _| node.location.start_offset }.last
    end

    # Review of #2910 — the fall-through exit is not every raise point:
    # `eval_if` discards a terminating then-branch when there is no else, so a
    # write on `if c; @x.r = nil; raise; end` never reaches it. The clause entry
    # must drop the fact the terminating branch invalidated anyway.
    it "drops a chain fact written on an if-branch that raises without an else" do
      scope = rescue_chain_read_scope(<<~RUBY)
        def f
          return unless @x.r.is_a?(String)
          begin
            if rand > 0.5
              @x.r = nil
              raise "x"
            end
          rescue
            probe = @x.r
          end
        end
      RUBY
      expect(scope.method_chain_narrowing(:ivar, :@x, :r)).to be_nil
    end

    it "drops an indexed narrowing written on an if-branch that raises without an else" do
      base = default_scope.with_ivar(:@h, Rigor::Type::Combinator.untyped)
                          .with_indexed_narrowing(:ivar, :@h, :k, array_nominal)
      scope = rescue_indexed_read_scope(<<~RUBY, base_scope: base)
        begin
          if rand > 0.5
            @h[:k] = nil
            raise "x"
          end
        rescue
          probe = @h[:k]
        end
      RUBY
      expect(scope.indexed_narrowing(:ivar, :@h, :k)).to be_nil
    end

    it "drops a chain fact written on an unless-branch that raises" do
      scope = rescue_chain_read_scope(<<~RUBY)
        def f
          return unless @x.r.is_a?(String)
          begin
            unless rand > 0.5
              @x.r = nil
              raise "x"
            end
          rescue
            probe = @x.r
          end
        end
      RUBY
      expect(scope.method_chain_narrowing(:ivar, :@x, :r)).to be_nil
    end

    it "drops a chain fact written on an `or` operand that raises" do
      scope = rescue_chain_read_scope(<<~RUBY)
        def f(flag)
          return unless @x.r.is_a?(String)
          begin
            flag or (@x.r = nil; raise "x")
          rescue
            probe = @x.r
          end
        end
      RUBY
      expect(scope.method_chain_narrowing(:ivar, :@x, :r)).to be_nil
    end

    it "keeps the chain fact when only the else clause writes it" do
      scope = rescue_chain_read_scope(<<~RUBY)
        def f
          return unless @x.r.is_a?(String)
          begin
            work
          rescue
            probe = @x.r
          else
            @x.r = nil
            raise "x"
          end
        end
      RUBY
      expect(scope.method_chain_narrowing(:ivar, :@x, :r)).to eq(string_nominal)
    end

    it "drops the chain fact for a retried begin's re-evaluated pass" do
      scope = rescue_chain_read_scope(<<~RUBY)
        def f
          return unless @x.r.is_a?(String)
          tries = 0
          begin
            if rand > 0.5
              @x.r = nil
              raise "x"
            end
          rescue
            probe = @x.r
            tries += 1
            retry if tries < 3
          end
        end
      RUBY
      expect(scope.method_chain_narrowing(:ivar, :@x, :r)).to be_nil
    end

    it "drops the chain fact for a write inside a nested begin's body" do
      scope = rescue_chain_read_scope(<<~RUBY)
        def f
          return unless @x.r.is_a?(String)
          begin
            begin
              @x.r = nil
              raise "x"
            rescue
            end
          rescue
            probe = @x.r
          end
        end
      RUBY
      expect(scope.method_chain_narrowing(:ivar, :@x, :r)).to be_nil
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
