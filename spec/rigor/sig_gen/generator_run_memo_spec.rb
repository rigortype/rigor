# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Issue #2300 — `rigor sig-gen` keeps one user-method return memo for the whole run, as `rigor check` does since
# ADR-84 WD2. Without a run-generation token the memo keyed on each file's merged `discovered_def_nodes`, a new
# table per file, so the bucket was dropped at every file boundary.
RSpec.describe Rigor::SigGen::Generator do
  let(:tmpdir) { Dir.mktmpdir }
  let(:paths) do
    [
      write_fixture("lib/alpha.rb", <<~RUBY),
        class Alpha
          def helper = [1, 2].map(&:to_s)
          def wrapped = helper
        end
      RUBY
      write_fixture("lib/beta.rb", <<~RUBY)
        class Beta
          def helper = { a: 1 }.keys
          def wrapped = helper
        end
      RUBY
    ]
  end

  after { FileUtils.remove_entry(tmpdir) }

  def write_fixture(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  def generator(paths)
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => paths))
    described_class.new(configuration: configuration, paths: paths)
  end

  it "indexes every file of a run under one memo token, and a second run under a fresh one" do
    tokens = []
    allow(Rigor::Inference::ScopeIndexer).to receive(:index).and_wrap_original do |original, root, **kwargs|
      tokens << kwargs.fetch(:default_scope).run_generation
      original.call(root, **kwargs)
    end

    generator(paths).run
    first_run = tokens.dup
    tokens.clear
    generator(paths).run

    expect(first_run.size).to eq(2)
    expect(first_run).to all(be_frozen)
    expect(first_run.uniq(&:object_id).size).to eq(1)
    expect(tokens.uniq(&:object_id).size).to eq(1)
    expect(tokens.first).not_to equal(first_run.first)
  end

  it "keeps the first file's memo entries after the second file is analysed" do
    candidates = generator(paths).run

    memoised = Rigor::Inference::ExpressionTyper.harvest_return_memo.keys.map do |def_node|
      [def_node.name, def_node.location.slice]
    end
    expect(memoised).to contain_exactly(
      [:helper, "def helper = [1, 2].map(&:to_s)"],
      [:helper, "def helper = { a: 1 }.keys"]
    )
    expect(candidates.map { |candidate| [candidate.class_name, candidate.method_name] }).to include(
      ["Alpha", :wrapped], ["Beta", :wrapped]
    )
  end
end
