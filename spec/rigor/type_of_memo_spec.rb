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
    state[Rigor::TypingState.slot(:type_of_memo).index] = described_class::Table.new
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

  it "compares the live table with the entry's last write of a key, not its first" do
    write = lambda do |*values|
      values.each do |value|
        state.log_bound_write(origins, store, node, value)
        store[node] = value
      end
      int
    end
    shadow { write.call(:first, :last) }
    shadow { write.call(:last, :first) }

    expect(counts).to include(mismatch: 1, mismatch_table: 1)
  end

  it "compares a recorded scope by identity, not by Scope#==" do
    other = Rigor::Scope.empty
    record = ->(recorded) { [recorded, int, 0].freeze }
    write = lambda do |recorded|
      state.log_bound_write(origins, store, node, record.call(recorded))
      store[node] = record.call(recorded)
      int
    end
    shadow { write.call(scope) }
    shadow { write.call(other) }

    expect(other).to eq(scope)
    expect(counts).to include(mismatch: 1, mismatch_table: 1)
  end

  it "compares types by their rendering too, which shows a hash shape's order that == ignores" do
    shape = ->(pairs) { Rigor::Type::Combinator.hash_shape_of(pairs) }
    forward = shape.call(a: int, b: str)
    backward = shape.call(b: str, a: int)
    shadow { forward }
    shadow { backward }

    expect(forward).to eq(backward)
    expect(counts).to include(mismatch: 1, mismatch_type: 1)
  end

  it "compares Hash table values in order, which Hash#== ignores" do
    write = lambda do |value|
      state.log_bound_write(origins, store, node, value)
      store[node] = value
      int
    end
    shadow { write.call({ a: 1, b: 2 }) }
    shadow { write.call({ b: 2, a: 1 }) }

    expect(counts).to include(mismatch: 1, mismatch_table: 1)
  end

  it "warns instead of raising when the report cannot be written" do
    previous = ENV.fetch("RIGOR_TYPE_OF_SHADOW_REPORT", nil)
    ENV["RIGOR_TYPE_OF_SHADOW_REPORT"] = File.join(Dir.tmpdir, "rigor-missing-#{Process.pid}", "r.jsonl")
    described_class.enable!
    expect { described_class.write_report }.to output(/not written/).to_stderr
  ensure
    ENV["RIGOR_TYPE_OF_SHADOW_REPORT"] = previous
    described_class.disable!
  end

  it "counts an error in the comparison as a mismatch and still answers the computation's value" do
    broken = Array.new(2) do
      Object.new.tap { |object| def object.==(_other) = raise(ArgumentError, "boom") }
    end
    shadow { broken[0] }

    expect(shadow { broken[1] }).to equal(broken[1])
    expect(counts).to include(mismatch: 1, mismatch_judge_error: 1)
  end

  it "shadows nothing outside a file's analysis, where no table is open" do
    state[Rigor::TypingState.slot(:type_of_memo).index] = nil
    2.times { shadow { int } }

    expect(described_class.counts).to be_empty
  end

  it "shadows a plain typer and bypasses one that carries operand types (WD1's instance state)" do
    current = Rigor::TypingState.current
    table = Rigor::TypingState.slot(:type_of_memo).index
    typed = lambda do |operand_types|
      described_class.reset
      Rigor::Inference::ExpressionTyper.new(scope: scope, operand_types: operand_types).type_of(node)
      described_class.counts.sum { |_, counters| counters[:lookups] }
    end
    described_class.enable!
    current[table] = described_class::Table.new
    begin
      expect(typed.call(nil)).to be_positive
      expect(typed.call({}.compare_by_identity)).to eq(0)
    ensure
      current[table] = nil
      described_class.disable!
    end
  end

  it "reports a forked child's own counts, not those it inherited, before the child's exit!" do
    shadow { int }
    report = Dir.mktmpdir do |dir|
      path = File.join(dir, "report.jsonl")
      write_child_report(path)
      JSON.parse(File.read(path))
    end

    expect(report.dig("counts", "other")).to eq("lookups" => 1, "checked" => 1)
  end

  def write_child_report(path)
    previous = ENV.fetch("RIGOR_TYPE_OF_SHADOW_REPORT", nil)
    ENV["RIGOR_TYPE_OF_SHADOW_REPORT"] = path
    described_class.enable!
    described_class.forked
    shadow { int }
    described_class.write_report
  ensure
    ENV["RIGOR_TYPE_OF_SHADOW_REPORT"] = previous
    described_class.disable!
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

  describe "ELIDE (ADR-129 WD2, measured in stage 3)" do
    let(:frame) { Rigor::TypingState.slot(:yield_value_type).index }
    let(:walk) { Rigor::TypingState.slot(:key_presence_walk).index }

    before { state.extend(Rigor::TypingState::ElideId) }

    it "keeps the ELIDE id across an install of the value the slot holds, and moves it for any other" do
      state.with(frame, int) do
        outer = state.elide_id
        state.with(frame, state[frame]) { expect(state.elide_id).to eq(outer) }
        state.with(frame, str) { expect(state.elide_id).not_to eq(outer) }
        state.without([walk]) { expect(state.elide_id).to eq(outer) }
        expect(state.elide_id).to eq(outer)
      end
    end

    it "moves the ELIDE id on a rewrite, and exits a frame open at one to a fresh id" do
      before = state.elide_id
      state.with(frame, int) { state.rewrite(walk) }

      expect(state.elide_id).not_to eq(before)
    end

    it "moves the ELIDE id on a push, a pop and a rewrite inside an open frame" do
      guard = Rigor::TypingState.slot(:user_method_inference_stack).index
      state.with(frame, int) do
        ids = [state.elide_id]
        state.push(guard, :entry)
        ids << state.elide_id
        state.pop(guard)
        ids << state.elide_id
        state.rewrite(walk)
        ids << state.elide_id
        expect(ids.uniq.size).to eq(4)
      end
    end

    it "keeps the ELIDE id across a pair install only when both values are the ones held" do
      other = Rigor::TypingState.slot(:forwarded_call_arg_types).index
      state.with_pair(frame, int, other, [int].freeze) do
        outer = state.elide_id
        state.with_pair(frame, state[frame], other, state[other]) { expect(state.elide_id).to eq(outer) }
        state.with_pair(frame, state[frame], other, [str].freeze) { expect(state.elide_id).not_to eq(outer) }
        state.without([frame]) { expect(state.elide_id).not_to eq(outer) }
      end
    end

    it "keys a table that elides on the ELIDE id, so an identical install looks the entry up" do
      table = described_class::Table.new(elide: true)
      state[Rigor::TypingState.slot(:type_of_memo).index] = table
      state.with(frame, int) do
        shadow { int }
        state.with(frame, state[frame]) { shadow { int } }
      end

      expect(counts).to include(stored: 1, checked: 1)
      expect(counts[:mismatch]).to eq(0)
    end
  end

  # ELIDE on a real run: the environment switch extends the state at the file's start, and the run's diagnostics and
  # G1's verdict are those of the plain shadow.
  it "leaves a real run's diagnostics unchanged with ELIDE on" do
    paths = Dir[File.expand_path("../integration/fixtures/*.rb", __dir__)].min_by(6) { |path| -File.size(path) }
    run = lambda do
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => paths, "parallel" => { "workers" => 0 })
      )
      guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)).diagnostics.map(&:to_h)
    end
    off = run.call
    previous = ENV.fetch("RIGOR_TYPE_OF_SHADOW_ELIDE", nil)
    ENV["RIGOR_TYPE_OF_SHADOW_ELIDE"] = "1"
    described_class.enable!
    on = begin
      run.call
    ensure
      described_class.disable!
      ENV["RIGOR_TYPE_OF_SHADOW_ELIDE"] = previous
    end

    expect(on).to eq(off)
    expect(Rigor::TypingState.current).to be_a(Rigor::TypingState::ElideId)
    expect(described_class.counts.sum { |_, counters| counters[:checked] }).to be_positive
    expect(described_class.mismatches).to eq(0), described_class.samples.first(3).inspect
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
    expect(described_class.counts.keys).to include(:main, :rule, :callee)
    expect(described_class.counts.keys).not_to include(:other)
    expect(described_class.mismatches).to eq(0), described_class.samples.first(3).inspect
  end
end
