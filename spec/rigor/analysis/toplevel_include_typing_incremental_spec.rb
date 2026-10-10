# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #1715 — a bare top-level call typed through a top-level `include` depends on the whole program: on the name
# being defined nowhere, in any spelling, and on the include chain. A consumer typed while nothing else defined the
# name must be re-checked when a definition appears in another file, in a spelling no method table records, and
# again when it goes away; a warm `--incremental` run that replays the earlier result is stale.
#
# The typed call is observable through `call.undefined-method` on its result (`helper.upcase` on an `Integer`).
# The oracle is a cold, cache-less run of the same tree; the driver is a fresh `IncrementalSession` per process,
# as in `toplevel_include_incremental_spec.rb`.
RSpec.describe "typing through a top-level include — incremental re-check (#1715)" do
  def rows(list)
    list.select { |d| d.qualified_rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def cold_run(config)
    rows(guarded_run(Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)).diagnostics)
  end

  def process_run(config, roots, snapshot)
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: roots)
    session = Rigor::Analysis::IncrementalSession.new(configuration: config, paths: roots)
    diagnostics, = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
    rows(diagnostics)
  end

  # A fresh project: the include in `lib/setup.rb`, the typed call in `lib/a.rb`.
  def with_project
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        Dir.mkdir("lib")
        Dir.mkdir("sig")
        File.write("sig/helpers.rbs", "module Helpers\n  def helper: () -> Integer\nend\nmodule Other\nend\n")
        File.write("lib/setup.rb", "include Helpers\n")
        File.write("lib/a.rb", "helper.upcase\n")
        yield Rigor::Configuration.new("paths" => ["lib"]),
              Rigor::Cache::IncrementalSnapshot.new(root: File.join(tmp, ".cache"))
      end
    end
  end

  let(:typed) { [["a.rb", 1]] }

  it "re-checks a typed caller when a same-named definition appears, changes spelling and goes away" do
    with_project do |config, snapshot|
      expect(process_run(config, ["lib"], snapshot)).to eq(typed)

      # Each spelling defines `helper` where no symbol fingerprint sees it but `def` on a class.
      ["class Widget\n  def helper = 1\nend\n", "class Widget\n  attr_reader :helper\nend\n",
       "def self.helper = 1\n", "Object.define_method(:helper) { 1 }\n"].each do |definer|
        File.write("lib/b.rb", definer)
        expect(cold_run(config)).to eq([])
        expect(process_run(config, ["lib"], snapshot)).to eq([])
      end

      File.delete("lib/b.rb")
      expect(cold_run(config)).to eq(typed)
      expect(process_run(config, ["lib"], snapshot)).to eq(typed)
    end
  end

  it "re-checks a typed caller when the include chain changes" do
    with_project do |config, snapshot|
      expect(process_run(config, ["lib"], snapshot)).to eq(typed)

      # An undeclared module beside the include makes the answer ambiguous; removing it restores it.
      File.write("lib/setup.rb", "include Helpers\ninclude Undeclared::Thing\n")
      expect(cold_run(config)).to eq([])
      expect(process_run(config, ["lib"], snapshot)).to eq([])

      File.write("lib/setup.rb", "include Helpers\n")
      expect(process_run(config, ["lib"], snapshot)).to eq(typed)

      File.write("lib/setup.rb", "include Other\n")
      expect(cold_run(config)).to eq([])
      expect(process_run(config, ["lib"], snapshot)).to eq([])
    end
  end
end
