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

  let(:fires) { [["use.rb", 1]] }
  let(:yields) { "module Ext\n  def self.define = yield\nend\n" }
  let(:rebinding_other) { "class Other\n  def define(&blk) = instance_exec(&blk)\nend\n" }

  # Absolute paths, read once the example has moved into its temporary directory.
  let(:lib) { File.join(Dir.pwd, "lib") }
  let(:config) { Rigor::Configuration.new("paths" => [lib]) }
  let(:snapshot) { Rigor::Cache::IncrementalSnapshot.new(root: File.join(Dir.pwd, ".cache")) }

  around do |example|
    Dir.mktmpdir { |tmp| Dir.chdir(tmp) { example.run } }
  end

  before do
    Dir.mkdir(lib)
    File.write(File.join(lib, "ext.rb"), yields)
    File.write(File.join(lib, "use.rb"), "Ext.define { helper }\n")
  end

  def warm = process_run(config, [lib], snapshot)

  it "re-checks the caller when the callee's body starts and stops rebinding" do
    ext = File.join(lib, "ext.rb")
    expect(warm).to eq(fires)

    File.write(ext, "module Ext\n  def self.define(&blk) = module_eval(&blk)\nend\n")
    expect(cold_run(config)).to eq([])
    expect(warm).to eq([])

    File.write(ext, yields)
    expect(cold_run(config)).to eq(fires)
    expect(warm).to eq(fires)
  end

  it "re-checks the caller when another file starts or stops defining a rebinding callee of the same name" do
    other = File.join(lib, "other.rb")
    File.write(other, "class Other\nend\n")
    expect(warm).to eq(fires)

    # Edits of an existing file, then the file's removal.
    File.write(other, rebinding_other)
    expect(cold_run(config)).to eq([])
    expect(warm).to eq([])

    File.write(other, "class Other\nend\n")
    expect(warm).to eq(fires)

    File.write(other, rebinding_other)
    expect(warm).to eq([])
    File.delete(other)
    expect(warm).to eq(fires)
  end

  # Nothing else asks about `each` here (Array's RBS answers the dispatch), so only the rule's own `defines:` edge
  # can bring this caller back.
  it "re-checks a caller whose callee no project file defined until an edit adds a rebinding one" do
    other = File.join(lib, "other.rb")
    File.write(File.join(lib, "use.rb"), "[1].each { helper }\n")
    File.write(other, "class Other\nend\n")
    expect(warm).to eq(fires)

    File.write(other, "class Other\n  def each(&blk) = instance_exec(&blk)\nend\n")
    expect(cold_run(config)).to eq([])
    expect(warm).to eq([])

    File.write(other, "class Other\nend\n")
    expect(warm).to eq(fires)
  end
end
