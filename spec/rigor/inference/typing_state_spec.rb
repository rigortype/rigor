# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# ADR-129 stage 1 — the typing state's four kinds, its state id (WD2) and its journal (WD3). No `type_of` memo exists
# yet, so these examples drive a bare {Rigor::Inference::TypingState::State}; the last group audits a real run's use of
# the declared slots.
RSpec.describe Rigor::Inference::TypingState do
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

      expect(slots.select(&:run_scoped).map(&:kind).uniq - %i[table memo]).to be_empty
      expect(slots.select(&:read_through).map(&:kind).uniq).to eq([:table])
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
      expect { described_class.frame(:typing_state_spec_probe, reason: "x", contents: :table) }
        .to raise_error(ArgumentError, /contents/)
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
  # is frozen while installed unless the frame declares its contents a Resource. An audited state stands in for the
  # thread's own, so every typer and evaluator of the run caches it.
  describe "a real run's slot accesses" do
    let(:audited_class) do
      Class.new(described_class::State) do
        attr_reader :violations, :reached

        def initialize
          super
          @violations = []
          @reached = Set.new
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
          check(slot, :touch) { |s| s.kind == :resource || s.contents }
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
            check(slot, name) { |s| s.kind == :table }
            super(slot, key, value)
          end
        end

        private

        def check(slot, access)
          declared = Rigor::Inference::TypingState.slots[slot]
          @reached << declared.name
          @violations << [declared.name, access] unless yield(declared)
        end

        def check_install(slot, value)
          check(slot, :install) { |s| s.kind == :frame }
          declared = Rigor::Inference::TypingState.slots[slot]
          @violations << [declared.name, :unfrozen, value.class] unless declared.contents || value.frozen?
        end
      end
    end

    let(:source) do
      <<~RUBY
        class Probe
          MAP = { a: 1, b: 2 }.freeze

          def lookup(key) = MAP.key?(key) && MAP[key].succ
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
        end

        probe = Probe.new
        [probe.lookup(:a), probe.fact(5), probe.even?(4), probe.first_even([1, 2]), probe.nexts([nil, 1]),
         probe.breaks([1]), probe.value_break([nil, 2]), probe.total, probe.forward(1), probe.use_yield,
         probe.retrying, probe.ensure_jump([1])]
      RUBY
    end

    def audited_run
      audited = audited_class.new
      key = described_class.const_get(:STATE_KEY)
      previous = Thread.current[key]
      Thread.current[key] = audited
      Dir.mktmpdir do |dir|
        path = File.join(dir, "probe.rb")
        File.write(path, source)
        configuration = Rigor::Configuration.new("paths" => [path], "parallel" => { "workers" => 0 })
        guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), [path])
      end
      audited
    ensure
      Thread.current[key] = previous
    end

    it "reaches each slot only through its kind's API, with every installed Frame value frozen" do
      audited = audited_run

      expect(audited.violations).to be_empty
      expect(audited.reached).to include(
        :return_sink, :provisional_returns, :next_sink, :break_sink, :break_value_sink, :retry_frames,
        :yield_value_type, :forwarded_call_arg_types, :threaded_block_body, :user_method_inference_stack,
        :user_method_return_summary, :user_method_summary_consult_depths, :user_method_transient_event_depths,
        :user_method_unroll_fuel, :user_method_return_memo, :inject_accumulator, :class_graph_cache,
        :key_presence_walk
      )
    end
  end
end
