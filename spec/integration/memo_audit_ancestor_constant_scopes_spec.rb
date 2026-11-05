# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# Issue #2848 / ADR-129 G2 — `Reflection.ancestor_constant_scopes` reads the resolution chain of the analysing file's
# discovery index, whose include order is that file's own view: a class declared in two files, each with an
# `include`, lists the reader's `include` first. The memo keyed on the run generation, so the second file's hit served
# the first file's order, and its audited hit raised a mismatch. Keyed on the discovery index, each file's hit
# recomputes to the value it stored.
RSpec.describe "MemoAudit on the ancestor constant scopes memo (#2848)" do
  around do |example|
    Rigor::Inference::MemoAudit.enable!
    Dir.mktmpdir("rigor-ancestor-scopes-") { |dir| Dir.chdir(dir) { example.run } }
  ensure
    Rigor::Inference::MemoAudit.disable!
  end

  # Each file references core constants inside `C`, so the step-2 ancestor rung runs, and hits, in both files.
  let(:files) do
    {
      "a.rb" => <<~RUBY,
        module M; end
        module A; include M; end
        module Z; end
        class Base; end
        class C < Base
          include A
          def a = [String, Integer]
        end
      RUBY
      "b.rb" => <<~RUBY
        class C
          include Z
          def b = [String, Integer]
        end
      RUBY
    }
  end

  def run_files
    FileUtils.mkdir_p("lib")
    files.each { |name, source| File.write(File.join("lib", name), source) }
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
  end

  it "audits its hits across both files without a mismatch" do
    hits = Hash.new(0)
    allow(Rigor::Inference::MemoAudit).to receive(:check).and_wrap_original do |original, label, *rest, &block|
      hits[label] += 1 unless Rigor::Inference::MemoAudit.suspended?
      original.call(label, *rest, &block)
    end
    expect { run_files }.not_to raise_error
    expect(hits["ancestor constant scopes"]).to be >= 2
  end
end
