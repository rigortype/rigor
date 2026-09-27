# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-116 WD5 — a warm cache must not answer for a run the `RIGOR_SHADOW_RULE_WALK` harness did not check,
# nor replay the harness's divergence rows into a run without it. The run-result cache and the incremental
# snapshot key on the switch; both halves of the harness (the rule walk and the discovery tables) read it.
RSpec.describe Rigor::Analysis::ShadowHarness do
  around do |example|
    saved = ENV.fetch(described_class::ENV_KEY, nil)
    ENV.delete(described_class::ENV_KEY)
    Dir.mktmpdir("rigor-shadow-cache-") do |dir|
      @dir = dir
      File.write(File.join(dir, "c.rb"), "class C\n  def m = (@@x = 1)\nend\n")
      example.run
    end
  ensure
    saved.nil? ? ENV.delete(described_class::ENV_KEY) : ENV.store(described_class::ENV_KEY, saved)
  end

  attr_reader :dir

  # A fresh runner over one persistent store, as a second `rigor check` process would build. A divergence
  # reports as an internal analyzer error, which some examples expect, so the guard's verdict is returned
  # rather than raised.
  def run_check
    configuration = Rigor::Configuration.new("paths" => [dir])
    store = Rigor::Cache::Store.new(root: File.join(dir, ".rigor", "cache"))
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: store)
    result = runner.run([dir])
    crash = begin
      InternalAnalyzerErrorGuard.check!(result, context: "shadow harness cache spec")
      nil
    rescue InternalAnalyzerErrorGuard::AnalyzerCrashed => e
      e
    end
    [result, runner.instance_variable_get(:@run_served_from_cache), crash]
  end

  def shadow_rows(result)
    result.diagnostics.select { |diagnostic| diagnostic.message.include?(described_class::ENV_KEY) }
  end

  # The class_cvars collector forgets every class, so the harness must report the file.
  def diverge!
    forgetful = Class.new(Rigor::Inference::ScopeIndexer::ClassCvarsCollector) do
      def table = {}.freeze
    end
    # Built before the stub: the subclass's `new` is the stubbed one.
    instance = forgetful.new
    allow(Rigor::Inference::ScopeIndexer::ClassCvarsCollector).to receive(:new).and_return(instance)
  end

  it "checks a warm run with the switch on even when a run without it cached the same inputs" do
    cold, _, cold_crash = run_check
    expect([shadow_rows(cold), cold_crash]).to eq([[], nil])

    ENV.store(described_class::ENV_KEY, "1")
    diverge!
    warm, served, warm_crash = run_check
    expect(served).to be(false)
    expect(shadow_rows(warm).map { |row| File.basename(row.path) }).to eq(["c.rb"])
    expect(warm_crash&.message).to include("discovery table `class_cvars`")
  end

  it "does not replay a divergence cached with the switch on into a run without it" do
    ENV.store(described_class::ENV_KEY, "1")
    diverge!
    checked, = run_check
    expect(shadow_rows(checked)).not_to be_empty

    ENV.delete(described_class::ENV_KEY)
    allow(Rigor::Inference::ScopeIndexer::ClassCvarsCollector).to receive(:new).and_call_original
    plain, _, plain_crash = run_check
    expect([shadow_rows(plain), plain_crash]).to eq([[], nil])
  end

  it "keys the run-result cache and the incremental snapshot on the switch, adding nothing when it is off" do
    configuration = Rigor::Configuration.new("paths" => [dir])
    key = lambda do
      Rigor::Analysis::RunCacheKey.descriptor(configuration: configuration, files: ["c.rb"], explain: false,
                                              rbs_config_entries: []).configs.map(&:key)
    end
    fingerprint = -> { Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: [dir]) }

    off_key = key.call
    off_fingerprint = fingerprint.call
    ENV.store(described_class::ENV_KEY, "0")
    expect(key.call - off_key).to eq(["shadow-harness"])
    expect(fingerprint.call).not_to eq(off_fingerprint)
    expect(off_key).not_to include("shadow-harness")
  end
end
