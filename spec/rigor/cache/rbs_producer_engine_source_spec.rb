# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/cache/engine_source"
require "rigor/cache/rbs_class_ancestor_table"
require "rigor/cache/rbs_class_type_param_names"
require "rigor/cache/rbs_constant_table"
require "rigor/cache/rbs_descriptor"
require "rigor/cache/rbs_environment"
require "rigor/cache/rbs_known_class_names"
require "rigor/cache/store"

# Issue #1014 — the five `rbs.*` producers all key through {Rigor::Cache::RbsDescriptor.build}, and that
# key carried the RBS inputs but not the engine that turned them into the cached value. Two of the slots
# were reproduced serving a stale value across an engine edit on a fixture project: an edit to
# `Inference::RbsTypeTranslator.translate` kept `rbs.constant_type_table` warm (a true positive dropped),
# and an edit to the ancestor walk kept `rbs.class_ancestor_table` warm (a `flow.unreachable-clause` false
# positive served) — in both cases on a run whose `analysis.run-diagnostics` key had correctly MISSED.
#
# The examples drive the real producers against a real on-disk {Rigor::Cache::Store}. The engine tree is
# relocated to a temporary directory rather than editing this checkout's own `lib/` from a spec;
# `engine_source_spec.rb` pins the un-relocated default.
RSpec.describe "rbs.* producer cache invalidation on an engine-source edit" do
  producers = {
    "rbs.constant_type_table" => Rigor::Cache::RbsConstantTable,
    "rbs.class_ancestor_table" => Rigor::Cache::RbsClassAncestorTable,
    "rbs.known_class_names" => Rigor::Cache::RbsKnownClassNames,
    "rbs.class_type_param_names" => Rigor::Cache::RbsClassTypeParamNames,
    "rbs.environment" => Rigor::Cache::RbsEnvironment
  }

  let(:tmpdir) { Dir.mktmpdir("rigor-rbs-producer-engine-source-") }
  let(:cache_root) { File.join(tmpdir, ".rigor", "cache") }
  let(:engine_root) { File.join(tmpdir, "engine") }

  after { FileUtils.rm_rf(tmpdir) }

  before do
    FileUtils.mkdir_p(File.join(engine_root, "lib"))
    allow(Rigor::Cache::EngineSource).to receive(:root).and_return(engine_root)
  end

  # One `rigor` process against the same on-disk cache root: its own engine bytes, its own engine-identity
  # memo (`process_identity` is per-process ON PURPOSE, so an example simulating successive processes has
  # to drop it), its own {Rigor::Cache::Store} (a hit must come off disk, not out of the in-process memo),
  # and its own loader (the descriptor is memoised per loader).
  #
  # `compute` stands in for the producer body the engine edit changed: it is what
  # `RbsTypeTranslator.translate` and the ancestor walk are reached through, and stubbing it keeps the
  # example about the KEY rather than about which RBS declaration happens to translate differently.
  def session(producer, build)
    File.write(File.join(engine_root, "lib", "engine.rb"), "# #{build}\n")
    Rigor::Cache::EngineSource.reset_process_identity!
    allow(producer).to receive(:compute).and_return(build)
    store = Rigor::Cache::Store.new(root: cache_root)
    value = producer.fetch(loader: Rigor::Environment::RbsLoader.new, store: store)
    [value, store]
  end

  def producer_stats(store, producer_id)
    store.stats.fetch(:by_producer).fetch(producer_id, {})
  end

  producers.each do |producer_id, producer_class|
    describe producer_id do
      it "recomputes across an engine-source edit instead of serving the writing build's value" do
        first, writing_store = session(producer_class, :old)

        expect(first).to eq(:old)
        # The writing session has to have WRITTEN, or the second session's miss proves only that the first
        # one never filled the slot — which every broken key would also satisfy.
        expect(producer_stats(writing_store, producer_id)).to include(misses: 1, writes: 1)

        value, store = session(producer_class, :new)

        expect(value).to eq(:new)
        expect(producer_stats(store, producer_id)).to include(misses: 1)
      end

      it "still hits while the engine and the signature inputs are unchanged" do
        session(producer_class, :old)

        value, store = session(producer_class, :old)

        expect(value).to eq(:old)
        expect(producer_stats(store, producer_id)).to include(hits: 1, misses: 0)
      end

      # An engine whose source cannot be digested must not be keyed by its RBS inputs alone — that is the
      # weaker key the row exists to replace. `RbsDescriptor.build` lets
      # {Rigor::Cache::EngineSource::Unavailable} out, the loader answers nil, and `RbsCacheProducer.fetch`
      # computes uncached. Asserted per producer rather than once: `rbs.environment` writes a ~1.9 MB blob,
      # so a slot that fell through to a weaker key here would be the most expensive one to get wrong.
      it "runs uncached, writing no entry, when the engine cannot be identified" do
        allow(Rigor::Cache::EngineSource).to receive(:process_identity)
          .and_raise(Rigor::Cache::EngineSource::Unavailable)
        allow(producer_class).to receive(:compute).and_return(:computed)
        store = Rigor::Cache::Store.new(root: cache_root)
        loader = Rigor::Environment::RbsLoader.new

        expect(producer_class.fetch(loader: loader, store: store)).to eq(:computed)
        expect(producer_class.fetch(loader: loader, store: store)).to eq(:computed)

        expect(producer_class).to have_received(:compute).twice
        expect(Dir.glob(File.join(cache_root, producer_id, "**", "*.entry"))).to be_empty
      end
    end
  end

  describe Rigor::Cache::RbsDescriptor do
    it "carries the engine-source row on the producer key while the run key stays free of it" do
      File.write(File.join(engine_root, "lib", "engine.rb"), "# build\n")
      Rigor::Cache::EngineSource.reset_process_identity!
      loader = Rigor::Environment::RbsLoader.new

      keys = described_class.build(loader).configs.map(&:key)

      expect(keys).to include(Rigor::Cache::EngineSource::CONFIG_KEY)
      # `RunCacheKey` contributes the identical row itself; a second one here would duplicate it in the run
      # key and would have to be reconstructible by the boot-slimming probe, which has no loader.
      expect(described_class.config_entries(loader).map(&:key))
        .not_to include(Rigor::Cache::EngineSource::CONFIG_KEY)
    end

    it "adds no row for a version-pinned tree, so a released gem's key is unchanged" do
      allow(Rigor::Cache::EngineSource).to receive(:process_identity).and_return(nil)

      keys = described_class.build(Rigor::Environment::RbsLoader.new).configs.map(&:key)

      expect(keys).not_to include(Rigor::Cache::EngineSource::CONFIG_KEY)
    end
  end
end
