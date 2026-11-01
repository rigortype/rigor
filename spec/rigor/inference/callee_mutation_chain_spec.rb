# frozen_string_literal: true

require "spec_helper"

# ADR-127 WD3 — `CalleeMutationChain.close` answers a property of the parameter-flow graph. Over random small graphs the
# answer equals the reference property, and it does not depend on the walks that filled the shared successor store
# before it.
RSpec.describe Rigor::Inference::CalleeMutationChain do
  let(:chain) { described_class }
  let(:edge_class) { described_class::Edge }

  # A def: `mutated` says whether it writes its one parameter itself, `callees` the defs it hands the parameter to.
  let(:def_class) { Struct.new(:id, :mutated, :callees) }

  def random_graph(random, size)
    defs = Array.new(size) { |id| def_class.new(id, random.rand < 0.12, []) }
    defs.each do |d|
      random.rand(0..3).times { d.callees << defs[random.rand(size)] }
    end
    defs
  end

  def adapters
    own = ->(d, _owner) { d.mutated ? { p: 0 } : {} }
    edges = lambda do |d, _owner|
      d.callees.map { |callee| edge_class.new(name: :p, slot: 0, callee: callee, callee_names: [:p]) }.uniq
    end
    [own, edges]
  end

  # The property: the root is own-mutated, or an own-mutated node is reachable from it, or more than `limit` distinct
  # nodes are reachable from it.
  def mutated_by_reference?(root, limit)
    return true if root.mutated

    seen = { root.id => true }
    queue = [root]
    until queue.empty?
      current = queue.shift
      current.callees.each do |callee|
        next if seen[callee.id]

        seen[callee.id] = true
        return true if callee.mutated || seen.size > limit

        queue << callee
      end
    end
    false
  end

  def answer(root, store)
    own, edges = adapters
    chain.close(root, own: own, edges: edges, store: store, ctx: :ctx).key?(:p) || root.mutated
  end

  it "answers the reference property, whichever walks filled the store first" do
    random = Random.new(2520)
    Rigor::Inference::MemoAudit.enable!
    200.times do
      limit = random.rand(2..8)
      stub_const("Rigor::Inference::CalleeMutationChain::MAX_NODES", limit)
      defs = random_graph(random, random.rand(2..20))
      expected = defs.to_h { |d| [d.id, mutated_by_reference?(d, limit)] }

      fresh = defs.to_h { |d| [d.id, answer(d, nil)] }
      shared = {}.compare_by_identity
      order = defs.shuffle(random: random)
      warmed = order.to_h { |d| [d.id, answer(d, shared)] }
      again = defs.reverse.to_h { |d| [d.id, answer(d, shared)] }

      expect([fresh, warmed, again]).to eq([expected, expected, expected])
    end
  ensure
    Rigor::Inference::MemoAudit.disable!
  end

  it "reports a cut for a fan-out wider than the limit and not for one at the limit" do
    stub_const("Rigor::Inference::CalleeMutationChain::MAX_NODES", 5)
    leaves = Array.new(5) { |i| def_class.new(i + 1, false, []) }
    root = def_class.new(0, false, leaves.dup)
    expect(answer(root, nil)).to be(true)
    root.callees.pop
    expect(answer(root, nil)).to be(false)
  end

  it "fails the memo audit when a stored successor list is stale" do
    own, edges = adapters
    leaf = def_class.new(1, false, [])
    root = def_class.new(0, false, [leaf])
    store = {}.compare_by_identity
    Rigor::Inference::MemoAudit.enable!
    chain.close(root, own: own, edges: edges, store: store, ctx: :ctx)
    leaf.callees << def_class.new(2, false, [])
    root.callees << def_class.new(3, false, [])
    expect { chain.close(root, own: own, edges: edges, store: store, ctx: :ctx) }
      .to raise_error(Rigor::Inference::MemoAudit::Mismatch, /successor/)
  ensure
    Rigor::Inference::MemoAudit.disable!
  end

  it "keeps a def reached under two owners as two nodes in the store" do
    owner_a = :owner_a
    owner_b = :owner_b
    writer = def_class.new(9, true, [])
    target = def_class.new(1, false, [])
    root = def_class.new(0, false, [])
    own = ->(d, _owner) { d.mutated ? { p: 0 } : {} }
    edges = lambda do |d, owner|
      if d.equal?(root)
        [owner_a, owner_b].map { |o| edge_class.new(name: :p, slot: 0, callee: target, callee_names: [:p], owner: o) }
      elsif d.equal?(target) && owner == owner_b
        [edge_class.new(name: :p, slot: 0, callee: writer, callee_names: [:p])]
      else
        []
      end
    end
    store = {}.compare_by_identity
    expect(chain.close(root, own: own, edges: edges, store: store, ctx: :ctx)).to eq({ p: 0 })
    expect(store[target].keys).to contain_exactly(owner_a, owner_b)
  end

  describe "the successor store of a closure (ADR-127 WD2)" do
    let(:source) { "class Mut\n  def run(acc)\n    stripes(acc)\n  end\n\n  def stripes(acc) = acc\nend\n" }
    let(:program) { Prism.parse(source).value }
    let(:index) { Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty) }
    let(:call) do
      found = nil
      Rigor::Source::NodeWalker.each(program) { |n| found ||= n if n.is_a?(Prism::CallNode) && n.name == :stripes }
      found
    end

    it "is the run's store for a plain scope and no store under a constant narrowing" do
      scope = index[call]
      plain = Rigor::Inference::StatementEvaluator.new(scope: scope).send(:callee_chain_store)
      narrowed_scope = scope.with_constant_narrowing("Mut", Rigor::Type::Combinator.nominal_of("Mut"), Rigor::Type::Combinator.untyped)
      narrowed = Rigor::Inference::StatementEvaluator.new(scope: narrowed_scope).send(:callee_chain_store)
      expect([plain.key?(:store), narrowed]).to eq([true, {}])
    end

    it "is no store while an audit recomputation runs" do
      evaluator = Rigor::Inference::StatementEvaluator.new(scope: index[call])
      inside = Rigor::Inference::MemoAudit.suspended { evaluator.send(:callee_chain_store) }
      expect(inside).to eq({})
    end
  end
end
