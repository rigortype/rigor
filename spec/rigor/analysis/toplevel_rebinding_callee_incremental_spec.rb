# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #1817 — `call.unresolved-toplevel` declines inside a block whose project callee may rebind `self`, which
# it learns by reading the callee's body in another file. A warm `--incremental` run must re-check the caller when
# that body starts or stops rebinding, and when a file starts or stops defining a same-named callee; replaying the
# earlier result is stale in both directions.
#
# The oracle is a cold, cache-less run of the same tree; the driver is a fresh `IncrementalSession` per process,
# as in `toplevel_include_incremental_spec.rb`.
RSpec.describe "call.unresolved-toplevel in a rebinding callee's block — incremental re-check (#1817)" do
  def rows(list)
    list.select { |d| d.qualified_rule == "call.unresolved-toplevel" }.map { |d| [File.basename(d.path), d.line] }.sort
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

  it "re-checks the caller when the callee's body changes and when a same-named callee appears or goes" do
    Dir.mktmpdir do |tmp|
      lib = File.join(tmp, "lib")
      Dir.mkdir(lib)
      ext = File.join(lib, "ext.rb")
      other = File.join(lib, "other.rb")
      File.write(ext, "module Ext\n  def self.define = yield\nend\n")
      File.write(File.join(lib, "use.rb"), "Ext.define { helper }\n")
      config = Rigor::Configuration.new("paths" => [lib])
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(tmp, ".cache"))
      fires = [["use.rb", 1]]

      expect(process_run(config, [lib], snapshot)).to eq(fires)

      File.write(ext, "module Ext\n  def self.define(&blk) = module_eval(&blk)\nend\n")
      expect(cold_run(config)).to eq([])
      expect(process_run(config, [lib], snapshot)).to eq([])

      File.write(ext, "module Ext\n  def self.define = yield\nend\n")
      expect(cold_run(config)).to eq(fires)
      expect(process_run(config, [lib], snapshot)).to eq(fires)

      File.write(other, "class Other\n  def define(&blk) = instance_exec(&blk)\nend\n")
      expect(cold_run(config)).to eq([])
      expect(process_run(config, [lib], snapshot)).to eq([])

      File.delete(other)
      expect(process_run(config, [lib], snapshot)).to eq(fires)
    end
  end
end
