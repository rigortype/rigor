# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/inference/indexed_narrowing"
require "rigor/scope"
require "rigor/type"

# Unit-level coverage for {Rigor::Inference::IndexedNarrowing}.
# The recorder side (`Inference::StatementEvaluator#eval_index_or_write`)
# and the consumer side (`Inference::ExpressionTyper#call_type_for`)
# are exercised end-to-end by the
# `fixtures/indexed_or_narrowing.rb` integration fixture; this
# file pins the address-recognition + invalidation primitives
# in isolation so the narrowing's soundness story has a stable
# regression surface.
RSpec.describe Rigor::Inference::IndexedNarrowing do
  let(:scope) { Rigor::Scope.empty }
  let(:tuple_empty) { Rigor::Type::Combinator.tuple_of }

  def parse_call(source)
    Prism.parse(source).value.statements.body.first
  end

  describe ".stable_receiver" do
    it "accepts a LocalVariableReadNode" do
      src = "p = 1\np\n"
      node = Prism.parse(src).value.statements.body.last
      expect(described_class.stable_receiver(node)).to eq(%i[local p])
    end

    it "accepts an InstanceVariableReadNode" do
      node = Prism.parse("@bag\n").value.statements.body.first
      expect(described_class.stable_receiver(node)).to eq(%i[ivar @bag])
    end

    it "rejects a CallNode and other non-variable receivers" do
      node = Prism.parse("foo.bar\n").value.statements.body.first
      expect(described_class.stable_receiver(node)).to be_nil
    end
  end

  describe ".stable_key" do
    it "extracts the literal value from SymbolNode" do
      node = Prism.parse(":k\n").value.statements.body.first
      expect(described_class.stable_key(node)).to eq(:k)
    end

    it "extracts the literal value from StringNode" do
      node = Prism.parse(%("k"\n)).value.statements.body.first
      expect(described_class.stable_key(node)).to eq("k")
    end

    it "extracts the literal value from IntegerNode" do
      node = Prism.parse("7\n").value.statements.body.first
      expect(described_class.stable_key(node)).to eq(7)
    end

    it "rejects a non-literal key (LocalVariableReadNode)" do
      src = "k = :x\nk\n"
      node = Prism.parse(src).value.statements.body.last
      expect(described_class.stable_key(node)).to be_nil
    end
  end

  describe ".lookup_for_call" do
    it "returns the recorded narrowing for a stable `receiver[key]` read" do
      scope2 = scope.with_indexed_narrowing(:local, :params, :f, tuple_empty)
      node = Prism.parse("params = {}\nparams[:f]\n").value.statements.body.last
      expect(described_class.lookup_for_call(node, scope2)).to eq(tuple_empty)
    end

    it "returns nil for a non-`[]` call" do
      node = Prism.parse("params.foo\n").value.statements.body.first
      expect(described_class.lookup_for_call(node, scope)).to be_nil
    end

    it "returns nil for a multi-argument `[]` (not a single-key read)" do
      node = Prism.parse("params[:a, :b]\n").value.statements.body.first
      expect(described_class.lookup_for_call(node, scope)).to be_nil
    end

    it "returns nil when no narrowing is recorded for the address" do
      node = Prism.parse("params = {}\nparams[:f]\n").value.statements.body.last
      expect(described_class.lookup_for_call(node, scope)).to be_nil
    end
  end

  describe ".invalidate_chain_after_call" do
    let(:scope_with_chain) do
      scope.with_method_chain_narrowing(:local, :x, :last, tuple_empty)
    end

    it "drops chain narrowings rooted at the call's stable receiver" do
      call = Prism.parse("x = []\nx << 1\n").value.statements.body.last
      post = described_class.invalidate_chain_after_call(call_node: call, current_scope: scope_with_chain)
      expect(post.method_chain_narrowing(:local, :x, :last)).to be_nil
    end

    it "is a no-op when the outer receiver is not stable (`x.last << y`)" do
      call = Prism.parse("x.last << 1\n").value.statements.body.first
      post = described_class.invalidate_chain_after_call(call_node: call, current_scope: scope_with_chain)
      expect(post.method_chain_narrowing(:local, :x, :last)).to eq(tuple_empty)
    end
  end

  describe ".invalidate_after_call" do
    let(:scope_with_narrowing) do
      scope.with_indexed_narrowing(:local, :params, :f, tuple_empty)
    end

    it "drops the specific `(receiver, key)` entry on `[]= against the same address`" do
      call = Prism.parse("params = {}\nparams[:f] = nil\n").value.statements.body.last
      post = described_class.invalidate_after_call(call_node: call, current_scope: scope_with_narrowing)
      expect(post.indexed_narrowing(:local, :params, :f)).to be_nil
    end

    it "preserves entries for a different key on the same receiver" do
      scope2 = scope_with_narrowing.with_indexed_narrowing(:local, :params, :other, tuple_empty)
      call = Prism.parse("params = {}\nparams[:f] = nil\n").value.statements.body.last
      post = described_class.invalidate_after_call(call_node: call, current_scope: scope2)
      expect(post.indexed_narrowing(:local, :params, :other)).to eq(tuple_empty)
      expect(post.indexed_narrowing(:local, :params, :f)).to be_nil
    end

    it "drops every entry for the receiver on a hash mutator (`clear`)" do
      scope2 = scope_with_narrowing.with_indexed_narrowing(:local, :params, :g, tuple_empty)
      call = Prism.parse("params = {}\nparams.clear\n").value.statements.body.last
      post = described_class.invalidate_after_call(call_node: call, current_scope: scope2)
      expect(post.indexed_narrowing(:local, :params, :f)).to be_nil
      expect(post.indexed_narrowing(:local, :params, :g)).to be_nil
    end

    it "does NOT invalidate on a non-mutator call (`keys`)" do
      call = Prism.parse("params = {}\nparams.keys\n").value.statements.body.last
      post = described_class.invalidate_after_call(call_node: call, current_scope: scope_with_narrowing)
      expect(post.indexed_narrowing(:local, :params, :f)).to eq(tuple_empty)
    end

    it "is a no-op when the receiver is not stable (`foo.bar.clear`)" do
      call = Prism.parse("foo.bar.clear\n").value.statements.body.first
      post = described_class.invalidate_after_call(call_node: call, current_scope: scope_with_narrowing)
      expect(post.indexed_narrowing(:local, :params, :f)).to eq(tuple_empty)
    end
  end

  describe "Scope receiver-rebind invalidation" do
    it "drops entries on `with_local(name)` when receiver name matches" do
      scope2 = scope.with_indexed_narrowing(:local, :params, :f, tuple_empty)
      rebound = scope2.with_local(:params, tuple_empty)
      expect(rebound.indexed_narrowing(:local, :params, :f)).to be_nil
    end

    it "preserves entries on `with_local(other)` for an unrelated name" do
      scope2 = scope.with_indexed_narrowing(:local, :params, :f, tuple_empty)
      unrelated = scope2.with_local(:other, tuple_empty)
      expect(unrelated.indexed_narrowing(:local, :params, :f)).to eq(tuple_empty)
    end

    it "drops entries on `with_ivar(name)` when receiver name matches" do
      scope2 = scope.with_indexed_narrowing(:ivar, :@bag, :items, tuple_empty)
      rebound = scope2.with_ivar(:@bag, tuple_empty)
      expect(rebound.indexed_narrowing(:ivar, :@bag, :items)).to be_nil
    end
  end

  describe "Scope join semantics" do
    it "keeps only narrowings present in both join inputs" do
      left = scope.with_indexed_narrowing(:local, :params, :f, tuple_empty)
      right = scope.with_indexed_narrowing(:local, :params, :f, tuple_empty)
      joined = left.join(right)
      expect(joined.indexed_narrowing(:local, :params, :f)).not_to be_nil
    end

    it "drops a narrowing present in only one branch" do
      left = scope.with_indexed_narrowing(:local, :params, :f, tuple_empty)
      joined = left.join(scope)
      expect(joined.indexed_narrowing(:local, :params, :f)).to be_nil
    end
  end
end
