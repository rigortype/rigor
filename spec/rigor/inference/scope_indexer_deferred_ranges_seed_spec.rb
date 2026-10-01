# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/inference/scope_indexer"

# Issue #1548 — a seeded deferred-ranges entry is reusable only when the pre-pass walked the same bytes. The
# mutation oracle analyses a mutant at the SAME path under a seed built over the unmutated files, so a reuse
# keyed on the path alone hands the mutant the original's byte offsets.
RSpec.describe Rigor::Inference::ScopeIndexer do
  let(:original) do
    <<~RUBY
      class Greeter
        def hello = 1
      end
    RUBY
  end
  let(:mutant) do
    <<~RUBY
      # a leading line that moves every offset
      class Greeter
        def hello = 1
        def world = 2
      end
    RUBY
  end

  # Deferred ranges over a seeded path.
  def seed_for(path)
    described_class.discovered_project_index_for_paths([path]).fetch(:def_index).fetch(:deferred_ranges)
  end

  def indexed_ranges(source, path, seed)
    base = Rigor::Scope.empty(source_path: path)
    scope = base.with_discovery(base.discovery.with(discovered_deferred_ranges: seed,
                                                    possible_discovered_deferred_ranges: {}))
    root = Prism.parse(source, filepath: path).value
    described_class.index(root, default_scope: scope).fetch(root).discovered_deferred_ranges
  end

  it "re-walks a path whose bytes differ from the seeded file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "greeter.rb")
      File.write(path, original)
      seed = seed_for(path)
      expect(seed.fetch(path)).not_to be_empty

      ranges = indexed_ranges(mutant, path, seed)

      fresh = described_class.send(:build_deferred_ranges, Prism.parse(mutant).value)
      expect(ranges[path]).to eq(fresh)
      expect(ranges[path]).not_to eq(seed[path])
    end
  end

  it "keeps the seed object when the bytes are identical" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "greeter.rb")
      File.write(path, original)
      seed = seed_for(path)

      expect(indexed_ranges(original, path, seed)).to equal(seed)
    end
  end
end
