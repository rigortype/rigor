# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# Issue #2883 — the runner builds the RBS environment before anything types (ADR-129 G1': no `type_of` reads the
# core-root Frame the build installs), except on a warm result-cache hit, which never types and must not pay for it.
RSpec.describe "the runner's RBS environment preparation" do
  let(:store_root) { Dir.mktmpdir("rigor-prepare-store-") }
  let(:project) { Dir.mktmpdir("rigor-prepare-project-") }

  before do
    File.write(File.join(project, "a.rb"), "class A\n  def go = [1, 2].sum\nend\nA.new.go\n")
  end

  after do
    FileUtils.remove_entry(store_root)
    FileUtils.remove_entry(project)
  end

  def run_once
    configuration = Rigor::Configuration.new(
      "paths" => [project], "bundler" => { "auto_detect" => false }, "rbs_collection" => { "auto_detect" => false }
    )
    runner = Rigor::Analysis::Runner.new(configuration: configuration, workers: 0,
                                         cache_store: Rigor::Cache::Store.new(root: store_root))
    Dir.chdir(project) { guarded_run(runner) }
  end

  # The order of `RbsLoader#prepare_for_typing!` calls and `ExpressionTyper#type_of` calls across one run.
  def events_of_run
    events = []
    allow_any_instance_of(Rigor::Environment::RbsLoader).to receive(:prepare_for_typing!).and_wrap_original do |m|
      events << :prepare
      m.call
    end
    allow_any_instance_of(Rigor::Inference::ExpressionTyper).to receive(:type_of).and_wrap_original do |m, *args|
      events << :type_of
      m.call(*args)
    end
    run_once
    events
  end

  it "builds the environment before the first type_of of a cold run" do
    events = events_of_run

    expect(events).to include(:type_of)
    expect(events.index(:prepare)).to be < events.index(:type_of)
  end

  it "builds no environment on a warm result-cache hit" do
    run_once
    prepared = 0
    allow_any_instance_of(Rigor::Environment::RbsLoader).to receive(:prepare_for_typing!).and_wrap_original do |m|
      prepared += 1
      m.call
    end

    run_once

    expect(prepared).to eq(0)
  end
end
