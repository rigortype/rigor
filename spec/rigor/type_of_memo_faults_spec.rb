# frozen_string_literal: true

require "spec_helper"

# ADR-129 G1′'s synthetic fixtures: stand-in computations that drive `TypeOfMemo.shadow` over the real slots, for the
# faults no source reaches through the engine. Each scenario runs on a fresh thread state, with the per-file table
# installed unless the memo is off, and answers what every typing answered and the advisory store's final entries.
class TypeOfMemoFaultScenarios
  # Fault => the mismatch kind the stage-4 form reports. Each scenario's comment says why no source fixture is used.
  KINDS = {
    skip_validation: :type, skip_absent_logging: :type, skip_upward_merge: :type, skip_replay_journal: :table,
    skip_memo_miss: :table, skip_read_through_memo_miss: :table, store_raised: :raised
  }.freeze

  ABSENT = Rigor::TypingState::ABSENT

  def initialize(memo:)
    @state = Rigor::TypingState::State.new
    @state[slot(:type_of_memo)] = Rigor::TypeOfMemo::Table.new if memo
    @store = {}.compare_by_identity
    @scope = Rigor::Scope.empty
    @outer, @inner = Prism.parse("a.b; c.d").value.statements.body
    @key = Prism.parse("e.f").value.statements.body.first
  end

  # A typing reads an origin; a later typing changes it, so the stored entry's read slice goes stale and serving it
  # would answer the old type. The source fixture for this fault (`dependency_read.rb`) shows only the stage-4 form's
  # own revalidation, since its stale reads are set-only; this one shows the wrong answer itself.
  def skip_validation
    typed = -> { shadow { read_origin == :first ? int : str } }
    @store[@key] = :first
    answers = [typed.call]
    @store[@key] = :second
    answers << typed.call
    [answers, entries]
  end

  # A typing reads an origin as absent; a later typing records one. No source fixture: over the 145 integration
  # fixtures no read slice goes stale outside the recording runs, and those stale reads are of the set-only recorder
  # tables, where a served write leaves the same entry. No production read of another Table was found that observes
  # ABSENT and is filled before the same key is typed again.
  def skip_absent_logging
    typed = -> { shadow { ABSENT.equal?(read_origin) ? int : str } }
    answers = [typed.call]
    @store[@key] = :cause
    answers << typed.call
    [answers, entries]
  end

  # An inner hit served inside an outer computation, whose read later goes stale. No source fixture: it needs a read
  # of a non-set-only Table that goes stale between typings of the same key (see {#skip_absent_logging}).
  def skip_upward_merge
    inner = -> { shadow(@inner) { read_origin == :first ? int : str } }
    @store[@key] = :first
    answers = [inner.call, shadow { inner.call }]
    @store[@key] = :second
    answers << shadow { inner.call }
    [answers, entries]
  end

  # An inner hit served inside an outer computation, whose write is cleared before the outer is typed again. No
  # source fixture: it needs a Table entry removed, or overwritten with a value the outer's recomputation does not
  # write back, between typings of the same key. Advisory entries are never removed in a run, and no such overwrite
  # was found.
  def skip_replay_journal
    inner = -> { shadow(@inner) { write_origin(:cause) && int } }
    answers = [inner.call, shadow { inner.call }]
    @store.delete(@key)
    answers << shadow { inner.call }
    [answers, entries]
  end

  # A Memo miss that writes a Table inside a stored computation, and a newer write of that entry. No source fixture:
  # over the integration fixtures the only plain-Memo misses that write a Table are the ADR-84 return memo's, which
  # read the transient log and push the guard stack first. Those Resource touches refuse the capture whether or not
  # the Memo rule applies.
  def skip_memo_miss
    memo = {}
    typed = -> { shadow { memo.fetch(:k) { memo[:k] = @state.memo_miss { write_origin(:first) && int } } } }
    answers = [typed.call]
    @store[@key] = :second
    answers << typed.call
    [answers, entries]
  end

  # A read-through Table's miss that writes another Table, and a newer write of that entry. No source fixture: a loop
  # record's miss that writes its record also writes `loops_evaluated`, a Resource, and a miss that writes no record
  # (a conditional with no loop in it) misses again on every typing, writing what the entry would replay. No inject
  # fold was found whose block body records an origin that a later typing overwrites with another.
  def skip_read_through_memo_miss
    typed = -> { shadow { (loop_record || @state.memo_miss(slot(:loop_value_record)) { fill_loop_record }) && int } }
    answers = [typed.call]
    @store[@key] = :second
    answers << typed.call
    [answers, entries]
  end

  # A computation that raises, typed twice. No source fixture: no typing raises out of `type_of` over the 145
  # integration fixtures. The engine is fail-soft, and a raise that reaches `type_of` is a defect to fix.
  def store_raised
    answers = Array.new(2) do
      shadow { raise ArgumentError, "typing failed" }
    rescue ArgumentError => e
      e.message
    end
    [answers, entries]
  end

  private

  # The store's entries, each key by its source, since every scenario parses its own nodes.
  def entries = @store.map { |node, value| [node.slice, value] }

  def slot(name) = Rigor::TypingState.slot(name).index

  def int = Rigor::Type::Combinator.nominal_of("Integer")
  def str = Rigor::Type::Combinator.nominal_of("String")

  def shadow(node = @outer, &) = Rigor::TypeOfMemo.shadow(@state, @scope, node, &)

  # A `dynamic_origins` read and write over the store, logged the way `Scope#dynamic_origin` and
  # `Scope#record_dynamic_origin` log them.
  def read_origin
    value = @store.fetch(@key, ABSENT)
    @state.log_bound_read(slot(:dynamic_origins), @store, @key, value)
    value
  end

  def write_origin(cause)
    @state.log_bound_write(slot(:dynamic_origins), @store, @key, cause)
    @store[@key] = cause
  end

  # The loop record held for the inner node, read as `LoopValueRecord.fetch` reads it, and the miss that fills it
  # and records an origin.
  def loop_record
    held = @state[slot(:loop_value_record)]&.[](@inner)
    @state.log_read(slot(:loop_value_record), @inner, held || ABSENT)
    held
  end

  def fill_loop_record
    write_origin(:first)
    record = [@scope, int].freeze
    @state.log_write(slot(:loop_value_record), @inner, record)
    @state.weak_key_map(slot(:loop_value_record))[@inner] = record
  end
end

# ADR-129 WD5's G1′, the gate's own gate: for each fault in {TypeOfMemoFaults::FAULTS}, G1's stage-4 form
# (`Rigor::TypeOfMemo.enable!(serve: true)`) reports a mismatch on a fixture. On the same fixture with no fault it
# reports none and answers what the memo off answers.
#
# A source fixture (`spec/fixtures/type_of_memo_faults/`) is analysed by a real `Runner`. Where no source reaches a
# fault's mechanism through the engine, a synthetic fixture ({TypeOfMemoFaultScenarios}) stands in.
RSpec.describe TypeOfMemoFaults do
  # Source fixtures: fault => [fixture, whether the run records dependencies and self-calls, the mismatch kind seen].
  #
  # - ignore_frame: the threaded-flag shape from ADR-129's Context. With the flag installed under the id already
  #   current, the statement pass looks up the entry the fold stored for the same scope object and node.
  # - skip_restore: the fold's install leaves its id behind, so the statement pass, typing the same node from the
  #   same scope object after the fold returns, runs at the fold's id.
  # - refuse_innermost: the `next` refuses only the `map` call's capture, so the `first` call around it is stored,
  #   and its recomputation, with the memo suspended, touches the next sink again.
  # - skip_validation: the only stale read slices a real run produces are of the set-only recorder tables, whose
  #   served writes leave the same entries. The stage-4 form's revalidation after the undo reports the stale entry.
  def self.source_cases
    {
      ignore_frame: ["threaded_block_body.rb", false, :type],
      skip_restore: ["threaded_block_body.rb", false, :type],
      refuse_innermost: ["nested_next_sink.rb", false, :resource],
      skip_validation: ["dependency_read.rb", true, :revalidate]
    }
  end

  def fixture(name) = File.expand_path("../fixtures/type_of_memo_faults/#{name}", __dir__)

  # G1's verdict since the last reset: how many would-be hits it checked, its mismatches, and their kinds.
  def verdict
    counts = Rigor::TypeOfMemo.counts
    kinds = counts.flat_map do |_, counters|
      counters.filter_map do |counter, n|
        counter.to_s.delete_prefix("mismatch_").to_sym if n.positive? && counter.to_s.start_with?("mismatch_")
      end
    end
    { checked: counts.sum { |_, counters| counters[:checked] }, mismatches: Rigor::TypeOfMemo.mismatches,
      kinds: kinds.uniq.sort, samples: Rigor::TypeOfMemo.samples.first(3) }
  end

  # Runs the block with the stage-4 form on and `fault` injected (nil for none), and answers the block's value and
  # G1's verdict.
  def serving(fault, &)
    Rigor::TypeOfMemo.reset
    Rigor::TypeOfMemo.enable!(serve: true)
    value = described_class.with(fault, &)
    [value, verdict]
  ensure
    Rigor::TypeOfMemo.disable!
    Rigor::TypeOfMemo.reset
  end

  def analyse(paths, recording: false)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => paths, "parallel" => { "workers" => 0 })
    )
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil,
                                         record_dependencies: recording, record_self_calls: recording)
    guarded_run(runner).diagnostics.map(&:to_h)
  end

  source_cases.values.uniq { |name, recording, _| [name, recording] }.each do |name, recording, _|
    it "serves hits on #{name} with no fault, reporting no mismatch and leaving its diagnostics as the memo off" do
      path = fixture(name)
      off = analyse([path], recording: recording)
      on, result = serving(nil) { analyse([path], recording: recording) }

      expect(on).to eq(off)
      expect(result[:checked]).to be_positive
      expect(result[:mismatches]).to eq(0), result[:samples].inspect
    end
  end

  source_cases.each do |fault, (name, recording, kind)|
    it "reports a #{kind} mismatch on #{name} with #{fault} injected" do
      _, result = serving(fault) { analyse([fixture(name)], recording: recording) }

      expect(result[:mismatches]).to be_positive
      expect(result[:kinds]).to include(kind)
    end
  end

  TypeOfMemoFaultScenarios::KINDS.each do |fault, kind|
    it "reports a #{kind} mismatch on the synthetic #{fault} fixture, and none with no fault" do
      off = TypeOfMemoFaultScenarios.new(memo: false).public_send(fault)
      on, clean = serving(nil) { TypeOfMemoFaultScenarios.new(memo: true).public_send(fault) }
      _, faulted = serving(fault) { TypeOfMemoFaultScenarios.new(memo: true).public_send(fault) }

      expect(on).to eq(off)
      expect(clean[:mismatches]).to eq(0), clean[:samples].inspect
      expect(faulted[:mismatches]).to be_positive
      expect(faulted[:kinds]).to include(kind)
    end
  end

  # A replay that raises while an entry is served (a store the entry outlived) is a counted mismatch, and the
  # recomputation's type is answered instead of a raise into the typing path.
  it "counts an error while serving as a mismatch and answers the recomputation's type" do
    state = Rigor::TypingState::State.new
    state[Rigor::TypingState.slot(:type_of_memo).index] = Rigor::TypeOfMemo::Table.new
    origins = Rigor::TypingState.slot(:dynamic_origins).index
    node = Prism.parse("a.b").value.statements.body.first
    scope = Rigor::Scope.empty
    store = {}.compare_by_identity
    type = Rigor::Type::Combinator.nominal_of("Integer")
    compute = lambda do
      state.log_bound_write(origins, store, node, :cause)
      store[node] = :cause
      type
    end
    def state.replay(_writes) = raise(ArgumentError, "store outlived")
    answers, result = serving(nil) { Array.new(2) { Rigor::TypeOfMemo.shadow(state, scope, node, &compute) } }

    expect(answers).to eq([type, type])
    expect(result[:kinds]).to include(:serve_error)
  end

  it "covers every fault with a source or a synthetic fixture" do
    expect((self.class.source_cases.keys + TypeOfMemoFaultScenarios::KINDS.keys).uniq)
      .to match_array(described_class::FAULTS)
  end

  it "serves hits over real fixtures with no fault, reporting no mismatch and leaving diagnostics as the memo off" do
    paths = Dir[File.expand_path("../integration/fixtures/*.rb", __dir__)].min_by(6) { |path| -File.size(path) }
    off = analyse(paths)
    on, result = serving(nil) { analyse(paths) }

    expect(on).to eq(off)
    expect(result[:checked]).to be_positive
    expect(result[:mismatches]).to eq(0), result[:samples].inspect
  end
end
