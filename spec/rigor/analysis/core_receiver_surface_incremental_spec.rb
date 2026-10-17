# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #1722 — a file that adds a `method_missing` to a core class or an RBS ancestor, mixes a module into one
# from outside its body, or declares a subclass that defines the method silences `call.undefined-method` in an
# unchanged caller. A warm `--incremental` run must re-check that caller when the file appears and when it goes.
#
# The oracle is a cold, cache-less run of the same tree; the driver is a fresh `IncrementalSession` per process, as
# in `toplevel_include_incremental_spec.rb`.
RSpec.describe "core-receiver surface across files — incremental re-check (#1722)" do
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

  {
    "a method_missing on Integer" => ["1.zzz\n(gets ? 1 : 2).zzz\n",
                                      "class Integer\n  def method_missing(*) = 1\nend\n"],
    "Integer.include(Ext)" => ["module Ext\n  def zzz = 1\nend\n1.zzz\n(gets ? 1 : 2).zzz\n", "Integer.include(Ext)\n"],
    "Comparable.include(Ext)" => ["module Ext\n  def zzz = 1\nend\n1.zzz\n\"a\".zzz\n", "Comparable.include(Ext)\n"],
    "a String subclass defining the method" => ["Box.new.make.zzz\nBox.new.make.zzz\n",
                                                "class MyStr < String\n  def zzz = 1\nend\n"]
  }.each do |title, (caller_source, added_source)|
    it "re-checks an unchanged caller when #{title} is added and removed" do
      Dir.mktmpdir do |tmp|
        lib = File.join(tmp, "lib")
        sig = File.join(tmp, "sig")
        Dir.mkdir(lib)
        Dir.mkdir(sig)
        File.write(File.join(sig, "box.rbs"), "class Box\n  def make: () -> String\nend\n")
        File.write(File.join(lib, "box.rb"), "class Box\n  def make = String.new\nend\n")
        File.write(File.join(lib, "a.rb"), caller_source)
        added = File.join(lib, "added.rb")
        config = Rigor::Configuration.new("paths" => [lib], "signature_paths" => [sig])
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(tmp, ".cache"))
        lines = caller_source.lines.each_index.filter_map do |index|
          ["a.rb", index + 1] if caller_source.lines[index].include?(".zzz")
        end

        expect(process_run(config, [lib], snapshot)).to eq(lines)

        File.write(added, added_source)
        expect(cold_run(config)).to eq([])
        expect(process_run(config, [lib], snapshot)).to eq([])

        File.delete(added)
        expect(cold_run(config)).to eq(lines)
        expect(process_run(config, [lib], snapshot)).to eq(lines)
      end
    end
  end
end
