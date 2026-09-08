# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Rigor::Cache::RbsEnvironment do
  let(:tmpdir) { Dir.mktmpdir("rigor-rbs-environment-spec-") }
  let(:cache_root) { File.join(tmpdir, ".rigor", "cache") }
  let(:store) { Rigor::Cache::Store.new(root: cache_root) }
  let(:loader) { Rigor::Environment::RbsLoader.new }

  # A loader carrying a non-default value for every `build_env_for` keyword, so a producer that forwards a
  # keyword but not the loader's value is distinguishable from one that forwards both.
  let(:fully_populated_loader) do
    sig_dir = File.join(tmpdir, "forwarding_sig")
    FileUtils.mkdir_p(sig_dir)
    File.write(File.join(sig_dir, "forwarded.rbs"), "class Forwarded[Elem]\nend\n")
    Rigor::Environment::RbsLoader.new(
      libraries: ["set"],
      signature_paths: [sig_dir],
      deferred_signature_paths: [sig_dir],
      virtual_rbs: [["forwarded_virtual.rbs", "class ForwardedVirtual\nend\n"]]
    )
  end

  after { FileUtils.rm_rf(tmpdir) }

  # The keyword parameters of the loader's OWN `build_env_for`. Resolved past `RbsEnvMemo::Interception`,
  # which the suite prepends onto the same singleton with a mirrored signature: reading the mirror would let
  # a keyword added to the loader and to neither the memo nor the producer pass unnoticed.
  def build_env_for_keywords
    owner = Rigor::Environment::RbsLoader.singleton_class
    method = owner.instance_method(:build_env_for)
    method = method.super_method until method.owner == owner
    method.parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
  end

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

    # Issue #849 — the example above pins ONE input; this pins the SHAPE. `build_env_for` is reached from
    # two entries (this producer on a cache miss, the loader's own `build_env` under `--no-cache` and every
    # probe command), and a keyword threaded through the second alone builds a different environment on the
    # default run. Reading the keyword list off the method itself is what makes the next such keyword fail
    # here rather than ship: the expectation has nothing to update when one is added, only the producer does.
    it "forwards every keyword build_env_for accepts" do
      forwarded = nil
      allow(Rigor::Environment::RbsLoader).to receive(:build_env_for).and_wrap_original do |original, **kwargs|
        forwarded = kwargs
        original.call(**kwargs)
      end

      described_class.fetch(loader: fully_populated_loader, store: store)

      missing = build_env_for_keywords - forwarded.keys
      expect(missing).to be_empty,
                         "Cache::RbsEnvironment.compute does not forward #{missing.join(', ')} to " \
                         "RbsLoader.build_env_for. Every cached run — the CLI default — builds its " \
                         "environment through this producer, so an input reaching only the loader's own " \
                         "build_env runs on no real `rigor check` at all (issue #610)."
    end

    # The keyword names double as the loader's reader names, so the producer's own value can be checked
    # against the loader it was handed. A keyword forwarded with a hard-coded default instead of the
    # loader's value fails here — the 0.3.8 failure mode one step short of omitting the keyword.
    it "forwards each keyword's value from the loader it is given" do
      forwarded = nil
      allow(Rigor::Environment::RbsLoader).to receive(:build_env_for).and_wrap_original do |original, **kwargs|
        forwarded = kwargs
        original.call(**kwargs)
      end

      described_class.fetch(loader: fully_populated_loader, store: store)

      expected = build_env_for_keywords.to_h { |keyword| [keyword, fully_populated_loader.public_send(keyword)] }
      expect(forwarded).to eq(expected)
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
