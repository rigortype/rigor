# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# ADR-129 stage 1 — the typing state's four kinds, its state id (WD2) and its journal (WD3). No `type_of` memo exists
# yet, so these examples drive a bare {Rigor::TypingState::State}; the last group audits a real run's use of
# the declared slots.
RSpec.describe Rigor::TypingState do
  let(:state) { described_class::State.new }

  def index(name) = described_class.slot(name).index
  def frame = index(:yield_value_type)
  def other_frame = index(:forwarded_call_arg_types)
  def guard_stack = index(:user_method_inference_stack)
  def fuel = index(:user_method_unroll_fuel)
  def event_log = index(:user_method_transient_event_depths)
  def walk = index(:key_presence_walk)
  def table = index(:inject_accumulator)

  describe "the registry" do
    it "declares each slot once, at its own index, with a kind and a reason" do
      slots = described_class.slots

      expect(slots.map(&:index)).to eq((0...slots.size).to_a)
      expect(described_class::KINDS).to include(*slots.map(&:kind).uniq)
      expect(slots.map(&:name).uniq.size).to eq(slots.size)
      expect(slots.map(&:reason)).to all(satisfy { |reason| !reason.strip.empty? })
    end

    it "keeps the registry shareable, so a Ractor worker can read it" do
      expect(Ractor.shareable?(described_class.slots)).to be(true)
    end

    it "gives each kind only the options it can carry" do
      slots = described_class.slots

      expect(slots.select(&:run_scoped).map(&:kind).uniq - %i[table memo resource]).to be_empty
      expect(slots.select(&:read_through).map(&:kind).uniq).to eq([:table])
      expect(slots.select(&:read_through).map(&:name)).to contain_exactly(:inject_accumulator, :loop_value_record)
      expect(slots.select(&:contents).map(&:kind).uniq).to eq([:frame])
      expect(slots.select(&:read_exemption).reject { |slot| slot.kind == :resource || slot.contents }).to be_empty
    end

    it "refuses a duplicate name, an empty reason and an option the kind cannot carry" do
      expect { described_class.frame(:yield_value_type, reason: "x") }.to raise_error(ArgumentError, /already declared/)
      expect { described_class.memo(:typing_state_spec_probe, reason: " ") }.to raise_error(ArgumentError, /why/)
      expect { described_class.resource(:typing_state_spec_probe, reason: "x", read_exemption: :maybe) }
        .to raise_error(ArgumentError, /read_exemption/)
      expect { described_class.frame(:typing_state_spec_probe, reason: "x", read_exemption: :delta_internal) }
        .to raise_error(ArgumentError, /contents/)
      expect { described_class.frame(:typing_state_spec_probe, reason: "x", contents: :store) }
        .to raise_error(ArgumentError, /contents/)
      expect do
        described_class.frame(:typing_state_spec_probe, reason: "x", contents: :table, read_exemption: :delta_internal)
      end.to raise_error(ArgumentError, /exemption/)
      expect(described_class.slots.map(&:name)).not_to include(:typing_state_spec_probe)
    end

    it "hands each thread its own state" do
      expect(Thread.new { described_class.current }.value).not_to be(described_class.current)
    end
  end

  describe "the state id (WD2)" do
    it "takes a fresh id for every install, an identical value included, and restores it on the way out" do
      ids = []
      state.with(frame, :a) do
        ids << state.id
        state.with(frame, :a) { ids << state.id }
        ids << state.id
      end

      expect(ids.first).not_to eq(0)
      expect(ids[1]).not_to eq(ids.first)
      expect(ids.last).to eq(ids.first)
      expect([state.id, state[frame]]).to eq([0, nil])
    end

    it "restores the slot and the id when the block raises" do
      expect { state.with(frame, :a) { raise "boom" } }.to raise_error(RuntimeError, "boom")
      expect([state.id, state[frame]]).to eq([0, nil])
    end

    it "installs a pair under one id and clears a list under one id" do
      state.with_pair(frame, :a, other_frame, :b) do
        expect([state[frame], state[other_frame]]).to eq(%i[a b])
        pair_id = state.id
        state.without([frame, other_frame].freeze) do
          expect([state[frame], state[other_frame]]).to eq([nil, nil])
          expect(state.id).not_to eq(pair_id)
        end
        expect([state[frame], state[other_frame], state.id]).to eq([:a, :b, pair_id])
      end
      expect([state.id, state[frame], state[other_frame]]).to eq([0, nil, nil])
    end

    it "moves the id on each push and pop of the guard stack, and a frame around both restores its own" do
      ids = []
      state.with(frame, :a) do
        ids << state.id
        state.push(guard_stack, :signature)
        ids << state.id
        state.pop(guard_stack)
        ids << state.id
      end

      expect(ids.uniq.size).to eq(3)
      expect(state.id).to eq(0)
      expect(state.stack(guard_stack)).to eq([])
    end

    it "exits every frame open at a rewrite to a fresh id rather than to the one that named the old contents" do
      inner_saved = nil
      state.with(frame, :a) do
        inner_saved = state.id
        state.with(other_frame, :b) { state.rewrite(walk) }
        expect(state.id).not_to eq(inner_saved)
      end

      expect(state.id).not_to eq(0)
    end
  end

  describe "the journal (WD3)" do
    it "logs Table reads and writes only while a capture is open" do
      state.log_read(table, :before, :value)
      state.open_capture
      state.log_read(table, :key, described_class::ABSENT)
      state.log_write(table, :key, :value)
      refused, records = state.close_capture

      expect(refused).to be(false)
      expect(records).to eq([:read, table, :key, described_class::ABSENT, :write, table, :key, :value])
      expect(state.capturing?).to be(false)
      expect(state.instance_variable_get(:@journal)).to be_empty
    end

    it "hands a nested capture's records on to the enclosing one" do
      state.open_capture
      state.log_write(table, :outer, 1)
      state.open_capture
      state.log_read(table, :inner, 2)
      _, inner = state.close_capture
      _, outer = state.close_capture

      expect(inner).to eq([:read, table, :inner, 2])
      expect(outer).to eq([:write, table, :outer, 1, :read, table, :inner, 2])
    end

    it "refuses every capture open at a touch (the any rule), and none opened after it" do
      state.open_capture
      state.open_capture
      state.touch(fuel)
      inner, = state.close_capture
      state.open_capture
      sibling, = state.close_capture
      outer, = state.close_capture

      expect([inner, sibling, outer]).to eq([true, false, true])
    end

    it "counts each Resource access as a touch, and a Frame read, an install or an exempt stack read as none" do
      touching = {
        read: -> { state.read(fuel) }, write: -> { state.write(fuel, 1) }, append: -> { state.append(event_log, 0) },
        acquire: -> { state.acquire(event_log) { [] } }, push: -> { state.push(guard_stack, :s) },
        pop: -> { state.pop(guard_stack) }, rewrite: -> { state.rewrite(walk) }, touch: -> { state.touch(walk) }
      }
      quiet = {
        frame_read: -> { state[frame] }, install: -> { state.with(frame, 1) { nil } },
        stack_read: -> { state.stack(guard_stack).size }, table_log: -> { state.log_read(table, :k, 1) }
      }

      refused = touching.merge(quiet).transform_values do |operation|
        state.open_capture
        operation.call
        state.close_capture.first
      end
      expect(refused).to eq(touching.transform_values { true }.merge(quiet.transform_values { false }))
    end
  end

  # The kind discipline of every slot a real run reaches: each access goes through its kind's API, and a Frame value
  # is frozen while installed unless the frame declares its contents a Resource (the retry frames' stack is frozen
  # even so: its edges are the contents). An audited state stands in for the thread's own, so every typer and
  # evaluator of the run caches it, and a capture stays open across the run, so the journal records what a future
  # `type_of` memo would see.
  describe "a real run's slot accesses" do
    let(:audited_class) do
      Class.new(described_class::State) do
        attr_reader :violations, :reached, :accesses, :touchers

        def initialize
          super
          @violations = []
          @reached = Set.new
          @accesses = Hash.new(0)
          @touchers = Hash.new { |hash, name| hash[name] = Set.new }
        end

        def [](slot)
          check(slot, :read) { |s| s.kind != :resource || s.read_exemption }
          super
        end

        def []=(slot, value)
          check(slot, :container) { |s| %i[memo table].include?(s.kind) }
          super
        end

        def with(slot, value, &)
          check_install(slot, value)
          super
        end

        def with_pair(slot, value, other, other_value, &)
          check_install(slot, value)
          check_install(other, other_value)
          super
        end

        def without(slots, &)
          slots.each { |slot| check_install(slot, nil) }
          super
        end

        def touch(slot)
          check(slot, :touch) { |s| s.kind == :resource || s.contents == :resource }
          @touchers[Rigor::TypingState.slots[slot].name] << toucher
          super
        end

        %i[read write acquire append].each do |name|
          define_method(name) do |slot, *args, &block|
            check(slot, name) { |s| s.kind == :resource }
            super(slot, *args, &block)
          end
        end

        %i[push pop stack].each do |name|
          define_method(name) do |slot, *args|
            check(slot, name) { |s| s.kind == :resource && s.read_exemption == :id_determined }
            super(slot, *args)
          end
        end

        def rewrite(slot)
          check(slot, :rewrite) { |s| s.read_exemption == :id_determined }
          super
        end

        def weak_key_map(slot)
          check(slot, :weak_key_map) { |s| %i[memo table].include?(s.kind) }
          super
        end

        %i[log_read log_write].each do |name|
          define_method(name) do |slot, key, value|
            check(slot, name) { |s| s.kind == :table && !s.bound }
            super(slot, key, value)
          end
        end

        %i[log_bound_read log_bound_write].each do |name|
          define_method(name) do |slot, store, key, value|
            check(slot, name) { |s| s.kind == :table && s.bound }
            super(slot, store, key, value)
          end
        end

        private

        # The first caller outside `TypingState` and this spec: the engine method that touched.
        def toucher
          caller_locations(2, 8).find { |location| !location.path.end_with?("typing_state.rb", "_spec.rb") }&.base_label
        end

        def check(slot, access)
          declared = Rigor::TypingState.slots[slot]
          @reached << declared.name
          @accesses[[declared.name, access]] += 1
          @violations << [declared.name, access] unless yield(declared)
        end

        def check_install(slot, value)
          check(slot, :install) { |s| s.kind == :frame }
          declared = Rigor::TypingState.slots[slot]
          frozen_needed = declared.contents.nil? || declared.name == :retry_frames
          @violations << [declared.name, :unfrozen, value.class] if frozen_needed && !value.frozen?
        end
      end
    end

    let(:source) do
      <<~RUBY
        class Probe
          MAP = { integer: { type: :integer }, string: { type: :string } }.freeze

          def lookup(prop)
            k = prop.column_type
            if MAP.key?(k)
              r = MAP[k].dup
              r[:a] = 1
            end
          end
          def fact(n) = n <= 1 ? 1 : n * fact(n - 1)
          def even?(n) = n.zero? ? true : odd?(n - 1)
          def odd?(n) = n.zero? ? false : even?(n - 1)

          def first_even(items)
            items.each { |item| return item if item.even? }
            nil
          end

          def nexts(items) = items.map { |item| next 0 if item.nil?; item }

          def breaks(items)
            found = while items.any?
                      break items.first
                    end
            found
          end

          def value_break(items) = items.each { |item| break item if item }

          def total = [1, 2].inject(0) { |sum, item| sum + item }
          def forward(...) = target(...)
          def target(first, second = 1) = first || second
          def yielder = yield(1)
          def use_yield = yielder { |x| x + 1 }

          def retrying
            tries = 0
            begin
              tries += 1
              raise "again" if tries < 2
            rescue StandardError
              retry
            end
            tries
          end

          def ensure_jump(items)
            items.each do |item|
              begin
                next if item
              ensure
                item = 1
              end
            end
          end

          def ensured_break(items)
            while items.any?
              begin
                break if items.first
              ensure
                items = []
              end
            end
            items
          end

          def rescued_break(items)
            while items.any?
              begin
                break if items.first
              rescue StandardError
                items = []
              end
            end
            items
          end
        end

        # The run-scoped Memos the alias-mutation floor, the self-call ivar proof, the toplevel def census and the
        # construction scans fill: a literal Hash held by two locals and a holder object, a `remove`r through the
        # alias, a self-call chain over an ivar, a receiverless call of a top-level def, and a constructed subclass.
        class Holder
          def initialize(items) = @items = items
          def add(item) = @items << item
          def log = note
          def note = (@count = 1)
          def run(first)
            @first = first
            log
            @first.to_s
          end
        end

        def top_helper(items) = items.size

        def aliasing
          first = { a: 1 }
          second = first
          second.delete(:a)
          holder = Holder.new(first)
          holder.add(2)
          top_helper(first)
          first
        end

        class Parent; end
        class Child < Parent; end
        Constructed = Class.new(StandardError)

        # A `class_eval` on a constant receiver inside a namespace: the file's declared names settle which constant it
        # denotes.
        module Outer
          class Inner; end
          Inner.class_eval { def made = 1 }
        end

        Holder.new(nil).run(1)
        aliasing
        Child.new
        probe = Probe.new
        [probe.lookup(nil), probe.fact(5), probe.even?(4), probe.first_even([1, 2]), probe.nexts([nil, 1]),
         probe.breaks([1]), probe.value_break([nil, 2]), probe.total, probe.forward(1), probe.use_yield,
         probe.retrying, probe.ensure_jump([1]), probe.ensured_break([1]), probe.rescued_break([1])]
      RUBY
    end

    # The audited state after one run of `source`, with the capture open across the run closed into `:refused` and
    # `:records`, and the run's `BudgetTrace` counts.
    def audited_run
      audited = audited_class.new
      key = described_class.const_get(:STATE_KEY)
      previous = Thread.current[key]
      Thread.current[key] = audited
      Rigor::Inference::BudgetTrace.enable!
      Rigor::Inference::BudgetTrace.reset
      audited.open_capture
      analyze_probe
      refused, records = audited.close_capture
      { state: audited, refused: refused, records: records, counts: Rigor::Inference::BudgetTrace.snapshot }
    ensure
      Rigor::Inference::BudgetTrace.disable!
      Rigor::Inference::BudgetTrace.reset
      Thread.current[key] = previous
    end

    def analyze_probe
      Dir.mktmpdir do |dir|
        path = File.join(dir, "probe.rb")
        File.write(path, source)
        patch = File.join(dir, "patch.rb")
        File.write(patch, "class String\n  def x = 1 unless method_defined?(:x)\n  private def y = 2\nend\n")
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge("paths" => [path], "pre_eval" => [patch],
                                               "parallel" => { "workers" => 0 })
        )
        guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), [path])
      end
    end

    # The audited state after a run with every recorder on: ADR-46 dependency recording (nested inside an outer
    # window, so each file's window suspends it), the self-call recorder, an `effects:` block and a flow trace.
    def audited_recording_run
      audited = audited_class.new
      key = described_class.const_get(:STATE_KEY)
      previous = Thread.current[key]
      Thread.current[key] = audited
      audited.open_capture
      Rigor::Inference::FlowTracer.record do
        Rigor::Analysis::DependencyRecorder.record_for("outer.rb") { analyze_recorded_probe }
      end
      refused, records = audited.close_capture
      { state: audited, refused: refused, records: records }
    ensure
      Thread.current[key] = previous
    end

    def analyze_recorded_probe
      Dir.mktmpdir do |dir|
        paths = recorded_probe_files.map do |name, text|
          File.join(dir, name).tap { |path| File.write(path, text) }
        end
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge("paths" => paths, "parallel" => { "workers" => 0 }, "effects" => {})
        )
        runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil,
                                             record_dependencies: true, record_self_calls: true)
        guarded_run(runner, paths)
      end
    end

    # A cross-file read (dependencies), a repeated callee (a replayed return-memo hit), a wrong-arity call (a withheld
    # read set), an external mixin (a resolution chain's prebuilt hook keys), a class extending a module whose
    # `extended` hook mixes into it (the extend hook keys) and an unresolved implicit-self call (the self-call
    # recorder).
    def recorded_probe_files
      {
        "base.rb" => <<~RUBY,
          class Base
            def greet = "hi"
            def twice(n) = n * 2
          end
        RUBY
        "child.rb" => <<~RUBY,
          class Child < Base
            include Comparable
            extend Forwardable

            def run
              greet.upcase
              missing_helper
            end

            def again = [twice(1), twice(1), Base.new.twice(1, 2)]
          end
          Child.new.run
          Child.new.again
        RUBY
        "hooked.rb" => hooked_probe_file
      }
    end

    def hooked_probe_file
      <<~RUBY
        module Mixer
          def self.extended(base)
            base.include(Comparable)
          end
        end

        class Hooked < Base
          extend Mixer
          def run = greet
        end
        Hooked.new.run
      RUBY
    end

    # The journal records as `[kind, slot name]` pairs.
    def journaled(records)
      records.each_slice(4).map { |kind, slot, _key, _value| [kind, described_class.slots[slot].name] }.uniq
    end

    it "reaches each slot only through its kind's API, with every installed Frame value frozen" do
      audited = audited_run.fetch(:state)

      expect(audited.violations).to be_empty
      expect(audited.reached).to include(
        :return_sink, :provisional_returns, :next_sink, :break_sink, :break_value_sink, :retry_frames,
        :yield_value_type, :forwarded_call_arg_types, :threaded_block_body, :user_method_inference_stack,
        :user_method_return_summary, :user_method_summary_consult_depths, :user_method_transient_event_depths,
        :user_method_unroll_fuel, :user_method_return_memo, :inject_accumulator, :class_graph_cache,
        :key_presence_walk, :reflective_ivar_write_repeating, :loop_value_record, :loops_evaluated, :summary_generation,
        :def_node_resolver_run, :definers_index_layers, :definers_index_seed, :definers_index_seed_alt,
        :patched_scanner_guarded_defs, :patched_scanner_def_visibilities,
        :alias_mutation_floor_facts, :alias_mutation_floor_ivar_mutators, :alias_mutation_floor_callee_floors,
        :alias_mutation_floor_unknown_stores, :self_call_ivar_writes_definition_counts, :void_tail_summary,
        :project_method_ownership, :ivar_contributions_table, :constructed_class, :own_method_subclasses,
        :toplevel_def_reliable, :construction_escape, :remover_narrowing_unsafe,
        :user_class_fallback_external_ancestor, :rbs_complete_member_names, :mixin_ancestor_dispatch,
        :core_stdlib_ancestor_dispatch, :project_method_names, :toplevel_definition_rows, :method_alias_names,
        :deferred_definition_names, :resolution_chain, :ancestor_constant_scopes,
        :check_rules_private_singleton_names, :file_digest_run, :scope_index_unentered_evaluator,
        :scope_index_declared_names, :acceptance_unread_shape_refused
      )
    end

    # Each run-scoped slot a run reached declares `run_scoped: true`, so the run's release empties it: a finished run
    # keeps none of its scopes, bodies or tables alive.
    #
    # The Memos that are not run-scoped hold no run's tables: a file's declared names live as long as the parse they are
    # keyed on, and the resolution chain's interned keys are built from names alone.
    it "leaves no value in a slot the run reached once the run has ended" do
      audited = audited_run.fetch(:state)
      kept = %i[scope_index_declared_names resolution_chain_extend_hook_keys resolution_chain_hook_keys
                resolution_chain_external_keys]

      expect(audited.holding - kept).to be_empty
    end

    it "touches each jump sink and the retry frames as it records into them, and rewrites the walk at each guard" do
      accesses = audited_run.fetch(:state).accesses

      expect(accesses.keys).to include(
        %i[return_sink touch], %i[next_sink touch], %i[break_sink touch], %i[break_value_sink touch],
        %i[retry_frames touch], %i[key_presence_walk rewrite]
      )
    end

    # A `begin` rewrites the `break`s it recorded itself: `restoring_error_info` and `carry_jumps_through_ensure` touch
    # the break sink as well as the `break` that records into it.
    it "touches the break sink where a begin rewrites the breaks it recorded" do
      expect(audited_run.fetch(:state).touchers[:break_sink])
        .to include("eval_break", "restoring_error_info", "carry_jumps_through_ensure")
    end

    it "journals each Table's reads and stores while a capture is open, refusing the capture" do
      run = audited_run

      expect(run.fetch(:refused)).to be(true)
      expect(journaled(run.fetch(:records))).to include(
        %i[read inject_accumulator], %i[write inject_accumulator], %i[read user_method_return_memo],
        %i[write user_method_return_memo], %i[read loop_value_record], %i[write loop_value_record],
        %i[read dynamic_origins], %i[write dynamic_origins]
      )
    end

    # Review of #2804 — each recorder's contents are a Resource in stage 1, so a record into them refuses the capture.
    it "touches each recorder's contents as a recording, effects and tracing run records into them" do
      run = audited_recording_run
      audited = run.fetch(:state)

      expect(audited.violations).to be_empty
      expect(run.fetch(:refused)).to be(true)
      touchers = audited.touchers
      expect(touchers[:dependency_recorder]).to include("record_for")
      expect(touchers[:dependency_capture_stack]).to include("capture", "withhold")
      expect(touchers[:effects_collector]).to include("record_root")
      expect(touchers[:flow_tracer]).to include("recording")
    end

    # ADR-129 stage 2 — the effects call-site decisions and the self-call misses are bound Tables: journaled, not
    # touched.
    it "journals the effects and self-call records as bound Tables rather than touching them" do
      run = audited_recording_run
      audited = run.fetch(:state)

      expect(audited.violations).to be_empty
      expect(audited.touchers[:effects_collector]).not_to include("record_call", "record_unresolved")
      expect(audited.touchers).not_to have_key(:self_call_resolution_recorder)
      expect(journaled(run.fetch(:records))).to include(
        %i[read effects_calls], %i[write effects_calls], %i[read self_call_misses], %i[write self_call_misses]
      )
    end

    # ADR-129 stage 2 — the ADR-46 dependency reads are a bound Table: every event path journals its filings and none
    # touches. The recorder's only touch left is a nested window's suspension; the capture stack is read exempt and
    # changed only by a push, a pop or a write-and-rewrite, each under a fresh id.
    it "journals the dependency reads and reaches the capture stack only by exempt reads and fresh-id changes" do
      run = audited_recording_run
      audited = run.fetch(:state)
      event_paths = %w[read_site read_name read_keys file_chain_once note_captured replay tee_read tee_missing]

      expect(audited.violations).to be_empty
      expect(audited.touchers[:dependency_recorder].to_a).to eq(["record_for"])
      expect(audited.touchers[:dependency_capture_stack].to_a).to contain_exactly("capture", "withhold")
      expect(audited.touchers.values.flat_map(&:to_a) & event_paths).to be_empty
      expect(audited.accesses.keys.filter_map { |name, access| access if name == :dependency_capture_stack })
        .to contain_exactly(:read, :push, :pop, :write, :rewrite, :touch)
      expect(journaled(run.fetch(:records))).to include(%i[read dependency_reads], %i[write dependency_reads])
    end

    # The memos only a recording run fills: the user-class fallback's name table, the recording run's ancestor scopes
    # and the resolution chain's interned negative keys (an external mixin's, and an `extended` hook's).
    it "reaches the memos a dependency-recording run fills" do
      audited = audited_recording_run.fetch(:state)

      expect(audited.violations).to be_empty
      expect(audited.reached).to include(
        :user_class_fallback_defines_name, :recorded_ancestor_constant_scopes, :resolution_chain_hook_keys,
        :resolution_chain_external_keys, :resolution_chain_extend_hook_keys
      )
    end

    it "leaves no value in a run-scoped slot a dependency-recording run reached once it has ended" do
      audited = audited_recording_run.fetch(:state)
      kept = %i[scope_index_declared_names resolution_chain_extend_hook_keys resolution_chain_hook_keys
                resolution_chain_external_keys]

      expect(audited.holding - kept).to be_empty
    end

    # WD3: a return-memo hit neither reads nor writes the ADR-55 summaries; only a compute takes them.
    it "takes the ADR-55 summaries once per return-memo compute and never on a hit" do
      run = audited_run
      counts = run.fetch(:counts)
      hits = counts.fetch(Rigor::Inference::BudgetTrace::MEMO_HITS)

      expect(hits).to be_positive
      expect(run.fetch(:state).accesses[%i[user_method_return_summary acquire]])
        .to eq(counts.fetch(Rigor::Inference::BudgetTrace::MEMO_ENTRIES) - hits)
    end
  end

  # Review of #2804 — each recorder a process switch installs is restored on the way out, and the slot holds it inside.
  it "restores the effects, self-call, dependency and tracer frames on the way out" do
    inside = {}
    Rigor::Effects::Collector.collect_for("probe.rb") { inside[:effects_collector] = typing_slot(:effects_collector) }
    Rigor::Analysis::SelfCallResolutionRecorder.record_for("probe.rb") do
      inside[:self_call_resolution_recorder] = typing_slot(:self_call_resolution_recorder)
    end
    Rigor::Analysis::DependencyRecorder.record_for("probe.rb") do
      inside[:dependency_recorder] = typing_slot(:dependency_recorder)
    end
    Rigor::Inference::FlowTracer.record { inside[:flow_tracer] = typing_slot(:flow_tracer) }

    expect(inside.values).to all(satisfy { |value| !value.nil? })
    expect(inside.keys.map { |name| typing_slot(name) }).to all(be_nil)
  end

  # A run's release must not empty what outlives a run: a file's declared names live as long as the parse they are keyed
  # on, and the interned negative keys are rebuilt from a name alone.
  it "keeps the declared-names and interned-key memos out of the run release" do
    kept = %i[scope_index_declared_names resolution_chain_extend_hook_keys resolution_chain_hook_keys
              resolution_chain_external_keys]

    expect(kept.map { |name| described_class.slot(name).run_scoped }).to all(be(false))
    expect(kept.map { |name| described_class.slot(name).kind }).to all(be(:memo))
  end

  # The index walk's evaluation is installed for that walk only; walks nest, so the outer one returns on the way out,
  # a raise included.
  it "restores the outer index walk's unentered evaluator on the way out of an inner one" do
    indexer = Rigor::Inference::ScopeIndexer
    outer = -> {}
    inner = -> {}
    seen = []
    indexer.send(:with_unentered_evaluator, outer) do
      seen << typing_slot(:scope_index_unentered_evaluator)
      begin
        indexer.send(:with_unentered_evaluator, inner) do
          seen << typing_slot(:scope_index_unentered_evaluator)
          raise "boom"
        end
      rescue RuntimeError
        nil
      end
      seen << typing_slot(:scope_index_unentered_evaluator)
    end

    expect(seen).to eq([outer, inner, outer])
    expect(typing_slot(:scope_index_unentered_evaluator)).to be_nil
  end

  # Review of #2796 — a typer or an evaluator caches the state it first reads, so one kept across threads would write
  # into a state whose thread's release has already run. The language server keeps the incremental session across save
  # rounds, each on a thread of its own, so the session's effects evaluator is kept per state.
  it "builds the incremental session's effects evaluator anew under another thread's state" do
    session = Rigor::Analysis::IncrementalSession.allocate
    round = lambda do
      evaluator = session.send(:effects_evaluator)
      [evaluator, session.send(:effects_evaluator), evaluator.send(:typing_state), described_class.current]
    end
    first, again, first_state, first_current = Thread.new(&round).value
    second, _, second_state, = Thread.new(&round).value

    expect(again).to be(first)
    expect(first_state).to be(first_current)
    expect(second).not_to be(first)
    expect(second_state).not_to be(first_state)
  end

  # ADR-129 stage 1, PR 7 — the core root an environment build reads is installed for that build only; builds nest, so
  # the outer one returns on the way out, a raise included.
  it "restores the outer core root on the way out of an inner environment build" do
    loader = Rigor::Environment::RbsLoader
    seen = []
    loader.with_core_root("/outer") do
      seen << typing_slot(:rbs_core_root)
      begin
        loader.with_core_root("/inner") do
          seen << typing_slot(:rbs_core_root)
          raise "boom"
        end
      rescue RuntimeError
        nil
      end
      seen << typing_slot(:rbs_core_root)
    end

    expect(seen).to eq(["/outer", "/inner", "/outer"])
    expect(typing_slot(:rbs_core_root)).to be_nil
  end

  # The refused kind of unread shape is installed for one block: inside it a tuple against an unknown-arity `Array`
  # answers `no`, outside it `maybe`; nested blocks restore the outer kind, a raise included.
  it "refuses unread shapes only inside the block, and restores the outer kind on the way out" do
    acceptance = Rigor::Inference::Acceptance
    int = Rigor::Type::Combinator.nominal_of(Integer)
    pair = Rigor::Type::Combinator.tuple_of(int, int)
    array = Rigor::Type::Combinator.nominal_of(Array, type_args: [int])
    asked = -> { acceptance.accepts(pair, array, mode: :gradual) }
    seen = []
    answers = [asked.call.maybe?]
    acceptance.refusing_unread_arrays do
      seen << typing_slot(:acceptance_unread_shape_refused)
      answers << asked.call.no?
      begin
        acceptance.send(:refusing_unread, :all) do
          seen << typing_slot(:acceptance_unread_shape_refused)
          raise "boom"
        end
      rescue RuntimeError
        nil
      end
      seen << typing_slot(:acceptance_unread_shape_refused)
      answers << asked.call.no?
    end
    answers << asked.call.maybe?

    expect(seen).to eq(%i[array all array])
    expect(answers).to all(be(true))
    expect(typing_slot(:acceptance_unread_shape_refused)).to be_nil
  end
end
