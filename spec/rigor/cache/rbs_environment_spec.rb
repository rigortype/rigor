# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Rigor::Cache::RbsEnvironment do
  let(:tmpdir) { Dir.mktmpdir("rigor-rbs-environment-spec-") }
  let(:cache_root) { File.join(tmpdir, ".rigor", "cache") }
  let(:store) { Rigor::Cache::Store.new(root: cache_root) }
  let(:loader) { Rigor::Environment::RbsLoader.new }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".fetch" do
    it "returns an RBS::Environment with the loaded class declarations" do
      env = described_class.fetch(loader: loader, store: store)
      expect(env).to be_a(RBS::Environment)
      expect(env.class_decls).not_to be_empty
      hash_decl = env.class_decls.find { |k, _| k.to_s == "::Hash" }
      expect(hash_decl).not_to be_nil
    end

    it "writes a single entry under rbs.environment/" do
      described_class.fetch(loader: loader, store: store)
      entries = Dir.glob(File.join(cache_root, "rbs.environment", "**", "*.entry"))
      expect(entries.size).to eq(1)
    end

    it "skips the build on a cache hit" do
      allow(Rigor::Environment::RbsLoader).to receive(:build_env_for).and_call_original
      described_class.fetch(loader: loader, store: store)
      described_class.fetch(loader: loader, store: store)
      expect(Rigor::Environment::RbsLoader).to have_received(:build_env_for).once
    end

    # Issue #610 — this producer is the build every cached run takes, and 0.3.8 called `build_env_for`
    # without the deferred (plugin-contributed) list, so the arity stand-down ran only under `--no-cache`.
    # Every input the loader's own `build_env` passes has to be passed from here too.
    it "hands the loader's deferred signature paths to the build on a miss" do
      sig_dir = File.join(tmpdir, "plugin_sig")
      Dir.mkdir(sig_dir)
      File.write(File.join(sig_dir, "relation.rbs"), "class Relation[Elem]\nend\n")
      deferred_loader = Rigor::Environment::RbsLoader.new(
        signature_paths: [sig_dir], deferred_signature_paths: [sig_dir]
      )
      allow(Rigor::Environment::RbsLoader).to receive(:build_env_for).and_call_original

      described_class.fetch(loader: deferred_loader, store: store)

      expect(Rigor::Environment::RbsLoader).to have_received(:build_env_for)
        .with(hash_including(deferred_signature_paths: deferred_loader.deferred_signature_paths))
    end

    it "produces an env that is still usable for instance_method lookups after cache hit" do
      described_class.fetch(loader: loader, store: store)
      reloaded = described_class.fetch(loader: loader, store: store)

      builder = RBS::DefinitionBuilder.new(env: reloaded)
      definition = builder.build_instance(RBS::TypeName.parse("::Hash"))
      expect(definition).to be_a(RBS::Definition)
      expect(definition.methods[:fetch]).not_to be_nil
    end
  end
end
