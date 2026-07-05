# frozen_string_literal: true

require "spec_helper"
require "tempfile"

# `Runner#run_source` — in-memory single-source analysis (a clean public entry point for embedders + a faster spec
# path). It must be diagnostic- equivalent to running the same source from a real file on disk.
RSpec.describe "Rigor::Analysis::Runner#run_source" do
  def configuration
    Rigor::Configuration.new("paths" => [])
  end

  def in_memory(source)
    Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
  end

  def from_disk(source)
    Tempfile.create(["probe", ".rb"]) do |file|
      file.write(source)
      file.flush
      return Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
                                    .run([file.path]).diagnostics
    end
  end

  def shapes(diagnostics)
    diagnostics.map { |d| [d.rule, d.line, d.column] }.sort
  end

  # Each source exercises a different analysis path; the in-memory and on-disk runs must agree on every diagnostic's
  # rule + location.
  {
    "same-file self-call resolution" => "class C\n  def run\n    helper\n  end\n  def helper\n    1\n  end\nend\n",
    "explicit-receiver undefined-method" => "x = 1\nx.no_such_method\n",
    "early-return nil narrowing" => "def f(a)\n  return if a.nil?\n  a.upcase\nend\n",
    "possible-nil receiver" => "def g(s)\n  v = s ? \"a\" : nil\n  v.upcase\nend\n",
    "clean code" => "class A\n  def x\n    1\n  end\nend\n"
  }.each do |label, source|
    it "matches an on-disk run for #{label}" do
      expect(shapes(in_memory(source))).to eq(shapes(from_disk(source)))
    end
  end

  it "carries the supplied logical path into diagnostic locations" do
    diagnostics = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
                                         .run_source(source: "x = 1\nx.nope\n", path: "buffer.rb")
                                         .diagnostics
    expect(diagnostics).not_to be_empty
    # Per-file diagnostics carry the logical path; the only other path is the run-level config-info stream
    # (`.rigor.yml`). No tmp/disk path.
    file_paths = diagnostics.map(&:path).reject { |p| p == ".rigor.yml" }.uniq
    expect(file_paths).to eq(["buffer.rb"])
  end

  it "reports parse errors without touching disk" do
    diagnostics = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
                                         .run_source(source: "def broken(\n", path: "bad.rb")
                                         .diagnostics
    expect(diagnostics).not_to be_empty
  end
end
