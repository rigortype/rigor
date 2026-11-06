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

  # The calls of `RbsLoader#prepare_for_typing!` and `ExpressionTyper#type_of` made by the block, in order, as
  # `:prepare` and `:type_of`.
  def traced_calls
    events = []
    traces = {
      prepare: Rigor::Environment::RbsLoader.instance_method(:prepare_for_typing!),
      type_of: Rigor::Inference::ExpressionTyper.instance_method(:type_of)
    }.map do |event, method|
      TracePoint.new(:call) { events << event }.tap { |trace| trace.enable(target: method) }
    end
    yield
    events
  ensure
    traces&.each(&:disable)
  end

  def events_of_run = traced_calls { run_once }

  it "builds the environment before the first type_of of a cold run" do
    events = events_of_run

    expect(events).to include(:type_of)
    expect(events.index(:prepare)).to be < events.index(:type_of)
  end

  it "builds no environment on a warm result-cache hit" do
    run_once

    expect(traced_calls { run_once }).to eq([])
  end
end
