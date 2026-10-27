# frozen_string_literal: true

# Issue #2412 — `LoopValueRecord` and the inject-accumulator record kept every finished run alive: each is an
# `ObjectSpace::WeakKeyMap` keyed by a node, whose strong value (a scope) reaches the parse tree that holds the key,
# so neither entry was ever collected and every in-process run (`check`, `sig-gen`, a language-server publish) added
# its whole analysis to the heap. Both are run-scoped slots ({Rigor::RunScopedSlots}), emptied when a run ends.
#
# Issue #2399 — about twenty other per-thread memo slots held the last run's discovery tables and environment until
# the next run on the thread replaced them. They are registered too, so a finished run leaves none of them behind.

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/language_server"

RSpec.describe Rigor::RunScopedSlots do
  let(:tmpdir) { Dir.mktmpdir }
  let(:path) do
    full = File.join(tmpdir, "lib/looper.rb")
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, <<~RUBY)
      class Looper
        def first(items)
          found = while items.any?
                    break items.first
                  end
          found.to_s
        end

        def total = [1, 2].inject(0) { |sum, item| sum + item }

        def wrapped = id(first([1]))

        def id(value) = value

        def fill(acc)
          stripes(acc)
          acc
        end

        def stripes(acc) = acc << 1
      end
    RUBY
    full
  end
  let(:configuration) { Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [path])) }

  # The per-thread keys `lib/` names that are deliberately not run-scoped, each with why. A frame slot is one a
  # `with_*`-style block installs and restores on the way out, so it is already empty when the run's frame returns,
  # and clearing it from inside a frame would break that frame.
  let(:not_run_scoped) do
    {
      __rigor_acceptance_unread_hash_refused__: "frame flag, installed and restored around a block",
      __rigor_declared_param_writer_scope__: "frame slot, installed and restored around a block",
      __rigor_dependency_capture_stack__: "frame slot of the ADR-46 dependency recorder",
      __rigor_dependency_recorder__: "frame slot of the ADR-46 dependency recorder",
      __rigor_effects_collector__: "frame slot of the effects collector",
      __rigor_flow_tracer__: "frame slot of the flow tracer",
      __rigor_forwarded_call_arg_types__: "frame slot, installed and restored around a block",
      __rigor_key_presence_guard: "frame slot of KeyPresenceGuard.with_guards",
      __rigor_project_round__: "a Debouncer key in the language server, not a thread-local",
      __rigor_reflective_ivar_write_repeating__: "frame depth counter, restored on the way out",
      __rigor_self_call_resolution_recorder__: "frame slot of the self-call resolution recorder",
      __rigor_threaded_block_body__: "frame flag, installed and restored around a block",
      __rigor_user_method_inference_stack__: "ADR-55 guard stack, popped to empty by each frame",
      __rigor_user_method_return_summary__: "ADR-55 state, cleared when the guard stack drains",
      __rigor_user_method_summary_consult_depths__: "ADR-55 state, cleared when the guard stack drains",
      __rigor_user_method_transient_event_depths__: "ADR-55 state, cleared when the guard stack drains",
      __rigor_user_method_unroll_fuel__: "ADR-55 state, cleared when the guard stack drains",
      __rigor_yield_value_type__: "frame slot, installed and restored around a block",
      rigor_break_sink: "jump sink frame, installed and restored around a loop",
      rigor_break_value_sink: "jump sink frame, installed and restored around a loop",
      rigor_cache_file_digest_memo: "Cache::FileDigest.with_run frame",
      rigor_cache_file_stat_memo: "Cache::FileDigest.with_run frame",
      rigor_cache_recording_instant: "Cache::FileDigest.with_run frame",
      rigor_cache_strict_validation: "Cache::FileDigest.with_run frame",
      rigor_def_node_resolver_memo: "DefNodeResolver.with_run frame",
      rigor_def_visibilities: "per-file scan state, cleared in the scanner's ensure",
      rigor_guarded_defs: "per-file scan state, cleared in the scanner's ensure",
      rigor_io_boundary_attribution: "thread-variable frame, installed and restored around a block",
      rigor_next_sink: "jump sink frame, installed and restored around a block",
      rigor_provisional_returns: "return sink frame, installed and restored around a body",
      rigor_retry_frames: "frame stack of the enclosing `begin` / `retry` edges",
      rigor_return_sink: "return sink frame, installed and restored around a body",
      rigor_run_disclosure_attribution: "thread-variable frame, installed and restored around a block",
      rigor_scope_index_unentered_evaluator: "frame slot, installed and restored around the index walk"
    }
  end

  after do
    FileUtils.remove_entry(tmpdir)
    loop_keys.each { |key| Thread.current[key] = nil }
  end

  def check_run = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), [path])

  def sig_gen_run = Rigor::SigGen::Generator.new(configuration: configuration, paths: [path]).run

  def loop_keys = %i[rigor_loop_value_record __rigor_inject_accumulator__]

  # The keys of `loop_keys` that hold something when the run calls {.release}, so an example reads a slot the run
  # really filled.
  def filled_at_release(keys)
    filled = []
    allow(described_class).to receive(:release).and_wrap_original do |original|
      filled.concat(keys.reject { |key| Thread.current[key].nil? })
      original.call
    end
    filled
  end

  def settled_environments
    4.times { GC.start(full_mark: true, immediate_sweep: true) }
    ObjectSpace.each_object(Rigor::Environment).count
  end

  { "Runner#run" => :check_run, "SigGen::Generator#run" => :sig_gen_run }.each do |entry_point, run|
    context "with #{entry_point}" do
      it "empties the loop-value and inject-accumulator records the run filled" do
        filled = filled_at_release(loop_keys)

        send(run)

        expect(filled).to match_array(loop_keys)
        expect(loop_keys.map { |key| Thread.current[key] }).to all(be_nil)
      end

      it "leaves no environment of its own behind" do
        # An earlier example's run may still be held by a slot nothing has released yet; start from none.
        Thread.current.keys.grep(/rigor/).each { |key| Thread.current[key] = nil }
        before = settled_environments
        send(run)

        expect(settled_environments).to eq(before)
      end

      # A slot a new owner adds is caught here until it is registered: the run fills it and nothing empties it.
      it "leaves every per-thread memo slot empty" do
        send(run)

        holding = Thread.current.keys.grep(/rigor/).reject do |key|
          value = Thread.current[key]
          value.nil? || value == 0 || (value.respond_to?(:empty?) && value.empty?)
        end
        expect(holding).to be_empty
        expect(described_class.keys.map { |key| Thread.current[key] }).to all(be_nil)
      end

      it "retains no more environments after the third run than after the first" do
        send(run)
        after_first = settled_environments
        2.times { send(run) }

        expect(settled_environments).to eq(after_first)
      end
    end
  end

  # A language-server provider types on the main thread outside any run, filling the same slots; one a run released
  # under it refills on its first miss and answers as before.
  it "answers a hover the same after the slots it filled are released" do
    buffer_table = Rigor::LanguageServer::BufferTable.new
    context = Rigor::LanguageServer::ProjectContext.new(configuration: Rigor::Configuration.new("paths" => []))
    provider = Rigor::LanguageServer::HoverProvider.new(buffer_table: buffer_table, project_context: context)
    uri = "file://#{tmpdir}/hover.rb"
    buffer_table.open(uri: uri, bytes: <<~RUBY, version: 1)
      class Greeter
        def name = [1, 2].map(&:to_s).first
        def greet = name
      end
      Greeter.new.greet
    RUBY
    hover = -> { provider.provide(uri: uri, line: 4, character: 12)&.dig(:contents, :value) }

    described_class.release
    first = hover.call
    filled = described_class.keys.reject { |key| Thread.current[key].nil? }
    described_class.release

    expect(filled).not_to be_empty
    expect(first).to include(%(type:   "1"))
    expect(hover.call).to eq(first)
  end

  it "empties the slots when the incremental session's return-type probe ends" do
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    allow(runner).to receive(:evaluate_return_types_setup) do
      loop_keys.each { |key| Thread.current[key] = :filled }
      {}
    end

    runner.evaluate_return_types([path], [{ class_name: "Looper", method_name: :id, singleton: false }])

    expect(loop_keys.map { |key| Thread.current[key] }).to all(be_nil)
  end

  it "empties the records when a run raises" do
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    allow(runner).to receive(:run_analysis) do
      loop_keys.each { |key| Thread.current[key] = :filled }
      raise "boom"
    end

    expect { guarded_run(runner, [path]) }.to raise_error(RuntimeError, "boom")
    expect(loop_keys.map { |key| Thread.current[key] }).to all(be_nil)
  end

  it "empties the records when a sig-gen run raises" do
    generator = Rigor::SigGen::Generator.new(configuration: configuration, paths: [path])
    allow(generator).to receive(:analyse_file) do
      loop_keys.each { |key| Thread.current[key] = :filled }
      raise "boom"
    end

    expect { generator.run }.to raise_error(RuntimeError, "boom")
    expect(loop_keys.map { |key| Thread.current[key] }).to all(be_nil)
  end

  # Every per-thread key `lib/` names: a `rigor` symbol read through `Thread.current[...]` or
  # `thread_variable_get` / `_set`, directly or through a constant, and every `*_KEY` / `*MEMO*` constant holding
  # one (a key passed on through a variable, as the RBS ancestor-dispatch memos are).
  def thread_keys_in_lib
    lib = File.expand_path("../../lib", __dir__)
    Dir[File.join(lib, "**/*.rb")].each_with_object({}) do |path, keys|
      source = File.read(path)
      constants = {}
      source.scan(/^\s*([A-Z][A-Z0-9_]*) = (?:RunScopedSlots\.register\()?:([a-z_]*rigor[a-z_]*)\)?$/) do |name, sym|
        constants[name] = sym
        keys[sym.to_sym] = path if name.end_with?("_KEY") || name.include?("MEMO")
      end
      access = /Thread\.current(?:\[|\.thread_variable_[gs]et\()\s*([A-Z][A-Z0-9_]*|:[a-z_]*rigor[a-z_]*)/
      source.scan(access).flatten.each do |used|
        sym = used.start_with?(":") ? used.delete_prefix(":") : constants[used]
        keys[sym.to_sym] = path if sym
      end
    end
  end

  # A memo slot a new owner adds is caught here even when no fixture fills it.
  it "registers every per-thread key in lib/ that is not a listed frame slot" do
    keys = thread_keys_in_lib

    unlisted = keys.keys - described_class.keys - not_run_scoped.keys
    expect(unlisted.to_h { |key| [key, keys[key]] }).to be_empty
    expect(described_class.keys - keys.keys).to be_empty
    expect(not_run_scoped.keys - keys.keys).to be_empty
    expect(not_run_scoped.keys & described_class.keys).to be_empty
  end

  it "registers a key once and hands it back" do
    registered = described_class.instance_variable_get(:@keys)
    described_class.instance_variable_set(:@keys, registered.dup)

    expect(2.times.map { described_class.register(:rigor_run_scoped_slots_probe) })
      .to eq(%i[rigor_run_scoped_slots_probe rigor_run_scoped_slots_probe])
    expect(described_class.keys.count(:rigor_run_scoped_slots_probe)).to eq(1)
  ensure
    described_class.instance_variable_set(:@keys, registered)
  end
end
