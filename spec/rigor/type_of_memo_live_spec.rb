# frozen_string_literal: true

require "spec_helper"

# ADR-129 stage 4 — the `type_of` memo live in the rule walk. A hit whose read slice holds is served without computing:
# its reads merged into the open captures, its writes replayed. These examples drive {Rigor::TypeOfMemo.live} with a
# stand-in computation, then a real run.
RSpec.describe Rigor::TypeOfMemo, ".live" do
  let(:state) { Rigor::TypingState::State.new }
  let(:scope) { Rigor::Scope.empty }
  let(:node) { Prism.parse("a.b").value.statements.body.first }
  let(:origins) { Rigor::TypingState.slot(:dynamic_origins).index }
  let(:fuel) { Rigor::TypingState.slot(:user_method_unroll_fuel).index }
  let(:guard) { Rigor::TypingState.slot(:user_method_inference_stack).index }
  let(:table) { Rigor::TypingState.slot(:type_of_memo).index }
  let(:store) { {}.compare_by_identity }

  def int = Rigor::Type::Combinator.nominal_of("Integer")
  def str = Rigor::Type::Combinator.nominal_of("String")

  def live(at = node, &) = described_class.live(state, scope, at, guard, &)

  def counts = described_class.counts.fetch(:rule, {})

  def write_cause(value = :cause)
    state.log_bound_write(origins, store, node, value)
    store[node] = value
  end

  before do
    described_class.reset
    described_class.enable!(live: true, count: true)
    state[table] = described_class::Table.new(phase: :rule)
  end

  after do
    described_class.disable!
    described_class.reset
  end

  it "serves a hit without computing it again" do
    calls = 0
    answers = Array.new(3) { live { (calls += 1) == 1 ? int : str } }

    expect(answers).to eq([int, int, int])
    expect(calls).to eq(1)
    expect(counts).to include(lookups: 3, stored: 1, hits: 2, root_hits: 2)
  end

  it "replays a served hit's writes, and journals them for the enclosing capture" do
    live do
      write_cause
      int
    end
    store.delete(node)
    state.open_capture
    live { raise "not served" }
    _, records = state.close_capture

    expect(store[node]).to eq(:cause)
    expect(records.each_slice(4).map(&:first)).to eq([:write])
  end

  it "merges a served hit's reads into the enclosing capture" do
    live do
      state.log_bound_read(origins, store, node, Rigor::TypingState::ABSENT)
      int
    end
    expect(state.journal_size).to eq(0)
    state.open_capture
    live { raise "not served" }
    _, records = state.close_capture

    expect(records.each_slice(4).to_a).to eq([[:read, origins, [store, node], Rigor::TypingState::ABSENT]])
    expect(counts[:root_hits]).to eq(0)
  end

  it "computes again when a read the entry logged no longer holds" do
    live do
      state.log_bound_read(origins, store, node, Rigor::TypingState::ABSENT)
      int
    end
    store[node] = :written_since
    answer = live { str }

    expect(answer).to eq(str)
    expect(counts).to include(stale: 1, stored: 2)
    expect(counts[:hits]).to eq(0)
  end

  it "stores neither a refused nor a raised computation, so each computes again" do
    calls = 0
    2.times do
      live do
        calls += 1
        state.touch(fuel)
        int
      end
    end
    expect { live { raise ArgumentError } }.to raise_error(ArgumentError)
    live { int }

    expect(calls).to eq(2)
    expect(counts).to include(refused: 2, raised: 1, stored: 1)
    expect(state.capturing?).to be(false)
  end

  it "keys on the state id, so a different frame install computes again" do
    threaded = Rigor::TypingState.slot(:threaded_block_body).index
    calls = 0
    live { (calls += 1) && int }
    state.with(threaded, true) { live { (calls += 1) && int } }

    expect(calls).to eq(2)
  end

  it "keys on the scope object too, so the same node at the same id in another scope computes again" do
    other = Rigor::Scope.empty
    first = live { int }
    second = described_class.live(state, other, node, guard) { str }

    expect([first, second]).to eq([int, str])
    expect(counts).to include(stored: 2)
    expect(counts[:hits]).to eq(0)
  end

  it "opens neither in a callee body, nor for a leaf, nor outside the rule walk" do
    calls = 0
    state.push(guard, :callee)
    2.times { live { (calls += 1) && int } }
    state.pop(guard)
    leaf = Prism.parse("a = 1; a").value.statements.body.last
    2.times { live(leaf) { (calls += 1) && int } }
    state[table] = nil
    2.times { live { (calls += 1) && int } }

    expect(calls).to eq(6)
    expect(counts).to be_empty
  end

  it "keeps no counters unless asked to, so the live path takes no lock" do
    described_class.enable!(live: true)
    2.times { live { int } }

    expect(described_class.counts).to be_empty
  end

  it "installs the file's table when the rule walk starts, not for the main pass" do
    current = Rigor::TypingState.current
    current[table] = nil
    described_class.begin_file
    expect(current[table]).to be_nil

    described_class.phase!(:rule)
    expect(current[table]).to be_a(described_class::Table).and(have_attributes(phase: :rule))

    described_class.end_file
    expect(current[table]).to be_nil
  end

  # A real run: the live memo serves rule-walk hits over fixtures, and the run's diagnostics are those with it off.
  it "leaves a real run's diagnostics unchanged over fixtures, and looks nothing up in the main pass" do
    paths = Dir[File.expand_path("../integration/fixtures/*.rb", __dir__)].min_by(12) { |path| -File.size(path) }
    run = lambda do
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => paths, "parallel" => { "workers" => 0 })
      )
      guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)).diagnostics.map(&:to_h)
    end
    described_class.disable!
    off = run.call
    described_class.reset
    described_class.enable!(live: true, count: true)
    main_pass = count_main_pass_lookups
    on = run.call

    expect(on).to eq(off)
    expect(described_class.counts.keys).to eq([:rule])
    expect(counts[:hits]).to be_positive
    expect(main_pass.sum).to eq(0)
  end

  # The lookups each file's main pass makes, the stretch between its `begin_file` and its `phase!(:rule)`.
  def count_main_pass_lookups
    lookups = []
    allow(described_class).to receive(:begin_file).and_wrap_original do |original|
      lookups << -counts.fetch(:lookups, 0)
      original.call
    end
    allow(described_class).to receive(:phase!).and_wrap_original do |original, phase|
      lookups[-1] += counts.fetch(:lookups, 0) if phase == :rule && lookups.any?
      original.call(phase)
    end
    lookups
  end
end
