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
  # process loaded. Returns `[exitstatus, engine_feature_count, stdout]`. Pass `baseline: true` to run without
  # `--no-baseline`, letting the config's `baseline:` key apply.
  def check_run(*extra_args, baseline: false)
    preload = File.join(dir, "loaded_features_probe.rb")
    marker = File.join(dir, "engine_features.txt")
    File.write(preload, <<~RUBY)
      at_exit do
        engine = $LOADED_FEATURES.grep(%r{/rigor/inference/}) +
                 $LOADED_FEATURES.grep(%r{/rigor/(analysis/runner|environment|scope)\\.rb\\z})
        File.write(#{marker.inspect}, engine.size.to_s)
      end
    RUBY

    baseline_args = baseline ? [] : ["--no-baseline"]
    cmd = ["bundle", "exec", "ruby", "-r", preload, exe,
           "check", "--no-ci-detect", "--no-stats", *baseline_args, *extra_args, "lib"]
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

  it "serves a warm HIT engine-free with an active baseline (the onboarding second-run sequence)" do
    write_project
    File.write(File.join(dir, ".rigor.yml"),
               "severity_profile: balanced\nbaseline: .rigor-baseline.yml\n")

    # The exact post-onboarding sequence: prime the run cache, generate + wire a baseline, run again normally.
    check_run(baseline: true) # cold miss primes the cache
    _stdout, _stderr, status = Open3.capture3("bundle", "exec", "ruby", exe, "baseline", "generate", chdir: dir)
    expect(status.exitstatus).to eq(0)

    hit_status, hit_engine, = check_run(baseline: true)
    expect(hit_status).to eq(0) # regression guard: this crashed with `uninitialized constant Analysis::Baseline`
    expect(hit_engine).to eq(0) # the baseline filter must not drag the engine onto the hit path
  end

  # ADR-103 WD13 / #382 — the effects sidecar is a SEPARATE producer entry, so `analysis.run-diagnostics`
  # still holds a plain diagnostics array whatever a collecting run wrote beside it. Had the summaries ridden
  # inside that entry, this run would have had to load the effects machinery to unpack its own hit.
  it "serves a warm HIT engine-free for a project that opted into effect collection" do
    write_project
    File.write(File.join(dir, ".rigor.yml"), "severity_profile: balanced\neffects: {}\n")

    miss_status, miss_engine, = check_run
    expect(miss_status).to eq(0)
    expect(miss_engine).to be > 0

    hit_status, hit_engine, = check_run
    expect(hit_status).to eq(0)
    expect(hit_engine).to eq(0)
  end

  # #428 — the other half of the sentence above. `effect.envelope-exceeded` and its two siblings are
  # recomputed every run from the effect table and never stored (ADR-103 WD12), so they are exactly what
  # `analysis.run-diagnostics` does NOT carry; serving that slot verbatim dropped them on every warm run.
  # A project that DECLARED an envelope therefore has to fall through to the full path — which is the one
  # that can re-judge — and the cost of knowing that is one glob, off the declarations alone.
  it "declines the probe (loads the engine) once the project declares an effect envelope" do
    write_project
    File.write(File.join(dir, ".rigor.yml"),
               "severity_profile: balanced\neffects:\n  envelopes:\n    " \
               "- match: \"lib/**/*.rb\"\n      effect: []\n")

    miss_status, miss_engine, = check_run
    expect(miss_status).to eq(0)
    expect(miss_engine).to be > 0

    _hit_status, hit_engine, = check_run
    expect(hit_engine).to be > 0
  end

  # The pass the probe reproduces rather than declines for. `effect.annotations-unchecked` was built to be
  # free — a glob and a regex over the project's own signature tree — so a hit can run it for itself, and
  # this example is what pins that it stays engine-free while doing so.
  it "reproduces effect.annotations-unchecked on an engine-free HIT" do
    write_project
    FileUtils.mkdir_p(File.join(dir, "sig"))
    File.write(File.join(dir, "sig", "widget.rbs"),
               "class Widget\n  %a{pure}\n  def price: () -> Integer\nend\n")

    check_run # cold miss primes the cache

    hit_status, hit_engine, hit_stdout = check_run
    expect(hit_status).to eq(0)
    expect(hit_engine).to eq(0)
    expect(hit_stdout).to include("effect collection never runs")
  end

  it "declines the probe (loads the engine) for --no-cache" do
    write_project
    check_run # prime

    status, engine, = check_run("--no-cache")
    expect(status).to eq(0)
    expect(engine).to be > 0 # --no-cache is not probe-eligible, so the full path runs
  end
end
