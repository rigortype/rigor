# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-129 stage 3 — the `type_of` memo's shadow form (G1, stage-3 form). The memo stores, validates and compares, and
# never serves: these examples drive {Rigor::TypeOfMemo.shadow} with a stand-in computation, then a real run.
RSpec.describe Rigor::TypeOfMemo do
  let(:state) { Rigor::TypingState::State.new }
  let(:scope) { Rigor::Scope.empty }
  let(:node) { Prism.parse("a.b").value.statements.body.first }
  let(:origins) { Rigor::TypingState.slot(:dynamic_origins).index }
  let(:fuel) { Rigor::TypingState.slot(:user_method_unroll_fuel).index }
  let(:store) { {}.compare_by_identity }

  def int = Rigor::Type::Combinator.nominal_of("Integer")
  def str = Rigor::Type::Combinator.nominal_of("String")

  def shadow(&) = described_class.shadow(state, scope, node, &)

  def counts = described_class.counts.fetch(:other, {})

  before do
    described_class.reset
    state[Rigor::TypingState.slot(:type_of_memo).index] = nil
  end

  after { described_class.reset }

  it "serves nothing: every call computes, and the computation's answer is the call's" do
    calls = 0
    answers = [int, str].map { shadow { (calls += 1) == 1 ? int : str } }

    expect(answers).to eq([int, str])
    expect(calls).to eq(2)
    expect(counts).to include(stored: 1, checked: 1, mismatch: 1, mismatch_type: 1)
  end

  it "finds no mismatch when the recomputation answers and writes what the stored entry did" do
    2.times do
      shadow do
        state.log_bound_write(origins, store, node, :cause)
        store[node] = :cause
        int
      end
    end

    expect(counts).to include(stored: 1, checked: 1)
    expect(counts[:mismatch]).to eq(0)
  end

  it "reports a table mismatch when the recomputation writes what the entry did not" do
    shadow { int }
    shadow do
      state.log_bound_write(origins, store, node, :cause)
      store[node] = :cause
      int
    end

    expect(counts).to include(mismatch: 1, mismatch_table: 1)
    expect(described_class.samples.first).to include(kinds: [:table], phase: :other)
  end

  it "reports a table mismatch when the recomputation leaves out a write the entry would replay" do
    shadow do
      state.log_bound_write(origins, store, node, :cause)
      store[node] = :cause
      int
    end
    store[node] = :overwritten
    store.delete(node)
    shadow { int }

    expect(counts).to include(mismatch: 1, mismatch_table: 1)
  end

  it "reports a resource mismatch when the recomputation touches a Resource the stored computation did not" do
    shadow { int }
    shadow do
      state.touch(fuel)
      int
    end

    expect(counts).to include(mismatch: 1, mismatch_resource: 1)
  end

  it "stores neither a refused nor a raised computation, nor a leaf" do
    shadow do
      state.touch(fuel)
      int
    end
    expect { shadow { raise ArgumentError } }.to raise_error(ArgumentError)
    leaf = Prism.parse("a = 1; a").value.statements.body.last
    described_class.shadow(state, scope, leaf) { int }

    expect(counts).to include(refused: 1, raised: 1)
    expect(counts[:stored]).to eq(0)
    expect(state.capturing?).to be(false)
  end

  it "counts a read slice that no longer holds as a stale miss by slot, not as a mismatch" do
    shadow do
      state.log_bound_read(origins, store, node, Rigor::TypingState::ABSENT)
      int
    end
    store[node] = :recorded
    shadow { str }

    expect(counts).to include(stale: 1, stored: 2)
    expect(counts[:mismatch]).to eq(0)
    expect(counts[:stale_set_only]).to eq(0)
    expect(described_class.stale.fetch(:other)).to eq("dynamic_origins" => 1)
  end

  it "keys on the state id, so a different frame install looks up nothing" do
    frame = Rigor::TypingState.slot(:yield_value_type).index
    shadow { int }
    state.with(frame, int) { shadow { str } }

    expect(counts).to include(stored: 2)
    expect(counts[:checked]).to eq(0)
  end

  # A real run: the shadow over fixtures finds would-be hits, compares them all equal, and leaves the run's output
  # byte-identical with the memo off.
  it "leaves a real run's diagnostics unchanged and finds no mismatch over a fixture" do
    paths = Dir[File.expand_path("../integration/fixtures/*.rb", __dir__)].min_by(12) { |path| -File.size(path) }
    run = lambda do
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => paths, "parallel" => { "workers" => 0 })
      )
      guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)).diagnostics.map(&:to_h)
    end
    off = run.call
    described_class.enable!
    on = begin
      run.call
    ensure
      described_class.disable!
    end
    checked = described_class.counts.sum { |_, counters| counters[:checked] }

    expect(on).to eq(off)
    expect(checked).to be_positive
    expect(described_class.mismatches).to eq(0), described_class.samples.first(3).inspect
  end
end
