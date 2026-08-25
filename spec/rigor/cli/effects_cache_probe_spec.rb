# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

# ADR-104 — the boot-slimming probe for the effects surfaces. The load-bearing assertions run in a real
# SUBPROCESS, because the claim is about `$LOADED_FEATURES`: a warm `rigor effects` / `rigor effects check`
# must reach its answer without loading the analysis engine.
#
# Two counters, because `lib/rigor/inference/` is not all engine. `Effects::Catalog` requires
# `inference/mutation_widening` (and `Reflection` / `Type::Combinator` the HKT trio) as shared VALUE-layer
# vocabulary, so a handful of files under that directory load on any path that can name an effect label at
# all. The engine proper is what `analysis/runner`, `environment` and `scope` head, and a served run must
# load **none** of those; the directory count is asserted as an order-of-magnitude drop against the
# analysing control rather than as zero, which is the honest form of the claim.
#
# Every decline assertion here is paired with a must-still-answer one, and every engine-free assertion with
# a control run that DOES load the engine — a probe that always declined, and a fixture that never loaded
# the engine either way, would each satisfy half this file on their own.
RSpec.describe "ADR-104 effects cache probe (subprocess)" do
  let(:exe) { File.join(File.expand_path("../../..", __dir__), "exe", "rigor") }

  # The value-layer residue described above, with room for a require or two: an engine load is ~90 files,
  # so nothing near this bound can be one.
  let(:value_layer_budget) { 15 }

  around do |example|
    Dir.mktmpdir("rigor-effects-probe-spec-") do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  # Runs `rigor <argv>` in a child process with a preload that records, at exit, what it loaded:
  # `engine` counts the analysis engine's entry points, `inference` everything under `inference/`.
  def rigor_run(*argv)
    preload = File.join(dir, "loaded_features_probe.rb")
    marker = File.join(dir, "engine_features.txt")
    File.write(preload, <<~RUBY)
      at_exit do
        engine = $LOADED_FEATURES.grep(%r{/rigor/(analysis/runner|environment|scope)\\.rb\\z})
        inference = $LOADED_FEATURES.grep(%r{/rigor/inference/})
        File.write(#{marker.inspect}, [engine.size, inference.size].join(" "))
      end
    RUBY

    stdout, _stderr, status = Open3.capture3("bundle", "exec", "ruby", "-r", preload, exe, *argv, chdir: dir)
    engine, inference = File.read(marker).split.map(&:to_i)
    { status: status.exitstatus, engine: engine, inference: inference, stdout: stdout }
  end

  def write_project(config: "effects: {}\n")
    lib = File.join(dir, "lib")
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, "a.rb"), <<~RUBY)
      class Reporter
        def report
          puts(Time.now.to_s)
        end
      end
    RUBY
    File.write(File.join(lib, "b.rb"), <<~RUBY)
      class Caller
        def go
          Reporter.new.report
        end
      end
    RUBY
    File.write(File.join(dir, ".rigor.yml"), "paths:\n  - lib\n#{config}")
  end

  it "serves a warm `rigor effects` engine-free, with the same report the analysing run printed" do
    write_project

    cold = rigor_run("effects")
    expect(cold.fetch(:status)).to eq(0)
    expect(cold.fetch(:engine)).to be > 0
    expect(cold.fetch(:stdout)).to include("Reporter#report")

    warm = rigor_run("effects")
    expect(warm.fetch(:status)).to eq(0)
    expect(warm.fetch(:engine)).to eq(0)
    expect(warm.fetch(:inference)).to be <= value_layer_budget
    expect(warm.fetch(:inference)).to be < cold.fetch(:inference) / 5
    expect(warm.fetch(:stdout)).to eq(cold.fetch(:stdout))
  end

  # The transitive lane is what a stored table carries and a re-derivation would have to re-propagate:
  # `Caller#go` earns its labels only through the edge to `Reporter#report`.
  it "serves the propagated lane, not just the direct summaries" do
    write_project

    cold = rigor_run("effects", "--label", "io.output.stdout")
    warm = rigor_run("effects", "--label", "io.output.stdout")

    expect(warm.fetch(:engine)).to eq(0)
    expect(warm.fetch(:stdout)).to eq(cold.fetch(:stdout))
    expect(warm.fetch(:stdout)).to include("Caller#go")
  end

  it "serves a warm `rigor effects check` engine-free, and still gates on real drift" do
    write_project
    rigor_run("effects", "update")

    fresh = rigor_run("effects", "check")
    expect(fresh.fetch(:status)).to eq(0)
    expect(fresh.fetch(:engine)).to eq(0)
    expect(fresh.fetch(:inference)).to be <= value_layer_budget

    # The must-still-fire half: an edit that moves a summary re-analyses (the entry's dependency
    # descriptor names the file) and the gate exits 1.
    File.write(File.join(dir, "lib", "a.rb"), <<~RUBY)
      class Reporter
        def report
          File.write("out.txt", Time.now.to_s)
        end
      end
    RUBY
    drift = rigor_run("effects", "check")
    expect(drift.fetch(:status)).to eq(1)
    expect(drift.fetch(:engine)).to be > 0
  end

  it "declines when the `effects:` policy changed, so a config edit is never served a stale table" do
    write_project
    rigor_run("effects")

    File.write(File.join(dir, ".rigor.yml"),
               "paths:\n  - lib\neffects:\n  tolerated: [\"nondet.time\"]\n")

    expect(rigor_run("effects").fetch(:engine)).to be > 0
  end

  it "declines a scope the primed entry does not cover, because the analysed set keys the entry" do
    write_project
    rigor_run("effects")

    expect(rigor_run("effects", File.join(dir, "lib", "a.rb")).fetch(:engine)).to be > 0
  end
end
