# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

# ADR-87 WD4 — the boot-slimming hit probe. The load-bearing assertion is run in a real SUBPROCESS: a warm
# cache HIT must reach its verdict and serve the run's diagnostics WITHOUT the inference engine in
# `$LOADED_FEATURES` (no `rigor/inference` entry, no `rigor/analysis/runner`, no `rigor/environment`). A MISS
# in the same setup DOES load the engine — the control that proves the probe, not the fixture, is what keeps
# the hit engine-free.
RSpec.describe "ADR-87 WD4 run-cache hit probe (subprocess)" do
  let(:exe) { File.join(File.expand_path("../../..", __dir__), "exe", "rigor") }

  around do |example|
    Dir.mktmpdir("rigor-hit-probe-spec-") do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  # Runs `rigor check` in a child process with a preload that records, at exit, how many engine features the
  # process loaded. Returns `[exitstatus, engine_feature_count, stdout]`.
  def check_run(*extra_args)
    preload = File.join(dir, "loaded_features_probe.rb")
    marker = File.join(dir, "engine_features.txt")
    File.write(preload, <<~RUBY)
      at_exit do
        engine = $LOADED_FEATURES.grep(%r{/rigor/inference/}) +
                 $LOADED_FEATURES.grep(%r{/rigor/(analysis/runner|environment|scope)\\.rb\\z})
        File.write(#{marker.inspect}, engine.size.to_s)
      end
    RUBY

    cmd = ["bundle", "exec", "ruby", "-r", preload, exe,
           "check", "--no-ci-detect", "--no-stats", "--no-baseline", *extra_args, "lib"]
    stdout, _stderr, status = Open3.capture3(*cmd, chdir: dir)
    [status.exitstatus, File.read(marker).to_i, stdout]
  end

  def write_project
    lib = File.join(dir, "lib")
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, "a.rb"), "class Widget\n  def price\n    10\n  end\nend\n")
    File.write(File.join(lib, "b.rb"), "class Shop\n  def total\n    Widget.new.price\n  end\nend\n")
    File.write(File.join(dir, ".rigor.yml"), "severity_profile: balanced\n")
  end

  it "serves a warm HIT without loading the inference engine, while a MISS loads it" do
    write_project

    # Cold miss primes the ADR-45 run-result cache AND proves the engine loads when analysis runs.
    miss_status, miss_engine, = check_run
    expect(miss_status).to eq(0)
    expect(miss_engine).to be > 0

    # Warm hit: the probe serves the cached diagnostics with the engine never required.
    hit_status, hit_engine, hit_stdout = check_run
    expect(hit_status).to eq(0)
    expect(hit_engine).to eq(0)
    # The clean fixture produces a clean run, served from cache.
    expect(hit_stdout).to include("No diagnostics")
  end

  it "declines the probe (loads the engine) for --no-cache" do
    write_project
    check_run # prime

    status, engine, = check_run("--no-cache")
    expect(status).to eq(0)
    expect(engine).to be > 0 # --no-cache is not probe-eligible, so the full path runs
  end
end
