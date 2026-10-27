# frozen_string_literal: true

# Issue #2412 — `LoopValueRecord` and the inject-accumulator record kept every finished run alive: each is an
# `ObjectSpace::WeakKeyMap` keyed by a node, whose strong value (a scope) reaches the parse tree that holds the key,
# so neither entry was ever collected and every in-process run (`check`, `sig-gen`, a language-server publish) added
# its whole analysis to the heap. Both are run-scoped slots ({Rigor::RunScopedSlots}), emptied when a run ends.

require "spec_helper"
require "fileutils"
require "tmpdir"

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
      end
    RUBY
    full
  end
  let(:configuration) { Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [path])) }

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

      it "retains no more environments after the third run than after the first" do
        send(run)
        after_first = settled_environments
        2.times { send(run) }

        expect(settled_environments).to eq(after_first)
      end
    end
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
