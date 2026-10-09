# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #1697 — a top-level `include` in one file silences `call.unresolved-toplevel` and
# `call.undefined-method` in another. A consumer checked while no top-level `include` existed must be re-checked
# when one appears, changes or goes away; a warm `--incremental` run that replays the earlier result is stale.
#
# The oracle is a cold, cache-less run of the same tree; the driver is a fresh `IncrementalSession` per process,
# as in `pre_eval_incremental_spec.rb`.
RSpec.describe "a top-level include across files — incremental re-check (#1697)" do
  def rows(list)
    list.select { |d| %w[call.unresolved-toplevel call.undefined-method].include?(d.qualified_rule) }
        .map { |d| [File.basename(d.path), d.line] }.sort
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

  it "re-checks a caller when the include is added, switched to an undeclared module, and removed" do
    Dir.mktmpdir do |tmp|
      lib = File.join(tmp, "lib")
      Dir.mkdir(lib)
      File.write(File.join(lib, "helpers.rb"), "module Helpers\n  def helper = 1\nend\n")
      File.write(File.join(lib, "a.rb"), "helper\n\"s\".helper\n")
      setup = File.join(lib, "setup.rb")
      config = Rigor::Configuration.new("paths" => [lib])
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(tmp, ".cache"))
      both = [["a.rb", 1], ["a.rb", 2]]

      expect(process_run(config, [lib], snapshot)).to eq(both)

      File.write(setup, "include Helpers\n")
      expect(cold_run(config)).to eq([])
      expect(process_run(config, [lib], snapshot)).to eq([])

      # An undeclared module silences the bare call only.
      File.write(setup, "include Undeclared::Thing\n")
      expect(cold_run(config)).to eq([["a.rb", 2]])
      expect(process_run(config, [lib], snapshot)).to eq([["a.rb", 2]])

      File.delete(setup)
      expect(process_run(config, [lib], snapshot)).to eq(both)
    end
  end
end
