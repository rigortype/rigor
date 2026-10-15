# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"

activejob_lib = File.expand_path("../../../plugins/rigor-activejob/lib", __dir__)
$LOAD_PATH.unshift(activejob_lib) unless $LOAD_PATH.include?(activejob_lib)
require "rigor-activejob"

# Issue #1898 — a recheck serves unchanged files' effect collections to the envelope pass, and a plugin stamps
# its attributions and edges into a collection when the file is collected. rigor-activejob's edges follow
# `config.active_job.queue_adapter`, a file no snapshot digest covers: under `:inline` `perform_later` runs
# `perform` in this process, under `:async` it does not. So switching the adapter has to move what a warm
# recheck reports exactly as it moves a cold run, in both directions.
RSpec.describe "effect.envelope-exceeded across a plugin effect-fact change" do
  def rule = "effect.envelope-exceeded"

  before do
    Rigor::Plugin.unregister!
    Rigor::Plugin.register(Rigor::Plugin::Activejob)
  end

  after { Rigor::Plugin.unregister! }

  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(%w[lib sig config])
        File.write(".rigor.yml", <<~YAML)
          paths:
            - lib
          signature_paths:
            - sig
          plugins:
            - gem: rigor-activejob
              id: activejob
          effects: {}
        YAML
        File.write("lib/welcome_job.rb",
                   "class WelcomeJob < ActiveJob::Base\n  def perform(x)\n    puts x\n  end\nend\n")
        File.write("lib/svc.rb", "class Svc\n  def go\n    WelcomeJob.perform_later(1)\n  end\nend\n")
        File.write("sig/svc.rbs", "class Svc\n  %a{pure} def go: () -> untyped\nend\n")
        adapter("inline")
        example.run
      end
    end
  end

  def adapter(name)
    File.write("config/application.rb",
               "module App\n  class Application\n    config.active_job.queue_adapter = :#{name}\n  end\nend\n")
  end

  def configuration
    Rigor::Configuration.load(".rigor.yml")
  end

  def envelope_rows(diagnostics)
    diagnostics.select { |diagnostic| diagnostic.rule == rule }.map(&:to_h)
  end

  # A fresh session's baseline is the cold answer for the tree as it stands.
  def cold_rows
    envelope_rows(guarded_baseline(Rigor::Analysis::IncrementalSession.new(configuration: configuration)))
  end

  [0, 2].each do |workers|
    it "re-judges a session's served collections when the adapter switches (workers: #{workers})" do
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, workers: workers)
      inline = envelope_rows(guarded_baseline(session))
      expect(inline.size).to eq(1)
      expect(guarded_recheck(session).rebaselined).to be(false)

      adapter("async")
      to_async = guarded_recheck(session)
      expect(to_async.rebaselined).to be(true)
      expect(envelope_rows(to_async.diagnostics)).to eq(cold_rows).and be_empty

      adapter("inline")
      expect(envelope_rows(guarded_recheck(session).diagnostics)).to eq(cold_rows).and eq(inline)
    end
  end

  # A recheck that re-analyses every file serves no collection, so there is nothing to re-baseline; it has to
  # adopt the new digest, or the next null recheck would compare against the old one and re-baseline for nothing.
  it "adopts the new digest from a recheck that served no collection" do
    session = Rigor::Analysis::IncrementalSession.new(configuration: configuration)
    guarded_baseline(session)
    adapter("async")
    %w[lib/welcome_job.rb lib/svc.rb].each { |path| File.write(path, "#{File.read(path)}# edited\n") }

    expect(guarded_recheck(session).rebaselined).to be(false)
    expect(guarded_recheck(session).rebaselined).to be(false)
  end

  # The re-baselined recheck is the run's answer: `run_incremental` reports it cold and does not baseline again.
  it "runs one baseline and reports cold when a restored snapshot's digest moved" do
    snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(Dir.pwd, ".rigor-snapshot"))
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: ["lib"])
    guarded_run_incremental(Rigor::Analysis::IncrementalSession.new(configuration: configuration),
                            snapshot: snapshot, fingerprint: fingerprint)
    adapter("async")
    session = Rigor::Analysis::IncrementalSession.new(configuration: configuration)
    allow(session).to receive(:baseline).and_call_original

    diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)

    expect(warm).to be(false)
    expect(session).to have_received(:baseline).once
    expect(envelope_rows(diagnostics)).to eq(cold_rows).and be_empty
  end

  describe "through rigor check --incremental" do
    def check(*flags)
      out = StringIO.new
      err = StringIO.new
      argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--format", "json", *flags, "lib"]
      Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: err).run
      [JSON.parse(out.string).fetch("diagnostics").select { |row| row["rule"] == rule }, err.string]
    end

    [0, 2].each do |workers|
      it "answers what a --no-cache run answers after each adapter switch (workers: #{workers})" do
        incremental = ["--incremental", "--workers=#{workers}"]
        primed, = check(*incremental)
        _, null_err = check(*incremental)
        adapter("async")
        to_async, async_err = check(*incremental)
        cold_async, = check("--no-cache")
        adapter("inline")
        to_inline, = check(*incremental)

        expect(primed.size).to eq(1)
        expect(null_err).to include("--incremental warm")
        expect(async_err).to include("--incremental cold")
        expect(to_async).to eq(cold_async).and be_empty
        expect(to_inline).to eq(check("--no-cache").first).and eq(primed)
      end
    end
  end
end
