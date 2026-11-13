# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/analysis/incremental_session"
require "rigor/plugin/base"

# Issue #3187 fixture — `Cfg.get(k)` types to the Integer in `policy.txt`, read through the plugin's boundary at every
# call, and a call whose argument is the literal `1` also registers the run-scoped notice `:one`. A call from a def's
# own body sees an untyped parameter, so only a reader that reaches the def under the key `1` registers the notice.
# `incremental_state_fingerprint` keeps the plugin non-opaque (ADR-88 WD1), so a warm recheck can serve a reader.
module Rigor
  module Plugin
    unless defined?(GateProbePolicy)
      class GateProbePolicy < Base
        manifest(id: "gate-probe-policy", version: "0.1.0")

        dynamic_return receivers: ["singleton(Cfg)"], methods: [:get] do |call_node, scope|
          argument = call_node.arguments&.arguments&.first
          one = !argument.nil? && scope.type_of(argument) == Rigor::Type::Combinator.constant_of(1)
          disclose_once(:one, message: "notice: policy read for key 1", severity: :warning) if one
          Rigor::Type::Combinator.constant_of(io_boundary.read_file("policy.txt").strip.to_i)
        end

        def incremental_state_fingerprint
          "static-gate-probe-policy"
        end
      end
    end
  end
end

# A reader the ADR-89 WD2 gate skips reaches the edited def's plugin reads and run-scoped registrations through it,
# exactly as it reaches the def's callees (#3180), yet before #3187 the probe credited it with none. Each example
# drives one in-memory session across the edits and compares every recheck with a cold run of the same tree.
RSpec.describe "IncrementalSession: a gate-skipped reader is credited with the probe's plugin rows (#3187)" do
  around do |example|
    Dir.mktmpdir("rigor-gate-probe-reads-") do |raw|
      # Realpath'd so the plugin's reads stay inside the trusted-read root (`Dir.pwd`; see #959).
      Dir.chdir(File.realpath(raw)) { example.run }
    end
  end

  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def requirer
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::GateProbePolicy)
      true
    end
  end

  def config
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => ["lib"],
                                                                  "plugins" => ["gate-probe-policy"]))
  end

  def cold
    Rigor::Plugin.unregister!
    runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil, plugin_requirer: requirer)
    guarded_run(runner).diagnostics
  end

  def sorted(diagnostics) = diagnostics.map { |d| [d.path, d.line, d.column, d.rule, d.message] }.sort
  def basenames(paths) = paths.map { |path| File.basename(path) }.sort

  def write(files)
    FileUtils.mkdir_p("lib")
    files.each { |name, text| File.write(name.include?("/") ? name : File.join("lib", name), text) }
  end

  def a_v = "class A; def self.v(k) = k == 5 ? k + 1 : k + 2; end\n"
  def cfg = "class Cfg; end\n"
  def w_plain = "class C; def self.w(k) = A.v(k); end\n"
  def w_reads = "class C; def self.w(k) = Cfg.get(k) == 6 ? A.v(k) : 0; end\n"
  # `C.w(2)` registers no notice, so only the plugin read can bring the reader back; `C.w(1)` registers one.
  def reader = "puts 'hit' if C.w(2) == 4\n"
  def noticing_reader = "puts 'hit' if C.w(1) == 3\n"

  # The baseline over `tree` and `policy`, then one recheck per step; each answers as a cold run does.
  def replay(tree, steps)
    write(tree)
    session = Rigor::Analysis::IncrementalSession.new(configuration: config, plugin_requirer: requirer)
    guarded_baseline(session)
    steps.map do |step|
      write(step)
      recheck = guarded_recheck(session)
      expect(sorted(recheck.diagnostics)).to eq(sorted(cold))
      recheck
    end
  end

  def tree(middle) = { "./policy.txt" => "6\n", "a.rb" => a_v, "cfg.rb" => cfg, "c.rb" => middle, "r.rb" => reader }

  # The reader's own answer: `c.rb` reports its own comparison of `Cfg.get(k)` as well.
  def truthy?(recheck)
    recheck.diagnostics.any? { |d| File.basename(d.path) == "r.rb" && d.message.include?("always truthy") }
  end

  def noticed?(recheck) = recheck.diagnostics.map(&:message).include?("notice: policy read for key 1")

  it "re-checks the skipped reader when the file the edited def's plugin call read changes" do
    rechecks = replay(tree(w_plain), [{ "c.rb" => w_reads }, { "./policy.txt" => "7\n" }])
    expect(basenames(rechecks.first.affected)).to eq(["c.rb"]) # the gate passed
    expect(basenames(rechecks.last.affected)).to include("r.rb")
    expect(rechecks.map { |recheck| truthy?(recheck) }).to eq([true, false])
    expect(rechecks.map { |recheck| noticed?(recheck) }).to eq([false, false])
  end

  # The control: a reader whose own analysis made the read is credited with it without the gate.
  it "re-checks the reader when the def called the plugin from the baseline on" do
    rechecks = replay(tree(w_reads), [{ "./policy.txt" => "7\n" }])
    expect(basenames(rechecks.last.affected)).to include("r.rb")
    expect(truthy?(rechecks.last)).to be(false)
  end

  it "replays the notice the edited def's plugin call registers for the skipped reader's key" do
    rechecks = replay(tree(w_plain).merge("r.rb" => noticing_reader), [{ "c.rb" => w_reads }, { "a.rb" => "#{a_v}\n" }])
    expect(basenames(rechecks.first.affected)).to eq(["c.rb"])
    expect(rechecks.map { |recheck| noticed?(recheck) }).to eq([true, true])
  end
end
